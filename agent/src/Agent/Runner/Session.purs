-- | Session runner: startup, ReACT loop, session listing, resumption.
-- | Wires together all Programs and Services.
-- | Covers A1, A2, A2a, A19, A21, A22, A24–A27, A31, A40–A42.
module Agent.Runner.Session
    ( runNewSession
    , runResumeSession
    , runListSessions
    ) where

import Prelude

import Data.Array as Array
import Data.Array.NonEmpty as NEA
import Data.Argonaut.Core as J
import Data.Argonaut.Parser as JP
import Data.Either (Either(..), fromRight)
import Data.Foldable (for_, foldl, foldr)
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Set (Set)
import Data.Set as Set
import Data.String as String
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Aff, attempt)
import Effect.Class (liftEffect)
import Effect.Exception (message)
import Foreign.Object as FO
import Node.Encoding (Encoding(..))
import Node.FS.Aff as FS
import Node.Process as Process

import Agent.Types
    ( WorkspacePath(..)
    , SessionId(..)
    , ModelName(..)
    , TokenCount(..)
    , HunkId(..)
    , RawJulia(..)
    , Config
    , ConversationHistory(..)
    , LlmResponse(..)
    , Message(..)
    , ToolCall
    , ToolCallId(..)
    , AppError(..)
    , LogEvent(..)
    )
import Agent.Programs.Config (parseConfig, readApiKey, placeDefaultConfigs)
import Agent.Programs.SessionLog
    ( allocateSessionId, writeLogEvent, readLogEvents
    , sessionDescription, reconstructHistory
    )
import Agent.Programs.SessionListing (formatSessionListing, SessionMeta)
import Agent.Programs.SessionResume (loadSessionForResume, ResumeResult(..))
import Agent.Programs.Template (substituteTemplate)
import Agent.Programs.ReactStep (reactStep, NextStep(..))
import Agent.Programs.Compaction (buildCompactionPlan)
import Agent.Programs.ToolOutput (processToolOutput)
import Agent.Programs.GitDiff (runGitDiff, parseHunkIds)
import Agent.Programs.GitCommit
    ( CommitWhat(..), validateCommitWhat, runGitCommit )
import Agent.Programs.JuliaDefs (extractDefs)
import Agent.Programs.ReplSerialize (buildSerializationSnippet)
import Agent.Programs.SandboxPreflight
    ( SandboxPreflightResult(..)
    , runSandboxPreflight
    )
import Agent.Services.Terminal (printLn, printStr, printErr)
import Agent.Services.Stdin (readLine, writePrompt)
import Agent.Services.Sandbox (SandboxHandle, spawnSandbox)
import Agent.Services.Jupyter
    ( KernelHandle, connectKernel, executeCode, interruptKernel, closeKernel )
import Agent.Services.Llm (callLlm)

-- ---------------------------------------------------------------------------
-- FFI
-- ---------------------------------------------------------------------------

foreign import nowIsoImpl :: Effect String

getTs :: Aff String
getTs = liftEffect nowIsoImpl

-- ---------------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------------

-- | Produce a one-or-more-line summary of a tool call's input for display.
-- | For julia_repl, shows the code (capped at 10 lines).
-- | For git tools, shows the relevant fields.
formatToolInput :: String -> String -> String
formatToolInput "julia_repl" input =
    let code = fromMaybe input do
            json <- case JP.jsonParser input of
                Right j -> Just j
                Left _  -> Nothing
            obj  <- J.toObject json
            val  <- FO.lookup "code" obj
            J.toString val
        ls     = String.split (String.Pattern "\n") code
        kept   = Array.take 10 ls
        more   = Array.length ls > 10
    in String.joinWith "\n" kept <> if more then "\n..." else ""
formatToolInput "git_diff" _ = ""
formatToolInput "git_commit" input =
    let msg = do
            json   <- case JP.jsonParser input of
                Right j -> Just j
                Left _  -> Nothing
            obj    <- J.toObject json
            msgVal <- FO.lookup "message" obj
            J.toString msgVal
        what = do
            json    <- case JP.jsonParser input of
                Right j -> Just j
                Left _  -> Nothing
            obj     <- J.toObject json
            whatVal <- FO.lookup "what" obj
            J.toString whatVal
    in "message: " <> fromMaybe "(none)" msg
       <> "  what: " <> fromMaybe "all" what
