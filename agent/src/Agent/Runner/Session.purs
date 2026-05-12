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
import Node.Encoding (Encoding(..))
import Node.FS.Aff as FS
import Node.Process as Process

import Agent.Types
    ( WorkspacePath(..)
    , Timestamp(..)
    , SessionId(..)
    , SessionEndReason(..)
    , ModelName(..)
    , TokenCount(..)
    , HunkId(..)
    , RawJulia(..)
    , Config
    , ConversationHistory(..)
    , LlmResponse(..)
    , Message(..)
    , AppError(..)
    , LogEvent(..)
    , extractContent
    , renderTimestamp
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
import Agent.Programs.Startup (interpretStartupExecution)
import Agent.Programs.JuliaDefs (extractDefs)
import Agent.Programs.ReplSerialize
    ( buildRestoreSnippet
    , buildSerializationSnippet
    )
import Agent.Programs.SandboxPreflight
    ( SandboxPreflightResult(..)
    , runSandboxPreflight
    )
import Agent.Runner.ToolExecution (doTool)
import Agent.Services.Terminal (printLn, printStr, printErr)
import Agent.Services.Stdin (readLine, writePrompt)
import Agent.Services.Sandbox (SandboxHandle, spawnSandbox)
import Agent.Services.Jupyter
    ( KernelHandle, connectKernel, executeCode, executeCodeDetailed, interruptKernel, closeKernel )
import Agent.Services.Llm (LlmUsage, callLlm)

-- ---------------------------------------------------------------------------
-- FFI
-- ---------------------------------------------------------------------------

foreign import nowIsoImpl :: Effect String

getTs :: Aff Timestamp
getTs = Timestamp <$> liftEffect nowIsoImpl

-- ---------------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------------

estimateTokens :: String -> TokenCount
estimateTokens s = TokenCount (max 1 (String.length s / 4))

addMsg :: ConversationHistory -> Message -> ConversationHistory
addMsg (ConversationHistory h) msg =
    ConversationHistory
        { messages: h.messages <>
            [{ message: msg, tokens: estimateTokens (extractContent msg) }]
        }

unwrapSid :: SessionId -> Int
unwrapSid (SessionId n) = n

unwrapTc :: TokenCount -> Int
unwrapTc (TokenCount n) = n

addTc :: TokenCount -> TokenCount -> TokenCount
addTc (TokenCount a) (TokenCount b) = TokenCount (a + b)

totalTokens :: ConversationHistory -> TokenCount
totalTokens (ConversationHistory h) =
    foldl addTc (TokenCount 0) (map _.tokens h.messages)

zeroLlmUsage :: LlmUsage
zeroLlmUsage =
    { inputTokens: TokenCount 0
    , cachedInputTokens: TokenCount 0
    , outputTokens: TokenCount 0
    }

type ReactLoopResult =
    { history :: ConversationHistory
    , knownHunks :: Set HunkId
    , usageTotals :: LlmUsage
    , error :: Maybe AppError
    }

addLlmUsage :: LlmUsage -> LlmUsage -> LlmUsage
addLlmUsage totals usage =
    { inputTokens: addTc totals.inputTokens usage.inputTokens
    , cachedInputTokens: addTc totals.cachedInputTokens usage.cachedInputTokens
    , outputTokens: addTc totals.outputTokens usage.outputTokens
    }

renderSessionTokenUsage :: LlmUsage -> String
renderSessionTokenUsage usage =
    "[session tokens] input="
        <> show (unwrapTc usage.inputTokens)
        <> " cached="
        <> show (unwrapTc usage.cachedInputTokens)
        <> " output="
        <> show (unwrapTc usage.outputTokens)

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
                    , started: String.take 16 (renderTimestamp r.timestamp)
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

computeDuration :: Timestamp -> Maybe LogEvent -> Maybe String
computeDuration _ Nothing = Nothing
computeDuration _start (Just (SessionEnd _)) = Nothing  -- would need full date math
computeDuration _ _ = Nothing

-- ---------------------------------------------------------------------------
-- A40: start a new session
-- ---------------------------------------------------------------------------

runNewSession :: WorkspacePath -> Maybe String -> Aff Unit
runNewSession ws prompt =
    startSession ws Nothing (ConversationHistory { messages: [] }) Nothing prompt

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
            startSession ws (Just sid) r.history
                (Just { juliaDefs: r.juliaDefs, hasStateFile: r.hasStateFile })
                prompt

-- ---------------------------------------------------------------------------
-- Core session startup
-- ---------------------------------------------------------------------------

startSession
    :: WorkspacePath
    -> Maybe SessionId
    -> ConversationHistory
    -> Maybe { juliaDefs :: Array String, hasStateFile :: Boolean }
    -> Maybe String
    -> Aff Unit
startSession ws@(WorkspacePath wp) resumedFrom existingHistory resumeState prompt = do

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

    let cleanupSandbox = do
            liftEffect $ closeKernel kernel
            liftEffect $ sandbox.kill

    -- A19: run Julia startup sequence
    startupResult <- runStartupSequence ws kernel
    startupOutput <- case startupResult of
        Left _ -> do
            cleanupSandbox
            exit1
        Right output ->
            pure output

    case resumedFrom, resumeState of
        Just priorSid, Just resumeData ->
            restoreResumedSession ws priorSid kernel resumeData
        _, _ ->
            pure unit

    -- A21-A22: build system prompt
    systemPromptR <- buildSystemPrompt ws config startupOutput
    systemPrompt <- case systemPromptR of
        Left _ -> do
            cleanupSandbox
            exit1
        Right promptText ->
            pure promptText

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
    exitCode <- runUserLoop
        ws sessionId config apiKey kernel initHistory Set.empty zeroLlmUsage prompt

    -- Cleanup
    cleanupSandbox
    liftEffect $ Process.exit' exitCode

-- ---------------------------------------------------------------------------
-- A19: Julia startup sequence
-- ---------------------------------------------------------------------------

runStartupSequence :: WorkspacePath -> KernelHandle -> Aff (Either AppError String)
runStartupSequence (WorkspacePath wp) kernel = do
    out1 <- runStartupExpression kernel "Loading CodeTree" "using CodeTree"
    case out1 of
        Left err ->
            pure (Left err)
        Right startupPrelude -> do
            startupR <- attempt (FS.readTextFile UTF8 (wp <> "/.7aigent/startup.jl"))
            let code = case startupR of
                    Left _ -> ""
                    Right t -> t
            if String.null (String.trim code)
                then pure (Right startupPrelude)
                else do
                    out2 <- runStartupExpression kernel "Running startup.jl" code
                    pure (map (\s -> startupPrelude <> "\n" <> s) out2)

runStartupExpression :: KernelHandle -> String -> String -> Aff (Either AppError String)
runStartupExpression kernel label code = do
    liftEffect $ printStr (label <> "... ")
    result <- executeCodeDetailed kernel (RawJulia code) (const (pure unit))
    case interpretStartupExecution result of
        Left (StartupExpressionError msg) -> do
            liftEffect $ printErr ("\n" <> msg)
            pure (Left (StartupExpressionError msg))
        Left err -> do
            liftEffect $ printErr ("\n" <> show err)
            pure (Left err)
        Right output -> do
            liftEffect $ printLn "OK"
            pure (Right output)

promptSandboxPreflight :: String -> Aff String
promptSandboxPreflight message = do
    liftEffect $ printLn ""
    liftEffect $ printLn message
    liftEffect $ writePrompt "> "
    readLine

restoreResumedSession
    :: WorkspacePath
    -> SessionId
    -> KernelHandle
    -> { juliaDefs :: Array String, hasStateFile :: Boolean }
    -> Aff Unit
restoreResumedSession (WorkspacePath wp) priorSid kernel resumeData = do
    for_ resumeData.juliaDefs \expr -> do
        out <- executeCode kernel (RawJulia (wrapDefinitionReplay expr)) (const (pure unit))
        let cleaned = String.trim out
        when (not (String.null cleaned)) do
            liftEffect $ printErr cleaned

    when resumeData.hasStateFile do
        out <- executeCode kernel
            (RawJulia (buildRestoreSnippet priorSid wp))
            (const (pure unit))
        let warnings = Array.filter (not <<< String.null)
                (map String.trim (String.split (String.Pattern "\n") out))
        liftEffect $ for_ warnings printErr

wrapDefinitionReplay :: String -> String
wrapDefinitionReplay expr = String.joinWith "\n"
    [ "try"
    , expr
    , "catch e"
    , "    println(\"Warning: failed to replay definition: \" * sprint(showerror, e))"
    , "end"
    ]

-- ---------------------------------------------------------------------------
-- A21-A22: system prompt template
-- ---------------------------------------------------------------------------

buildSystemPrompt :: WorkspacePath -> Config -> String -> Aff (Either AppError String)
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
            , Tuple "datetime" (renderTimestamp ts)
            , Tuple "model" model
            ]
    case substituteTemplate vars tmpl of
        Left err -> do
            liftEffect $ printErr ("Error in system_prompt.md: " <> show err)
            pure (Left (TemplateError ("system_prompt.md: " <> show err)))
        Right s -> pure (Right s)

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
    -> LlmUsage
    -> Maybe String
    -> Aff Int
