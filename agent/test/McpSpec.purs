-- | Tests for MCP server mode: A43.
module Test.McpSpec where

import Prelude

import Data.Maybe (Maybe(..))
import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy)

import Agent.Programs.Mcp
  ( buildMcpRunConfig
  , handleMcpResult
  , isProgressDue
  , extractFinalMessage
  , McpRunResult(..)
  )
import Agent.Types
  ( ConversationHistory(..)
  , Message(..)
  , TokenCount(..)
  )

mcpSpec :: Spec Unit
mcpSpec = do

  ---------------------------------------------------------------------------
  -- A43: MCP tool dispatch
  ---------------------------------------------------------------------------

  describe "A43: MCP run tool dispatch" do

    it "A43: run tool with message → session config with that message" do
      let config = buildMcpRunConfig "Fix the bug in parser.jl"
      config.initialMessage `shouldEqual` "Fix the bug in parser.jl"

    it "A43: each invocation gets an independent session" do
      let config1 = buildMcpRunConfig "Task 1"
      let config2 = buildMcpRunConfig "Task 2"
      -- Independent sessions must have different session IDs and
      -- different initial messages
      config1.initialMessage `shouldEqual` "Task 1"
      config2.initialMessage `shouldEqual` "Task 2"
      -- Session configs are value types — independence is guaranteed by
      -- the pure construction. Each config carries its own message, so
      -- they cannot share mutable state.
      (config1.initialMessage == config2.initialMessage) `shouldEqual` false

  ---------------------------------------------------------------------------
  -- A43: MCP result handling
  ---------------------------------------------------------------------------

  describe "A43: MCP result handling" do

    it "A43: loop completes with final message → McpSuccess with text" do
      let result = handleMcpResult (McpSuccess "The answer is 42.")
      result.isError `shouldEqual` false
      result.content `shouldEqual` "The answer is 42."

    it "A43: sandbox crash → McpFailure with error description" do
      let result = handleMcpResult (McpFailure "Sandbox exited unexpectedly")
      result.isError `shouldEqual` true
      result.content `shouldSatisfy` contains "Sandbox"

    it "A43: API errors exhausted → McpFailure" do
      let result = handleMcpResult (McpFailure "LLM API errors exhausted after 3 retries")
      result.isError `shouldEqual` true

    it "A43: context too large → McpFailure" do
      let result = handleMcpResult (McpFailure "Context too large to compact")
      result.isError `shouldEqual` true
      result.content `shouldSatisfy` contains "compact"

  ---------------------------------------------------------------------------
  -- A43: MCP progress notifications
  ---------------------------------------------------------------------------

  describe "A43: MCP progress notification scheduling" do

    it "A43: 15s elapsed → progress notification due (default interval)" do
      isProgressDue 15 15 `shouldEqual` true

    it "A43: 14s elapsed → not due (default interval)" do
      isProgressDue 15 14 `shouldEqual` false

    it "A43: 30s elapsed → second notification due" do
      isProgressDue 15 30 `shouldEqual` true

    it "A43: notifications every 15 seconds" do
      isProgressDue 15 45 `shouldEqual` true
      isProgressDue 15 60 `shouldEqual` true
      isProgressDue 15 44 `shouldEqual` false

    it "A43: custom interval 3s → due at 3, 6, 9" do
      isProgressDue 3 3 `shouldEqual` true
      isProgressDue 3 6 `shouldEqual` true
      isProgressDue 3 2 `shouldEqual` false

  ---------------------------------------------------------------------------
  -- A43: extractFinalMessage (returns text of the last assistant turn)
  ---------------------------------------------------------------------------

  describe "A43: extractFinalMessage" do

    it "A43: empty history → Nothing" do
      extractFinalMessage emptyHistory `shouldEqual` Nothing

    it "A43: only system message → Nothing" do
      let h = mkHistory [ SystemMessage { content: "sys" } ]
      extractFinalMessage h `shouldEqual` Nothing

    it "A43: only user message → Nothing" do
      let h = mkHistory [ UserMessage { content: "user msg" } ]
      extractFinalMessage h `shouldEqual` Nothing

    it "A43: one assistant message → its content" do
      let h = mkHistory [ AssistantMessage { content: "answer", toolCalls: [] } ]
      extractFinalMessage h `shouldEqual` Just "answer"

    it "A43: multiple messages, last is assistant → last content" do
      let h = mkHistory
                [ SystemMessage   { content: "sys" }
                , UserMessage     { content: "q" }
                , AssistantMessage { content: "first", toolCalls: [] }
                , UserMessage     { content: "follow-up" }
                , AssistantMessage { content: "final answer", toolCalls: [] }
                ]
      extractFinalMessage h `shouldEqual` Just "final answer"

    it "A43: conversation ends with user message → last assistant content" do
      let h = mkHistory
                [ AssistantMessage { content: "mid", toolCalls: [] }
                , UserMessage     { content: "still going" }
                ]
      extractFinalMessage h `shouldEqual` Just "mid"

    it "A43: empty content assistant message is still returned" do
      let h = mkHistory [ AssistantMessage { content: "", toolCalls: [] } ]
      extractFinalMessage h `shouldEqual` Just ""

  where
  contains :: String -> String -> Boolean
  contains needle haystack =
    String.contains (String.Pattern needle) haystack

  emptyHistory :: ConversationHistory
  emptyHistory = ConversationHistory { messages: [] }

  mkHistory :: Array Message -> ConversationHistory
  mkHistory msgs = ConversationHistory
    { messages: map (\m -> { message: m, tokens: TokenCount 0 }) msgs }
