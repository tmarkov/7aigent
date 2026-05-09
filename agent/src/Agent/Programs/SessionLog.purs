-- | Session logging: event encoding/decoding, session ID allocation,
-- | log read/write, session description, and history reconstruction.
-- | Covers requirements A24, A25, A26, A27.
module Agent.Programs.SessionLog
    ( allocateSessionId
    , writeLogEvent
    , readLogEvents
    , encodeLogEvent
    , decodeLogEvent
    , sessionDescription
    , reconstructHistory
    ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldl)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as String
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Foreign.Object as FO
import Data.Argonaut.Core as J
import Data.Argonaut.Parser as JP

import Agent.Types
    ( WorkspacePath(..)
    , SessionId(..)
    , ModelName(..)
    , ToolCallId(..)
    , TokenCount(..)
    , LogEvent(..)
    , ConversationHistory(..)
    , Message(..)
    , AppError(..)
    )

-- FFI imports
foreign import listDirSync :: String -> Effect (Array String)
foreign import mkdirSyncRecursive :: String -> Effect Unit
foreign import appendFileSync :: String -> String -> Effect Unit
foreign import readFileSyncImpl :: String -> Effect String
foreign import fileExistsSync :: String -> Effect Boolean

----------------------------------------------------------------------------
-- A24: session ID allocation
----------------------------------------------------------------------------

allocateSessionId :: WorkspacePath -> Aff SessionId
allocateSessionId (WorkspacePath wp) = liftEffect do
    let sessionsDir = wp <> "/.7aigent/sessions"
    mkdirSyncRecursive sessionsDir
    entries <- listDirSync sessionsDir
    let maxId = foldl
            (\acc entry -> case Int.fromString entry of
                Just n -> max acc n
                Nothing -> acc
            ) 0 entries
    let newId = maxId + 1
    mkdirSyncRecursive (sessionsDir <> "/" <> show newId)
    pure (SessionId newId)

----------------------------------------------------------------------------
-- A25: log event writing
----------------------------------------------------------------------------

writeLogEvent :: WorkspacePath -> SessionId -> LogEvent -> Aff Unit
writeLogEvent (WorkspacePath wp) (SessionId sid) event = liftEffect do
    let logPath = wp <> "/.7aigent/sessions/" <> show sid <> "/log.jsonl"
    appendFileSync logPath (encodeLogEvent event <> "\n")

----------------------------------------------------------------------------
-- A25: log event reading
----------------------------------------------------------------------------

readLogEvents
    :: WorkspacePath -> SessionId -> Aff (Either AppError (Array LogEvent))
readLogEvents (WorkspacePath wp) (SessionId sid) = liftEffect do
    let logPath = wp <> "/.7aigent/sessions/" <> show sid <> "/log.jsonl"
    content <- readFileSyncImpl logPath
    let rawLines = String.split (String.Pattern "\n") (String.trim content)
    let lines = Array.filter (\l -> l /= "") rawLines
    pure (traverse decodeLogEvent lines)

----------------------------------------------------------------------------
-- A26: JSON encoding
----------------------------------------------------------------------------

encodeLogEvent :: LogEvent -> String
encodeLogEvent event = J.stringify (encodeLogEventJson event)

encodeLogEventJson :: LogEvent -> J.Json
encodeLogEventJson (SessionStart r) =
    mkObj
        [ Tuple "type" (J.fromString "session_start")
        , Tuple "id" (J.fromNumber (Int.toNumber (unwrapSessionId r.id)))
        , Tuple "timestamp" (J.fromString r.timestamp)
        , Tuple "workspace" (J.fromString r.workspace)
        , Tuple "model" (J.fromString (unwrapModelName r.model))
        , Tuple "resumed_from" (case r.resumedFrom of
            Nothing -> J.jsonNull
            Just (SessionId n) -> J.fromNumber (Int.toNumber n))
        ]
encodeLogEventJson (EvtUserMessage r) =
    mkObj
        [ Tuple "type" (J.fromString "user_message")
        , Tuple "timestamp" (J.fromString r.timestamp)
        , Tuple "content" (J.fromString r.content)
        ]
encodeLogEventJson (EvtLlmResponse r) =
    mkObj
        [ Tuple "type" (J.fromString "llm_response")
        , Tuple "timestamp" (J.fromString r.timestamp)
        , Tuple "content" (J.fromString r.content)
        ]
