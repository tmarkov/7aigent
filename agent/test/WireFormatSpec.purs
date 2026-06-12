-- | Wire-format assertions for A26: verify that encoded JSON contains the
-- | exact field names specified in the requirements table.
-- |
-- | This catches anti-pattern 3 (internal round-trip passes even with wrong
-- | field names) by asserting on the actual wire representation.
module Test.WireFormatSpec where

import Prelude

import Data.Maybe (Maybe(..), isJust)
import Data.Either (Either(..))
import Foreign.Object as FO
import Data.Argonaut.Core as J
import Data.Argonaut.Parser as JP
import Effect.Aff (Aff)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, fail)

import Test.Helpers.LogEvent
    ( sessionStartEvent
    , systemPromptEvent
    , userMessageEvent
    , reflectionUserMessageEvent
    , llmResponseEvent
    , llmQueryEvent
    , toolCallEvent
    , toolResultEvent
    , tokenUsageEvent
    , compactionEvent
    , sessionEndEvent
    , escapeEvent
    , sigintEvent
    , timeoutCheckEvent
    , timeoutResponseEvent
    , reflectionEvent
    )
import Agent.Programs.SessionLog (encodeLogEvent)
import Agent.Types
    ( SessionId(..)
    , ModelName(..)
    , ToolCallId(..)
    , TokenCount(..)
    , Timestamp(..)
    , LogEvent(..)
    )

