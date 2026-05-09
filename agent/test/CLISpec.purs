-- | Tests for CLI argument parsing: A40, A42.
module Test.CLISpec where

import Prelude

import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, fail)

import Agent.Programs.CLI (parseCLIArgs, CLIMode(..))
import Agent.Types (SessionId(..), Port(..))

cliSpec :: Spec Unit
cliSpec = do

  describe "A40: CLI start session" do

    it "A40: no arguments → StartSession" do
      case parseCLIArgs [] of
        StartSession -> pure unit
        _ -> fail "Expected StartSession for no arguments"

  describe "A41: CLI sessions listing" do

    it "A41: 'sessions' → ListSessions" do
      case parseCLIArgs ["sessions"] of
        ListSessions -> pure unit
        _ -> fail "Expected ListSessions"

  describe "A42: CLI resume" do

    it "A42: 'resume 3' → ResumeSession (SessionId 3)" do
      case parseCLIArgs ["resume", "3"] of
        ResumeSession sid -> sid `shouldEqual` SessionId 3
        _ -> fail "Expected ResumeSession with ID 3"

    it "A42: 'resume' without session ID → CLIError" do
      case parseCLIArgs ["resume"] of
        CLIError _ -> pure unit
        _ -> fail "Expected CLIError for missing session ID"

    it "A42: 'resume abc' (non-numeric) → CLIError" do
      case parseCLIArgs ["resume", "abc"] of
        CLIError _ -> pure unit
        _ -> fail "Expected CLIError for non-numeric session ID"

  describe "A43: CLI MCP mode" do

    it "A43: 'mcp 8080' → McpServer (Port 8080)" do
      case parseCLIArgs ["mcp", "8080"] of
        McpServer port -> port `shouldEqual` Port 8080
        _ -> fail "Expected McpServer with port 8080"

    it "A43: 'mcp' without port → CLIError" do
      case parseCLIArgs ["mcp"] of
        CLIError _ -> pure unit
        _ -> fail "Expected CLIError for missing port"

  describe "CLI: unknown command" do

    it "unknown command → CLIError with usage info" do
      case parseCLIArgs ["unknown"] of
        CLIError msg ->
          shouldEqual true (String.length msg > 0)
        _ -> fail "Expected CLIError for unknown command"
