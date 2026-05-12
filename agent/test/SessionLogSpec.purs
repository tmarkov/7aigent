-- | Tests for session logging: A24, A25, A26, A27.
module Test.SessionLogSpec where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.String as String
import Control.Parallel (parTraverse)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy, fail)

import Test.Helpers.Workspace (withWorkspace, readWorkspaceFile, workspaceFileExists, writeWorkspaceFile)
import Test.Helpers.LogEvent
  ( sessionStartEvent
  , userMessageEvent
  , llmResponseEvent
  , sessionEndEvent
  , toolCallEvent
  , toolResultEvent
  , tokenUsageEvent
  , compactionEvent
  , escapeEvent
  , sigintEvent
  , timeoutCheckEvent
  , timeoutResponseEvent
  )
import Agent.Programs.SessionLog
  ( allocateSessionId
  , writeLogEvent
  , readLogEvents
  , sessionDescription
  , encodeLogEvent
  , decodeLogEvent
  )
import Agent.Types
  ( WorkspacePath(..)
  , SessionId(..)
  , ModelName(..)
  , ToolCallId(..)
  , TokenCount(..)
  , LogEvent(..)
  )

sessionLogSpec :: Spec Unit
sessionLogSpec = do

  ---------------------------------------------------------------------------
  -- A24: session directory allocation
  ---------------------------------------------------------------------------

  describe "A24: session directory allocation" do

    it "A24: first session in fresh workspace → ID is 1" do
      withWorkspace \ws -> do
        sid <- allocateSessionId ws
        sid `shouldEqual` SessionId 1

    it "A24: second session → ID is 2" do
      withWorkspace \ws -> do
        _sid1 <- allocateSessionId ws
        sid2  <- allocateSessionId ws
        sid2 `shouldEqual` SessionId 2

    it "A24: non-sequential existing dirs → next ID is max + 1" do
      withWorkspace \ws -> do
        -- Manually create session dirs 1 and 3 (skipping 2)
        writeWorkspaceFile ws ".7aigent/sessions/1/log.jsonl" ""
        writeWorkspaceFile ws ".7aigent/sessions/3/log.jsonl" ""
        sid <- allocateSessionId ws
        sid `shouldEqual` SessionId 4

    it "A24: session directory is created on disk" do
      withWorkspace \ws -> do
        sid <- allocateSessionId ws
        exists <- workspaceFileExists ws ".7aigent/sessions/1/"
        exists `shouldEqual` true

    it "A24: session allocation creates the documented lock file path" do
      withWorkspace \ws -> do
        _ <- allocateSessionId ws
        lockExists <- workspaceFileExists ws ".7aigent/sessions/.lock"
        lockExists `shouldEqual` true

  ---------------------------------------------------------------------------
  -- A25 + A26: log event writing
  ---------------------------------------------------------------------------

  describe "A25 + A26: log event writing" do

    it "A26: session_start event has correct fields" do
      let event = sessionStartEvent
            { id: SessionId 1
            , timestamp: "2026-01-15T14:32:00Z"
            , workspace: "/home/user/project"
            , model: ModelName "test-model"
            , resumedFrom: Nothing
            }
      let json = encodeLogEvent event
      -- Verify the JSON contains expected fields
      String.contains (String.Pattern "session_start") json `shouldEqual` true
      String.contains (String.Pattern "2026-01-15T14:32:00Z") json `shouldEqual` true

    it "A25: writing multiple events → each on its own line" do
      withWorkspace \ws -> do
        let sid = SessionId 1
        _ <- allocateSessionId ws  -- creates directory
        writeLogEvent ws sid (userMessageEvent "2026-01-15T14:32:01Z" "hello")
        writeLogEvent ws sid (llmResponseEvent "2026-01-15T14:32:02Z" "hi there")
        content <- readWorkspaceFile ws ".7aigent/sessions/1/log.jsonl"
        let lineCount = Array.length (String.split (String.Pattern "\n") (String.trim content))
        lineCount `shouldEqual` 2

    it "A26: round-trip — write event, read back, parsed event matches" do
      let event = userMessageEvent "2026-01-15T14:32:01Z" "test message"
      let encoded = encodeLogEvent event
      case decodeLogEvent encoded of
        Right decoded ->
          case decoded of
            EvtUserMessage r -> do
              r.content `shouldEqual` "test message"
              r.timestamp `shouldEqual` "2026-01-15T14:32:01Z"
            _ -> fail "Expected UserMessage event"
        Left err -> fail ("Decode failed: " <> show err)

    it "A26: all event types encode with correct type field" do
      let events =
            [ sessionStartEvent { id: SessionId 1, timestamp: "t", workspace: "/w", model: ModelName "m", resumedFrom: Nothing }
            , userMessageEvent "t" "content"
            , llmResponseEvent "t" "response"
            , sessionEndEvent "t" "eof"
            ]
      let jsons = map encodeLogEvent events
      -- Each encoded event must contain its type identifier
      Array.index jsons 0 `shouldSatisfy` \j -> containsPattern "session_start" j
      Array.index jsons 1 `shouldSatisfy` \j -> containsPattern "user_message" j
      Array.index jsons 2 `shouldSatisfy` \j -> containsPattern "llm_response" j
      Array.index jsons 3 `shouldSatisfy` \j -> containsPattern "session_end" j

  ---------------------------------------------------------------------------
  -- A26: encode/decode round-trip for all event types
  ---------------------------------------------------------------------------

  describe "A26: round-trip encode/decode for all event types" do

    it "A26: tool_call event round-trips correctly" do
      let event = toolCallEvent "t1" "julia_repl" (ToolCallId "tc1") "1+1"
      case decodeLogEvent (encodeLogEvent event) of
        Right (EvtToolCall r) -> do
          r.toolName `shouldEqual` "julia_repl"
          r.toolCallId `shouldEqual` ToolCallId "tc1"
          r.input `shouldEqual` "1+1"
        Right _ -> fail "Expected ToolCall event"
        Left err -> fail ("Decode failed: " <> show err)

    it "A26: tool_result event round-trips correctly" do
      let event = toolResultEvent "t1" (ToolCallId "tc1") "2" false
      case decodeLogEvent (encodeLogEvent event) of
        Right (ToolResult r) -> do
          r.toolCallId `shouldEqual` ToolCallId "tc1"
          r.output `shouldEqual` "2"
          r.truncated `shouldEqual` false
        Right _ -> fail "Expected ToolResult event"
        Left err -> fail ("Decode failed: " <> show err)

    it "A26: token_usage event round-trips correctly" do
      let event = tokenUsageEvent "t1" (TokenCount 500) (TokenCount 200)
      case decodeLogEvent (encodeLogEvent event) of
        Right (TokenUsage r) -> do
          r.inputTokens `shouldEqual` TokenCount 500
          r.outputTokens `shouldEqual` TokenCount 200
        Right _ -> fail "Expected TokenUsage event"
        Left err -> fail ("Decode failed: " <> show err)

    it "A26: compaction event round-trips correctly" do
      let event = compactionEvent
            { timestamp: "t1"
            , summary: "The conversation was about X."
            , initialMessageCount: 3
            , compactedMessageCount: 5
            , finalMessageCount: 2
            , totalTokensBefore: 150000
            }
      case decodeLogEvent (encodeLogEvent event) of
        Right (Compaction r) -> do
          r.summary `shouldEqual` "The conversation was about X."
          r.totalTokensBefore `shouldEqual` 150000
        Right _ -> fail "Expected Compaction event"
        Left err -> fail ("Decode failed: " <> show err)

    it "A26: escape event round-trips correctly" do
      let event = escapeEvent "t1"
      case decodeLogEvent (encodeLogEvent event) of
        Right (Escape r) -> r.timestamp `shouldEqual` "t1"
        Right _ -> fail "Expected Escape event"
        Left err -> fail ("Decode failed: " <> show err)

    it "A26: sigint event round-trips correctly" do
      let event = sigintEvent "t1"
      case decodeLogEvent (encodeLogEvent event) of
        Right (Sigint r) -> r.timestamp `shouldEqual` "t1"
        Right _ -> fail "Expected Sigint event"
        Left err -> fail ("Decode failed: " <> show err)

    it "A26: timeout_check event round-trips correctly" do
      let event = timeoutCheckEvent "t1" 45 "partial output"
      case decodeLogEvent (encodeLogEvent event) of
        Right (TimeoutCheck r) -> do
          r.elapsedSeconds `shouldEqual` 45
          r.partialOutput `shouldEqual` "partial output"
        Right _ -> fail "Expected TimeoutCheck event"
        Left err -> fail ("Decode failed: " <> show err)

    it "A26: timeout_response event round-trips correctly" do
      let event = timeoutResponseEvent "t1" true
      case decodeLogEvent (encodeLogEvent event) of
        Right (TimeoutResponse r) -> do
          r.interrupt `shouldEqual` true
        Right _ -> fail "Expected TimeoutResponse event"
        Left err -> fail ("Decode failed: " <> show err)

  ---------------------------------------------------------------------------
  -- A24: concurrent session allocation
  ---------------------------------------------------------------------------

  describe "A24: concurrent session allocation" do

    it "A24: concurrent allocations produce unique IDs" do
      withWorkspace \ws -> do
        -- Allocate 5 sessions concurrently using parTraverse
        let indices = Array.range 1 5
        sids <- parTraverse (\_ -> allocateSessionId ws) indices
        -- All IDs must be unique
        let uniqueCount = Set.size (Set.fromFoldable sids)
        uniqueCount `shouldEqual` 5

  ---------------------------------------------------------------------------
  -- A27: session description
  ---------------------------------------------------------------------------

  describe "A27: session description" do

    it "A27: message under 120 chars → returned verbatim" do
      let msg = "Fix the failing test in runtests.jl"
      sessionDescription msg `shouldEqual` msg

    it "A27: message over 120 chars → truncated to 120" do
      let msg = String.joinWith "" (Array.replicate 150 "x")
      let desc = sessionDescription msg
      String.length desc `shouldEqual` 120

    it "A27: exactly 120 chars → returned verbatim" do
      let msg = String.joinWith "" (Array.replicate 120 "a")
      sessionDescription msg `shouldEqual` msg

  where
  containsPattern :: String -> Maybe String -> Boolean
  containsPattern _ Nothing = false
  containsPattern pat (Just s) = String.contains (String.Pattern pat) s
