module Agent.Runner.ToolExecution
    ( doTool
    ) where

import Prelude

import Data.Argonaut.Core as J
import Data.Argonaut.Parser as JP
import Data.Array as Array
import Data.Array.NonEmpty as NEA
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set
import Data.String as String
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
    , HunkId(..)
    , RawJulia(..)
    , TokenCount(..)
    , Message(..)
    , AppError(..)
    , LogEvent(..)
    , LlmResponse(..)
    , renderToolName
    , extractContent
    )
import Agent.Programs.GitCommit
    ( CommitWhat(..)
    , validateCommitWhat
    , runGitCommit
    )
import Agent.Programs.GitDiff (runGitDiff, parseHunkIds)
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
    , parseGitCommitInput
    )
import Agent.Programs.ToolOutput (processToolOutput)
import Agent.Runner.Services (RunnerServices)
import Agent.Services.Jupyter (KernelHandle)

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
    -> Aff { history :: ConversationHistory, hunks :: Set HunkId, interrupted :: Boolean }
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

    { output: rawOut, hunks: hunks', interrupted } <- dispatchTool svc ws sessionId config apiKey kernel tc knownHunks

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
    pure { history: addMsg history toolMsg, hunks: hunks', interrupted }

dispatchTool
    :: RunnerServices
    -> WorkspacePath
    -> SessionId
    -> Config
    -> String
    -> KernelHandle
    -> ToolCall
    -> Set HunkId
    -> Aff { output :: String, hunks :: Set HunkId, interrupted :: Boolean }
dispatchTool svc ws sessionId config apiKey kernel tc knownHunks =
    case tc.name of
        JuliaRepl -> do
            let code = parseJuliaCodeInput tc.input
            result <- runJuliaReplWithTimeoutChecks svc ws sessionId config apiKey kernel (RawJulia code)
            pure { output: result.output, hunks: Set.empty, interrupted: result.interrupted }

        GitDiff -> do
            diff <- runGitDiff ws
            let ids = parseHunkIds diff
            pure { output: diff, hunks: ids, interrupted: false }

        GitCommit -> do
            case parseGitCommitInput tc.input of
                Nothing -> pure { output: "Invalid git_commit input", hunks: knownHunks, interrupted: false }
                Just input ->
                    case parseCommitWhat input.what knownHunks of
                        Left err -> pure { output: show err, hunks: knownHunks, interrupted: false }
                        Right commitWhat -> do
                            commitR <- runGitCommit ws commitWhat input.message input.body
                            case commitR of
                                Left err -> pure { output: show err, hunks: knownHunks, interrupted: false }
                                Right msg -> pure { output: msg, hunks: Set.empty, interrupted: false }

        UnknownToolName other ->
            pure { output: "Unknown tool: " <> other, hunks: knownHunks, interrupted: false }

runJuliaReplWithTimeoutChecks
    :: RunnerServices
    -> WorkspacePath
    -> SessionId
    -> Config
    -> String
    -> KernelHandle
    -> RawJulia
    -> Aff { output :: String, interrupted :: Boolean }
runJuliaReplWithTimeoutChecks svc ws sessionId config apiKey kernel source = do
    partialRef <- liftEffect $ Ref.new ""
    resultRef <- liftEffect $ Ref.new Nothing
    errorRef <- liftEffect $ Ref.new Nothing
    _ <- forkAff do
        result <- attempt $ svc.executeCodeDetailed kernel source \chunk ->
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
                pure { output: result.output, interrupted: false }
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
                            pure { output: interruptedOutput <> "\n[interrupted]", interrupted: true }
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
        llmR <- svc.callLlm config apiKey (timeoutCheckHistory requestText) (liftEffect <<< svc.printStr)
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
    String.joinWith "\n\n" (map _.content (buildTimeoutCheckRequest source elapsed partialOutput))

timeoutCheckHistory :: String -> ConversationHistory
timeoutCheckHistory requestText =
    ConversationHistory
        { messages:
            [ { message: UserMessage { content: requestText }
              , tokens: estimateTokens requestText
              }
            ]
        }

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

addMsg :: ConversationHistory -> Message -> ConversationHistory
addMsg (ConversationHistory history) msg =
    ConversationHistory
        { messages: history.messages <>
            [{ message: msg, tokens: estimateTokens (extractContent msg) }]
        }

estimateTokens :: String -> TokenCount
estimateTokens s = TokenCount (max 1 (String.length s / 4))