runUserLoop ws sessionId config apiKey kernel history knownHunks usageTotals maybePrompt = do
    line <- case maybePrompt of
        Just p -> do
            liftEffect $ printLn ("\n> " <> p)
            pure p
        Nothing -> do
            liftEffect $ writePrompt "\n> "
            readLine

    -- EOF → clean exit
    when (String.null line) do
        finishSession ws sessionId kernel history SessionEndedEof
    if String.null line then
        pure 0
    else do

        ts <- getTs
        writeLogEvent ws sessionId (EvtUserMessage { timestamp: ts, content: line })

        let history' = addMsg history (UserMessage { content: line })
        loopResult <-
            runReactLoop ws sessionId config apiKey kernel history'
                (TokenCount 0) knownHunks usageTotals
        liftEffect $ printLn (renderSessionTokenUsage loopResult.usageTotals)

        case loopResult.error, maybePrompt of
            Just _, Just _ -> do
                finishSession ws sessionId kernel loopResult.history SessionEndedError
                pure 1
            Just _, Nothing ->
                runUserLoop ws sessionId config apiKey kernel loopResult.history
                    loopResult.knownHunks loopResult.usageTotals Nothing
            Nothing, Just _ -> do
                finishSession ws sessionId kernel loopResult.history SessionEndedPrompt
                pure 0
            Nothing, Nothing ->
                runUserLoop ws sessionId config apiKey kernel loopResult.history
                    loopResult.knownHunks loopResult.usageTotals Nothing

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
    -> LlmUsage
    -> Aff ReactLoopResult
