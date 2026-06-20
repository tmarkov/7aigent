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
    , Timestamp(..)
    , ModelName(..)
    , SessionEndReason
    , ToolCall
    , ToolName
    , SessionId(..)
    , ToolCallId(..)
    , TokenCount(..)
    , LogEvent(..)
    , ConversationHistory(..)
    , Message(..)
    , AppError(..)
    , renderTimestamp
    , renderToolName
    , renderSessionEndReason
    , toolNameFromString
    , sessionEndReasonFromString
    )

-- FFI imports
foreign import listDirSync :: String -> Effect (Array String)
foreign import mkdirSyncRecursive :: String -> Effect Unit
foreign import appendFileSync :: String -> String -> Effect Unit
foreign import readFileSyncImpl :: String -> Effect String
foreign import fileExistsSync :: String -> Effect Boolean
foreign import allocateSessionIdImpl :: String -> Effect Int

----------------------------------------------------------------------------
-- A24: session ID allocation
----------------------------------------------------------------------------

allocateSessionId :: WorkspacePath -> Aff SessionId
allocateSessionId (WorkspacePath wp) = liftEffect do
    SessionId <$> allocateSessionIdImpl wp

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
        , Tuple "timestamp" (J.fromString (renderTimestamp r.timestamp))
        , Tuple "workspace" (J.fromString r.workspace)
        , Tuple "model" (J.fromString (unwrapModelName r.model))
        , Tuple "resumed_from" (case r.resumedFrom of
            Nothing -> J.jsonNull
            Just (SessionId n) -> J.fromNumber (Int.toNumber n))
        ]
encodeLogEventJson (EvtSystemPrompt r) =
    mkObj
        [ Tuple "type" (J.fromString "system_prompt")
        , Tuple "timestamp" (J.fromString (renderTimestamp r.timestamp))
        , Tuple "content" (J.fromString r.content)
        ]
encodeLogEventJson (EvtUserMessage r) =
    mkObj
        [ Tuple "type" (J.fromString "user_message")
        , Tuple "timestamp" (J.fromString (renderTimestamp r.timestamp))
        , Tuple "content" (J.fromString r.content)
        , Tuple "raw_content" case r.rawContent of
            Nothing -> J.jsonNull
            Just raw -> J.fromString raw
        , Tuple "source" case r.source of
            Nothing -> J.jsonNull
            Just src -> J.fromString src
        ]
encodeLogEventJson (EvtLlmResponse r) =
    mkObj
        [ Tuple "type" (J.fromString "llm_response")
        , Tuple "timestamp" (J.fromString (renderTimestamp r.timestamp))
        , Tuple "content" (J.fromString r.content)
        , Tuple "origin" (J.fromString r.origin)
        ]
encodeLogEventJson (EvtLlmQuery r) =
    mkObj
        [ Tuple "type" (J.fromString "llm_query")
        , Tuple "timestamp" (J.fromString (renderTimestamp r.timestamp))
        , Tuple "purpose" (J.fromString r.purpose)
        , Tuple "input" (J.fromString r.input)
        ]
encodeLogEventJson (EvtToolCall r) =
    mkObj
        [ Tuple "type" (J.fromString "tool_call")
        , Tuple "timestamp" (J.fromString (renderTimestamp r.timestamp))
        , Tuple "tool" (J.fromString (renderToolName r.toolName))
        , Tuple "tool_call_id" (J.fromString (unwrapToolCallId r.toolCallId))
        , Tuple "input" (J.fromString r.input)
        , Tuple "origin" (J.fromString r.origin)
        ]
encodeLogEventJson (ToolResult r) =
    mkObj
        [ Tuple "type" (J.fromString "tool_result")
        , Tuple "timestamp" (J.fromString (renderTimestamp r.timestamp))
        , Tuple "tool_call_id" (J.fromString (unwrapToolCallId r.toolCallId))
        , Tuple "output" (J.fromString r.output)
        , Tuple "truncated" (J.fromBoolean r.truncated)
        , Tuple "origin" (J.fromString r.origin)
        ]