encodeLogEventJson (EvtToolCall r) =
    mkObj
        [ Tuple "type" (J.fromString "tool_call")
        , Tuple "timestamp" (J.fromString r.timestamp)
        , Tuple "tool" (J.fromString r.toolName)
        , Tuple "tool_call_id" (J.fromString (unwrapToolCallId r.toolCallId))
        , Tuple "input" (J.fromString r.input)
        ]
encodeLogEventJson (ToolResult r) =
    mkObj
        [ Tuple "type" (J.fromString "tool_result")
        , Tuple "timestamp" (J.fromString r.timestamp)
        , Tuple "tool_call_id" (J.fromString (unwrapToolCallId r.toolCallId))
        , Tuple "output" (J.fromString r.output)
        , Tuple "truncated" (J.fromBoolean r.truncated)
        ]
encodeLogEventJson (TokenUsage r) =
    mkObj
        [ Tuple "type" (J.fromString "token_usage")
        , Tuple "timestamp" (J.fromString r.timestamp)
        , Tuple "input_tokens" (J.fromNumber (Int.toNumber (unwrapTokenCount r.inputTokens)))
        , Tuple "cached_input_tokens" (J.fromNumber (Int.toNumber (unwrapTokenCount r.cachedInputTokens)))
        , Tuple "output_tokens" (J.fromNumber (Int.toNumber (unwrapTokenCount r.outputTokens)))
        , Tuple "total_session_input_tokens" (J.fromNumber (Int.toNumber (unwrapTokenCount r.totalSessionInputTokens)))
        , Tuple "total_session_cached_input_tokens" (J.fromNumber (Int.toNumber (unwrapTokenCount r.totalSessionCachedInputTokens)))
        , Tuple "total_session_output_tokens" (J.fromNumber (Int.toNumber (unwrapTokenCount r.totalSessionOutputTokens)))
        ]
encodeLogEventJson (Compaction r) =
    mkObj
        [ Tuple "type" (J.fromString "compaction")
        , Tuple "timestamp" (J.fromString r.timestamp)
        , Tuple "summary" (J.fromString r.summary)
        , Tuple "initial_message_count" (J.fromNumber (Int.toNumber r.initialMessageCount))
        , Tuple "compacted_message_count" (J.fromNumber (Int.toNumber r.compactedMessageCount))
        , Tuple "final_message_count" (J.fromNumber (Int.toNumber r.finalMessageCount))
        , Tuple "total_tokens_before" (J.fromNumber (Int.toNumber r.totalTokensBefore))
        ]
encodeLogEventJson (SessionEnd r) =
    mkObj
        [ Tuple "type" (J.fromString "session_end")
        , Tuple "timestamp" (J.fromString r.timestamp)
        , Tuple "reason" (J.fromString r.reason)
        ]
encodeLogEventJson (Escape r) =
    mkObj
        [ Tuple "type" (J.fromString "escape")
        , Tuple "timestamp" (J.fromString r.timestamp)
        ]
encodeLogEventJson (Sigint r) =
    mkObj
        [ Tuple "type" (J.fromString "sigint")
        , Tuple "timestamp" (J.fromString r.timestamp)
        ]
encodeLogEventJson (TimeoutCheck r) =
    mkObj
        [ Tuple "type" (J.fromString "timeout_check")
        , Tuple "timestamp" (J.fromString r.timestamp)
        , Tuple "elapsed_seconds" (J.fromNumber (Int.toNumber r.elapsedSeconds))
        , Tuple "partial_output" (J.fromString r.partialOutput)
        ]
encodeLogEventJson (TimeoutResponse r) =
    mkObj
        [ Tuple "type" (J.fromString "timeout_response")
        , Tuple "timestamp" (J.fromString r.timestamp)
        , Tuple "interrupt" (J.fromBoolean r.interrupt)
        ]

mkObj :: Array (Tuple String J.Json) -> J.Json
mkObj = J.fromObject <<< FO.fromFoldable

----------------------------------------------------------------------------
-- A26: JSON decoding
----------------------------------------------------------------------------

