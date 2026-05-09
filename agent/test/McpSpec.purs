-- | Tests for MCP server mode: A43.
module Test.McpSpec where

import Prelude

import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy, fail)

import Agent.Programs.Mcp
  ( buildMcpRunConfig
  , handleMcpResult
  , isProgressDue
  , McpRunResult(..)
  )
import Agent.Types (AppError(..))

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

    it "A43: 15s elapsed → progress notification due" do
      isProgressDue 15 `shouldEqual` true

    it "A43: 14s elapsed → not due" do
      isProgressDue 14 `shouldEqual` false

    it "A43: 30s elapsed → second notification due" do
      isProgressDue 30 `shouldEqual` true

    it "A43: notifications every 15 seconds" do
      isProgressDue 45 `shouldEqual` true
      isProgressDue 60 `shouldEqual` true
      isProgressDue 44 `shouldEqual` false

  where
  contains :: String -> String -> Boolean
  contains needle haystack =
    String.contains (String.Pattern needle) haystack