runReactLoop ws sessionId config apiKey kernel history accumulated knownHunks usageTotals = do
    liftEffect $ printLn ""
    llmR <- callLlm config apiKey history (liftEffect <<< printStr)
    liftEffect $ printLn ""

    case llmR of
        Left err -> do
            liftEffect $ printErr ("LLM error: " <> show err)
            pure { history, knownHunks, usageTotals, error: Just err }

        Right result -> case result.response of
            response@(LlmResponse r) -> do
                ts <- getTs
                writeLogEvent ws sessionId
                    (EvtLlmResponse { timestamp: ts, content: r.content })

                let usageTotals' = addLlmUsage usageTotals result.usage
                writeLogEvent ws sessionId (TokenUsage
                    { timestamp: ts
                    , inputTokens: result.usage.inputTokens
                    , cachedInputTokens: result.usage.cachedInputTokens
                    , outputTokens: result.usage.outputTokens
                    , totalSessionInputTokens: usageTotals'.inputTokens
                    , totalSessionCachedInputTokens: usageTotals'.cachedInputTokens
                    , totalSessionOutputTokens: usageTotals'.outputTokens
                    })

                let newAcc = addTc accumulated r.inputTokens
                let history' = addMsg history
                        (AssistantMessage { content: r.content, toolCalls: r.toolCalls })

                case reactStep config newAcc history' response of

                    PromptUser ->
                        pure
                            { history: history'
                            , knownHunks
                            , usageTotals: usageTotals'
                            , error: Nothing
                            }

                    CompactThenPromptUser -> do
                        compactR <- doCompact ws sessionId config apiKey history' usageTotals'
                        pure
                            { history: compactR.history
                            , knownHunks
                            , usageTotals: compactR.usageTotals
                            , error: Nothing
                            }

                    ExecuteTool tc -> do
                        Tuple history'' hunks' <-
                            doTool getTs ws sessionId config kernel history' tc knownHunks
                        runReactLoop ws sessionId config apiKey kernel history''
                            newAcc hunks' usageTotals'

                    ExecuteToolThenCompact tc -> do
                        Tuple history'' hunks' <-
                            doTool getTs ws sessionId config kernel history' tc knownHunks
                        compactR <- doCompact ws sessionId config apiKey history'' usageTotals'
                        runReactLoop ws sessionId config apiKey kernel compactR.history
                            (TokenCount 0) hunks' compactR.usageTotals

                    ExecuteToolThenEndTurn tc -> do
                        Tuple history'' hunks' <-
                            doTool getTs ws sessionId config kernel history' tc knownHunks
                        liftEffect $ printLn "\n[Token limit reached — please continue]"
                        pure
                            { history: history''
                            , knownHunks: hunks'
                            , usageTotals: usageTotals'
                            , error: Nothing
                            }

-- ---------------------------------------------------------------------------
-- Compaction (A33-A36)
-- ---------------------------------------------------------------------------

doCompact
    :: WorkspacePath
    -> SessionId
    -> Config
    -> String
    -> ConversationHistory
    -> LlmUsage
    -> Aff { history :: ConversationHistory, usageTotals :: LlmUsage }
doCompact ws@(WorkspacePath wp) sessionId config apiKey history usageTotals = do
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
        Left _ -> pure { history, usageTotals }
        Right result -> case result.response of
            LlmResponse r -> do
                ts <- getTs
                let usageTotals' = addLlmUsage usageTotals result.usage
                writeLogEvent ws sessionId (TokenUsage
                    { timestamp: ts
                    , inputTokens: result.usage.inputTokens
                    , cachedInputTokens: result.usage.cachedInputTokens
                    , outputTokens: result.usage.outputTokens
                    , totalSessionInputTokens: usageTotals'.inputTokens
                    , totalSessionCachedInputTokens: usageTotals'.cachedInputTokens
                    , totalSessionOutputTokens: usageTotals'.outputTokens
                    })

                let summary = r.content
                let summaryMsg = case substituteTemplate
                        (Map.fromFoldable [Tuple "summary" summary]) summaryTmpl of
                        Left _ -> summary
                        Right t -> t

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
                pure
                    { history: ConversationHistory { messages: newMsgs }
                    , usageTotals: usageTotals'
                    }
  where
    toE m = { message: m, tokens: estimateTokens (extractContent m) }

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
    -> SessionEndReason
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