encodeLogEventJson (TokenUsage r) =
    mkObj
        [ Tuple "type" (J.fromString "token_usage")
        , Tuple "timestamp" (J.fromString (renderTimestamp r.timestamp))
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
        , Tuple "timestamp" (J.fromString (renderTimestamp r.timestamp))
        , Tuple "summary" (J.fromString r.summary)
        , Tuple "initial_message_count" (J.fromNumber (Int.toNumber r.initialMessageCount))
        , Tuple "compacted_message_count" (J.fromNumber (Int.toNumber r.compactedMessageCount))
        , Tuple "final_message_count" (J.fromNumber (Int.toNumber r.finalMessageCount))
        , Tuple "total_tokens_before" (J.fromNumber (Int.toNumber r.totalTokensBefore))
        ]
encodeLogEventJson (SessionEnd r) =
    mkObj
        [ Tuple "type" (J.fromString "session_end")
        , Tuple "timestamp" (J.fromString (renderTimestamp r.timestamp))
        , Tuple "reason" (J.fromString (renderSessionEndReason r.reason))
        ]
encodeLogEventJson (Escape r) =
    mkObj
        [ Tuple "type" (J.fromString "escape")
        , Tuple "timestamp" (J.fromString (renderTimestamp r.timestamp))
        ]
encodeLogEventJson (Sigint r) =
    mkObj
        [ Tuple "type" (J.fromString "sigint")
        , Tuple "timestamp" (J.fromString (renderTimestamp r.timestamp))
        ]
encodeLogEventJson (TimeoutCheck r) =
    mkObj
        [ Tuple "type" (J.fromString "timeout_check")
        , Tuple "timestamp" (J.fromString (renderTimestamp r.timestamp))
        , Tuple "elapsed_seconds" (J.fromNumber (Int.toNumber r.elapsedSeconds))
        , Tuple "partial_output" (J.fromString r.partialOutput)
        ]
encodeLogEventJson (TimeoutResponse r) =
    mkObj
        [ Tuple "type" (J.fromString "timeout_response")
        , Tuple "timestamp" (J.fromString (renderTimestamp r.timestamp))
        , Tuple "action" (J.fromString r.action)
        , Tuple "timeout_seconds" case r.timeoutSeconds of
            Nothing -> J.jsonNull
            Just seconds -> J.fromNumber (Int.toNumber seconds)
        , Tuple "value" case r.value of
            Nothing -> J.jsonNull
            Just value -> J.fromString value
        , Tuple "error" case r.error of
            Nothing -> J.jsonNull
            Just err -> J.fromString err
        ]
encodeLogEventJson (StdinRequest r) =
    mkObj
        [ Tuple "type" (J.fromString "stdin_request")
        , Tuple "timestamp" (J.fromString (renderTimestamp r.timestamp))
        , Tuple "tool_call_id" (J.fromString (unwrapToolCallId r.toolCallId))
        , Tuple "sequence" (J.fromNumber (Int.toNumber r.sequence))
        , Tuple "attempt" (J.fromNumber (Int.toNumber r.attempt))
        , Tuple "elapsed_seconds" (J.fromNumber (Int.toNumber r.elapsedSeconds))
        , Tuple "prompt" (J.fromString r.prompt)
        , Tuple "value" (case r.value of
            Nothing -> J.jsonNull
            Just value -> J.fromString value)
        , Tuple "interrupt" (case r.interrupt of
            Nothing -> J.jsonNull
            Just interrupt -> J.fromBoolean interrupt)
        , Tuple "error" (case r.error of
            Nothing -> J.jsonNull
            Just err -> J.fromString err)
        ]
encodeLogEventJson (EvtReflection r) =
    let base =
            [ Tuple "type" (J.fromString "reflection")
            , Tuple "timestamp" (J.fromString (renderTimestamp r.timestamp))
            , Tuple "turn_index" (J.fromNumber (Int.toNumber r.turnIndex))
            , Tuple "auto_turns_taken" (J.fromNumber (Int.toNumber r.autoTurnsTaken))
            , Tuple "complete" (J.fromBoolean r.complete)
            ]
        withFeedback = case r.feedback of
            Nothing -> base
            Just fb -> base <> [ Tuple "feedback" (J.fromString fb) ]
    in mkObj withFeedback

mkObj :: Array (Tuple String J.Json) -> J.Json
mkObj = J.fromObject <<< FO.fromFoldable

----------------------------------------------------------------------------
-- A26: JSON decoding
----------------------------------------------------------------------------