decodeLogEvent :: String -> Either AppError LogEvent
decodeLogEvent input = case JP.jsonParser input of
    Left parseErr -> Left (ConfigFieldMissing ("JSON parse error: " <> parseErr))
    Right json -> case J.toObject json of
        Nothing -> Left (ConfigFieldMissing "Expected JSON object")
        Just obj -> decodeLogEventObj obj

decodeLogEventObj :: FO.Object J.Json -> Either AppError LogEvent
decodeLogEventObj obj = do
    evType <- getStr obj "type"
    case evType of
        "session_start" -> do
            idNum <- getNum obj "id"
            ts <- getStr obj "timestamp"
            ws <- getStr obj "workspace"
            mdl <- getStr obj "model"
            let resumed = case FO.lookup "resumed_from" obj of
                    Just v | not (J.isNull v) -> case J.toNumber v of
                        Just n -> Just (SessionId (numToInt n))
                        Nothing -> Nothing
                    _ -> Nothing
            Right $ SessionStart
                { id: SessionId (numToInt idNum)
                , timestamp: ts
                , workspace: ws
                , model: ModelName mdl
                , resumedFrom: resumed
                }
        "user_message" -> do
            ts <- getStr obj "timestamp"
            content <- getStr obj "content"
            Right $ EvtUserMessage { timestamp: ts, content }
        "llm_response" -> do
            ts <- getStr obj "timestamp"
            content <- getStr obj "content"
            Right $ EvtLlmResponse { timestamp: ts, content }
        "tool_call" -> do
            ts <- getStr obj "timestamp"
            tool <- getStr obj "tool"
            tcId <- getStr obj "tool_call_id"
            inp <- getStr obj "input"
            Right $ EvtToolCall
                { timestamp: ts
                , toolName: tool
                , toolCallId: ToolCallId tcId
                , input: inp
                }
        "tool_result" -> do
            ts <- getStr obj "timestamp"
            tcId <- getStr obj "tool_call_id"
            out <- getStr obj "output"
            trunc <- getBool obj "truncated"
            Right $ ToolResult
                { timestamp: ts
                , toolCallId: ToolCallId tcId
                , output: out
                , truncated: trunc
                }
        "token_usage" -> do
            ts <- getStr obj "timestamp"
            inp <- getNum obj "input_tokens"
            cached <- getNum obj "cached_input_tokens"
            outp <- getNum obj "output_tokens"
            totalInp <- getNum obj "total_session_input_tokens"
            totalCached <- getNum obj "total_session_cached_input_tokens"
            totalOutp <- getNum obj "total_session_output_tokens"
            Right $ TokenUsage
                { timestamp: ts
                , inputTokens: TokenCount (numToInt inp)
                , cachedInputTokens: TokenCount (numToInt cached)
                , outputTokens: TokenCount (numToInt outp)
                , totalSessionInputTokens: TokenCount (numToInt totalInp)
                , totalSessionCachedInputTokens: TokenCount (numToInt totalCached)
                , totalSessionOutputTokens: TokenCount (numToInt totalOutp)
                }
        "compaction" -> do
            ts <- getStr obj "timestamp"
            summary <- getStr obj "summary"
            initial <- getNum obj "initial_message_count"
            compacted <- getNum obj "compacted_message_count"
            final <- getNum obj "final_message_count"
            totalBefore <- getNum obj "total_tokens_before"
            Right $ Compaction
                { timestamp: ts
                , summary
                , initialMessageCount: numToInt initial
                , compactedMessageCount: numToInt compacted
                , finalMessageCount: numToInt final
                , totalTokensBefore: numToInt totalBefore
                }
        "session_end" -> do
            ts <- getStr obj "timestamp"
            reason <- getStr obj "reason"
            Right $ SessionEnd { timestamp: ts, reason }
        "escape" -> do
            ts <- getStr obj "timestamp"
            Right $ Escape { timestamp: ts }
        "sigint" -> do
            ts <- getStr obj "timestamp"
            Right $ Sigint { timestamp: ts }
        "timeout_check" -> do
            ts <- getStr obj "timestamp"
            elapsed <- getNum obj "elapsed_seconds"
            partial <- getStr obj "partial_output"
            Right $ TimeoutCheck
                { timestamp: ts
                , elapsedSeconds: numToInt elapsed
                , partialOutput: partial
                }
        "timeout_response" -> do
            ts <- getStr obj "timestamp"
            interrupt <- getBool obj "interrupt"
            Right $ TimeoutResponse { timestamp: ts, interrupt }
        other ->
            Left (ConfigFieldMissing ("Unknown event type: " <> other))