wireFormatSpec :: Spec Unit
wireFormatSpec = do

  ---------------------------------------------------------------------------
  -- A26: session_start wire format
  ---------------------------------------------------------------------------

  describe "A26: session_start wire-format field names" do

    it "A26: session_start has fields: type, id, timestamp, workspace, model, resumed_from" do
      let event = sessionStartEvent
            { id: SessionId 1
            , timestamp: "2026-01-15T14:32:00Z"
            , workspace: "/home/user/project"
            , model: ModelName "claude-3"
            , resumedFrom: Nothing
            }
      let obj = parseToObj (encodeLogEvent event)
      assertHasField obj "type"
      assertHasField obj "id"
      assertHasField obj "timestamp"
      assertHasField obj "workspace"
      assertHasField obj "model"
      assertHasField obj "resumed_from"

    it "A26: session_start resumed_from is non-null when resuming" do
      let event = sessionStartEvent
            { id: SessionId 2
            , timestamp: "2026-01-15T14:32:00Z"
            , workspace: "/w"
            , model: ModelName "m"
            , resumedFrom: Just (SessionId 1)
            }
      let obj = parseToObj (encodeLogEvent event)
      assertFieldNotNull obj "resumed_from"

  ---------------------------------------------------------------------------
  -- A26: user_message wire format
  ---------------------------------------------------------------------------

  describe "A26: user_message wire-format field names" do

    it "A26: user_message has fields: type, timestamp, content" do
      let event = userMessageEvent "t1" "hello"
      let obj = parseToObj (encodeLogEvent event)
      assertHasField obj "type"
      assertHasField obj "timestamp"
      assertHasField obj "content"
      assertFieldEquals obj "type" "user_message"

    it "A26: user_message source field omitted for human input" do
      let event = userMessageEvent "t1" "hello"
      let obj = parseToObj (encodeLogEvent event)
      assertLacksField obj "source"

    it "A26: user_message source field present for reflection input" do
      let event = reflectionUserMessageEvent "t1" "feedback"
      let obj = parseToObj (encodeLogEvent event)
      assertHasField obj "source"

  ---------------------------------------------------------------------------
  -- A26: llm_response wire format
  ---------------------------------------------------------------------------

  describe "A26: llm_response wire-format field names" do

    it "A26: llm_response has fields: type, timestamp, content" do
      let event = llmResponseEvent "t1" "Hi!"
      let obj = parseToObj (encodeLogEvent event)
      assertHasField obj "type"
      assertHasField obj "timestamp"
      assertHasField obj "content"
      assertFieldEquals obj "type" "llm_response"

  describe "A26 + A56: stdin_request wire-format field names" do

    it "A26: stdin_request contains every specified field" do
      let event = StdinRequest
            { timestamp: Timestamp "t1"
            , toolCallId: ToolCallId "tc1"
            , sequence: 1
            , attempt: 1
            , elapsedSeconds: 4
            , prompt: "Name: "
            , value: Just "Ada"
            , interrupt: Just false
            , error: Nothing
            }
      let obj = parseToObj (encodeLogEvent event)
      assertFieldEquals obj "type" "stdin_request"
      assertHasField obj "timestamp"
      assertHasField obj "tool_call_id"
      assertHasField obj "sequence"
      assertHasField obj "attempt"
      assertHasField obj "elapsed_seconds"
      assertHasField obj "prompt"
      assertHasField obj "value"
      assertHasField obj "interrupt"
      assertHasField obj "error"

  ---------------------------------------------------------------------------
  -- A26: llm_query wire format
  ---------------------------------------------------------------------------

  describe "A26: llm_query wire-format field names" do

    it "A26: llm_query has fields: type, timestamp, purpose, input" do
      let event = llmQueryEvent "t1" "summary" "{}"
      let obj = parseToObj (encodeLogEvent event)
      assertHasField obj "type"
      assertHasField obj "timestamp"
      assertHasField obj "purpose"
      assertHasField obj "input"
      assertFieldEquals obj "type" "llm_query"

  ---------------------------------------------------------------------------
  -- A26: tool_call wire format
  ---------------------------------------------------------------------------

  describe "A26: tool_call wire-format field names" do

    it "A26: tool_call has fields: type, timestamp, tool, tool_call_id, input" do
      let event = toolCallEvent "t1" "julia_repl" (ToolCallId "tc1") "1+1"
      let obj = parseToObj (encodeLogEvent event)
      assertHasField obj "type"
      assertHasField obj "timestamp"
      assertHasField obj "tool"
      assertHasField obj "tool_call_id"
      assertHasField obj "input"
      assertFieldEquals obj "type" "tool_call"
      -- Specifically NOT "toolName" or "toolCallId" — snake_case per spec
      assertLacksField obj "toolName"
      assertLacksField obj "toolCallId"
      assertLacksField obj "tool_name"

  ---------------------------------------------------------------------------
  -- A26: tool_result wire format
  ---------------------------------------------------------------------------

  describe "A26: tool_result wire-format field names" do

    it "A26: tool_result has fields: type, timestamp, tool_call_id, output, truncated" do
      let event = toolResultEvent "t1" (ToolCallId "tc1") "42" false
      let obj = parseToObj (encodeLogEvent event)
      assertHasField obj "type"
      assertHasField obj "timestamp"
      assertHasField obj "tool_call_id"
      assertHasField obj "output"
      assertHasField obj "truncated"
      assertFieldEquals obj "type" "tool_result"
      -- Must NOT use camelCase
      assertLacksField obj "toolCallId"

  ---------------------------------------------------------------------------
  -- A26: token_usage wire format
  ---------------------------------------------------------------------------

  describe "A26: token_usage wire-format field names" do

    it "A26: token_usage has all required snake_case fields" do
      let event = tokenUsageEvent "t1" (TokenCount 500) (TokenCount 200)
      let obj = parseToObj (encodeLogEvent event)
      assertHasField obj "type"
      assertHasField obj "timestamp"
      assertHasField obj "input_tokens"
      assertHasField obj "cached_input_tokens"
      assertHasField obj "output_tokens"
      assertHasField obj "total_session_input_tokens"
      assertHasField obj "total_session_cached_input_tokens"
      assertHasField obj "total_session_output_tokens"
      assertFieldEquals obj "type" "token_usage"
      -- Must NOT use camelCase
      assertLacksField obj "inputTokens"
      assertLacksField obj "cachedInputTokens"
      assertLacksField obj "outputTokens"
      assertLacksField obj "totalSessionInputTokens"

  ---------------------------------------------------------------------------
  -- A26: compaction wire format
  ---------------------------------------------------------------------------

  describe "A26: compaction wire-format field names" do

    it "A26: compaction has fields: type, timestamp, summary, initial_message_count, compacted_message_count, final_message_count, total_tokens_before" do
      let event = compactionEvent
            { timestamp: "t1"
            , summary: "summary text"
            , initialMessageCount: 3
            , compactedMessageCount: 5
            , finalMessageCount: 2
            , totalTokensBefore: 150000
            }
      let obj = parseToObj (encodeLogEvent event)
      assertHasField obj "type"
      assertHasField obj "timestamp"
      assertHasField obj "summary"
      assertHasField obj "initial_message_count"
      assertHasField obj "compacted_message_count"
      assertHasField obj "final_message_count"
      assertHasField obj "total_tokens_before"
      assertFieldEquals obj "type" "compaction"
      -- Must NOT use camelCase
      assertLacksField obj "initialMessageCount"
      assertLacksField obj "compactedMessageCount"
      assertLacksField obj "finalMessageCount"
      assertLacksField obj "totalTokensBefore"

  ---------------------------------------------------------------------------
  -- A26: reflection wire format
  ---------------------------------------------------------------------------

  describe "A26: reflection wire-format field names" do

    it "A26: reflection has fields: type, timestamp, turn_index, auto_turns_taken, complete, feedback" do
      let event = reflectionEvent
            { timestamp: "t1"
            , turnIndex: 2
            , autoTurnsTaken: 1
            , complete: false
            , feedback: Just "Continue"
            }
      let obj = parseToObj (encodeLogEvent event)
      assertHasField obj "type"
      assertHasField obj "timestamp"
      assertHasField obj "turn_index"
      assertHasField obj "auto_turns_taken"
      assertHasField obj "complete"
      assertHasField obj "feedback"
      assertFieldEquals obj "type" "reflection"
      -- Must NOT use camelCase
      assertLacksField obj "turnIndex"
      assertLacksField obj "autoTurnsTaken"

    it "A26: reflection feedback field omitted when Nothing" do
      let event = reflectionEvent
            { timestamp: "t1"
            , turnIndex: 1
            , autoTurnsTaken: 0
            , complete: true
            , feedback: Nothing
            }
      let obj = parseToObj (encodeLogEvent event)
      assertLacksField obj "feedback"

  ---------------------------------------------------------------------------
  -- A26: timeout_check wire format
  ---------------------------------------------------------------------------

  describe "A26: timeout_check wire-format field names" do

    it "A26: timeout_check has fields: type, timestamp, elapsed_seconds, partial_output" do
      let event = timeoutCheckEvent "t1" 45 "partial"
      let obj = parseToObj (encodeLogEvent event)
      assertHasField obj "type"
      assertHasField obj "timestamp"
      assertHasField obj "elapsed_seconds"
      assertHasField obj "partial_output"
      assertFieldEquals obj "type" "timeout_check"
      -- Must NOT use camelCase
      assertLacksField obj "elapsedSeconds"
      assertLacksField obj "partialOutput"

  ---------------------------------------------------------------------------
  -- A26: timeout_response wire format
  ---------------------------------------------------------------------------

  describe "A26: timeout_response wire-format field names" do

    it "A26: timeout_response has fields: type, timestamp, interrupt" do
      let event = timeoutResponseEvent "t1" true
      let obj = parseToObj (encodeLogEvent event)
      assertHasField obj "type"
      assertHasField obj "timestamp"
      assertHasField obj "interrupt"
      assertFieldEquals obj "type" "timeout_response"

  ---------------------------------------------------------------------------
  -- A26: escape wire format
  ---------------------------------------------------------------------------

  describe "A26: escape wire-format field names" do

    it "A26: escape has fields: type, timestamp" do
      let event = escapeEvent "t1"
      let obj = parseToObj (encodeLogEvent event)
      assertHasField obj "type"
      assertHasField obj "timestamp"
      assertFieldEquals obj "type" "escape"

  ---------------------------------------------------------------------------
  -- A26: sigint wire format
  ---------------------------------------------------------------------------

  describe "A26: sigint wire-format field names" do

    it "A26: sigint has fields: type, timestamp" do
      let event = sigintEvent "t1"
      let obj = parseToObj (encodeLogEvent event)
      assertHasField obj "type"
      assertHasField obj "timestamp"
      assertFieldEquals obj "type" "sigint"

  ---------------------------------------------------------------------------
  -- A26: session_end wire format
  ---------------------------------------------------------------------------

  describe "A26: session_end wire-format field names" do

    it "A26: session_end has fields: type, timestamp, reason" do
      let event = sessionEndEvent "t1" "eof"
      let obj = parseToObj (encodeLogEvent event)
      assertHasField obj "type"
      assertHasField obj "timestamp"
      assertHasField obj "reason"
      assertFieldEquals obj "type" "session_end"

  ---------------------------------------------------------------------------
  -- A26: system_prompt wire format
  ---------------------------------------------------------------------------

  describe "A26: system_prompt wire-format field names" do

    it "A26: system_prompt has fields: type, timestamp, content" do
      let event = systemPromptEvent "t1" "You are 7aigent."
      let obj = parseToObj (encodeLogEvent event)
      assertHasField obj "type"
      assertHasField obj "timestamp"
      assertHasField obj "content"
      assertFieldEquals obj "type" "system_prompt"

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

