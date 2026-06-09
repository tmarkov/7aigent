-- | Session runner: startup, ReACT loop, session listing, resumption.
-- | Wires together all Programs and Services.
-- | Covers A1, A2, A2a, A19, A21, A22, A24–A27, A31, A40–A42.
module Agent.Runner.Session
    ( runNewSession
    , runResumeSession
    , runListSessions
    , runMcpServer
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
import Effect.Aff (Aff, attempt, launchAff_)
import Effect.Class (liftEffect)
import Effect.Exception (message)
import Unsafe.Coerce (unsafeCoerce)
import Node.Encoding (Encoding(..))
import Node.FS.Aff as FS

import Agent.Types
    ( WorkspacePath(..)
    , ApiEndpoint(..)
    , Timestamp(..)
    , SessionId(..)
    , SessionEndReason(..)
    , ModelName(..)
    , TokenCount(..)
    , Port(..)
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
    ( allocateSessionId, writeLogEvent, readLogEvents, decodeLogEvent
    , sessionDescription, reconstructHistory
    )
import Agent.Programs.SessionListing (formatSessionListing, SessionMeta)
import Agent.Programs.SessionResume (loadSessionForResume, ResumeResult(..))
import Agent.Programs.Template (substituteTemplate)
import Agent.Programs.ReactStep (reactStep, NextStep(..))
import Agent.Programs.Steering (buildSteeringMessage)
import Agent.Programs.ToolStep (ToolPostMode(..), ToolStepDecision(..), toolStepDecision)
import Agent.Programs.Compaction (buildCompactionPlan)
import Agent.Programs.Startup (interpretStartupExecution)
import Agent.Programs.JuliaDefs (extractDefs)
import Agent.Programs.Reflection (ReflectionResult, parseReflectionResponse)
import Agent.Programs.Mcp
    ( McpRunResult(..)
    , extractFinalMessage
    , handleMcpResult
    , startMcpServerImpl
    )
import Agent.Programs.ReplSerialize
    ( buildRestoreSnippet
    , buildSerializationSnippet
    )
import Agent.Programs.SandboxPreflight
    ( SandboxPreflightResult(..)
    , runSandboxPreflight
    )
import Agent.Runner.ToolExecution (doTool)
import Agent.Runner.Services (RunnerServices)
import Agent.Services.Jupyter (KernelHandle, ExecutionResult) as Jupyter
import Agent.Services.Llm (LlmUsage, CallLlmResult) as Llm
import Agent.Services.Sandbox (SandboxHandle) as Sandbox

foreign import computeDurationImpl :: String -> String -> String

-- ---------------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------------

getTs :: RunnerServices -> Aff Timestamp
getTs svc = Timestamp <$> liftEffect svc.nowIso

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

zeroLlmUsage :: Llm.LlmUsage
zeroLlmUsage =
    { inputTokens: TokenCount 0
    , cachedInputTokens: TokenCount 0
    , outputTokens: TokenCount 0
    }

type ReactLoopResult =
    { history :: ConversationHistory
    , knownHunks :: Set HunkId
    , usageTotals :: Llm.LlmUsage
    , error :: Maybe AppError
    }

type RoundResult =
    { history :: ConversationHistory
    , knownHunks :: Set HunkId
    , usageTotals :: Llm.LlmUsage
    , autoTurnsTaken :: Int
    , error :: Maybe AppError
    }

addLlmUsage :: Llm.LlmUsage -> Llm.LlmUsage -> Llm.LlmUsage
addLlmUsage totals usage =
    { inputTokens: addTc totals.inputTokens usage.inputTokens
    , cachedInputTokens: addTc totals.cachedInputTokens usage.cachedInputTokens
    , outputTokens: addTc totals.outputTokens usage.outputTokens
    }

renderSessionTokenUsage :: Llm.LlmUsage -> String
renderSessionTokenUsage usage =
    "[session tokens] input="
        <> show (unwrapTc usage.inputTokens)
        <> " cached="
        <> show (unwrapTc usage.cachedInputTokens)
        <> " output="
        <> show (unwrapTc usage.outputTokens)

isRecoverableSessionError :: AppError -> Boolean
isRecoverableSessionError (LlmApiError _) = true
isRecoverableSessionError _ = false

exit1 :: forall a. RunnerServices -> Aff a
exit1 svc = liftEffect (unsafeCoerce (svc.exit 1))

-- ---------------------------------------------------------------------------
-- A41: list sessions
-- ---------------------------------------------------------------------------

runListSessions :: RunnerServices -> WorkspacePath -> Aff Unit
runListSessions svc ws@(WorkspacePath wp) = do
    dirResult <- attempt (FS.readdir (wp <> "/.7aigent/sessions"))
    case dirResult of
        Left _ -> liftEffect $ svc.printLn "No sessions found."
        Right entries -> do
            let sids = Array.sort (Array.mapMaybe Int.fromString entries)
            metas <- traverse (loadMeta ws) sids
            let listing = formatSessionListing (Array.catMaybes metas)
            liftEffect $ svc.printLn listing

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
computeDuration (Timestamp start) (Just (SessionEnd r)) =
    case computeDurationImpl start (renderTimestamp r.timestamp) of
        "" -> Nothing
        formatted -> Just formatted
computeDuration _ _ = Nothing

-- ---------------------------------------------------------------------------
-- A40: start a new session
-- ---------------------------------------------------------------------------

runNewSession :: RunnerServices -> WorkspacePath -> Maybe String -> Aff Unit
runNewSession svc ws prompt =
    startSession svc ws Nothing (ConversationHistory { messages: [] }) Nothing prompt

-- ---------------------------------------------------------------------------
-- A42: resume a session
-- ---------------------------------------------------------------------------

runResumeSession :: RunnerServices -> WorkspacePath -> SessionId -> Maybe String -> Aff Unit
runResumeSession svc ws sid prompt = do
    result <- loadSessionForResume ws sid
    case result of
        ResumeError msg -> do
            liftEffect $ svc.printErr ("Error resuming session: " <> msg)
            exit1 svc
        ResumeReady r -> do
            liftEffect $ for_ r.warnings svc.printErr
            startSession svc ws (Just sid) r.history
                (Just { juliaDefs: r.juliaDefs, hasStateFile: r.hasStateFile })
                prompt

-- ---------------------------------------------------------------------------
-- Core session startup
-- ---------------------------------------------------------------------------

startSession
    :: RunnerServices
    -> WorkspacePath
    -> Maybe SessionId
    -> ConversationHistory
    -> Maybe { juliaDefs :: Array String, hasStateFile :: Boolean }
    -> Maybe String
    -> Aff Unit
startSession svc ws@(WorkspacePath wp) resumedFrom existingHistory resumeState prompt = do

    -- A2a: place default config files
    placed <- placeDefaultConfigs ws
    liftEffect $ for_ placed svc.printLn

    -- A37-A39: parse config
    configR <- attempt (FS.readTextFile UTF8 (wp <> "/.7aigent/config.toml"))
    config <- case configR of
        Left _ -> do
            liftEffect $ svc.printErr "Error: .7aigent/config.toml not found. Run 7aigent once to create it."
            exit1 svc
        Right text -> case parseConfig text of
            Left (PlaceholderValue msg) -> do
                liftEffect $ svc.printErr ("Error: " <> msg <> "\nEdit .7aigent/config.toml before starting.")
                exit1 svc
            Left err -> do
                liftEffect $ svc.printErr ("Config error: " <> show err)
                exit1 svc
            Right c -> pure c

    apiKeyR <- readApiKey config.apiKeyEnv
    apiKey <- case apiKeyR of
        Left err -> do
            liftEffect $ svc.printErr ("Error: " <> show err)
            exit1 svc
        Right k -> pure k

    let (ApiEndpoint summaryApiEndpoint) = config.apiEndpoint
    let (ModelName summaryModel) = config.model

    preflight <- runSandboxPreflight ws (promptSandboxPreflight svc)
    case preflight of
        HaltStartup -> do
            liftEffect $ svc.printErr "Startup halted before sandbox launch."
            exit1 svc
        ContinueStartup ->
            pure unit

    -- A24: allocate session ID
    sessionId <- allocateSessionId ws
    -- A51: set LLM request debug log path
    let SessionId sidNum = sessionId
    liftEffect $ svc.setLlmRequestLogPath
        (wp <> "/.7aigent/sessions/" <> show sidNum <> "/llm-requests.jsonl")

    -- A2: spawn sandbox
    liftEffect $ svc.printStr "Starting sandbox... "
    sbxR <- svc.spawnSandbox ws
    sandbox <- case sbxR of
        Left err -> do
            liftEffect $ svc.printErr ("\nError: " <> show err)
            exit1 svc
        Right s -> do
            liftEffect $ svc.printLn "OK"
            pure s

    -- Connect to Jupyter kernel
    kernelR <- svc.connectKernel sandbox.kernelJsonPath
        { apiEndpoint: summaryApiEndpoint
        , apiKey
        , model: summaryModel
        }
        (\purpose input -> launchAff_ do
            ts' <- getTs svc
            writeLogEvent ws sessionId (EvtLlmQuery
                { timestamp: ts'
                , purpose
                , input
                }))
    kernel <- case kernelR of
        Left err -> do
            svc.killSandbox sandbox
            liftEffect $ svc.printErr ("Error: " <> show err)
            exit1 svc
        Right k -> pure k

    let cleanupSandbox = do
            liftEffect $ svc.closeKernel kernel
            svc.killSandbox sandbox

    -- A19: run Julia startup sequence
    startupResult <- runStartupSequence svc ws kernel
    startupOutput <- case startupResult of
        Left _ -> do
            cleanupSandbox
            exit1 svc
        Right output ->
            pure output

    case resumedFrom, resumeState of
        Just priorSid, Just resumeData ->
            restoreResumedSession svc ws priorSid kernel resumeData
        _, _ ->
            pure unit

    -- A21-A22: build system prompt
    systemPromptR <- buildSystemPrompt svc ws config startupOutput
    systemPrompt <- case systemPromptR of
        Left _ -> do
            cleanupSandbox
            exit1 svc
        Right promptText ->
            pure promptText

    -- Log session start
    ts <- getTs svc
    writeLogEvent ws sessionId (SessionStart
        { id: sessionId
        , timestamp: ts
        , workspace: wp
        , model: config.model
        , resumedFrom
        })
    writeLogEvent ws sessionId (EvtSystemPrompt
        { timestamp: ts
        , content: systemPrompt
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
    steeringTmpl    <- loadSteeringTemplate svc ws cleanupSandbox
    reflectionTmpl  <- loadReflectionTemplate svc ws cleanupSandbox

    exitCode <- runUserLoop svc
        ws sessionId config apiKey kernel sandbox steeringTmpl reflectionTmpl
        initHistory Set.empty zeroLlmUsage 0 prompt

    -- Cleanup
    cleanupSandbox
    liftEffect $ svc.exit exitCode

-- ---------------------------------------------------------------------------
-- A19: Julia startup sequence
-- ---------------------------------------------------------------------------

runStartupSequence :: RunnerServices -> WorkspacePath -> Jupyter.KernelHandle -> Aff (Either AppError String)
runStartupSequence svc (WorkspacePath wp) kernel = do
    out1 <- runStartupExpression svc kernel "Loading CodeTree" "using CodeTree"
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
                    out2 <- runStartupExpression svc kernel "Running startup.jl" code
                    pure (map (\s -> startupPrelude <> "\n" <> s) out2)

runStartupExpression :: RunnerServices -> Jupyter.KernelHandle -> String -> String -> Aff (Either AppError String)
runStartupExpression svc kernel label code = do
    liftEffect $ svc.printStr (label <> "... ")
    result <- svc.executeCodeDetailed kernel (RawJulia code) (const (pure unit))
    case interpretStartupExecution result of
        Left (StartupExpressionError msg) -> do
            liftEffect $ svc.printErr ("\n" <> msg)
            pure (Left (StartupExpressionError msg))
        Left err -> do
            liftEffect $ svc.printErr ("\n" <> show err)
            pure (Left err)
        Right output -> do
            liftEffect $ svc.printLn "OK"
            pure (Right output)

promptSandboxPreflight :: RunnerServices -> String -> Aff String
promptSandboxPreflight svc message = do
    liftEffect $ svc.printLn ""
    liftEffect $ svc.printLn message
    liftEffect $ svc.writePrompt "> "
    svc.readLine

restoreResumedSession
    :: RunnerServices
    -> WorkspacePath
    -> SessionId
    -> Jupyter.KernelHandle
    -> { juliaDefs :: Array String, hasStateFile :: Boolean }
    -> Aff Unit
restoreResumedSession svc (WorkspacePath wp) priorSid kernel resumeData = do
    for_ resumeData.juliaDefs \expr -> do
        out <- svc.executeCode kernel (RawJulia (wrapDefinitionReplay expr)) (const (pure unit))
        let cleaned = String.trim out
        when (not (String.null cleaned)) do
            liftEffect $ svc.printErr cleaned

    when resumeData.hasStateFile do
        out <- svc.executeCode kernel
            (RawJulia (buildRestoreSnippet priorSid wp))
            (const (pure unit))
        let warnings = Array.filter (not <<< String.null)
                (map String.trim (String.split (String.Pattern "\n") out))
        liftEffect $ for_ warnings svc.printErr

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

buildSystemPrompt :: RunnerServices -> WorkspacePath -> Config -> String -> Aff (Either AppError String)
buildSystemPrompt svc (WorkspacePath wp) config startupOutput = do
    tmplR <- attempt (FS.readTextFile UTF8 (wp <> "/.7aigent/system_prompt.md"))
    let tmpl = case tmplR of
            Left _  -> ""
            Right t -> t

    startupJlR <- attempt (FS.readTextFile UTF8 (wp <> "/.7aigent/startup.jl"))
    let startupJl = case startupJlR of
            Left _  -> ""
            Right t -> t

    agentsMdR <- attempt (FS.readTextFile UTF8 (wp <> "/AGENTS.md"))
    let agentsMd = case agentsMdR of
            Left _  -> ""
            Right t -> t

    ts <- getTs svc
    let (ModelName model) = config.model
    let vars = Map.fromFoldable
            [ Tuple "initial_repl_output" startupOutput
            , Tuple "agents_md" agentsMd
            , Tuple "startup_jl" startupJl
            , Tuple "datetime" (renderTimestamp ts)
            , Tuple "model" model
            ]
    case substituteTemplate vars tmpl of
        Left err -> do
            liftEffect $ svc.printErr ("Error in system_prompt.md: " <> show err)
            pure (Left (TemplateError ("system_prompt.md: " <> show err)))
        Right s -> pure (Right s)

-- ---------------------------------------------------------------------------
-- A1: outer loop — user prompt ↔ LLM loop
-- ---------------------------------------------------------------------------

runUserLoop
    :: RunnerServices
    -> WorkspacePath
    -> SessionId
    -> Config
    -> String
    -> Jupyter.KernelHandle
    -> Sandbox.SandboxHandle
    -> String
    -> String
    -> ConversationHistory
    -> Set HunkId
    -> Llm.LlmUsage
    -> Int
    -> Maybe String
    -> Aff Int
runUserLoop svc ws sessionId config apiKey kernel sandbox steeringTemplate reflectionTemplate history knownHunks usageTotals autoTurnsTaken maybePrompt = do
    line <- case maybePrompt of
        Just p -> do
            liftEffect $ svc.printLn ("\n> " <> p)
            pure p
        Nothing -> do
            liftEffect $ svc.writePrompt "\n> "
            svc.readLine

    -- EOF → clean exit
    when (String.null line) do
        finishSession svc ws sessionId kernel history SessionEndedEof
    if String.null line then
        pure 0
    else do

        ts <- getTs svc
        writeLogEvent ws sessionId (EvtUserMessage { timestamp: ts, content: line, source: Nothing })

        let history' = addMsg history (UserMessage { content: line })
        roundResult <-
            runRound svc ws sessionId config apiKey kernel sandbox steeringTemplate reflectionTemplate history'
                knownHunks usageTotals autoTurnsTaken
        liftEffect $ svc.printLn (renderSessionTokenUsage roundResult.usageTotals)

        case roundResult.error, maybePrompt of
            Just err, Nothing | isRecoverableSessionError err ->
                runUserLoop svc ws sessionId config apiKey kernel sandbox steeringTemplate reflectionTemplate
                    roundResult.history roundResult.knownHunks roundResult.usageTotals
                    roundResult.autoTurnsTaken Nothing
            Just _, _ -> do
                finishSession svc ws sessionId kernel roundResult.history SessionEndedError
                pure 1
            Nothing, Just _ -> do
                finishSession svc ws sessionId kernel roundResult.history SessionEndedPrompt
                pure 0
            Nothing, Nothing ->
                runUserLoop svc ws sessionId config apiKey kernel sandbox steeringTemplate reflectionTemplate
                    roundResult.history roundResult.knownHunks roundResult.usageTotals
                    roundResult.autoTurnsTaken Nothing

-- ---------------------------------------------------------------------------
-- A1: inner loop — LLM calls + tool execution
-- ---------------------------------------------------------------------------

runReactLoop
    :: RunnerServices
    -> WorkspacePath
    -> SessionId
    -> Config
    -> String
    -> Jupyter.KernelHandle
    -> Sandbox.SandboxHandle
    -> String
    -> ConversationHistory
    -> TokenCount  -- ^ turn baseline: input tokens from first call of this turn (0 = first call)
    -> TokenCount  -- ^ last call tokens: input tokens from the most recent LLM call (0 = first call)
    -> Set HunkId
    -> Llm.LlmUsage
    -> Int
    -> Int
    -> Aff ReactLoopResult
runReactLoop svc ws sessionId config apiKey kernel sandbox steeringTemplate history turnBaseline lastCallTokens knownHunks usageTotals turnIndex autoTurnsTaken = do
    -- A46: inject ephemeral steering message after the first tool call
    historyForLlm <-
        if turnBaseline == TokenCount 0
        then pure history
        else do
            juliaState <- getJuliaState svc kernel
            let maybeSteer = buildSteeringMessage steeringTemplate turnBaseline lastCallTokens config juliaState turnIndex autoTurnsTaken
            pure $ case maybeSteer of
                Nothing  -> history
                Just msg -> addMsg history (UserMessage { content: msg })
    liftEffect $ svc.printLn ""
    llmR <- svc.callLlm config apiKey historyForLlm (liftEffect <<< svc.printStr)
    liftEffect $ svc.printLn ""

    case llmR of
        Left err -> do
            liftEffect $ svc.printErr ("LLM error: " <> show err)
            pure { history, knownHunks, usageTotals, error: Just err }

        Right result -> case result.response of
            response@(LlmResponse r) -> do
                ts <- getTs svc
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

                -- On the first call of the turn, record the baseline.
                -- On subsequent calls, keep the baseline unchanged so that
                -- reactStep can compute the delta (growth since turn start).
                let newBaseline = if turnBaseline == TokenCount 0 then r.inputTokens else turnBaseline
                let history' = addMsg history
                        (AssistantMessage { content: r.content, toolCalls: r.toolCalls })

                case reactStep config newBaseline history' response of

                    PromptUser ->
                        pure
                            { history: history'
                            , knownHunks
                            , usageTotals: usageTotals'
                            , error: Nothing
                            }

                    CompactThenPromptUser -> do
                        compactR <- doCompact svc
                            ws
                            sessionId
                            config
                            apiKey
                            kernel
                            r.inputTokens
                            history'
                            usageTotals'
                        case compactR of
                            Left err -> do
                                liftEffect $ svc.printErr
                                    "Context is too large to compact. Start a new session."
                                pure
                                    { history: history'
                                    , knownHunks
                                    , usageTotals: usageTotals'
                                    , error: Just err
                                    }
                            Right compacted ->
                                pure
                                    { history: compacted.history
                                    , knownHunks
                                    , usageTotals: compacted.usageTotals
                                    , error: Nothing
                                    }

                    ExecuteTool tc -> do
                        toolR <- attempt $
                            doTool svc ws sessionId config apiKey kernel sandbox history' tc knownHunks
                        case toolR of
                            Left err -> do
                                let errMsg = message err
                                liftEffect $ svc.printErr ("Session error: " <> errMsg)
                                pure
                                    { history: history'
                                    , knownHunks
                                    , usageTotals: usageTotals'
                                    , error: Just (KernelError errMsg)
                                    }
                            Right toolResult ->
                                handleCompletedToolStep ContinueAfterTool
                                    svc ws sessionId config apiKey kernel sandbox steeringTemplate
                                    newBaseline r.inputTokens usageTotals' turnIndex autoTurnsTaken toolResult

                    ExecuteToolThenCompact tc -> do
                        toolR <- attempt $
                            doTool svc ws sessionId config apiKey kernel sandbox history' tc knownHunks
                        case toolR of
                            Left err -> do
                                let errMsg = message err
                                liftEffect $ svc.printErr ("Session error: " <> errMsg)
                                pure
                                    { history: history'
                                    , knownHunks
                                    , usageTotals: usageTotals'
                                    , error: Just (KernelError errMsg)
                                    }
                            Right toolResult ->
                                handleCompletedToolStep CompactAfterTool
                                    svc ws sessionId config apiKey kernel sandbox steeringTemplate
                                    newBaseline r.inputTokens usageTotals' turnIndex autoTurnsTaken toolResult

                    ExecuteToolThenEndTurn tc -> do
                        toolR <- attempt $
                            doTool svc ws sessionId config apiKey kernel sandbox history' tc knownHunks
                        case toolR of
                            Left err -> do
                                let errMsg = message err
                                liftEffect $ svc.printErr ("Session error: " <> errMsg)
                                pure
                                    { history: history'
                                    , knownHunks
                                    , usageTotals: usageTotals'
                                    , error: Just (KernelError errMsg)
                                    }
                            Right toolResult ->
                                handleCompletedToolStep EndTurnAfterTool
                                    svc ws sessionId config apiKey kernel sandbox steeringTemplate
                                    newBaseline r.inputTokens usageTotals' turnIndex autoTurnsTaken toolResult

handleCompletedToolStep
    :: ToolPostMode
    -> RunnerServices
    -> WorkspacePath
    -> SessionId
    -> Config
    -> String
    -> Jupyter.KernelHandle
    -> Sandbox.SandboxHandle
    -> String
    -> TokenCount
    -> TokenCount
    -> Llm.LlmUsage
    -> Int
    -> Int
    -> { history :: ConversationHistory, hunks :: Set HunkId, toolInterrupted :: Boolean }
    -> Aff ReactLoopResult
handleCompletedToolStep postMode svc ws sessionId config apiKey kernel sandbox steeringTemplate turnBaseline
    currentRequestTokens usageTotals turnIndex autoTurnsTaken toolResult =
    case toolStepDecision postMode toolResult.toolInterrupted of
        ContinueTurn ->
            runReactLoop svc ws sessionId config apiKey kernel sandbox steeringTemplate toolResult.history
                turnBaseline currentRequestTokens toolResult.hunks usageTotals turnIndex autoTurnsTaken

        CompactAndContinueTurn -> do
            compactR <- doCompact svc
                ws
                sessionId
                config
                apiKey
                kernel
                currentRequestTokens
                toolResult.history
                usageTotals
            case compactR of
                Left err -> do
                    liftEffect $ svc.printErr
                        "Context is too large to compact. Start a new session."
                    pure
                        { history: toolResult.history
                        , knownHunks: toolResult.hunks
                        , usageTotals
                        , error: Just err
                        }
                Right compacted ->
                    runReactLoop svc ws sessionId config apiKey kernel sandbox steeringTemplate
                        compacted.history
                        (TokenCount 0) (TokenCount 0) toolResult.hunks
                        compacted.usageTotals turnIndex autoTurnsTaken

        EndTurnAndReflect -> do
            liftEffect $ svc.printLn "\n[Token limit reached — continuing...]"
            pure
                { history: toolResult.history
                , knownHunks: toolResult.hunks
                , usageTotals
                , error: Nothing
                }

-- ---------------------------------------------------------------------------
-- A47: Julia state for steering and compaction
-- ---------------------------------------------------------------------------

-- | Execute `SevenAigentREPL.status()` in an ans-preserving wrapper and return
-- | its stdout output. Returns empty string on any error.
getJuliaState :: RunnerServices -> Jupyter.KernelHandle -> Aff String
getJuliaState svc kernel = do
    let code = String.joinWith "\n"
            [ "begin"
            , "  local _ans = isdefined(Main, :ans) ? Main.ans : nothing"
            , "  SevenAigentREPL.status()"
            , "  _ans"
            , "end"
            ]
    result <- attempt $ svc.executeCodeDetailed kernel (RawJulia code) (const (pure unit))
    pure $ case result of
        Left _ -> ""
        Right execResult
            | execResult.hadError -> ""
            | otherwise -> String.trim execResult.output

-- | Load and validate the steering_message.md template.
-- | Falls back to a built-in default if the file is absent.
-- | Calls `cleanup` then exits if the template contains unknown keywords.
loadSteeringTemplate :: RunnerServices -> WorkspacePath -> Aff Unit -> Aff String
loadSteeringTemplate svc (WorkspacePath wp) cleanup = do
    let defaultTmpl = String.joinWith "\n"
            [ "**Turn status:** {{turn_tokens}}/{{turn_token_limit}} tokens"
            , "(compaction threshold: {{compaction_threshold}})"
            , "{{julia_state}}"
            ]
    tmplR <- attempt (FS.readTextFile UTF8 (wp <> "/.7aigent/steering_message.md"))
    let tmpl = case tmplR of
            Left  _ -> defaultTmpl
            Right t -> t
    let validateVars = Map.fromFoldable
            [ Tuple "julia_state"          ""
            , Tuple "turn_tokens"          ""
            , Tuple "turn_token_limit"     ""
            , Tuple "compaction_threshold" ""
            , Tuple "turn_index"           ""
            , Tuple "max_turns_per_round"  ""
            , Tuple "auto_turns_taken"     ""
            ]
    case substituteTemplate validateVars tmpl of
        Left err -> do
            liftEffect $ svc.printErr ("Error in steering_message.md: " <> show err)
            cleanup
            exit1 svc
        Right _ -> pure tmpl

-- | Load and validate the reflection_prompt.md template.
-- | Falls back to a built-in default if the file is absent.
-- | Calls `cleanup` then exits if the template contains unknown keywords.
loadReflectionTemplate :: RunnerServices -> WorkspacePath -> Aff Unit -> Aff String
loadReflectionTemplate svc (WorkspacePath wp) cleanup = do
    let defaultTmpl = String.joinWith "\n"
            [ "You are reviewing the progress of an ongoing agent session."
            , "Turn index (within round): {{turn_index}}"
            , "Auto-turns taken this session: {{auto_turns_taken}}"
            , "Max turns per round: {{max_turns_per_round}}"
            , "Current Julia state:\n{{julia_state}}"
            , ""
            , "Reply with JSON: {\"complete\": true} if the task is done,"
            , "or {\"complete\": false, \"feedback\": \"<next steps>\"} if not."
            ]
    tmplR <- attempt (FS.readTextFile UTF8 (wp <> "/.7aigent/reflection_prompt.md"))
    let tmpl = case tmplR of
            Left  _ -> defaultTmpl
            Right t -> t
    let validateVars = Map.fromFoldable
            [ Tuple "turn_index"         ""
            , Tuple "auto_turns_taken"   ""
            , Tuple "max_turns_per_round" ""
            , Tuple "julia_state"        ""
            ]
    case substituteTemplate validateVars tmpl of
        Left err -> do
            liftEffect $ svc.printErr ("Error in reflection_prompt.md: " <> show err)
            cleanup
            exit1 svc
        Right _ -> pure tmpl

-- ---------------------------------------------------------------------------
-- A49-A50: Round orchestration and reflection
-- ---------------------------------------------------------------------------

-- | Perform one reflection LLM call: build the reflection prompt, call the
-- | LLM in JSON mode, log the result, and return the parsed ReflectionResult
-- | together with token usage.
doReflection
    :: RunnerServices
    -> WorkspacePath
    -> SessionId
    -> Config
    -> String
    -> Jupyter.KernelHandle
    -> String
    -> ConversationHistory
    -> Int
    -> Int
    -> Llm.LlmUsage
    -> Aff { result :: ReflectionResult, usageTotals :: Llm.LlmUsage }
doReflection svc ws sessionId config apiKey kernel reflectionTemplate history turnIndex autoTurnsTaken usageTotals = do
    juliaState <- getJuliaState svc kernel
    let vars = Map.fromFoldable
            [ Tuple "turn_index"          (show turnIndex)
            , Tuple "auto_turns_taken"    (show autoTurnsTaken)
            , Tuple "max_turns_per_round" (show config.maxTurnsPerRound)
            , Tuple "julia_state"         juliaState
            ]
    let prompt = case substituteTemplate vars reflectionTemplate of
            Left  _ -> reflectionTemplate
            Right p -> p
    let reflHistory = addMsg history (UserMessage { content: prompt })
    llmR <- svc.callLlmJson config apiKey reflHistory
    ts <- getTs svc
    case llmR of
        Left _ -> do
            let parsed = parseReflectionResponse ""
            writeLogEvent ws sessionId (EvtReflection
                { timestamp: ts
                , turnIndex
                , autoTurnsTaken
                , complete: parsed.complete
                , feedback: parsed.feedback
                })
            pure { result: parsed, usageTotals }
        Right llmResult -> do
            let (LlmResponse r) = llmResult.response
            let parsed = parseReflectionResponse r.content
            let usageTotals' = addLlmUsage usageTotals llmResult.usage
            writeLogEvent ws sessionId (EvtReflection
                { timestamp: ts
                , turnIndex
                , autoTurnsTaken
                , complete: parsed.complete
                , feedback: parsed.feedback
                })
            writeLogEvent ws sessionId (TokenUsage
                { timestamp: ts
                , inputTokens: llmResult.usage.inputTokens
                , cachedInputTokens: llmResult.usage.cachedInputTokens
                , outputTokens: llmResult.usage.outputTokens
                , totalSessionInputTokens: usageTotals'.inputTokens
                , totalSessionCachedInputTokens: usageTotals'.cachedInputTokens
                , totalSessionOutputTokens: usageTotals'.outputTokens
                })
            pure { result: parsed, usageTotals: usageTotals' }

-- | Run a full round: one or more turns, with reflection between them.
-- | A round ends when reflection reports complete, an error occurs, or
-- | maxTurnsPerRound is reached (A48).
runRound
    :: RunnerServices
    -> WorkspacePath
    -> SessionId
    -> Config
    -> String
    -> Jupyter.KernelHandle
    -> Sandbox.SandboxHandle
    -> String
    -> String
    -> ConversationHistory
    -> Set HunkId
    -> Llm.LlmUsage
    -> Int
    -> Aff RoundResult
runRound svc ws sessionId config apiKey kernel sandbox steeringTemplate reflectionTemplate history knownHunks usageTotals autoTurnsTaken =
    go history knownHunks usageTotals autoTurnsTaken 1
  where
    go hist hunks usage auto turnIndex = do
        loopResult <- runReactLoop svc ws sessionId config apiKey kernel sandbox steeringTemplate hist
            (TokenCount 0) (TokenCount 0) hunks usage turnIndex auto

        case loopResult.error of
            Just err ->
                pure
                    { history: loopResult.history
                    , knownHunks: loopResult.knownHunks
                    , usageTotals: loopResult.usageTotals
                    , autoTurnsTaken: auto
                    , error: Just err
                    }
            Nothing -> do
                reflR <- doReflection svc ws sessionId config apiKey kernel reflectionTemplate
                    loopResult.history turnIndex auto loopResult.usageTotals
                if reflR.result.complete || turnIndex >= config.maxTurnsPerRound
                    then
                        pure
                            { history: loopResult.history
                            , knownHunks: loopResult.knownHunks
                            , usageTotals: reflR.usageTotals
                            , autoTurnsTaken: auto
                            , error: Nothing
                            }
                    else do
                        let feedbackMsg = case reflR.result.feedback of
                                Nothing -> "[Reflection: continue]"
                                Just fb -> fb
                        ts <- getTs svc
                        writeLogEvent ws sessionId (EvtUserMessage
                            { timestamp: ts, content: feedbackMsg, source: Just "reflection" })
                        let hist' = addMsg loopResult.history (UserMessage { content: feedbackMsg })
                        go hist' loopResult.knownHunks reflR.usageTotals (auto + 1) (turnIndex + 1)

-- ---------------------------------------------------------------------------
-- Compaction (A33-A36)
-- ---------------------------------------------------------------------------

doCompact
    :: RunnerServices
    -> WorkspacePath
    -> SessionId
    -> Config
    -> String
    -> Jupyter.KernelHandle
    -> TokenCount
    -> ConversationHistory
    -> Llm.LlmUsage
    -> Aff (Either AppError { history :: ConversationHistory, usageTotals :: Llm.LlmUsage })
doCompact svc ws@(WorkspacePath wp) sessionId config apiKey kernel requestTokensBefore history usageTotals = do
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
    juliaState <- getJuliaState svc kernel
    let promptVars = Map.fromFoldable
            [ Tuple "initial_messages"   (render plan.initialBlock)
            , Tuple "compacted_messages" (render plan.compactedBlock)
            , Tuple "final_messages"     (render plan.finalBlock)
            , Tuple "julia_state"        juliaState
            ]
    let promptText = case substituteTemplate promptVars compactTmpl of
            Left _ -> render plan.compactedBlock
            Right t -> t

    let compactHistory = ConversationHistory
            { messages: [{ message: UserMessage { content: promptText }, tokens: TokenCount 0 }] }

    liftEffect $ svc.printStr "[Compacting context...]"
    summaryR <- svc.callLlm config apiKey compactHistory (const (pure unit))
    liftEffect $ svc.printLn ""

    case summaryR of
        Left _ -> pure (Right { history, usageTotals })
        Right result -> case result.response of
            LlmResponse r -> do
                ts <- getTs svc
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

                let newMsgs =
                        map toE plan.initialBlock <>
                        [{ message: UserMessage { content: summaryMsg }
                         , tokens: estimateTokens summaryMsg
                          }] <>
                        map toE plan.finalBlock
                let newHistory = ConversationHistory { messages: newMsgs }
                let totalTokensAfter = foldl (\acc entry -> acc + unwrapTc entry.tokens) 0 newMsgs
                let TokenCount threshold = config.compactionThreshold
                if totalTokensAfter > threshold then
                    pure (Left (CompactionError "Context is too large to compact. Start a new session."))
                else do
                    writeLogEvent ws sessionId (Compaction
                        { timestamp: ts
                        , summary
                        , initialMessageCount:  Array.length plan.initialBlock
                        , compactedMessageCount: Array.length plan.compactedBlock
                        , finalMessageCount:    Array.length plan.finalBlock
                        , totalTokensBefore:    unwrapTc requestTokensBefore
                        })
                    pure (Right
                        { history: newHistory
                        , usageTotals: usageTotals'
                        })
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
    :: RunnerServices
    -> WorkspacePath
    -> SessionId
    -> Jupyter.KernelHandle
    -> ConversationHistory
    -> SessionEndReason
    -> Aff Unit
finishSession svc ws@(WorkspacePath wp) sessionId kernel _history reason = do
    let logPath = wp <> "/.7aigent/sessions/" <> show (unwrapSid sessionId) <> "/log.jsonl"
    logTextR <- attempt (FS.readTextFile UTF8 logPath)
    let defs = case logTextR of
            Left _ -> []
            Right text ->
                let lines =
                        Array.filter (not <<< String.null)
                            (String.split (String.Pattern "\n") (String.trim text))
                    decoded = Array.mapMaybe
                        (\line -> case decodeLogEvent line of
                            Left _ -> Nothing
                            Right evt -> Just evt)
                        lines
                in extractDefs decoded
    let defsPath = wp <> "/.7aigent/sessions/"
            <> show (unwrapSid sessionId) <> "/julia_defs.jl"
    _ <- attempt (FS.writeTextFile UTF8 defsPath (String.joinWith "\n" defs))

    let snippet = buildSerializationSnippet sessionId wp
    _ <- attempt (svc.executeCode kernel (RawJulia snippet) (const (pure unit)))
    pure unit

    ts <- getTs svc
    writeLogEvent ws sessionId (SessionEnd { timestamp: ts, reason })

-- ---------------------------------------------------------------------------
-- A43: MCP server
-- ---------------------------------------------------------------------------

-- | Run a single MCP session: spawn sandbox, run one full round, return result.
-- | Used as the tool-call handler for the `run` tool (A43).
runMcpSession
    :: RunnerServices
    -> WorkspacePath
    -> Config
    -> String
    -> String
    -> Aff McpRunResult
runMcpSession svc ws@(WorkspacePath wp) config apiKey message = do
    let summaryApiEndpoint = let (ApiEndpoint e) = config.apiEndpoint in e
    let summaryModel       = let (ModelName m)   = config.model       in m

    sessionId <- allocateSessionId ws

    sbxR <- svc.spawnSandbox ws
    sandbox <- case sbxR of
        Left err ->
            pure (Left (McpFailure ("Sandbox error: " <> show err)))
        Right s -> pure (Right s)

    case sandbox of
        Left e -> pure e
        Right s -> do
            let cleanup = svc.killSandbox s

            kernelR <- svc.connectKernel s.kernelJsonPath
                { apiEndpoint: summaryApiEndpoint
                , apiKey
                , model: summaryModel
                }
                (\purpose input -> launchAff_ do
                    ts' <- getTs svc
                    writeLogEvent ws sessionId (EvtLlmQuery
                        { timestamp: ts'
                        , purpose
                        , input
                        }))
            case kernelR of
                Left err -> do
                    cleanup
                    pure (McpFailure ("Kernel error: " <> show err))
                Right kernel -> do
                    let cleanupAll = do
                            liftEffect $ svc.closeKernel kernel
                            svc.killSandbox s

                    startupResult <- runStartupSequence svc ws kernel
                    startupOutput <- case startupResult of
                        Left _       -> do
                            cleanupAll
                            pure (Left (McpFailure "Startup failed"))
                        Right output -> pure (Right output)

                    case startupOutput of
                        Left e -> pure e
                        Right output -> do
                            systemPromptR <- buildSystemPrompt svc ws config output
                            case systemPromptR of
                                Left _ -> do
                                    cleanupAll
                                    pure (McpFailure "Could not build system prompt")
                                Right systemPrompt -> do
                                    ts <- getTs svc
                                    writeLogEvent ws sessionId (SessionStart
                                        { id: sessionId
                                        , timestamp: ts
                                        , workspace: wp
                                        , model: config.model
                                        , resumedFrom: Nothing
                                        })
                                    writeLogEvent ws sessionId (EvtSystemPrompt
                                        { timestamp: ts
                                        , content: systemPrompt
                                        })
                                    writeLogEvent ws sessionId (EvtUserMessage
                                        { timestamp: ts
                                        , content: message
                                        , source: Nothing
                                        })

                                    steeringTmpl   <- loadSteeringTemplate svc   ws cleanupAll
                                    reflectionTmpl <- loadReflectionTemplate svc ws cleanupAll

                                    let initHistory =
                                            addMsg
                                                (addMsg (ConversationHistory { messages: [] })
                                                    (SystemMessage { content: systemPrompt }))
                                                (UserMessage { content: message })

                                    roundResult <- runRound svc ws sessionId config apiKey kernel s
                                        steeringTmpl reflectionTmpl initHistory
                                        Set.empty zeroLlmUsage 0

                                    finishSession svc ws sessionId kernel
                                        roundResult.history
                                        (case roundResult.error of
                                            Just _ -> SessionEndedError
                                            Nothing -> SessionEndedPrompt)
                                    cleanupAll

                                    pure $ case roundResult.error of
                                        Just err ->
                                            McpFailure ("Session error: " <> show err)
                                        Nothing ->
                                            case extractFinalMessage roundResult.history of
                                                Nothing  ->
                                                    McpFailure "Agent produced no response"
                                                Just msg ->
                                                    McpSuccess msg

-- | Start the MCP HTTP server on the given port (A43).
-- | Reads config once at startup; each tool invocation spawns its own sandbox.
runMcpServer :: RunnerServices -> WorkspacePath -> Port -> Aff Unit
runMcpServer svc ws (Port port) = do
    let (WorkspacePath wp) = ws
    placed <- placeDefaultConfigs ws
    liftEffect $ for_ placed svc.printLn

    configR <- attempt (FS.readTextFile UTF8 (wp <> "/.7aigent/config.toml"))
    config <- case configR of
        Left _ -> do
            liftEffect $ svc.printErr "Error: .7aigent/config.toml not found."
            exit1 svc
        Right text -> case parseConfig text of
            Left (PlaceholderValue msg) -> do
                liftEffect $ svc.printErr ("Error: " <> msg)
                exit1 svc
            Left err -> do
                liftEffect $ svc.printErr ("Config error: " <> show err)
                exit1 svc
            Right c -> pure c

    apiKeyR <- readApiKey config.apiKeyEnv
    apiKey <- case apiKeyR of
        Left err -> do
            liftEffect $ svc.printErr ("Error: " <> show err)
            exit1 svc
        Right k -> pure k

    let progressMs = config.progressIntervalSeconds * 1000
    liftEffect $ startMcpServerImpl port progressMs \message done ->
        launchAff_ do
            result <- attempt (runMcpSession svc ws config apiKey message)
            let ffiResult = case result of
                    Left err -> handleMcpResult (McpFailure ("Unexpected error: " <> show err))
                    Right r  -> handleMcpResult r
            liftEffect $ done ffiResult