getStr :: FO.Object J.Json -> String -> Either AppError String
getStr obj key = case FO.lookup key obj of
    Nothing -> Left (ConfigFieldMissing ("Missing field: " <> key))
    Just v -> case J.toString v of
        Nothing -> Left (ConfigFieldMissing ("Field " <> key <> " is not a string"))
        Just s -> Right s

getNum :: FO.Object J.Json -> String -> Either AppError Number
getNum obj key = case FO.lookup key obj of
    Nothing -> Left (ConfigFieldMissing ("Missing field: " <> key))
    Just v -> case J.toNumber v of
        Nothing -> Left (ConfigFieldMissing ("Field " <> key <> " is not a number"))
        Just n -> Right n

getBool :: FO.Object J.Json -> String -> Either AppError Boolean
getBool obj key = case FO.lookup key obj of
    Nothing -> Left (ConfigFieldMissing ("Missing field: " <> key))
    Just v -> case J.toBoolean v of
        Nothing -> Left (ConfigFieldMissing ("Field " <> key <> " is not a boolean"))
        Just b -> Right b

numToInt :: Number -> Int
numToInt = Int.round

unwrapSessionId :: SessionId -> Int
unwrapSessionId (SessionId n) = n

unwrapModelName :: ModelName -> String
unwrapModelName (ModelName s) = s

unwrapToolCallId :: ToolCallId -> String
unwrapToolCallId (ToolCallId s) = s

unwrapTokenCount :: TokenCount -> Int
unwrapTokenCount (TokenCount n) = n

----------------------------------------------------------------------------
-- A27: session description
----------------------------------------------------------------------------

sessionDescription :: String -> String
sessionDescription msg
    | String.length msg <= 120 = msg
    | otherwise = String.take 120 msg

----------------------------------------------------------------------------
-- A31: history reconstruction from log events
----------------------------------------------------------------------------

reconstructHistory :: Array LogEvent -> Either AppError ConversationHistory
reconstructHistory events =
    Right $ ConversationHistory { messages: buildMessages events }

buildMessages :: Array LogEvent -> Array { message :: Message, tokens :: TokenCount }
buildMessages events =
    let
        result = foldl processEvent { msgs: [], compactionState: NoCompaction } events
    in
        result.msgs

data CompactionState
    = NoCompaction
    | CompactionApplied
        { initialCount :: Int
        , compactedCount :: Int
        , finalCount :: Int
        , summary :: String
        }

type AccState =
    { msgs :: Array { message :: Message, tokens :: TokenCount }
    , compactionState :: CompactionState
    }

processEvent :: AccState -> LogEvent -> AccState
processEvent acc (EvtUserMessage r) =
    acc { msgs = acc.msgs <> [mkMsg (UserMessage { content: r.content })] }
processEvent acc (EvtLlmResponse r) =
    acc { msgs = acc.msgs <> [mkMsg (AssistantMessage { content: r.content, toolCalls: [] })] }
processEvent acc (EvtToolCall r) =
    acc { msgs = acc.msgs <> [mkMsg (AssistantMessage
        { content: ""
        , toolCalls: [{ name: r.toolName, input: r.input, id: r.toolCallId }]
        })] }
processEvent acc (ToolResult r) =
    acc { msgs = acc.msgs <> [mkMsg (ToolResultMessage
        { toolCallId: r.toolCallId, output: r.output })] }
processEvent acc (Compaction r) =
    let
        totalMsgs = Array.length acc.msgs
        initialCount = r.initialMessageCount
        compactedCount = r.compactedMessageCount
        finalCount = r.finalMessageCount
        -- Keep initial block, replace compacted block with summary, keep final block
        initialBlock = Array.take initialCount acc.msgs
        finalBlock = Array.drop (totalMsgs - finalCount) acc.msgs
        summaryMsg = mkMsg (UserMessage { content: r.summary })
    in
        acc { msgs = initialBlock <> [summaryMsg] <> finalBlock }
processEvent acc _ = acc

mkMsg :: Message -> { message :: Message, tokens :: TokenCount }
mkMsg msg = { message: msg, tokens: TokenCount 0 }