formatToolInput _ input = input

estimateTokens :: String -> TokenCount
estimateTokens s = TokenCount (max 1 (String.length s / 4))

addMsg :: ConversationHistory -> Message -> ConversationHistory
addMsg (ConversationHistory h) msg =
    ConversationHistory
        { messages: h.messages <>
            [{ message: msg, tokens: estimateTokens (msgContent msg) }]
        }

msgContent :: Message -> String
msgContent (SystemMessage r)    = r.content
msgContent (UserMessage r)      = r.content
msgContent (AssistantMessage r) = r.content
msgContent (ToolResultMessage r) = r.output

unwrapSid :: SessionId -> Int
unwrapSid (SessionId n) = n

unwrapTc :: TokenCount -> Int
unwrapTc (TokenCount n) = n

addTc :: TokenCount -> TokenCount -> TokenCount
addTc (TokenCount a) (TokenCount b) = TokenCount (a + b)

totalTokens :: ConversationHistory -> TokenCount
totalTokens (ConversationHistory h) =
    foldl addTc (TokenCount 0) (map _.tokens h.messages)

exit1 :: forall a. Aff a
exit1 = liftEffect (Process.exit' 1)

-- ---------------------------------------------------------------------------
-- A41: list sessions
-- ---------------------------------------------------------------------------

runListSessions :: WorkspacePath -> Aff Unit
runListSessions ws@(WorkspacePath wp) = do
    dirResult <- attempt (FS.readdir (wp <> "/.7aigent/sessions"))
    case dirResult of
        Left _ -> liftEffect $ printLn "No sessions found."
        Right entries -> do
            let sids = Array.sort (Array.mapMaybe Int.fromString entries)
            metas <- traverse (loadMeta ws) sids
            let listing = formatSessionListing (Array.catMaybes metas)
            liftEffect $ printLn listing

loadMeta :: WorkspacePath -> Int -> Aff (Maybe SessionMeta)
loadMeta ws n = do
    evtsR <- readLogEvents ws (SessionId n)
    case evtsR of
        Left _ -> pure Nothing
        Right evts ->
            let startEv  = Array.find isSessionStart evts
                firstMsg = Array.find isUserMessage evts
                endEv    = Array.find isSessionEnd evts
            in case startEv of
                Just (SessionStart r) -> pure $ Just
                    { id: r.id
                    , started: String.take 16 r.timestamp
                    , duration: computeDuration r.timestamp endEv
                    , description: sessionDescription
                        (fromMaybe "(no description)"
                            (firstMsg >>= userMsgContent))
                    }
                _ -> pure Nothing
  where
    userMsgContent (EvtUserMessage m) = Just m.content
    userMsgContent _                  = Nothing
    isSessionStart (SessionStart _)   = true
    isSessionStart _                  = false
    isUserMessage (EvtUserMessage _)  = true
    isUserMessage _                   = false
    isSessionEnd (SessionEnd _)       = true
    isSessionEnd _                    = false

computeDuration :: String -> Maybe LogEvent -> Maybe String
computeDuration _ Nothing = Nothing
computeDuration _start (Just (SessionEnd _)) = Nothing  -- would need full date math
computeDuration _ _ = Nothing

-- ---------------------------------------------------------------------------
-- A40: start a new session
-- ---------------------------------------------------------------------------

runNewSession :: WorkspacePath -> Maybe String -> Aff Unit
runNewSession ws prompt = startSession ws Nothing (ConversationHistory { messages: [] }) prompt

-- ---------------------------------------------------------------------------
-- A42: resume a session
-- ---------------------------------------------------------------------------

runResumeSession :: WorkspacePath -> SessionId -> Maybe String -> Aff Unit
runResumeSession ws sid prompt = do
    result <- loadSessionForResume ws sid
    case result of
        ResumeError msg -> do
            liftEffect $ printErr ("Error resuming session: " <> msg)
            exit1
        ResumeReady r -> do
            liftEffect $ for_ r.warnings printErr
            startSession ws (Just sid) r.history prompt

-- ---------------------------------------------------------------------------
-- Core session startup
-- ---------------------------------------------------------------------------

startSession :: WorkspacePath -> Maybe SessionId -> ConversationHistory -> Maybe String -> Aff Unit
startSession ws@(WorkspacePath wp) resumedFrom existingHistory prompt = do

    -- A2a: place default config files
    placed <- placeDefaultConfigs ws
    liftEffect $ for_ placed printLn

    -- A37-A39: parse config
    configR <- attempt (FS.readTextFile UTF8 (wp <> "/.7aigent/config.toml"))
    config <- case configR of
        Left _ -> do
            liftEffect $ printErr "Error: .7aigent/config.toml not found. Run 7aigent once to create it."
            exit1
        Right text -> case parseConfig text of
            Left (PlaceholderValue msg) -> do
                liftEffect $ printErr ("Error: " <> msg <> "\nEdit .7aigent/config.toml before starting.")
                exit1
            Left err -> do
                liftEffect $ printErr ("Config error: " <> show err)
                exit1
            Right c -> pure c

    apiKeyR <- readApiKey config.apiKeyEnv
    apiKey <- case apiKeyR of
        Left err -> do
            liftEffect $ printErr ("Error: " <> show err)
            exit1
        Right k -> pure k

    preflight <- runSandboxPreflight ws promptSandboxPreflight
    case preflight of
        HaltStartup -> do
            liftEffect $ printErr "Startup halted before sandbox launch."
            exit1
        ContinueStartup ->
            pure unit

    -- A24: allocate session ID
    sessionId <- allocateSessionId ws

    -- A2: spawn sandbox
    liftEffect $ printStr "Starting sandbox... "
    sbxR <- spawnSandbox ws
    sandbox <- case sbxR of
        Left err -> do
            liftEffect $ printErr ("\nError: " <> show err)
            exit1
        Right s -> do
            liftEffect $ printLn "OK"
            pure s

    -- Connect to Jupyter kernel
    kernelR <- connectKernel sandbox.kernelJsonPath
    kernel <- case kernelR of
        Left err -> do
            liftEffect $ sandbox.kill
            liftEffect $ printErr ("Error: " <> show err)
            exit1
        Right k -> pure k

    -- A19: run Julia startup sequence
    startupOutput <- runStartupSequence ws kernel

    -- A21-A22: build system prompt
    systemPrompt <- buildSystemPrompt ws config startupOutput

    -- Log session start
    ts <- getTs
    writeLogEvent ws sessionId (SessionStart
        { id: sessionId
        , timestamp: ts
        , workspace: wp
        , model: config.model
        , resumedFrom
        })

    -- Build initial conversation history
    let initHistory = case resumedFrom of
            Nothing ->
                addMsg (ConversationHistory { messages: [] })
                    (SystemMessage { content: systemPrompt })
            Just _ ->
                -- Replace the system message's datetime placeholder on resume
                existingHistory

    -- Enter the main user ↔ LLM loop
    runUserLoop ws sessionId config apiKey kernel initHistory Set.empty prompt

    -- Cleanup
    liftEffect $ closeKernel kernel
    liftEffect $ sandbox.kill

-- ---------------------------------------------------------------------------
-- A19: Julia startup sequence
-- ---------------------------------------------------------------------------

runStartupSequence :: WorkspacePath -> KernelHandle -> Aff String
runStartupSequence (WorkspacePath wp) kernel = do
    liftEffect $ printStr "Loading CodeTree... "
    out1 <- executeCode kernel (RawJulia "using CodeTree") (const (pure unit))
    liftEffect $ printLn "OK"

    startupR <- attempt (FS.readTextFile UTF8 (wp <> "/.7aigent/startup.jl"))
    let code = case startupR of
            Left _ -> ""
            Right t -> t
    if String.null (String.trim code)
        then pure out1
        else do
            liftEffect $ printStr "Running startup.jl... "
            out2 <- executeCode kernel (RawJulia code) (const (pure unit))
            liftEffect $ printLn "OK"
            pure (out1 <> "\n" <> out2)

promptSandboxPreflight :: String -> Aff String
promptSandboxPreflight message = do
    liftEffect $ printLn ""
    liftEffect $ printLn message
    liftEffect $ writePrompt "> "
    readLine

-- ---------------------------------------------------------------------------
-- A21-A22: system prompt template
-- ---------------------------------------------------------------------------

buildSystemPrompt :: WorkspacePath -> Config -> String -> Aff String
buildSystemPrompt (WorkspacePath wp) config startupOutput = do
    tmplR <- attempt (FS.readTextFile UTF8 (wp <> "/.7aigent/system_prompt.md"))
    let tmpl = case tmplR of
            Left _  -> ""
            Right t -> t

    agentsMdR <- attempt (FS.readTextFile UTF8 (wp <> "/AGENTS.md"))
    let agentsMd = case agentsMdR of
            Left _  -> ""
            Right t -> t

    ts <- getTs
    let (ModelName model) = config.model
    let vars = Map.fromFoldable
            [ Tuple "initial_repl_output" startupOutput
            , Tuple "agents-md" agentsMd
            , Tuple "datetime" ts
            , Tuple "model" model
            ]
    case substituteTemplate vars tmpl of
        Left err -> do
            liftEffect $ printErr ("Error in system_prompt.md: " <> show err)
            exit1
        Right s -> pure s

-- ---------------------------------------------------------------------------
-- A1: outer loop — user prompt ↔ LLM loop
-- ---------------------------------------------------------------------------

runUserLoop
    :: WorkspacePath
    -> SessionId
    -> Config
    -> String
    -> KernelHandle
    -> ConversationHistory
    -> Set HunkId
    -> Maybe String
    -> Aff Unit
runUserLoop ws sessionId config apiKey kernel history knownHunks maybePrompt = do
    line <- case maybePrompt of
        Just p -> do
            liftEffect $ printLn ("\n> " <> p)
            pure p
        Nothing -> do
            liftEffect $ writePrompt "\n> "
            readLine

    -- EOF → clean exit
    when (String.null line) do
        finishSession ws sessionId kernel history "eof"
        liftEffect $ Process.exit' 0

    ts <- getTs
    writeLogEvent ws sessionId (EvtUserMessage { timestamp: ts, content: line })

    let history' = addMsg history (UserMessage { content: line })
    knownHunks' <-
        runReactLoop ws sessionId config apiKey kernel history' (TokenCount 0) knownHunks

    case maybePrompt of
        -- Single-turn mode: exit after the turn completes
        Just _ -> do
            finishSession ws sessionId kernel history' "prompt"
            liftEffect $ Process.exit' 0
        -- Interactive mode: loop back to wait for the next user message
        Nothing ->
            runUserLoop ws sessionId config apiKey kernel history' knownHunks' Nothing

-- ---------------------------------------------------------------------------
-- A1: inner loop — LLM calls + tool execution
-- ---------------------------------------------------------------------------

runReactLoop
    :: WorkspacePath
    -> SessionId
    -> Config
    -> String
    -> KernelHandle
    -> ConversationHistory
    -> TokenCount
    -> Set HunkId
    -> Aff (Set HunkId)
runReactLoop ws sessionId config apiKey kernel history accumulated knownHunks = do
    liftEffect $ printLn ""
    llmR <- callLlm config apiKey history (liftEffect <<< printStr)
    liftEffect $ printLn ""

    case llmR of
        Left err -> do
            liftEffect $ printErr ("LLM error: " <> show err)
            pure knownHunks

        Right response@(LlmResponse r) -> do
            ts <- getTs
            writeLogEvent ws sessionId
                (EvtLlmResponse { timestamp: ts, content: r.content })

            let newAcc = addTc accumulated r.inputTokens
            let history' = addMsg history
                    (AssistantMessage { content: r.content, toolCalls: r.toolCalls })

            case reactStep config newAcc history' response of

                PromptUser ->
                    pure knownHunks

                CompactThenPromptUser -> do
                    _ <- doCompact ws sessionId config apiKey history'
                    pure knownHunks

                ExecuteTool tc -> do
                    Tuple history'' hunks' <-
                        doTool ws sessionId config kernel history' tc knownHunks
                    runReactLoop ws sessionId config apiKey kernel history'' newAcc hunks'

                ExecuteToolThenCompact tc -> do
                    Tuple history'' hunks' <-
                        doTool ws sessionId config kernel history' tc knownHunks
                    history''' <- doCompact ws sessionId config apiKey history''
                    runReactLoop ws sessionId config apiKey kernel history''' (TokenCount 0) hunks'

                ExecuteToolThenEndTurn tc -> do
                    Tuple _ hunks' <-
                        doTool ws sessionId config kernel history' tc knownHunks
                    liftEffect $ printLn "\n[Token limit reached — please continue]"
                    pure hunks'

-- ---------------------------------------------------------------------------
-- Tool dispatch (A3-A6)
-- ---------------------------------------------------------------------------

doTool
    :: WorkspacePath
    -> SessionId
    -> Config
    -> KernelHandle
    -> ConversationHistory
    -> ToolCall
    -> Set HunkId
    -> Aff (Tuple ConversationHistory (Set HunkId))
doTool ws sessionId config kernel history tc knownHunks = do
    ts <- getTs
    writeLogEvent ws sessionId (EvtToolCall
        { timestamp: ts
        , toolName: tc.name
        , toolCallId: tc.id
        , input: tc.input
        })
    liftEffect $ printLn ("\n[Tool: " <> tc.name <> "]")
    let inputSummary = formatToolInput tc.name tc.input
    when (not (String.null inputSummary)) do
        liftEffect $ printLn inputSummary

    Tuple rawOut hunks' <- dispatchTool ws config kernel tc knownHunks

    let proc = processToolOutput config.outputThresholdChars rawOut
    liftEffect $ printLn proc.displayText

    ts2 <- getTs
    writeLogEvent ws sessionId (ToolResult
        { timestamp: ts2
        , toolCallId: tc.id
        , output: proc.fullOutput
        , truncated: proc.truncated
        })

    let toolMsg = ToolResultMessage { toolCallId: tc.id, output: proc.llmFacing }
    pure (Tuple (addMsg history toolMsg) hunks')

dispatchTool
    :: WorkspacePath
    -> Config
    -> KernelHandle
    -> ToolCall
    -> Set HunkId
    -> Aff (Tuple String (Set HunkId))
dispatchTool ws _config kernel tc knownHunks =
    case tc.name of
        "julia_repl" -> do
            let code = fromMaybe tc.input do
                    json <- case JP.jsonParser tc.input of
                        Right j -> Just j
                        Left _  -> Nothing
                    obj  <- J.toObject json
                    val  <- FO.lookup "code" obj
                    J.toString val
            out <- executeCode kernel (RawJulia code) (const (pure unit))
            pure (Tuple out knownHunks)

        "git_diff" -> do
            diff <- runGitDiff ws
            let ids = parseHunkIds diff
            pure (Tuple diff ids)

        "git_commit" -> do
            let parsed = do
                    json <- case JP.jsonParser tc.input of
                        Right j -> Just j
                        Left _  -> Nothing
                    obj <- J.toObject json
                    whatJson <- FO.lookup "what" obj
                    let whatStr = fromMaybe (J.stringify whatJson)
                                    (J.toString whatJson)
                    let msg = fromMaybe "Commit" do
                                  msgJson <- FO.lookup "message" obj
                                  J.toString msgJson
                    let body = do
                                  bodyJson <- FO.lookup "body" obj
                                  J.toString bodyJson
                    pure { what: whatStr, message: msg, body }
            case parsed of
                Nothing -> pure (Tuple "Invalid git_commit input" knownHunks)
                Just r ->
                    case parseCommitWhat r.what knownHunks of
                        Left err -> pure (Tuple (show err) knownHunks)
                        Right cw -> do
                            commitR <- runGitCommit ws cw r.message r.body
                            case commitR of
                                Left err  -> pure (Tuple (show err) knownHunks)
                                Right msg -> pure (Tuple msg Set.empty)

        other ->
            pure (Tuple ("Unknown tool: " <> other) knownHunks)

-- | Parse the `what` field from a git_commit tool call.
parseCommitWhat :: String -> Set HunkId -> Either AppError CommitWhat
parseCommitWhat input knownHunks
    | input == "all" || input == "\"all\"" = Right CommitAll
    | otherwise =
        case JP.jsonParser input of
            Left _ -> Left (StaleHunkIds [])
            Right json ->
                case J.toArray json of
                    Nothing -> Left (StaleHunkIds [])
                    Just arr ->
                        let ids = Array.mapMaybe (map HunkId <<< J.toString) arr
                        in case NEA.fromArray ids of
                            Nothing -> Left (StaleHunkIds [])
                            Just ne -> validateCommitWhat knownHunks (CommitHunks ne)

-- ---------------------------------------------------------------------------
-- Compaction (A33-A36)
-- ---------------------------------------------------------------------------

doCompact
    :: WorkspacePath
    -> SessionId
    -> Config
    -> String
    -> ConversationHistory
    -> Aff ConversationHistory
doCompact ws@(WorkspacePath wp) sessionId config apiKey history = do
    compactTmplR <- attempt (FS.readTextFile UTF8 (wp <> "/.7aigent/compaction_prompt.md"))
    summaryTmplR <- attempt (FS.readTextFile UTF8 (wp <> "/.7aigent/summary_message.md"))
    let compactTmpl = case compactTmplR of
            Left _ -> "Summarise:\n{{compacted_messages}}"
            Right t -> t
    let summaryTmpl = case summaryTmplR of
            Left _ -> "{{summary}}"
            Right t -> t

    let plan = buildCompactionPlan config.preserveInitial config.preserveFinal history
    let render msgs = String.joinWith "\n---\n" (map showMsg msgs)
    let promptVars = Map.fromFoldable
            [ Tuple "initial_messages"  (render plan.initialBlock)
            , Tuple "compacted_messages" (render plan.compactedBlock)
            , Tuple "final_messages"    (render plan.finalBlock)
            ]
    let promptText = case substituteTemplate promptVars compactTmpl of
            Left _ -> render plan.compactedBlock
            Right t -> t

    let compactHistory = ConversationHistory
            { messages: [{ message: UserMessage { content: promptText }, tokens: TokenCount 0 }] }

    liftEffect $ printStr "[Compacting context...]"
    summaryR <- callLlm config apiKey compactHistory (const (pure unit))
    liftEffect $ printLn ""

    case summaryR of
        Left _ -> pure history
        Right (LlmResponse r) -> do
            let summary = r.content
            let summaryMsg = case substituteTemplate
                    (Map.fromFoldable [Tuple "summary" summary]) summaryTmpl of
                    Left _ -> summary
                    Right t -> t

            ts <- getTs
            writeLogEvent ws sessionId (Compaction
                { timestamp: ts
                , summary
                , initialMessageCount:  Array.length plan.initialBlock
                , compactedMessageCount: Array.length plan.compactedBlock
                , finalMessageCount:    Array.length plan.finalBlock
                , totalTokensBefore:    unwrapTc (totalTokens history)
                })

            let newMsgs =
                    map toE plan.initialBlock <>
                    [{ message: UserMessage { content: summaryMsg }
                     , tokens: estimateTokens summaryMsg
                     }] <>
                    map toE plan.finalBlock
            pure (ConversationHistory { messages: newMsgs })
  where
    toE m = { message: m, tokens: estimateTokens (msgContent m) }

showMsg :: Message -> String
showMsg (SystemMessage r)    = "[system] " <> r.content
showMsg (UserMessage r)      = "[user] " <> r.content
showMsg (AssistantMessage r) = "[assistant] " <> r.content
showMsg (ToolResultMessage r) = "[tool] " <> r.output

-- ---------------------------------------------------------------------------
-- A28-A30: session teardown
-- ---------------------------------------------------------------------------

finishSession
    :: WorkspacePath
    -> SessionId
    -> KernelHandle
    -> ConversationHistory
    -> String
    -> Aff Unit
finishSession ws@(WorkspacePath wp) sessionId kernel _history reason = do
    evtsR <- readLogEvents ws sessionId
    let defs = case evtsR of
            Left _ -> []
            Right evts -> extractDefs evts
    let defsPath = wp <> "/.7aigent/sessions/"
            <> show (unwrapSid sessionId) <> "/julia_defs.jl"
    _ <- attempt (FS.writeTextFile UTF8 defsPath (String.joinWith "\n" defs))

    let snippet = buildSerializationSnippet sessionId wp
    _ <- attempt (executeCode kernel (RawJulia snippet) (const (pure unit)))

    ts <- getTs
    writeLogEvent ws sessionId (SessionEnd { timestamp: ts, reason })
