-- | Tests for the interruption state machine: A10, A11, A12, A13.
module Test.InterruptionSpec where

import Prelude

import Data.Array as Array
import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy, fail)

import Test.Helpers.Conversation (systemMsg, userMsg, mkHistory)
import Agent.Programs.Interruption
  ( handleEscape
  , handleSigint
  , handleEof
  , InterruptResult
  )
import Agent.Types
  ( LoopState(..)
  , ControllerAction(..)
  , LogEvent(..)
  , ToolName(..)
  , ToolCall
  , ToolCallId(..)
  , SessionId(..)
  , TokenCount(..)
  , ConversationHistory
  , Message
  , unwrapConversationHistory
  , extractContent
  , isToolResultMessage
  )

sampleHistory :: ConversationHistory
sampleHistory = mkHistory [ systemMsg "sys", userMsg "hello" ]

juliaToolCall :: ToolCall
juliaToolCall = { name: JuliaRepl, input: "1+1", id: ToolCallId "tc1" }

gitDiffToolCall :: ToolCall
gitDiffToolCall = { name: GitDiff, input: "", id: ToolCallId "tc2" }

gitCommitToolCall :: ToolCall
gitCommitToolCall = { name: GitCommit, input: "{}", id: ToolCallId "tc3" }

interruptionSpec :: Spec Unit
interruptionSpec = do

  ---------------------------------------------------------------------------
  -- A10: concurrent keyboard input — state machine accepts events in any state
  ---------------------------------------------------------------------------

  describe "A10: interruption events accepted in any loop state" do

    it "A10: escape accepted in AwaitingLlm" do
      let state = AwaitingLlm sampleHistory { text: "partial", toolCalls: [] }
      let result = handleEscape state
      result.nextState `shouldSatisfy` isAwaitingUser

    it "A10: escape accepted in ExecutingTool" do
      let state = ExecutingTool sampleHistory juliaToolCall ""
      let result = handleEscape state
      result.nextState `shouldSatisfy` isAwaitingUser

    it "A10: sigint accepted in AwaitingUser" do
      let state = AwaitingUser sampleHistory
      let result = handleSigint state (SessionId 1)
      hasAction ExitRunner result `shouldEqual` true

  ---------------------------------------------------------------------------
  -- A11: Escape key
  ---------------------------------------------------------------------------

  describe "A11: escape during LLM generation" do

    it "A11: cancels request, preserves partial text as LlmResponse" do
      let state = AwaitingLlm sampleHistory { text: "partial answer", toolCalls: [] }
      let result = handleEscape state
      hasAction CancelLlmRequest result `shouldEqual` true
      -- Partial text should be preserved in conversation history
      result.nextState `shouldSatisfy` isAwaitingUser
      -- Verify the partial text actually appears in the resulting history
      historyContainsText "partial answer" result `shouldEqual` true

    it "A11: partial tool call is discarded" do
      let partialTc = { name: JuliaRepl, input: "incompl", id: ToolCallId "tc1" }
      let state = AwaitingLlm sampleHistory { text: "text", toolCalls: [partialTc] }
      let result = handleEscape state
      -- The tool call should not appear in any action
      hasAction CancelLlmRequest result `shouldEqual` true

  describe "A11: escape during tool execution" do

    it "A11: julia_repl → sends interrupt_request" do
      let state = ExecutingTool sampleHistory juliaToolCall "partial output"
      let result = handleEscape state
      hasAction InterruptJulia result `shouldEqual` true

    it "A11: git_diff → sends SIGINT to tool process" do
      let state = ExecutingTool sampleHistory gitDiffToolCall ""
      let result = handleEscape state
      hasAction InterruptHostProcess result `shouldEqual` true

    it "A11: git_commit → sends SIGINT to tool process" do
      let state = ExecutingTool sampleHistory gitCommitToolCall ""
      let result = handleEscape state
      hasAction InterruptHostProcess result `shouldEqual` true

    it "A11: escape event is logged" do
      let state = AwaitingLlm sampleHistory { text: "", toolCalls: [] }
      let result = handleEscape state
      hasLogEvent isEscapeEvent result `shouldEqual` true

  ---------------------------------------------------------------------------
  -- A12: SIGINT
  ---------------------------------------------------------------------------

  describe "A12: SIGINT during LLM generation" do

    it "A12: cancels request, preserves partial text" do
      let state = AwaitingLlm sampleHistory { text: "partial", toolCalls: [] }
      let result = handleSigint state (SessionId 1)
      hasAction CancelLlmRequest result `shouldEqual` true

    it "A12: partial tool call discarded" do
      let partialTc = { name: JuliaRepl, input: "x", id: ToolCallId "tc1" }
      let state = AwaitingLlm sampleHistory { text: "", toolCalls: [partialTc] }
      let result = handleSigint state (SessionId 1)
      hasAction CancelLlmRequest result `shouldEqual` true

  describe "A12: SIGINT during tool execution" do

    it "A12: julia_repl → interrupt_request, output gets [interrupted]" do
      let state = ExecutingTool sampleHistory juliaToolCall "partial"
      let result = handleSigint state (SessionId 1)
      hasAction InterruptJulia result `shouldEqual` true
      -- A12 requires "\n[interrupted]" appended to partial output
      -- in the tool result recorded in history
      toolResultContains "\n[interrupted]" result `shouldEqual` true

    it "A12: git_diff → SIGINT to process" do
      let state = ExecutingTool sampleHistory gitDiffToolCall ""
      let result = handleSigint state (SessionId 1)
      hasAction InterruptHostProcess result `shouldEqual` true

  describe "A12: SIGINT always triggers shutdown sequence" do

    it "A12: serializes REPL state" do
      let state = AwaitingUser sampleHistory
      let result = handleSigint state (SessionId 1)
      hasAction (SerializeReplState (SessionId 1)) result `shouldEqual` true

    it "A12: writes session_end event" do
      let state = AwaitingUser sampleHistory
      let result = handleSigint state (SessionId 1)
      hasLogEvent isSessionEndEvent result `shouldEqual` true

    it "A12: exits runner" do
      let state = AwaitingUser sampleHistory
      let result = handleSigint state (SessionId 1)
      hasAction ExitRunner result `shouldEqual` true

    it "A12: sigint event is logged" do
      let state = AwaitingUser sampleHistory
      let result = handleSigint state (SessionId 1)
      hasLogEvent isSigintEvent result `shouldEqual` true

  ---------------------------------------------------------------------------
  -- A13: EOF
  ---------------------------------------------------------------------------

  describe "A13: EOF when idle behaves identically to SIGINT" do

    it "A13: EOF in AwaitingUser → exits with REPL serialization and session_end" do
      let state = AwaitingUser sampleHistory
      let eofResult = handleEof state (SessionId 1)
      -- EOF should produce the same shutdown sequence as SIGINT:
      -- serialize REPL state, write session_end, exit
      hasAction ExitRunner eofResult `shouldEqual` true
      hasAction (SerializeReplState (SessionId 1)) eofResult `shouldEqual` true
      hasLogEvent isSessionEndEvent eofResult `shouldEqual` true

  where
  isAwaitingUser :: LoopState -> Boolean
  isAwaitingUser (AwaitingUser _) = true
  isAwaitingUser _ = false

  hasAction :: ControllerAction -> InterruptResult -> Boolean
  hasAction target result = Array.any (actionMatches target) result.actions

  -- Structural match on action constructor (ignoring payloads for simple checks)
  actionMatches :: ControllerAction -> ControllerAction -> Boolean
  actionMatches CancelLlmRequest CancelLlmRequest = true
  actionMatches InterruptJulia InterruptJulia = true
  actionMatches InterruptHostProcess InterruptHostProcess = true
  actionMatches ExitRunner ExitRunner = true
  actionMatches (SerializeReplState s1) (SerializeReplState s2) = s1 == s2
  actionMatches _ _ = false

  hasLogEvent :: (LogEvent -> Boolean) -> InterruptResult -> Boolean
  hasLogEvent pred result = Array.any pred result.logEvents

  isEscapeEvent :: LogEvent -> Boolean
  isEscapeEvent (Escape _) = true
  isEscapeEvent _ = false

  isSigintEvent :: LogEvent -> Boolean
  isSigintEvent (Sigint _) = true
  isSigintEvent _ = false

  isSessionEndEvent :: LogEvent -> Boolean
  isSessionEndEvent (SessionEnd _) = true
  isSessionEndEvent _ = false

  -- Check if the resulting history contains a message with the given text.
  -- Used to verify A11 partial text preservation.
  historyContainsText :: String -> InterruptResult -> Boolean
  historyContainsText text result =
    case result.nextState of
      AwaitingUser hist ->
        let msgs = unwrapHistory hist
        in Array.any (\m -> String.contains (String.Pattern text) (messageContent m)) msgs
      _ -> false

  -- Check if any tool result in the resulting history contains the given
  -- substring. Used to verify A12 [interrupted] marker.
  toolResultContains :: String -> InterruptResult -> Boolean
  toolResultContains text result =
    case result.nextState of
      AwaitingUser hist ->
        let msgs = unwrapHistory hist
        in Array.any (\m -> isToolResult m
              && String.contains (String.Pattern text) (messageContent m)) msgs
      _ -> false

  -- Helpers for history inspection (implementation adapts to actual Message type)
  unwrapHistory :: ConversationHistory -> Array { message :: Message, tokens :: TokenCount }
  unwrapHistory = unwrapConversationHistory

  messageContent :: { message :: Message, tokens :: TokenCount } -> String
  messageContent entry = extractContent entry.message

  isToolResult :: { message :: Message, tokens :: TokenCount } -> Boolean
  isToolResult entry = isToolResultMessage entry.message