parseToObj :: String -> FO.Object J.Json
parseToObj json = case JP.jsonParser json of
    Left err -> unsafeCrashWith ("Failed to parse JSON: " <> err)
    Right val -> case J.toObject val of
        Nothing -> unsafeCrashWith "Expected JSON object"
        Just obj -> obj

assertHasField :: FO.Object J.Json -> String -> Aff Unit
assertHasField obj field =
    isJust (FO.lookup field obj) `shouldEqual` true

assertLacksField :: FO.Object J.Json -> String -> Aff Unit
assertLacksField obj field =
    isJust (FO.lookup field obj) `shouldEqual` false

assertFieldEquals :: FO.Object J.Json -> String -> String -> Aff Unit
assertFieldEquals obj field expected =
    case FO.lookup field obj of
        Nothing -> fail ("Missing field: " <> field)
        Just val -> case J.toString val of
            Nothing -> fail ("Field " <> field <> " is not a string")
            Just s -> s `shouldEqual` expected

assertFieldNotNull :: FO.Object J.Json -> String -> Aff Unit
assertFieldNotNull obj field =
    case FO.lookup field obj of
        Nothing -> fail ("Missing field: " <> field)
        Just val -> J.isNull val `shouldEqual` false

foreign import unsafeCrashWith :: forall a. String -> a
