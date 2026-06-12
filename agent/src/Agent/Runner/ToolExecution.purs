module Agent.Runner.ToolExecution
    ( doTool
    ) where

import Prelude

import Control.Alt ((<|>))
import Control.Parallel (parallel, sequential)
import Data.Argonaut.Core as J
import Data.Argonaut.Parser as JP
import Data.Array as Array
import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set
import Data.String as String
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Aff (Aff, Milliseconds(..), attempt, bracket, delay, forkAff)
import Effect.Aff.AVar as AVar
import Effect.AVar as EffectAVar
import Effect.Class (liftEffect)
import Effect.Exception as Exception
import Effect.Exception (message)
import Effect.Ref as Ref

import Agent.Types
    ( WorkspacePath
    , SessionId
    , Timestamp(..)
    , ToolName(..)
    , Config
    , ConversationHistory(..)
    , ToolCall
    , ToolCallId
    , HunkId
    , RawJulia(..)
    , TokenCount(..)
    , Message(..)
    , LogEvent(..)
    , LlmResponse(..)
    , renderToolName
    , extractContent
    )
import Agent.Programs.ExecutionDecision
    ( DecisionFailure(..)
    , StdinDecision(..)
    , TimeoutDecision(..)
    , decisionRetryDelayMilliseconds
    , parseStdinDecision
    , parseTimeoutDecision
    , renderInputAnnotation
    , renderStdinPrompt
    , renderTimeoutPrompt
    )
import Agent.Programs.GitCommit
    ( runGitCommitAll
    , runGitCommitPlan
    , runGitCommitStaged
    )
import Agent.Programs.GitStage
    ( runGitStageAll
    , runGitStagePlan
    )
import Agent.Programs.GitWritePlan (GitWritePlan)
import Agent.Programs.SessionLog (writeLogEvent)
import Agent.Programs.SummaryRequest
    ( buildSummaryHistory
    , encodeSummaryError
    , encodeSummaryResult
    , parseSummaryResponse
    )
import Agent.Programs.Timeout (isCheckDue)
import Agent.Programs.ToolInput
    ( summarizeToolInput
    , parseJuliaCodeInput
    , parseGitStageInput
    , parseGitCommitInput
    )
import Agent.Programs.ToolOutput (processToolOutput)
import Agent.Runner.Services (RunnerServices)
import Agent.Services.Jupyter as Jupyter
import Agent.Services.Jupyter (KernelHandle)
import Agent.Services.Llm as Llm
import Agent.Services.Sandbox (SandboxHandle)

foreign import decodeHexUtf8 :: String -> String
foreign import nowEpochMilliseconds :: Effect Number

data GitStageWhat
    = StageAll
    | StageSelectors (Array String)

data GitCommitWhat
    = CommitAll
    | CommitStaged
    | CommitSelectors (Array String)

data InputOutcome
    = InputReplied
    | InputInterrupted String

data ExecutionEvent
    = InputArrived Jupyter.InputRequest
    | ExecutionCompleted Jupyter.ExecutionResult
    | ExecutionFailed String

type ParsedGitWritePlan =
    { wholeFiles :: Array { path :: String, oldPath :: Maybe String }
    , partialAllPatch :: Maybe String
    , partialUnstagedPatch :: Maybe String
    }

doTool
    :: RunnerServices
    -> WorkspacePath
    -> SessionId
    -> Config
    -> String
    -> KernelHandle
    -> SandboxHandle
    -> String
    -> String
    -> ConversationHistory
    -> ToolCall
    -> Set HunkId
    -> Llm.LlmUsage
    -> Aff
        { history :: ConversationHistory
        , hunks :: Set HunkId
        , toolInterrupted :: Boolean
        , usageTotals :: Llm.LlmUsage
        }
