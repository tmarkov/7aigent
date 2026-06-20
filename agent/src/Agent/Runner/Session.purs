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
    , unwrapConversationHistory
    )
import Agent.Programs.Config (parseConfig, readApiKey, placeDefaultConfigs)
import Agent.Programs.SessionLog
    ( allocateSessionId, writeLogEvent, readLogEvents, decodeLogEvent
    , sessionDescription, reconstructHistory
    )
import Agent.Programs.SessionListing (formatSessionListing, SessionMeta)
import Agent.Programs.SessionResume (loadSessionForResume, ResumeResult(..))
import Agent.Programs.Template (substituteTemplate)
import Agent.Programs.InitialMessage (ParsedInitialMessage, parseInitialMessage)
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
import Agent.Services.Llm
    ( CallLlmResult
    , LlmResponseFormat(..)
    , LlmRetryMode(..)
    , LlmUsage
    ) as Llm
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

type ExecutionTemplates =
    { timeout :: String
    , stdin :: String
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
                firstMsg = Array.find isHumanUserMessage evts
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
    userMsgContent (EvtUserMessage m)
        | m.source == Just "reflection" = Nothing
        | otherwise = Just (fromMaybe m.content m.rawContent)
    userMsgContent _                  = Nothing
    isSessionStart (SessionStart _)   = true
    isSessionStart _                  = false
    isHumanUserMessage (EvtUserMessage m) = m.source /= Just "reflection"
    isHumanUserMessage _                  = false
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

    startupFilesR <- validateStartupFiles svc ws config (resumedFrom == Nothing)
    startupFiles <- case startupFilesR of
        Left _ ->
            exit1 svc
        Right validated ->
            pure validated

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
    case startupResult of
        Left _ -> do
            cleanupSandbox
            exit1 svc
        Right _ ->
            pure unit

    case resumedFrom, resumeState of
        Just priorSid, Just resumeData ->
            restoreResumedSession svc ws priorSid kernel resumeData
        _, _ ->
            pure unit

    -- A21-A22: build system prompt
    systemPromptR <- buildSystemPrompt svc ws config
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
                ConversationHistory
                    { messages:
                        [{ message: SystemMessage { content: systemPrompt }
                         , tokens: estimateTokens systemPrompt
                         }] <>
                        unwrapConversationHistory existingHistory
                    }

    -- Enter the main user ↔ LLM loop
    steeringTmpl    <- loadSteeringTemplate svc ws cleanupSandbox
    reflectionTmpl  <- loadReflectionTemplate svc ws cleanupSandbox
    timeoutTmpl     <- loadTimeoutTemplate svc ws cleanupSandbox
    stdinTmpl       <- loadStdinTemplate svc ws cleanupSandbox
    let executionTemplates = { timeout: timeoutTmpl, stdin: stdinTmpl }

    exitCode <- runUserLoop svc
        ws sessionId config apiKey kernel sandbox
        steeringTmpl reflectionTmpl executionTemplates
        initHistory Set.empty zeroLlmUsage 0
        startupFiles.userMessageTemplate
        (if resumedFrom == Nothing then startupFiles.initialSeed else Nothing)
        prompt

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

validateStartupFiles
    :: RunnerServices
    -> WorkspacePath
    -> Config
    -> Boolean
    -> Aff (Either AppError
        { userMessageTemplate :: String
        , initialSeed :: Maybe ParsedInitialMessage
        })
validateStartupFiles svc ws@(WorkspacePath wp) config validateInitialSeed = do
    systemPromptR <- buildSystemPrompt svc ws config
    case systemPromptR of
        Left err ->
            pure (Left err)
        Right _ -> do
            userMessageTemplateR <- readAndValidateTemplate svc
                (wp <> "/.7aigent/user_message.md")
                "user_message.md"
                (Map.fromFoldable [Tuple "user_message" ""])
            case userMessageTemplateR of
                Left err -> pure (Left err)
                Right userMessageTemplate -> do
                    otherValidation <- validateNonSystemTemplates svc wp
                    case otherValidation of
                        Left err -> pure (Left err)
                        Right _ -> do
                            if validateInitialSeed then do
                                    initialTextR <- readInitialMessageText
                                        (wp <> "/.7aigent/initial_message.md")
                                    initialText <- case initialTextR of
                                        Left err -> do
                                            liftEffect $ svc.printErr
                                                ("Error in initial_message.md: " <> show err)
                                            pure (Left err)
                                        Right text ->
                                            pure (Right text)
                                    case initialText of
                                        Left err ->
                                            pure (Left err)
                                        Right seedText ->
                                            case parseInitialMessage config.maxReplTimeoutSeconds seedText of
                                                Left err -> do
                                                    liftEffect $ svc.printErr ("Error in initial_message.md: " <> err)
                                                    pure (Left (TemplateError ("initial_message.md: " <> err)))
                                                Right initialSeed ->
                                                    pure (Right { userMessageTemplate, initialSeed })
                            else
                                pure (Right { userMessageTemplate, initialSeed: Nothing })

validateNonSystemTemplates
    :: RunnerServices
    -> String
    -> Aff (Either AppError Unit)
validateNonSystemTemplates svc wp = do
    let validations =
            [ { file: "compaction_prompt.md"
              , vars: Map.fromFoldable
                    [ Tuple "initial_messages" ""
                    , Tuple "compacted_messages" ""
                    , Tuple "final_messages" ""
                    , Tuple "julia_state" ""
                    ]
              }
            , { file: "summary_message.md"
              , vars: Map.fromFoldable [Tuple "summary" ""]
              }
            , { file: "steering_message.md"
              , vars: Map.fromFoldable
                    [ Tuple "julia_state" ""
                    , Tuple "turn_tokens" ""
                    , Tuple "turn_token_limit" ""
                    , Tuple "compaction_threshold" ""
                    , Tuple "turn_index" ""
                    , Tuple "max_turns_per_round" ""
                    , Tuple "auto_turns_taken" ""
                    ]
              }
            , { file: "reflection_prompt.md"
              , vars: Map.fromFoldable
                    [ Tuple "turn_index" ""
                    , Tuple "auto_turns_taken" ""
                    , Tuple "max_turns_per_round" ""
                    , Tuple "julia_state" ""
                    ]
              }
            , { file: "timeout_prompt.md"
              , vars: Map.fromFoldable
                    [ Tuple "julia_source" ""
                    , Tuple "elapsed_time" ""
                    , Tuple "output_so_far" ""
                    , Tuple "json_schema" ""
                    ]
              }
            , { file: "stdin_prompt.md"
              , vars: Map.fromFoldable
                    [ Tuple "julia_source" ""
                    , Tuple "elapsed_time" ""
                    , Tuple "output_so_far" ""
                    , Tuple "prompt" ""
                    , Tuple "json_schema" ""
                    ]
              }
            ]
    go validations
  where
    go entries = case Array.uncons entries of
        Nothing ->
            pure (Right unit)
        Just { head: entry, tail: rest } -> do
            textR <- readAndValidateTemplate svc
                (wp <> "/.7aigent/" <> entry.file)
                entry.file
                entry.vars
            case textR of
                Left err -> pure (Left err)
                Right _ -> go rest

readAndValidateTemplate
    :: RunnerServices
    -> String
    -> String
    -> Map.Map String String
    -> Aff (Either AppError String)
readAndValidateTemplate svc path label vars = do
    textR <- readFileOrError path label
    case textR of
        Left err -> do
            liftEffect $ svc.printErr ("Error in " <> label <> ": " <> show err)
            pure (Left err)
        Right text ->
            validateTemplateText svc label vars text

readAndRenderTemplate
    :: RunnerServices
    -> String
    -> String
    -> Map.Map String String
    -> Aff (Either AppError String)
readAndRenderTemplate svc path label vars = do
    textR <- readFileOrError path label
    case textR of
        Left err -> do
            liftEffect $ svc.printErr ("Error in " <> label <> ": " <> show err)
            pure (Left err)
        Right text ->
            renderTemplateText svc label vars text

validateTemplateText
    :: RunnerServices
    -> String
    -> Map.Map String String
    -> String
    -> Aff (Either AppError String)
validateTemplateText svc label vars text =
    case substituteTemplate vars text of
        Left err -> do
            liftEffect $ svc.printErr ("Error in " <> label <> ": " <> show err)
            pure (Left (TemplateError (label <> ": " <> show err)))
        Right _ ->
            pure (Right text)

renderTemplateText
    :: RunnerServices
    -> String
    -> Map.Map String String
    -> String
    -> Aff (Either AppError String)
renderTemplateText svc label vars text =
    case substituteTemplate vars text of
        Left err -> do
            liftEffect $ svc.printErr ("Error in " <> label <> ": " <> show err)
            pure (Left (TemplateError (label <> ": " <> show err)))
        Right rendered ->
            pure (Right rendered)

readFileOrError :: String -> String -> Aff (Either AppError String)
readFileOrError path label = do
    contentR <- attempt (FS.readTextFile UTF8 path)
    pure case contentR of
        Left err -> Left (TemplateError (label <> ": " <> message err))
        Right text -> Right text

readInitialMessageText :: String -> Aff (Either AppError String)
readInitialMessageText path = do
    contentR <- attempt (FS.readTextFile UTF8 path)
    pure case contentR of
        Right text ->
            Right text
        Left err ->
            let errMsg = message err
                lowerMsg = String.toLower errMsg
            in if String.contains (String.Pattern "ENOENT") errMsg
                || String.contains (String.Pattern "no such file") lowerMsg then
                Right ""
            else
                Left (TemplateError ("initial_message.md: " <> errMsg))

renderUserMessage :: String -> String -> Either AppError String
renderUserMessage template userMessage =
    substituteTemplate
        (Map.fromFoldable [Tuple "user_message" userMessage])
        template

applyInitialSeed
    :: RunnerServices
    -> WorkspacePath
    -> SessionId
    -> Config
    -> String
    -> Jupyter.KernelHandle
    -> Sandbox.SandboxHandle
    -> ExecutionTemplates
    -> ConversationHistory
    -> Set HunkId
    -> Llm.LlmUsage
    -> ParsedInitialMessage
    -> Aff
        { history :: ConversationHistory
        , knownHunks :: Set HunkId
        , usageTotals :: Llm.LlmUsage
        }
applyInitialSeed
    svc ws sessionId config apiKey kernel sandbox executionTemplates
    history knownHunks usageTotals seed = do
    ts <- getTs svc
    writeLogEvent ws sessionId
        (EvtLlmResponse
            { timestamp: ts
            , content: seed.assistantContent
            , origin: "initial_seed"
            })
    let historyWithAssistant =
            addMsg history
                (AssistantMessage
                    { content: seed.assistantContent
                    , toolCalls: [seed.toolCall]
                    })
    toolResult <- doTool
        svc ws sessionId config apiKey kernel sandbox
        executionTemplates.timeout executionTemplates.stdin
        historyWithAssistant "initial_seed" seed.toolCall knownHunks usageTotals
    pure
        { history: toolResult.history
        , knownHunks: toolResult.hunks
        , usageTotals: toolResult.usageTotals
        }

buildSystemPrompt :: RunnerServices -> WorkspacePath -> Config -> Aff (Either AppError String)
buildSystemPrompt svc (WorkspacePath wp) config = do
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
            [ Tuple "agents_md" agentsMd
            , Tuple "startup_jl" startupJl
            , Tuple "datetime" (renderTimestamp ts)
            , Tuple "model" model
            ]
    readAndRenderTemplate svc
        (wp <> "/.7aigent/system_prompt.md")
        "system_prompt.md"
        vars

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
    -> ExecutionTemplates
    -> ConversationHistory
    -> Set HunkId
    -> Llm.LlmUsage
    -> Int
    -> String
    -> Maybe ParsedInitialMessage
    -> Maybe String
    -> Aff Int
runUserLoop
    svc ws sessionId config apiKey kernel sandbox
    steeringTemplate reflectionTemplate executionTemplates history
    knownHunks usageTotals autoTurnsTaken
    userMessageTemplate initialSeed maybePrompt = do
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

        let renderedLineR = renderUserMessage userMessageTemplate line
        renderedLine <- case renderedLineR of
            Left err -> do
                liftEffect $ svc.printErr ("Error in user_message.md: " <> show err)
                exit1 svc
            Right rendered ->
                pure rendered

        ts <- getTs svc
        writeLogEvent ws sessionId (EvtUserMessage
            { timestamp: ts
            , content: renderedLine
            , rawContent: Just line
            , source: Just "user"
            })

        let history' = addMsg history (UserMessage { content: renderedLine })
        seeded <- case initialSeed of
            Nothing ->
                pure
                    { history: history'
                    , knownHunks
                    , usageTotals
                    }
            Just seed ->
                applyInitialSeed
                    svc ws sessionId config apiKey kernel sandbox
                    executionTemplates history' knownHunks usageTotals seed
        roundResult <-
            runRound
                svc ws sessionId config apiKey kernel sandbox
                steeringTemplate reflectionTemplate executionTemplates seeded.history
                seeded.knownHunks seeded.usageTotals autoTurnsTaken
        liftEffect $ svc.printLn (renderSessionTokenUsage roundResult.usageTotals)

        case roundResult.error, maybePrompt of
            Just err, Nothing | isRecoverableSessionError err ->
                runUserLoop
                    svc ws sessionId config apiKey kernel sandbox
                    steeringTemplate reflectionTemplate executionTemplates
                    roundResult.history roundResult.knownHunks roundResult.usageTotals
                    roundResult.autoTurnsTaken userMessageTemplate Nothing Nothing
            Just _, _ -> do
                finishSession svc ws sessionId kernel roundResult.history SessionEndedError
                pure 1
            Nothing, Just _ -> do
                finishSession svc ws sessionId kernel roundResult.history SessionEndedPrompt
                pure 0
            Nothing, Nothing ->
                runUserLoop
                    svc ws sessionId config apiKey kernel sandbox
                    steeringTemplate reflectionTemplate executionTemplates
                    roundResult.history roundResult.knownHunks roundResult.usageTotals
                    roundResult.autoTurnsTaken userMessageTemplate Nothing Nothing

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
    -> ExecutionTemplates
    -> ConversationHistory
    -> TokenCount  -- ^ turn baseline: input tokens from first call of this turn (0 = first call)
    -> TokenCount  -- ^ last call tokens: input tokens from the most recent LLM call (0 = first call)
    -> Set HunkId
    -> Llm.LlmUsage
    -> Int
    -> Int
    -> Aff ReactLoopResult
runReactLoop
    svc ws sessionId config apiKey kernel sandbox steeringTemplate executionTemplates
    history turnBaseline lastCallTokens knownHunks usageTotals
    turnIndex autoTurnsTaken = do
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
    llmR <- svc.callLlm config apiKey historyForLlm
        { responseFormat: Llm.TextResponse
        , toolsEnabled: true
        , retryMode: Llm.RetryApiErrors
        , onToken: liftEffect <<< svc.printStr
        }
    liftEffect $ svc.printLn ""

    case llmR of
        Left err -> do
            liftEffect $ svc.printErr ("LLM error: " <> show err)
            pure { history, knownHunks, usageTotals, error: Just err }

        Right result -> case result.response of
            response@(LlmResponse r) -> do
                ts <- getTs svc
                writeLogEvent ws sessionId
                    (EvtLlmResponse { timestamp: ts, content: r.content, origin: "model" })

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
                            doTool
                                svc ws sessionId config apiKey kernel sandbox
                                executionTemplates.timeout executionTemplates.stdin
                                history' "model" tc knownHunks usageTotals'
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
                                    executionTemplates newBaseline r.inputTokens
                                    turnIndex autoTurnsTaken toolResult

                    ExecuteToolThenCompact tc -> do
                        toolR <- attempt $
                            doTool
                                svc ws sessionId config apiKey kernel sandbox
                                executionTemplates.timeout executionTemplates.stdin
                                history' "model" tc knownHunks usageTotals'
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
                                    executionTemplates newBaseline r.inputTokens
                                    turnIndex autoTurnsTaken toolResult

                    ExecuteToolThenEndTurn tc -> do
                        toolR <- attempt $
                            doTool
                                svc ws sessionId config apiKey kernel sandbox
                                executionTemplates.timeout executionTemplates.stdin
                                history' "model" tc knownHunks usageTotals'
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
                                    executionTemplates newBaseline r.inputTokens
                                    turnIndex autoTurnsTaken toolResult

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
    -> ExecutionTemplates
    -> TokenCount
    -> TokenCount
    -> Int
    -> Int
    ->
        { history :: ConversationHistory
        , hunks :: Set HunkId
        , toolInterrupted :: Boolean
        , usageTotals :: Llm.LlmUsage
        }
    -> Aff ReactLoopResult
handleCompletedToolStep
    postMode svc ws sessionId config apiKey kernel sandbox
    steeringTemplate executionTemplates turnBaseline
    currentRequestTokens turnIndex autoTurnsTaken toolResult =
    case toolStepDecision postMode toolResult.toolInterrupted of
        ContinueTurn ->
            runReactLoop
                svc ws sessionId config apiKey kernel sandbox
                steeringTemplate executionTemplates toolResult.history
                turnBaseline currentRequestTokens toolResult.hunks toolResult.usageTotals turnIndex autoTurnsTaken

        CompactAndContinueTurn -> do
            compactR <- doCompact svc
                ws
                sessionId
                config
                apiKey
                kernel
                currentRequestTokens
                toolResult.history
                toolResult.usageTotals
            case compactR of
                Left err -> do
                    liftEffect $ svc.printErr
                        "Context is too large to compact. Start a new session."
                    pure
                        { history: toolResult.history
                        , knownHunks: toolResult.hunks
                        , usageTotals: toolResult.usageTotals
                        , error: Just err
                        }
                Right compacted ->
                    runReactLoop
                        svc ws sessionId config apiKey kernel sandbox
                        steeringTemplate executionTemplates
                        compacted.history
                        (TokenCount 0) (TokenCount 0) toolResult.hunks
                        compacted.usageTotals turnIndex autoTurnsTaken

        EndTurnAndReflect -> do
            liftEffect $ svc.printLn "\n[Token limit reached — continuing...]"
            pure
                { history: toolResult.history
                , knownHunks: toolResult.hunks
                , usageTotals: toolResult.usageTotals
                , error: Nothing
                }

-- ---------------------------------------------------------------------------
-- A47: Julia state for steering and compaction
-- ---------------------------------------------------------------------------

-- | Print `SevenAigentREPL.status()` while preserving the current `Main.ans`.
-- | The trailing semicolon suppresses the restored value's execute result.
-- | Returns empty string on any error.
getJuliaState :: RunnerServices -> Jupyter.KernelHandle -> Aff String
getJuliaState svc kernel = do
    let code = String.joinWith "\n"
            [ "begin"
            , "  local _ans = isdefined(Main, :ans) ? Main.ans : nothing"
            , "  SevenAigentREPL.status()"
            , "  _ans"
            , "end;"
            ]
    result <- attempt $ svc.executeCodeDetailed kernel (RawJulia code) (const (pure unit))
    pure $ case result of
        Left _ -> ""
        Right execResult
            | execResult.hadError -> ""
            | otherwise -> String.trim execResult.output

-- | Load and validate the steering_message.md template.
-- | Calls `cleanup` then exits if the template cannot be read or contains unknown keywords.
loadSteeringTemplate :: RunnerServices -> WorkspacePath -> Aff Unit -> Aff String
loadSteeringTemplate svc (WorkspacePath wp) cleanup = do
    let validateVars = Map.fromFoldable
            [ Tuple "julia_state"          ""
            , Tuple "turn_tokens"          ""
            , Tuple "turn_token_limit"     ""
            , Tuple "compaction_threshold" ""
            , Tuple "turn_index"           ""
            , Tuple "max_turns_per_round"  ""
            , Tuple "auto_turns_taken"     ""
            ]
    tmplR <- readAndValidateTemplate svc
        (wp <> "/.7aigent/steering_message.md")
        "steering_message.md"
        validateVars
    case tmplR of
        Left _ -> do
            cleanup
            exit1 svc
        Right tmpl -> pure tmpl

-- | Load and validate the reflection_prompt.md template.
-- | Calls `cleanup` then exits if the template cannot be read or contains unknown keywords.
loadReflectionTemplate :: RunnerServices -> WorkspacePath -> Aff Unit -> Aff String
loadReflectionTemplate svc (WorkspacePath wp) cleanup = do
    let validateVars = Map.fromFoldable
            [ Tuple "turn_index"         ""
            , Tuple "auto_turns_taken"   ""
            , Tuple "max_turns_per_round" ""
            , Tuple "julia_state"        ""
            ]
    tmplR <- readAndValidateTemplate svc
        (wp <> "/.7aigent/reflection_prompt.md")
        "reflection_prompt.md"
        validateVars
    case tmplR of
        Left _ -> do
            cleanup
            exit1 svc
        Right tmpl -> pure tmpl

loadTimeoutTemplate :: RunnerServices -> WorkspacePath -> Aff Unit -> Aff String
loadTimeoutTemplate svc (WorkspacePath wp) cleanup = do
    let validateVars = Map.fromFoldable
            [ Tuple "julia_source" ""
            , Tuple "elapsed_time" ""
            , Tuple "output_so_far" ""
            , Tuple "json_schema" ""
            ]
    tmplR <- readAndValidateTemplate svc
        (wp <> "/.7aigent/timeout_prompt.md")
        "timeout_prompt.md"
        validateVars
    case tmplR of
        Left _ -> do
            cleanup
            exit1 svc
        Right tmpl -> pure tmpl

loadStdinTemplate :: RunnerServices -> WorkspacePath -> Aff Unit -> Aff String
loadStdinTemplate svc (WorkspacePath wp) cleanup = do
    let validateVars = Map.fromFoldable
            [ Tuple "julia_source" ""
            , Tuple "elapsed_time" ""
            , Tuple "output_so_far" ""
            , Tuple "prompt" ""
            , Tuple "json_schema" ""
            ]
    tmplR <- readAndValidateTemplate svc
        (wp <> "/.7aigent/stdin_prompt.md")
        "stdin_prompt.md"
        validateVars
    case tmplR of
        Left _ -> do
            cleanup
            exit1 svc
        Right tmpl -> pure tmpl

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
    llmR <- svc.callLlm config apiKey reflHistory
        { responseFormat: Llm.JsonObjectResponse
        , toolsEnabled: false
        , retryMode: Llm.RetryApiErrors
        , onToken: const (pure unit)
        }
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
    -> ExecutionTemplates
    -> ConversationHistory
    -> Set HunkId
    -> Llm.LlmUsage
    -> Int
    -> Aff RoundResult
runRound
    svc ws sessionId config apiKey kernel sandbox
    steeringTemplate reflectionTemplate executionTemplates history
    knownHunks usageTotals autoTurnsTaken =
    go history knownHunks usageTotals autoTurnsTaken 1
  where
    go hist hunks usage auto turnIndex = do
        loopResult <- runReactLoop
            svc ws sessionId config apiKey kernel sandbox
            steeringTemplate executionTemplates hist
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
                            { timestamp: ts
                            , content: feedbackMsg
                            , rawContent: Nothing
                            , source: Just "reflection"
                            })
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
    compactTmplR <- readAndValidateTemplate svc
        (wp <> "/.7aigent/compaction_prompt.md")
        "compaction_prompt.md"
        (Map.fromFoldable
            [ Tuple "initial_messages" ""
            , Tuple "compacted_messages" ""
            , Tuple "final_messages" ""
            , Tuple "julia_state" ""
            ])
    summaryTmplR <- readAndValidateTemplate svc
        (wp <> "/.7aigent/summary_message.md")
        "summary_message.md"
        (Map.fromFoldable [Tuple "summary" ""])
    case compactTmplR, summaryTmplR of
        Left err, _ ->
            pure (Left err)
        _, Left err ->
            pure (Left err)
        Right compactTmpl, Right summaryTmpl -> do

            let plan = buildCompactionPlan config.preserveInitial config.preserveFinal history
            let render msgs = String.joinWith "\n---\n" (map showMsg msgs)
            juliaState <- getJuliaState svc kernel
            let promptVars = Map.fromFoldable
                    [ Tuple "initial_messages"   (render plan.initialBlock)
                    , Tuple "compacted_messages" (render plan.compactedBlock)
                    , Tuple "final_messages"     (render plan.finalBlock)
                    , Tuple "julia_state"        juliaState
                    ]
            let promptText = fromMaybe
                    (render plan.compactedBlock)
                    (case substituteTemplate promptVars compactTmpl of
                        Left _ -> Nothing
                        Right t -> Just t)

            let compactHistory = ConversationHistory
                    { messages: [{ message: UserMessage { content: promptText }, tokens: TokenCount 0 }] }

            liftEffect $ svc.printStr "[Compacting context...]"
            summaryR <- svc.callLlm config apiKey compactHistory
                { responseFormat: Llm.TextResponse
                , toolsEnabled: true
                , retryMode: Llm.RetryApiErrors
                , onToken: const (pure unit)
                }
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
                        let summaryMsg = fromMaybe summary
                                (case substituteTemplate
                                    (Map.fromFoldable [Tuple "summary" summary]) summaryTmpl of
                                    Left _ -> Nothing
                                    Right t -> Just t)

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
    sessionId <- allocateSessionId ws

    startupFilesR <- validateStartupFiles svc ws config true
    startupFiles <- case startupFilesR of
        Left _ ->
            pure (Left (McpFailure "Template validation failed"))
        Right validated ->
            pure (Right validated)

    case startupFiles of
        Left e -> pure e
        Right files -> do
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
                    case kernelR of
                        Left err -> do
                            cleanup
                            pure (McpFailure ("Kernel error: " <> show err))
                        Right kernel -> do
                            let cleanupAll = do
                                    liftEffect $ svc.closeKernel kernel
                                    svc.killSandbox s

                            startupResult <- runStartupSequence svc ws kernel
                            startupOk <- case startupResult of
                                Left _       -> do
                                    cleanupAll
                                    pure (Left (McpFailure "Startup failed"))
                                Right _ -> pure (Right unit)

                            case startupOk of
                                Left e -> pure e
                                Right _ -> do
                                    systemPromptR <- buildSystemPrompt svc ws config
                                    case systemPromptR of
                                        Left _ -> do
                                            cleanupAll
                                            pure (McpFailure "Could not build system prompt")
                                        Right systemPrompt -> do
                                            case renderUserMessage files.userMessageTemplate message of
                                                Left _ -> do
                                                    cleanupAll
                                                    pure (McpFailure "Could not render user_message.md")
                                                Right renderedMessage -> do
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
                                                        , content: renderedMessage
                                                        , rawContent: Just message
                                                        , source: Just "user"
                                                        })

                                                    steeringTmpl   <- loadSteeringTemplate svc   ws cleanupAll
                                                    reflectionTmpl <- loadReflectionTemplate svc ws cleanupAll
                                                    timeoutTmpl    <- loadTimeoutTemplate svc ws cleanupAll
                                                    stdinTmpl      <- loadStdinTemplate svc ws cleanupAll
                                                    let executionTemplates =
                                                            { timeout: timeoutTmpl, stdin: stdinTmpl }

                                                    let baseHistory =
                                                            addMsg
                                                                (addMsg (ConversationHistory { messages: [] })
                                                                    (SystemMessage { content: systemPrompt }))
                                                                (UserMessage { content: renderedMessage })

                                                    seeded <- case files.initialSeed of
                                                        Nothing ->
                                                            pure
                                                                { history: baseHistory
                                                                , knownHunks: Set.empty
                                                                , usageTotals: zeroLlmUsage
                                                                }
                                                        Just seed ->
                                                            applyInitialSeed
                                                                svc ws sessionId config apiKey kernel s
                                                                executionTemplates baseHistory Set.empty zeroLlmUsage seed

                                                    roundResult <- runRound svc ws sessionId config apiKey kernel s
                                                        steeringTmpl reflectionTmpl executionTemplates seeded.history
                                                        seeded.knownHunks seeded.usageTotals 0

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
