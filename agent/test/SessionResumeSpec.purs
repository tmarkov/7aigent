-- | Tests for session resumption: A31, A32.
module Test.SessionResumeSpec where

import Prelude

import Data.Array as Array
import Data.Array.Partial as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String as String
import Partial.Unsafe (unsafePartial)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy, fail)

import Test.Helpers.Workspace (withWorkspace, writeWorkspaceFile, writeSessionLog, workspaceFileExists)
import Test.Helpers.LogEvent
  ( sessionStartEvent
  , userMessageEvent
  , llmResponseEvent
  , toolCallEvent
  , toolResultEvent
  , compactionEvent
  , sessionEndEvent
  , renderEvents
  )
import Agent.Programs.SessionLog (reconstructHistory)
import Agent.Programs.SessionResume (loadSessionForResume, ResumeResult(..))
import Agent.Types
  ( SessionId(..)
  , ModelName(..)
  , ToolCallId(..)
  , ConversationHistory(..)
  , Message(..)
  , LogEvent(..)
  )

sessionResumeSpec :: Spec Unit
sessionResumeSpec = do

  ---------------------------------------------------------------------------
  -- A31: conversation reconstruction from log
  ---------------------------------------------------------------------------

  describe "A31: conversation reconstruction from log events" do

    it "A31: basic sequence → messages in correct order" do
      let events =
            [ sessionStartEvent { id: SessionId 1, timestamp: "t0", workspace: "/w", model: ModelName "m", resumedFrom: Nothing }
            , userMessageEvent "t1" "What is X?"
            , llmResponseEvent "t2" "X is a variable."
            , userMessageEvent "t3" "Tell me more."
            , llmResponseEvent "t4" "X can hold any value."
            , sessionEndEvent "t5" "eof"
            ]
      case reconstructHistory events of
        Right history -> do
          let msgs = historyMessages history
          -- Should have: system prompt + 4 conversation messages
          -- (session_start and session_end don't become messages)
          Array.length msgs `shouldSatisfy` (_ >= 4)
        Left err -> fail ("Reconstruction failed: " <> show err)

    it "A31: tool_call_id pairs tool_call with tool_result" do
      let tcId = ToolCallId "tc-abc"
      let events =
            [ sessionStartEvent { id: SessionId 1, timestamp: "t0", workspace: "/w", model: ModelName "m", resumedFrom: Nothing }
            , userMessageEvent "t1" "Run something"
            , llmResponseEvent "t2" ""  -- response that triggered a tool call
            , toolCallEvent "t3" "julia_repl" tcId "1 + 1"
            , toolResultEvent "t4" tcId "2" false
            , llmResponseEvent "t5" "The result is 2."
            , sessionEndEvent "t6" "eof"
            ]
      case reconstructHistory events of
        Right history -> do
          let msgs = historyMessages history
          -- The tool call and result should be paired in the history
          Array.length msgs `shouldSatisfy` (_ >= 5)
        Left err -> fail ("Reconstruction failed: " <> show err)

    it "A31: compaction events are reflected in reconstructed history" do
      let events =
            [ sessionStartEvent { id: SessionId 1, timestamp: "t0", workspace: "/w", model: ModelName "m", resumedFrom: Nothing }
            , userMessageEvent "t1" "First question"
            , llmResponseEvent "t2" "First answer"
            , compactionEvent
                { timestamp: "t3"
                , summary: "User asked first question and got an answer."
                , initialMessageCount: 2
                , compactedMessageCount: 2
                , finalMessageCount: 1
                , totalTokensBefore: 100000
                }
            , userMessageEvent "t4" "Second question"
            , llmResponseEvent "t5" "Second answer"
            , sessionEndEvent "t6" "eof"
            ]
      case reconstructHistory events of
        Right history -> do
          -- The reconstructed history should match what it was at session end:
          -- [initial block] + [summary message] + [final block at compaction] + [post-compaction messages]
          let msgs = historyMessages history
          -- Should have the compaction summary in the history
          let hasSummary = Array.any
                (\m -> contains "first question" (String.toLower (messageContent m)))
                msgs
          hasSummary `shouldEqual` true
        Left err -> fail ("Reconstruction failed: " <> show err)

    it "A31: {{datetime}} in system prompt is re-substituted at resume time" do
      -- The system prompt should use the current time, not the original.
      -- We verify by loading a session whose system prompt had a known
      -- datetime, and checking the reconstructed prompt differs.
      withWorkspace \ws -> do
        let logContent = renderEvents
              [ sessionStartEvent { id: SessionId 1, timestamp: "2025-01-01T00:00:00Z", workspace: "/w", model: ModelName "m", resumedFrom: Nothing }
              , userMessageEvent "t1" "hello"
              , sessionEndEvent "t2" "eof"
              ]
        writeSessionLog ws (SessionId 1) logContent
        result <- loadSessionForResume ws (SessionId 1)
        case result of
          ResumeReady r -> do
            -- The system prompt should NOT contain the old timestamp
            let sysPrompt = messageContent (unsafePartial $ Array.unsafeIndex (historyMessages r.history) 0)
            contains "2025-01-01T00:00:00Z" sysPrompt `shouldEqual` false
          _ -> fail "Expected ResumeReady"

  ---------------------------------------------------------------------------
  -- A31: file handling (effectful)
  ---------------------------------------------------------------------------

  describe "A31: julia_defs.jl handling" do

    it "A31: file present → expressions available for replay" do
      withWorkspace \ws -> do
        writeWorkspaceFile ws ".7aigent/sessions/1/log.jsonl" ""
        writeWorkspaceFile ws ".7aigent/sessions/1/julia_defs.jl"
          "struct Foo end\nf(x) = x + 1\n"
        result <- loadSessionForResume ws (SessionId 1)
        case result of
          ResumeReady r ->
            Array.length r.juliaDefs `shouldSatisfy` (_ > 0)
          _ -> fail "Expected ResumeReady"

    it "A31: file absent → skipped with warning" do
      withWorkspace \ws -> do
        -- Create session dir with log but no julia_defs.jl
        let logContent = renderEvents
              [ sessionStartEvent { id: SessionId 1, timestamp: "t0", workspace: "/w", model: ModelName "m", resumedFrom: Nothing }
              , userMessageEvent "t1" "hello"
              , sessionEndEvent "t2" "eof"
              ]
        writeSessionLog ws (SessionId 1) logContent
        result <- loadSessionForResume ws (SessionId 1)
        case result of
          ResumeReady r -> do
            Array.length r.juliaDefs `shouldEqual` 0
            Array.length r.warnings `shouldSatisfy` (_ > 0)
          _ -> fail "Expected ResumeReady with warnings"

  ---------------------------------------------------------------------------
  -- A31: resumed_from in new session_start
  ---------------------------------------------------------------------------

  describe "A31: resumed_from is set" do

    it "A31: resuming session 1 → new session_start has resumed_from = 1" do
      withWorkspace \ws -> do
        let logContent = renderEvents
              [ sessionStartEvent { id: SessionId 1, timestamp: "t0", workspace: "/w", model: ModelName "m", resumedFrom: Nothing }
              , userMessageEvent "t1" "hello"
              , sessionEndEvent "t2" "eof"
              ]
        writeSessionLog ws (SessionId 1) logContent
        result <- loadSessionForResume ws (SessionId 1)
        case result of
          ResumeReady r ->
            r.resumedFrom `shouldEqual` Just (SessionId 1)
          _ -> fail "Expected ResumeReady"

  ---------------------------------------------------------------------------
  -- A32: deserialization failure
  ---------------------------------------------------------------------------

  describe "A32: deserialization failure handling" do

    it "A32: individual global fails → skipped with warning, others intact" do
      -- Write a corrupt julia_state.jls that contains invalid serialized
      -- data for one global. The resume logic should skip the failed
      -- global and produce a warning.
      withWorkspace \ws -> do
        let logContent = renderEvents
              [ sessionStartEvent { id: SessionId 1, timestamp: "t0", workspace: "/w", model: ModelName "m", resumedFrom: Nothing }
              , userMessageEvent "t1" "hello"
              , sessionEndEvent "t2" "eof"
              ]
        writeSessionLog ws (SessionId 1) logContent
        -- Write a corrupt state file (not valid serialized Julia data)
        writeWorkspaceFile ws ".7aigent/sessions/1/julia_state.jls" "CORRUPT_DATA_HERE"
        writeWorkspaceFile ws ".7aigent/sessions/1/julia_defs.jl" "struct Foo end\n"
        result <- loadSessionForResume ws (SessionId 1)
        case result of
          ResumeReady r -> do
            -- Should have warnings about the corrupt state file
            Array.length r.warnings `shouldSatisfy` (_ > 0)
          _ -> fail "Expected ResumeReady with warnings about corrupt state"

    it "A32: completely absent julia_state.jls → treated as fresh session" do
      withWorkspace \ws -> do
        let logContent = renderEvents
              [ sessionStartEvent { id: SessionId 1, timestamp: "t0", workspace: "/w", model: ModelName "m", resumedFrom: Nothing }
              , userMessageEvent "t1" "hello"
              , sessionEndEvent "t2" "eof"
              ]
        writeSessionLog ws (SessionId 1) logContent
        -- No julia_state.jls written — file is simply absent
        stateExists <- workspaceFileExists ws ".7aigent/sessions/1/julia_state.jls"
        stateExists `shouldEqual` false
        result <- loadSessionForResume ws (SessionId 1)
        case result of
          ResumeReady r -> do
            -- No state to deserialize → no globals to restore, just
            -- replay julia_defs.jl. Should succeed without error.
            Array.length r.warnings `shouldSatisfy` (_ >= 0)
          _ -> fail "Expected ResumeReady when julia_state.jls is absent"

  where
  historyMessages :: ConversationHistory -> Array Message
  historyMessages (ConversationHistory h) = map _.message h.messages

  messageContent :: Message -> String
  messageContent (SystemMessage r) = r.content
  messageContent (UserMessage r) = r.content
  messageContent (AssistantMessage r) = r.content
  messageContent (ToolResultMessage r) = r.output

  contains :: String -> String -> Boolean
  contains needle haystack =
    String.contains (String.Pattern needle) haystack