doTool
    svc ws sessionId config apiKey kernel _sandbox timeoutTemplate stdinTemplate
    history tc knownHunks usageTotals = do
    ts <- Timestamp <$> liftEffect svc.nowIso
    writeLogEvent ws sessionId (EvtToolCall
        { timestamp: ts
        , toolName: tc.name
        , toolCallId: tc.id
        , input: tc.input
        })
    liftEffect $ svc.printLn ("\n[Tool: " <> renderToolName tc.name <> "]")
    let inputSummary = summarizeToolInput tc.name tc.input
    when (not (String.null inputSummary)) do
        liftEffect $ svc.printLn inputSummary

    usageRef <- liftEffect $ Ref.new usageTotals
    { output: rawOut, hunks: hunks', toolInterrupted } <-
        dispatchTool
            svc ws sessionId config apiKey kernel timeoutTemplate stdinTemplate
            tc knownHunks usageRef

    let proc = processToolOutput config.outputThresholdChars rawOut
    liftEffect $ svc.printLn proc.displayText

    ts2 <- Timestamp <$> liftEffect svc.nowIso
    writeLogEvent ws sessionId (ToolResult
        { timestamp: ts2
        , toolCallId: tc.id
        , output: proc.fullOutput
        , truncated: proc.truncated
        })

    let toolMsg = ToolResultMessage { toolCallId: tc.id, output: proc.llmFacing }
    usageTotals' <- liftEffect $ Ref.read usageRef
    pure
        { history: addMsg history toolMsg
        , hunks: hunks'
        , toolInterrupted
        , usageTotals: usageTotals'
        }

dispatchTool
    :: RunnerServices
    -> WorkspacePath
    -> SessionId
    -> Config
    -> String
    -> KernelHandle
    -> String
    -> String
    -> ToolCall
    -> Set HunkId
    -> Ref.Ref Llm.LlmUsage
    -> Aff { output :: String, hunks :: Set HunkId, toolInterrupted :: Boolean }
dispatchTool
    svc ws sessionId config apiKey kernel timeoutTemplate stdinTemplate
    tc knownHunks usageRef =
    case tc.name of
        JuliaRepl -> do
            let code = parseJuliaCodeInput tc.input
            result <- runJuliaReplWithTimeoutChecks
                svc
                ws
                sessionId
                config
                apiKey
                kernel
                tc.id
                timeoutTemplate
                stdinTemplate
                usageRef
                (RawJulia code)
            pure
                { output: result.output
                , hunks: Set.empty
                , toolInterrupted: result.toolInterrupted
                }

        GitStage ->
            case parseGitStageInput tc.input of
                Nothing ->
                    toolFailure "Invalid git_stage input"
                Just input ->
                    case parseGitStageWhat input.what of
                        Left err ->
                            toolFailure err
                        Right StageAll -> do
                            refreshR <- refreshWorkspaceView svc kernel
                            case refreshR of
                                Left err ->
                                    toolFailure err
                                Right _ -> do
                                    stageR <- runGitStageAll ws
                                    pure case stageR of
                                        Left err ->
                                            { output: show err
                                            , hunks: Set.empty
                                            , toolInterrupted: false
                                            }
                                        Right msg ->
                                            { output: msg
                                            , hunks: Set.empty
                                            , toolInterrupted: false
                                            }
                        Right (StageSelectors selectors) -> do
                            planR <- loadGitWritePlan svc kernel selectors
                            case planR of
                                Left err ->
                                    toolFailure err
                                Right plan -> do
                                    stageR <- runGitStagePlan ws plan
                                    pure case stageR of
                                        Left err ->
                                            { output: show err
                                            , hunks: Set.empty
                                            , toolInterrupted: false
                                            }
                                        Right msg ->
                                            { output: msg
                                            , hunks: Set.empty
                                            , toolInterrupted: false
                                            }

        GitCommit ->
            case parseGitCommitInput tc.input of
                Nothing ->
                    toolFailure "Invalid git_commit input"
                Just input ->
                    case parseGitCommitWhat input.what of
                        Left err ->
                            toolFailure err
                        Right CommitAll -> do
                            refreshR <- refreshWorkspaceView svc kernel
                            case refreshR of
                                Left err ->
                                    toolFailure err
                                Right _ -> do
                                    commitR <- runGitCommitAll ws input.message input.body
                                    pure case commitR of
                                        Left err ->
                                            { output: show err
                                            , hunks: Set.empty
                                            , toolInterrupted: false
                                            }
                                        Right msg ->
                                            { output: msg
                                            , hunks: Set.empty
                                            , toolInterrupted: false
                                            }
                        Right CommitStaged -> do
                            refreshR <- refreshWorkspaceView svc kernel
                            case refreshR of
                                Left err ->
                                    toolFailure err
                                Right _ -> do
                                    commitR <- runGitCommitStaged ws input.message input.body
                                    pure case commitR of
                                        Left err ->
                                            { output: show err
                                            , hunks: Set.empty
                                            , toolInterrupted: false
                                            }
                                        Right msg ->
                                            { output: msg
                                            , hunks: Set.empty
                                            , toolInterrupted: false
                                            }
                        Right (CommitSelectors selectors) -> do
                            planR <- loadGitWritePlan svc kernel selectors
                            case planR of
                                Left err ->
                                    toolFailure err
                                Right plan -> do
                                    commitR <- runGitCommitPlan ws plan input.message input.body
                                    pure case commitR of
                                        Left err ->
                                            { output: show err
                                            , hunks: Set.empty
                                            , toolInterrupted: false
                                            }
                                        Right msg ->
                                            { output: msg
                                            , hunks: Set.empty
                                            , toolInterrupted: false
                                            }

        UnknownToolName other ->
            pure
                { output: "Unknown tool: " <> other
                , hunks: knownHunks
                , toolInterrupted: false
                }
  where
    toolFailure output =
        pure
            { output
            , hunks: Set.empty
            , toolInterrupted: false
            }

runJuliaReplWithTimeoutChecks
    :: RunnerServices
    -> WorkspacePath
    -> SessionId
    -> Config
    -> String
    -> KernelHandle
    -> ToolCallId
    -> String
    -> String
    -> Ref.Ref Llm.LlmUsage
    -> RawJulia
    -> Aff { output :: String, toolInterrupted :: Boolean }
runJuliaReplWithTimeoutChecks
    svc ws sessionId config apiKey kernel toolCallId
    timeoutTemplate stdinTemplate usageRef source = do
    startedAt <- liftEffect nowEpochMilliseconds
    partialRef <- liftEffect $ Ref.new ""
    eventVar <- AVar.empty
    sequenceRef <- liftEffect $ Ref.new 0
    let wrappedSource = wrapJuliaSourceWithRefresh source
    _ <- forkAff do
        result <- attempt $ svc.executeCodeDetailedWithInput
            kernel
            wrappedSource
            (\chunk -> Ref.modify_ (_ <> chunk) partialRef)
            (\request ->
                void $ EffectAVar.put
                    (InputArrived request)
                    eventVar
                    (const (pure unit)))
        case result of
            Left err ->
                AVar.put (ExecutionFailed (message err)) eventVar
            Right execResult ->
                AVar.put (ExecutionCompleted execResult) eventVar
    waitForResult startedAt 0 0 partialRef eventVar sequenceRef
  where
    waitForResult
        startedAt scheduleElapsed lastCheckAt partialRef eventVar sequenceRef = do
        next <- raceAff
            (delay (Milliseconds 1000.0))
            (AVar.take eventVar)
        case next of
            Right event ->
                handleExecutionEvent
                    startedAt scheduleElapsed lastCheckAt
                    partialRef eventVar sequenceRef event
            Left _ ->
                checkTimeout
      where
        checkTimeout = do
            let scheduleElapsed' = scheduleElapsed + 1
            if isCheckDue config.timeoutCheckSeconds scheduleElapsed' lastCheckAt then do
                partialOutput <- liftEffect $ Ref.read partialRef
                elapsed <- elapsedSince startedAt
                next <- raceAff
                    (runTimeoutCheck elapsed partialOutput)
                    (AVar.take eventVar)
                case next of
                    Right event ->
                        handleExecutionEvent
                            startedAt scheduleElapsed' lastCheckAt
                            partialRef eventVar sequenceRef event
                    Left InterruptForTimeout -> do
                        svc.interruptKernel kernel
                        interruptedOutput <- liftEffect $ Ref.read partialRef
                        pure
                            { output: interruptedOutput <> "\n[interrupted]"
                            , toolInterrupted: true
                            }
                    Left ContinueAfterTimeout ->
                        waitForResult
                            startedAt scheduleElapsed' scheduleElapsed'
                            partialRef eventVar sequenceRef
            else
                waitForResult
                    startedAt scheduleElapsed' lastCheckAt
                    partialRef eventVar sequenceRef

    handleExecutionEvent
        startedAt scheduleElapsed lastCheckAt partialRef eventVar sequenceRef event =
        case event of
            ExecutionFailed errMsg ->
                liftEffect $ Exception.throw errMsg
            ExecutionCompleted result ->
                pure { output: result.output, toolInterrupted: false }
            InputArrived request -> do
                outcome <- bracket
                    (pure unit)
                    (const (liftEffect request.cancel))
                    (const case request.summaryRequest of
                        Nothing -> do
                            sequence <- liftEffect $
                                Ref.modify (\n -> n + 1) sequenceRef
                            handleInputRequest
                                startedAt sequence request partialRef
                        Just loadRequest ->
                            handleSummaryRequest request loadRequest)
                case outcome of
                    InputReplied ->
                        waitForResult
                            startedAt 0 0 partialRef eventVar sequenceRef
                    InputInterrupted marker -> do
                        partialOutput <- liftEffect $ Ref.read partialRef
                        pure
                            { output: partialOutput <> marker
                            , toolInterrupted: true
                            }

    handleSummaryRequest request loadRequest = do
        requestResult <- attempt loadRequest
        replyValue <- case requestResult of
            Left err ->
                pure (encodeSummaryError (message err))
            Right requestJson -> do
                ts <- Timestamp <$> liftEffect svc.nowIso
                writeLogEvent ws sessionId (EvtLlmQuery
                    { timestamp: ts
                    , purpose: "summary"
                    , input: requestJson
                    })
                case buildSummaryHistory requestJson of
                    Left err ->
                        pure (encodeSummaryError err)
                    Right summaryCall -> do
                        result <- runStructuredCall
                            summaryCall.history
                            (parseSummaryResponse summaryCall.targetIds)
                            (\_ _ -> pure unit)
                        pure case result of
                            Left err ->
                                encodeSummaryError err
                            Right summaries ->
                                encodeSummaryResult summaries
        replyResult <- Jupyter.sendInputReply request replyValue ""
        case replyResult of
            Right _ ->
                pure InputReplied
            Left _ -> do
                liftEffect request.cancel
                svc.interruptKernel kernel
                pure
                    (InputInterrupted
                        "\n[interrupted: summary reply failed]")

    raceAff :: forall left right. Aff left -> Aff right -> Aff (Either left right)
    raceAff left right =
        sequential $
            parallel (Left <$> left)
            <|>
            parallel (Right <$> right)

    elapsedSince startedAt = do
        now <- liftEffect nowEpochMilliseconds
        pure (Int.floor ((now - startedAt) / 1000.0))

    handleInputRequest startedAt sequence request partialRef = do
        elapsed <- elapsedSince startedAt
        partialOutput <- liftEffect $ Ref.read partialRef
        let promptResult = renderStdinPrompt stdinTemplate
                { juliaSource: unwrapRawJulia source
                , elapsedSeconds: elapsed
                , outputSoFar: partialOutput
                , prompt: request.prompt
                }
        case promptResult of
            Left _ -> do
                liftEffect request.cancel
                svc.interruptKernel kernel
                pure (InputInterrupted "\n[interrupted: stdin response unavailable]")
            Right requestText -> do
                liftEffect $ svc.printLn requestText
                decision <- runDecisionCall
                    requestText
                    parseStdinDecision
                    (logStdinDecisionAttempt elapsed sequence request)
                case decision of
                    Just InterruptForStdin -> do
                        liftEffect request.cancel
                        svc.interruptKernel kernel
                        pure (InputInterrupted "\n[interrupted]")
                    Just (ReplyWithInput value) -> do
                        let annotation = renderInputAnnotation value
                        replyResult <- Jupyter.sendInputReply
                            request
                            value
                            annotation
                        case replyResult of
                            Right _ ->
                                pure InputReplied
                            Left _ -> do
                                liftEffect request.cancel
                                svc.interruptKernel kernel
                                pure
                                    (InputInterrupted
                                        "\n[interrupted: stdin reply failed]")
                    _ -> do
                        liftEffect request.cancel
                        svc.interruptKernel kernel
                        pure
                            (InputInterrupted
                                "\n[interrupted: stdin response unavailable]")

    logStdinDecisionAttempt elapsed sequence request attemptNumber result =
        case result of
            Left err ->
                logStdinAttempt
                    elapsed sequence attemptNumber request
                    Nothing Nothing (Just err)
            Right InterruptForStdin ->
                logStdinAttempt
                    elapsed sequence attemptNumber request
                    Nothing (Just true) Nothing
            Right (ReplyWithInput value) ->
                logStdinAttempt
                    elapsed sequence attemptNumber request
                    (Just value)
                    (Just false)
                    Nothing

    logStdinAttempt elapsed sequence attemptNumber request value interrupt err = do
        ts <- Timestamp <$> liftEffect svc.nowIso
        writeLogEvent ws sessionId (StdinRequest
            { timestamp: ts
            , toolCallId
            , sequence
            , attempt: attemptNumber
            , elapsedSeconds: elapsed
            , prompt: request.prompt
            , value
            , interrupt
            , error: err
            })

    recordUsage usage = do
        totals <- liftEffect $ Ref.read usageRef
        let totals' = addUsage totals usage
        liftEffect $ Ref.write totals' usageRef
        ts <- Timestamp <$> liftEffect svc.nowIso
        writeLogEvent ws sessionId (TokenUsage
            { timestamp: ts
            , inputTokens: usage.inputTokens
            , cachedInputTokens: usage.cachedInputTokens
            , outputTokens: usage.outputTokens
            , totalSessionInputTokens: totals'.inputTokens
            , totalSessionCachedInputTokens: totals'.cachedInputTokens
            , totalSessionOutputTokens: totals'.outputTokens
            })

    runTimeoutCheck elapsed partialOutput = do
        ts <- Timestamp <$> liftEffect svc.nowIso
        writeLogEvent ws sessionId (TimeoutCheck
            { timestamp: ts
            , elapsedSeconds: elapsed
            , partialOutput
            })

        let promptResult = renderTimeoutPrompt timeoutTemplate
                { juliaSource: unwrapRawJulia source
                , elapsedSeconds: elapsed
                , outputSoFar: partialOutput
                }
        decision <- case promptResult of
            Left _ ->
                pure ContinueAfterTimeout
            Right requestText -> do
                liftEffect $ svc.printLn requestText
                result <- runDecisionCall
                    requestText
                    parseTimeoutDecision
                    (\_ _ -> pure unit)
                pure case result of
                    Just parsed -> parsed
                    Nothing -> ContinueAfterTimeout
        ts2 <- Timestamp <$> liftEffect svc.nowIso
        writeLogEvent ws sessionId (TimeoutResponse
            { timestamp: ts2
            , interrupt: decision == InterruptForTimeout
            })
        pure decision

    runDecisionCall
        :: forall decision
         . String
        -> (String -> Either String decision)
        -> (Int -> Either String decision -> Aff Unit)
        -> Aff (Maybe decision)
    runDecisionCall requestText parseDecision onAttempt =
        map hushStructuredResult $ runStructuredCall
            (decisionHistory requestText)
            parseDecision
            onAttempt

    runStructuredCall
        :: forall result
         . ConversationHistory
        -> (String -> Either String result)
        -> (Int -> Either String result -> Aff Unit)
        -> Aff (Either String result)
    runStructuredCall history parseResult onAttempt =
        go 1
      where
        go attemptNumber = do
            llmR <- svc.callLlm
                config
                apiKey
                history
                { responseFormat: Llm.JsonObjectResponse
                , toolsEnabled: false
                , retryMode: Llm.SingleApiAttempt
                , onToken: const (pure unit)
                }
            attemptResult <- case llmR of
                Left err ->
                    pure (Left (DecisionApiFailure (show err)))
                Right result -> do
                    recordUsage result.usage
                    let (LlmResponse response) = result.response
                    pure case parseResult response.content of
                        Left err ->
                            Left (DecisionResponseFailure err)
                        Right decision ->
                            Right decision
            case attemptResult of
                Left (DecisionApiFailure err) ->
                    onAttempt attemptNumber (Left err)
                Left (DecisionResponseFailure err) ->
                    onAttempt attemptNumber (Left err)
                Right parsedDecision ->
                    onAttempt attemptNumber (Right parsedDecision)
            case attemptResult of
                Right decision ->
                    pure (Right decision)
                Left failure | attemptNumber <= config.maxApiRetries -> do
                    case decisionRetryDelayMilliseconds attemptNumber failure of
                        Nothing ->
                            pure unit
                        Just milliseconds ->
                            svc.delayMilliseconds milliseconds
                    go (attemptNumber + 1)
                Left failure ->
                    pure (Left (decisionFailureMessage failure))

    hushStructuredResult :: forall result. Either String result -> Maybe result
    hushStructuredResult result =
        case result of
            Left _ -> Nothing
            Right value -> Just value

    decisionFailureMessage :: DecisionFailure -> String
    decisionFailureMessage failure =
        case failure of
            DecisionApiFailure err -> err
            DecisionResponseFailure err -> err

refreshWorkspaceView
    :: RunnerServices
    -> KernelHandle
    -> Aff (Either String Unit)
refreshWorkspaceView svc kernel = do
    result <- svc.executeCodeDetailed kernel workspaceRefreshSource (\_ -> pure unit)
    pure $
        if result.hadError then Left result.output else Right unit

loadGitWritePlan
    :: RunnerServices
    -> KernelHandle
    -> Array String
    -> Aff (Either String GitWritePlan)
loadGitWritePlan svc kernel selectors = do
    let source = RawJulia (renderGitWritePlanJulia selectors)
    result <- svc.executeCodeDetailed kernel source (\_ -> pure unit)
    pure $
        if result.hadError
        then Left result.output
        else parseGitWritePlanText result.output

workspaceRefreshSource :: RawJulia
workspaceRefreshSource =
    RawJulia $ String.joinWith "\n"
        ([ "begin" ] <> workspaceRefreshLines <> [ "nothing;", "end" ])

wrapJuliaSourceWithRefresh :: RawJulia -> RawJulia
wrapJuliaSourceWithRefresh (RawJulia code) =
    RawJulia $ String.joinWith "\n"
        ([ "begin" ] <> workspaceRefreshLines <> [ code, "end" ])

workspaceRefreshLines :: Array String
workspaceRefreshLines =
    [ "if isdefined(Main, :db)"
    , "    let"
    , "        __sevenaigent_summary_overrides__ = copy(getfield(db.code, :_summary_overrides))"
    , "        CodeTree.reload(db)"
    , "        for (__sevenaigent_id__, __sevenaigent_summary__) in __sevenaigent_summary_overrides__"
    , "            __sevenaigent_idx__ = findfirst(==(__sevenaigent_id__), db.code.id)"
    , "            isnothing(__sevenaigent_idx__) && continue"
    , "            db.code[__sevenaigent_idx__, :summary] = __sevenaigent_summary__"
    , "        end"
    , "    end"
    , "end"
    ]

renderGitWritePlanJulia :: Array String -> String
renderGitWritePlanJulia selectors =
    String.joinWith "\n"
        ( [ "begin" ]
            <> workspaceRefreshLines
            <> [ "let"
               , "    __sevenaigent_selectors__ = " <> renderJuliaStringArray selectors
               , "    print(CodeTree._git_write_plan_text(db, __sevenaigent_selectors__))"
               , "end"
               , "nothing;"
               , "end"
               ]
        )

renderJuliaStringArray :: Array String -> String
renderJuliaStringArray selectors =
    "[" <> String.joinWith ", " (map show selectors) <> "]"

parseGitStageWhat :: String -> Either String GitStageWhat
parseGitStageWhat input
    | input == "all" || input == "\"all\"" = Right StageAll
    | otherwise = StageSelectors <$> parseSelectorArray input

parseGitCommitWhat :: String -> Either String GitCommitWhat
parseGitCommitWhat input
    | input == "all" || input == "\"all\"" = Right CommitAll
    | input == "staged" || input == "\"staged\"" = Right CommitStaged
    | otherwise = CommitSelectors <$> parseSelectorArray input

parseSelectorArray :: String -> Either String (Array String)
parseSelectorArray input =
    case JP.jsonParser input of
        Left _ ->
            Left "Expected a non-empty JSON array of selectors"
        Right json ->
            case J.toArray json of
                Nothing ->
                    Left "Expected a non-empty JSON array of selectors"
                Just [] ->
                    Left "Expected a non-empty JSON array of selectors"
                Just values ->
                    case traverse J.toString values of
                        Nothing ->
                            Left "Expected a non-empty JSON array of selectors"
                        Just selectors ->
                            Right selectors

parseGitWritePlanText :: String -> Either String GitWritePlan
parseGitWritePlanText input = do
    parsed <- go initialPlanState nonEmptyLines
    case { allPatch: parsed.partialAllPatch, unstagedPatch: parsed.partialUnstagedPatch } of
        { allPatch: Just partialAllPatch, unstagedPatch: Just partialUnstagedPatch } ->
            Right
                { wholeFiles: parsed.wholeFiles
                , partialAllPatch
                , partialUnstagedPatch
                }
        _ ->
            Left "Invalid git write plan output"
  where
    nonEmptyLines =
        Array.filter (not <<< String.null)
            (String.split (String.Pattern "\n") input)

    initialPlanState =
        { wholeFiles: []
        , partialAllPatch: Nothing
        , partialUnstagedPatch: Nothing
        }

    go state lines =
        case Array.uncons lines of
            Nothing ->
                Right state
            Just { head: line, tail: rest } -> do
                nextState <- parseGitWritePlanLine state line
                go nextState rest

parseGitWritePlanLine
    :: ParsedGitWritePlan
    -> String
    -> Either String ParsedGitWritePlan
parseGitWritePlanLine state line =
    case String.stripPrefix (String.Pattern "WHOLE\t") line of
        Just payload ->
            case String.split (String.Pattern "\t") payload of
                [ path64, oldPath64 ] ->
                    let wholeFile =
                            { path: decodeHexUtf8 path64
                            , oldPath:
                                if String.null oldPath64
                                then Nothing
                                else Just (decodeHexUtf8 oldPath64)
                            }
                    in Right $ state { wholeFiles = state.wholeFiles <> [ wholeFile ] }
                _ ->
                    Left "Invalid git write plan output"
        Nothing ->
            case String.stripPrefix (String.Pattern "PARTIAL_ALL\t") line of
                Just payload ->
                    Right $ state
                        { partialAllPatch = Just (decodeHexUtf8 payload) }
                Nothing ->
                    case String.stripPrefix (String.Pattern "PARTIAL_UNSTAGED\t") line of
                        Just payload ->
                            Right $ state
                                { partialUnstagedPatch = Just (decodeHexUtf8 payload) }
                        Nothing ->
                            Left "Invalid git write plan output"

addMsg :: ConversationHistory -> Message -> ConversationHistory
addMsg (ConversationHistory history) msg =
    ConversationHistory
        { messages: history.messages <>
            [{ message: msg, tokens: estimateTokens (extractContent msg) }]
        }

estimateTokens :: String -> TokenCount
estimateTokens s = TokenCount (max 1 (String.length s / 4))

unwrapRawJulia :: RawJulia -> String
unwrapRawJulia (RawJulia source) = source

decisionHistory :: String -> ConversationHistory
decisionHistory prompt =
    ConversationHistory
        { messages:
            [ { message: UserMessage { content: prompt }
              , tokens: estimateTokens prompt
              }
            ]
        }

addUsage :: Llm.LlmUsage -> Llm.LlmUsage -> Llm.LlmUsage
addUsage totals usage =
    { inputTokens: addTokenCounts totals.inputTokens usage.inputTokens
    , cachedInputTokens:
        addTokenCounts totals.cachedInputTokens usage.cachedInputTokens
    , outputTokens: addTokenCounts totals.outputTokens usage.outputTokens
    }

addTokenCounts :: TokenCount -> TokenCount -> TokenCount
addTokenCounts (TokenCount left) (TokenCount right) =
    TokenCount (left + right)
