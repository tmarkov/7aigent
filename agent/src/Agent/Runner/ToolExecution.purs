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
import Data.Tuple (Tuple(..))
import Effect.Aff (Aff)
import Effect.Class (liftEffect)

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
    -> KernelHandle
    -> ConversationHistory
    -> ToolCall
    -> Set HunkId
    -> Aff (Tuple ConversationHistory (Set HunkId))
doTool svc ws sessionId config kernel history tc knownHunks = do
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

    Tuple rawOut hunks' <- dispatchTool svc ws kernel tc knownHunks

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
    pure (Tuple (addMsg history toolMsg) hunks')

dispatchTool
    :: RunnerServices
    -> WorkspacePath
    -> KernelHandle
    -> ToolCall
    -> Set HunkId
    -> Aff (Tuple String (Set HunkId))
dispatchTool svc ws kernel tc knownHunks =
    case tc.name of
        JuliaRepl -> do
            let code = parseJuliaCodeInput tc.input
            out <- svc.executeCode kernel (RawJulia code) (const (pure unit))
            pure (Tuple out Set.empty)

        GitDiff -> do
            diff <- runGitDiff ws
            let ids = parseHunkIds diff
            pure (Tuple diff ids)

        GitCommit -> do
            case parseGitCommitInput tc.input of
                Nothing -> pure (Tuple "Invalid git_commit input" knownHunks)
                Just input ->
                    case parseCommitWhat input.what knownHunks of
                        Left err -> pure (Tuple (show err) knownHunks)
                        Right commitWhat -> do
                            commitR <- runGitCommit ws commitWhat input.message input.body
                            case commitR of
                                Left err -> pure (Tuple (show err) knownHunks)
                                Right msg -> pure (Tuple msg Set.empty)

        UnknownToolName other ->
            pure (Tuple ("Unknown tool: " <> other) knownHunks)

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
