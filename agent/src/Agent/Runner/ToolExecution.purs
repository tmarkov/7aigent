module Agent.Runner.ToolExecution
    ( doTool
    ) where

import Prelude

import Data.Argonaut.Core as J
import Data.Argonaut.Parser as JP
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set
import Data.String as String
import Data.Traversable (traverse)
import Effect.Aff (Aff, Milliseconds(..), attempt, delay, forkAff)
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
    , HunkId
    , RawJulia(..)
    , TokenCount(..)
    , Message(..)
    , LogEvent(..)
    , LlmResponse(..)
    , renderToolName
    , extractContent
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
import Agent.Programs.Timeout
    ( buildTimeoutCheckRequest
    , interpretTimeoutResponse
    , isCheckDue
    , TimeoutDecision(..)
    )
import Agent.Programs.ToolInput
    ( summarizeToolInput
    , parseJuliaCodeInput
    , parseGitStageInput
    , parseGitCommitInput
    )
import Agent.Programs.ToolOutput (processToolOutput)
import Agent.Runner.Services (RunnerServices)
import Agent.Services.Jupyter (KernelHandle)

foreign import decodeHexUtf8 :: String -> String

data GitStageWhat
    = StageAll
    | StageSelectors (Array String)

data GitCommitWhat
    = CommitAll
    | CommitStaged
    | CommitSelectors (Array String)

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
    -> ConversationHistory
    -> ToolCall
    -> Set HunkId
    -> Aff { history :: ConversationHistory, hunks :: Set HunkId, toolInterrupted :: Boolean }
doTool svc ws sessionId config apiKey kernel history tc knownHunks = do
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

    { output: rawOut, hunks: hunks', toolInterrupted } <-
        dispatchTool svc ws sessionId config apiKey kernel tc knownHunks

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
    pure { history: addMsg history toolMsg, hunks: hunks', toolInterrupted }

dispatchTool
    :: RunnerServices
    -> WorkspacePath
    -> SessionId
    -> Config
    -> String
    -> KernelHandle
    -> ToolCall
    -> Set HunkId
    -> Aff { output :: String, hunks :: Set HunkId, toolInterrupted :: Boolean }
dispatchTool svc ws sessionId config apiKey kernel tc knownHunks =
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
                                Right unit -> do
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
                                Right unit -> do
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
                                Right unit -> do
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
    -> RawJulia
    -> Aff { output :: String, toolInterrupted :: Boolean }
runJuliaReplWithTimeoutChecks svc ws sessionId config apiKey kernel source = do
    partialRef <- liftEffect $ Ref.new ""
    resultRef <- liftEffect $ Ref.new Nothing
    errorRef <- liftEffect $ Ref.new Nothing
    let wrappedSource = wrapJuliaSourceWithRefresh source
    _ <- forkAff do
        result <- attempt $ svc.executeCodeDetailed kernel wrappedSource \chunk ->
            Ref.modify_ (_ <> chunk) partialRef
        case result of
            Left err ->
                liftEffect $ Ref.write (Just (message err)) errorRef
            Right execResult ->
                liftEffect $ Ref.write (Just execResult) resultRef
    waitForResult 0 0 partialRef resultRef errorRef
  where
    waitForResult elapsed lastCheckAt partialRef resultRef errorRef = do
        maybeError <- liftEffect $ Ref.read errorRef
        case maybeError of
            Just errMsg ->
                liftEffect $ Exception.throw errMsg
            Nothing ->
                pure unit
        maybeResult <- liftEffect $ Ref.read resultRef
        case maybeResult of
            Just result ->
                pure { output: result.output, toolInterrupted: false }
            Nothing -> do
                delay (Milliseconds 1000.0)
                let elapsed' = elapsed + 1
                if isCheckDue elapsed' lastCheckAt then do
                    partialOutput <- liftEffect $ Ref.read partialRef
                    decision <- runTimeoutCheck elapsed' partialOutput
                    case decision of
                        Interrupt -> do
                            svc.interruptKernel kernel
                            interruptedOutput <- liftEffect $ Ref.read partialRef
                            pure
                                { output: interruptedOutput <> "\n[interrupted]"
                                , toolInterrupted: true
                                }
                        ScheduleNext _ ->
                            waitForResult elapsed' elapsed' partialRef resultRef errorRef
                else
                    waitForResult elapsed' lastCheckAt partialRef resultRef errorRef

    runTimeoutCheck elapsed partialOutput = do
        ts <- Timestamp <$> liftEffect svc.nowIso
        writeLogEvent ws sessionId (TimeoutCheck
            { timestamp: ts
            , elapsedSeconds: elapsed
            , partialOutput
            })

        let requestText = renderTimeoutCheckRequest source elapsed partialOutput
        liftEffect $ svc.printLn requestText
        llmR <- svc.callLlm
            config
            apiKey
            (timeoutCheckHistory requestText)
            (liftEffect <<< svc.printStr)
        liftEffect $ svc.printLn ""

        let decision = case llmR of
                Left _ -> ScheduleNext 60
                Right result ->
                    let (LlmResponse response) = result.response
                    in interpretTimeoutResponse response.content
        ts2 <- Timestamp <$> liftEffect svc.nowIso
        writeLogEvent ws sessionId (TimeoutResponse
            { timestamp: ts2
            , interrupt: decision == Interrupt
            })
        pure decision

renderTimeoutCheckRequest :: RawJulia -> Int -> String -> String
renderTimeoutCheckRequest source elapsed partialOutput =
    String.joinWith "\n\n"
        (map _.content (buildTimeoutCheckRequest source elapsed partialOutput))

timeoutCheckHistory :: String -> ConversationHistory
timeoutCheckHistory requestText =
    ConversationHistory
        { messages:
            [ { message: UserMessage { content: requestText }
              , tokens: estimateTokens requestText
              }
            ]
        }

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
    [ "let"
    , "    __sevenaigent_summary_overrides__ = copy(getfield(db.code, :_summary_overrides))"
    , "    CodeTree.reload(db)"
    , "    for (__sevenaigent_id__, __sevenaigent_summary__) in __sevenaigent_summary_overrides__"
    , "        __sevenaigent_idx__ = findfirst(==(__sevenaigent_id__), db.code.id)"
    , "        isnothing(__sevenaigent_idx__) && continue"
    , "        db.code[__sevenaigent_idx__, :summary] = __sevenaigent_summary__"
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
