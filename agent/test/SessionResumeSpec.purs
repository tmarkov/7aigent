-- | Tests for session resumption: A31, A32.
module Test.SessionResumeSpec where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy, fail)

import Test.Helpers.Workspace (withWorkspace, writeWorkspaceFile, writeSessionLog, workspaceFileExists)
import Test.Helpers.LogEvent
  ( sessionStartEvent
  , systemPromptEvent
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
  , ToolName(..)
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
        Right history -> case historyMessages history of
          [ UserMessage user
          , AssistantMessage assistantWithTool
          , ToolResultMessage result
          , AssistantMessage finalAssistant
          ] -> do
            user.content `shouldEqual` "Run something"
            assistantWithTool.content `shouldEqual` ""
            Array.length assistantWithTool.toolCalls `shouldEqual` 1
            case Array.head assistantWithTool.toolCalls of
              Just toolCall -> do
                toolCall.id `shouldEqual` tcId
                toolCall.name `shouldEqual` JuliaRepl
                toolCall.input `shouldEqual` "1 + 1"
              Nothing ->
                fail "Expected paired assistant tool call"
            result.toolCallId `shouldEqual` tcId
            result.output `shouldEqual` "2"
            finalAssistant.content `shouldEqual` "The result is 2."
            finalAssistant.toolCalls `shouldEqual` []
          msgs ->
            fail ("Expected exact paired resume history, got: " <> show msgs)
        Left err -> fail ("Reconstruction failed: " <> show err)

    it "A31: tool_call_id pairs an early tool_result with its later tool_call" do
      let tcId = ToolCallId "tc-early"
      let events =
            [ sessionStartEvent { id: SessionId 1, timestamp: "t0", workspace: "/w", model: ModelName "m", resumedFrom: Nothing }
            , userMessageEvent "t1" "Run early result case"
            , llmResponseEvent "t2" ""
            , toolResultEvent "t3" tcId "early output" false
            , toolCallEvent "t4" "julia_repl" tcId "early_call()"
            , llmResponseEvent "t5" "Done."
            , sessionEndEvent "t6" "eof"
            ]
      case reconstructHistory events of
        Right history -> case historyMessages history of
          [ UserMessage user
          , AssistantMessage assistantWithTool
          , ToolResultMessage result
          , AssistantMessage finalAssistant
          ] -> do
            user.content `shouldEqual` "Run early result case"
            Array.length assistantWithTool.toolCalls `shouldEqual` 1
            case Array.head assistantWithTool.toolCalls of
              Just toolCall -> do
                toolCall.id `shouldEqual` tcId
                toolCall.input `shouldEqual` "early_call()"
              Nothing ->
                fail "Expected paired assistant tool call"
            result.toolCallId `shouldEqual` tcId
            result.output `shouldEqual` "early output"
            finalAssistant.content `shouldEqual` "Done."
          msgs ->
            fail ("Expected ID-paired resume history, got: " <> show msgs)
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

    it "A31: compaction counts from system-inclusive logs apply to non-system resume history" do
      let events =
            [ sessionStartEvent { id: SessionId 1, timestamp: "t0", workspace: "/w", model: ModelName "m", resumedFrom: Nothing }
            , systemPromptEvent "t0" "system prompt"
            , userMessageEvent "t1" "first user"
            , llmResponseEvent "t2" "old answer"
            , userMessageEvent "t3" "middle user"
            , llmResponseEvent "t4" "middle answer"
            , userMessageEvent "t5" "recent user"
            , llmResponseEvent "t6" "recent answer"
            , compactionEvent
                { timestamp: "t7"
                , summary: "summary text"
                , initialMessageCount: 2
                , compactedMessageCount: 3
                , finalMessageCount: 2
                , totalTokensBefore: 100000
                }
            , sessionEndEvent "t8" "eof"
            ]
      case reconstructHistory events of
        Right history -> case historyMessages history of
          [ UserMessage first
          , UserMessage summary
          , UserMessage recentUser
          , AssistantMessage recentAnswer
          ] -> do
            first.content `shouldEqual` "first user"
            summary.content `shouldEqual` "summary text"
            recentUser.content `shouldEqual` "recent user"
            recentAnswer.content `shouldEqual` "recent answer"
          msgs ->
            fail ("Expected system-adjusted compaction replay, got: " <> show msgs)
        Left err -> fail ("Reconstruction failed: " <> show err)

  ---------------------------------------------------------------------------
  -- A31: file handling (effectful)
  ---------------------------------------------------------------------------

  describe "A31: julia_defs.jl handling" do

    it "A31: file present → expressions available for replay" do
      withWorkspace \ws -> do
        writeWorkspaceFile ws ".7aigent/sessions/1/log.jsonl" ""
        writeWorkspaceFile ws ".7aigent/sessions/1/julia_defs.jl"
          "struct Foo end\nf(x) = x + 1\n"
        writeWorkspaceFile ws ".7aigent/sessions/1/julia_state.jls" "serialized"
        result <- loadSessionForResume ws (SessionId 1)
        case result of
          ResumeReady r -> do
            Array.length r.juliaDefs `shouldSatisfy` (_ > 0)
            r.hasStateFile `shouldEqual` true
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

    it "A32: state file present is prepared for runtime restore" do
      withWorkspace \ws -> do
        let logContent = renderEvents
              [ sessionStartEvent { id: SessionId 1, timestamp: "t0", workspace: "/w", model: ModelName "m", resumedFrom: Nothing }
              , userMessageEvent "t1" "hello"
              , sessionEndEvent "t2" "eof"
               ]
        writeSessionLog ws (SessionId 1) logContent
        writeWorkspaceFile ws ".7aigent/sessions/1/julia_state.jls" "CORRUPT_DATA_HERE"
        writeWorkspaceFile ws ".7aigent/sessions/1/julia_defs.jl" "struct Foo end\n"
        result <- loadSessionForResume ws (SessionId 1)
        case result of
          ResumeReady r ->
            r.hasStateFile `shouldEqual` true
          _ -> fail "Expected ResumeReady with state restore metadata"

    it "A32: completely absent julia_state.jls → skipped with warning" do
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
            r.hasStateFile `shouldEqual` false
            Array.length r.warnings `shouldSatisfy` (_ > 0)
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