decodeLogEvent :: String -> Either AppError LogEvent
decodeLogEvent input = case JP.jsonParser input of
    Left parseErr -> Left (JsonDecodeError ("JSON parse error: " <> parseErr))
    Right json -> case J.toObject json of
        Nothing -> Left (JsonDecodeError "Expected JSON object")
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
                , timestamp: Timestamp ts
                , workspace: ws
                , model: ModelName mdl
                , resumedFrom: resumed
                }
        "system_prompt" -> do
            ts <- getStr obj "timestamp"
            content <- getStr obj "content"
            Right $ EvtSystemPrompt { timestamp: Timestamp ts, content }
        "user_message" -> do
            ts <- getStr obj "timestamp"
            content <- getStr obj "content"
            rawContent <- getOptionalNullableString obj "raw_content"
            let src = case FO.lookup "source" obj of
                    Just v | not (J.isNull v) -> J.toString v
                    Nothing -> Nothing
                    _ -> Nothing
            Right $ EvtUserMessage
                { timestamp: Timestamp ts
                , content
                , rawContent
                , source: src
                }
        "llm_response" -> do
            ts <- getStr obj "timestamp"
            content <- getStr obj "content"
            let origin = fromMaybe "model" do
                    value <- FO.lookup "origin" obj
                    J.toString value
            Right $ EvtLlmResponse { timestamp: Timestamp ts, content, origin }
        "llm_query" -> do
            ts <- getStr obj "timestamp"
            purpose <- getStr obj "purpose"
            inp <- getStr obj "input"
            Right $ EvtLlmQuery
                { timestamp: Timestamp ts
                , purpose
                , input: inp
                }
        "tool_call" -> do
            ts <- getStr obj "timestamp"
            tool <- getStr obj "tool"
            tcId <- getStr obj "tool_call_id"
            inp <- getStr obj "input"
            Right $ EvtToolCall
                { timestamp: Timestamp ts
                , toolName: toolNameFromString tool
                , toolCallId: ToolCallId tcId
                , input: inp
                , origin: fromMaybe "model" do
                    value <- FO.lookup "origin" obj
                    J.toString value
                }
        "tool_result" -> do
            ts <- getStr obj "timestamp"
            tcId <- getStr obj "tool_call_id"
            out <- getStr obj "output"
            trunc <- getBool obj "truncated"
            Right $ ToolResult
                { timestamp: Timestamp ts
                , toolCallId: ToolCallId tcId
                , output: out
                , truncated: trunc
                , origin: fromMaybe "model" do
                    value <- FO.lookup "origin" obj
                    J.toString value
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
                { timestamp: Timestamp ts
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
                { timestamp: Timestamp ts
                , summary
                , initialMessageCount: numToInt initial
                , compactedMessageCount: numToInt compacted
                , finalMessageCount: numToInt final
                , totalTokensBefore: numToInt totalBefore
                }
        "session_end" -> do
            ts <- getStr obj "timestamp"
            reason <- getStr obj "reason"
            Right $ SessionEnd
                { timestamp: Timestamp ts
                , reason: sessionEndReasonFromString reason
                }
        "escape" -> do
            ts <- getStr obj "timestamp"
            Right $ Escape { timestamp: Timestamp ts }
        "sigint" -> do
            ts <- getStr obj "timestamp"
            Right $ Sigint { timestamp: Timestamp ts }
        "timeout_check" -> do
            ts <- getStr obj "timestamp"
            elapsed <- getNum obj "elapsed_seconds"
            partial <- getStr obj "partial_output"
            Right $ TimeoutCheck
                { timestamp: Timestamp ts
                , elapsedSeconds: numToInt elapsed
                , partialOutput: partial
                }
        "timeout_response" -> do
            ts <- getStr obj "timestamp"
            action <- getStr obj "action"
            timeoutSeconds <- getNullableInt obj "timeout_seconds"
            value <- getNullableString obj "value"
            err <- getNullableString obj "error"
            Right $ TimeoutResponse
                { timestamp: Timestamp ts
                , action
                , timeoutSeconds
                , value
                , error: err
                }
        "stdin_request" -> do
            ts <- getStr obj "timestamp"
            tcId <- getStr obj "tool_call_id"
            sequence <- getNum obj "sequence"
            attemptNumber <- getNum obj "attempt"
            elapsed <- getNum obj "elapsed_seconds"
            prompt <- getStr obj "prompt"
            value <- getNullableString obj "value"
            interrupt <- getNullableBool obj "interrupt"
            err <- getNullableString obj "error"
            Right $ StdinRequest
                { timestamp: Timestamp ts
                , toolCallId: ToolCallId tcId
                , sequence: numToInt sequence
                , attempt: numToInt attemptNumber
                , elapsedSeconds: numToInt elapsed
                , prompt
                , value
                , interrupt
                , error: err
                }
        "reflection" -> do
            ts <- getStr obj "timestamp"
            turnIdx <- getNum obj "turn_index"
            autoTurns <- getNum obj "auto_turns_taken"
            complete <- getBool obj "complete"
            let fb = case FO.lookup "feedback" obj of
                    Just v -> J.toString v
                    Nothing -> Nothing
            Right $ EvtReflection
                { timestamp: Timestamp ts
                , turnIndex: numToInt turnIdx
                , autoTurnsTaken: numToInt autoTurns
                , complete
                , feedback: fb
                }
        other ->
            Left (JsonDecodeError ("Unknown event type: " <> other))

getStr :: FO.Object J.Json -> String -> Either AppError String
getStr obj key = case FO.lookup key obj of
    Nothing -> Left (JsonDecodeError ("Missing field: " <> key))
    Just v -> case J.toString v of
        Nothing -> Left (JsonDecodeError ("Field " <> key <> " is not a string"))
        Just s -> Right s

getNullableString
    :: FO.Object J.Json
    -> String
    -> Either AppError (Maybe String)
getNullableString obj key = case FO.lookup key obj of
    Nothing -> Left (JsonDecodeError ("Missing field: " <> key))
    Just value
        | J.isNull value -> Right Nothing
        | otherwise -> case J.toString value of
            Nothing -> Left (JsonDecodeError ("Field " <> key <> " is not a string or null"))
            Just text -> Right (Just text)

getOptionalNullableString
    :: FO.Object J.Json
    -> String
    -> Either AppError (Maybe String)
getOptionalNullableString obj key = case FO.lookup key obj of
    Nothing -> Right Nothing
    Just value
        | J.isNull value -> Right Nothing
        | otherwise -> case J.toString value of
            Nothing -> Left (JsonDecodeError ("Field " <> key <> " is not a string or null"))
            Just text -> Right (Just text)

getNullableBool
    :: FO.Object J.Json
    -> String
    -> Either AppError (Maybe Boolean)
getNullableBool obj key = case FO.lookup key obj of
    Nothing -> Left (JsonDecodeError ("Missing field: " <> key))
    Just value
        | J.isNull value -> Right Nothing
        | otherwise -> case J.toBoolean value of
            Nothing -> Left (JsonDecodeError ("Field " <> key <> " is not a boolean or null"))
            Just decision -> Right (Just decision)

getNullableInt
    :: FO.Object J.Json
    -> String
    -> Either AppError (Maybe Int)
getNullableInt obj key = case FO.lookup key obj of
    Nothing -> Left (JsonDecodeError ("Missing field: " <> key))
    Just value
        | J.isNull value -> Right Nothing
        | otherwise -> case J.toNumber value of
            Nothing -> Left (JsonDecodeError ("Field " <> key <> " is not a number or null"))
            Just n -> Right (Just (numToInt n))

getNum :: FO.Object J.Json -> String -> Either AppError Number
getNum obj key = case FO.lookup key obj of
    Nothing -> Left (JsonDecodeError ("Missing field: " <> key))
    Just v -> case J.toNumber v of
        Nothing -> Left (JsonDecodeError ("Field " <> key <> " is not a number"))
        Just n -> Right n

getBool :: FO.Object J.Json -> String -> Either AppError Boolean
getBool obj key = case FO.lookup key obj of
    Nothing -> Left (JsonDecodeError ("Missing field: " <> key))
    Just v -> case J.toBoolean v of
        Nothing -> Left (JsonDecodeError ("Field " <> key <> " is not a boolean"))
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
        result = foldl processEvent
            { msgs: []
            , pendingAssistant: Nothing
            , orphanToolResults: []
            , seenToolCallIds: []
            , sawSystemPrompt: false
            }
            events
    in
        (flushPendingAssistant result).msgs

type AccState =
    { msgs :: Array { message :: Message, tokens :: TokenCount }
    , pendingAssistant :: Maybe { content :: String, toolCalls :: Array ToolCall }
    , orphanToolResults :: Array ToolResultRecord
    , seenToolCallIds :: Array ToolCallId
    , sawSystemPrompt :: Boolean
    }

type ToolResultRecord =
    { toolCallId :: ToolCallId
    , output :: String
    }

processEvent :: AccState -> LogEvent -> AccState
processEvent acc (EvtSystemPrompt _) =
    acc { sawSystemPrompt = true }
processEvent acc (EvtUserMessage r) =
    appendMessage (flushPendingAssistant acc) (UserMessage { content: r.content })
processEvent acc (EvtLlmResponse r) =
    (flushPendingAssistant acc)
        { pendingAssistant = Just { content: r.content, toolCalls: [] } }
processEvent acc (EvtLlmQuery _) = acc
processEvent acc (EvtToolCall r) =
    let toolCall = { name: r.toolName, input: r.input, id: r.toolCallId }
    in case acc.pendingAssistant of
        Just pending ->
            acc
                { pendingAssistant = Just
                    pending { toolCalls = pending.toolCalls <> [toolCall] }
                , seenToolCallIds = addSeenToolCallId r.toolCallId acc.seenToolCallIds
                }
        Nothing ->
            acc
                { pendingAssistant = Just
                    { content: ""
                    , toolCalls: [toolCall]
                    }
                , seenToolCallIds = addSeenToolCallId r.toolCallId acc.seenToolCallIds
                }
processEvent acc (ToolResult r) =
    let result = { toolCallId: r.toolCallId, output: r.output }
    in if pendingAssistantHasToolCall r.toolCallId acc.pendingAssistant then
        appendToolResultMessage (flushPendingAssistant acc) result
    else if Array.elem r.toolCallId acc.seenToolCallIds then
        appendToolResultMessage acc result
    else
        acc { orphanToolResults = acc.orphanToolResults <> [result] }
processEvent acc (Compaction r) =
    let
        flushed = flushPendingAssistant acc
        totalMsgs = Array.length flushed.msgs
        initialCount =
            if acc.sawSystemPrompt then
                max 0 (r.initialMessageCount - 1)
            else
                r.initialMessageCount
        finalCount = r.finalMessageCount
        -- Keep initial block, replace compacted block with summary, keep final block
        initialBlock = Array.take initialCount flushed.msgs
        finalBlock = Array.drop (totalMsgs - finalCount) flushed.msgs
        summaryMsg = mkMsg (UserMessage { content: r.summary })
    in
        flushed { msgs = initialBlock <> [summaryMsg] <> finalBlock }
processEvent acc _ = acc

mkMsg :: Message -> { message :: Message, tokens :: TokenCount }
mkMsg msg = { message: msg, tokens: TokenCount 0 }

appendMessage :: AccState -> Message -> AccState
appendMessage acc msg =
    acc { msgs = acc.msgs <> [mkMsg msg] }

appendToolResultMessage :: AccState -> ToolResultRecord -> AccState
appendToolResultMessage acc r =
    appendMessage acc (ToolResultMessage { toolCallId: r.toolCallId, output: r.output })

flushPendingAssistant :: AccState -> AccState
flushPendingAssistant acc = case acc.pendingAssistant of
    Nothing ->
        acc
    Just pending ->
        let
            toolCallIds = map _.id pending.toolCalls
            matchedResults = Array.filter
                (\r -> Array.elem r.toolCallId toolCallIds)
                acc.orphanToolResults
            remainingResults = Array.filter
                (\r -> not (Array.elem r.toolCallId toolCallIds))
                acc.orphanToolResults
            resultMessages = map
                (\r -> mkMsg
                    (ToolResultMessage { toolCallId: r.toolCallId, output: r.output }))
                matchedResults
        in
            acc
            { msgs =
                acc.msgs
                    <> [mkMsg
                        (AssistantMessage
                            { content: pending.content
                            , toolCalls: pending.toolCalls
                            })
                       ]
                    <> resultMessages
            , pendingAssistant = Nothing
            , orphanToolResults = remainingResults
            }

pendingAssistantHasToolCall :: ToolCallId -> Maybe { content :: String, toolCalls :: Array ToolCall } -> Boolean
pendingAssistantHasToolCall toolCallId pendingAssistant =
    case pendingAssistant of
        Nothing ->
            false
        Just pending ->
            Array.any (\toolCall -> toolCall.id == toolCallId) pending.toolCalls

addSeenToolCallId :: ToolCallId -> Array ToolCallId -> Array ToolCallId
addSeenToolCallId toolCallId seen =
    if Array.elem toolCallId seen then
        seen
    else
        seen <> [toolCallId]
