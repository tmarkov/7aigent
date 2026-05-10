-- | Tests for CLI argument parsing: A40, A42, A44.
module Test.CLISpec where

import Prelude

import Data.Maybe (Maybe(..), isNothing)
import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, fail)

import Agent.Programs.CLI (parseCLIArgs, CLIMode(..))
import Agent.Types (SessionId(..), Port(..), WorkspacePath(..))

cliSpec :: Spec Unit
cliSpec = do

  describe "A40: CLI start session" do

    it "A40: no arguments → StartSession" do
      case (parseCLIArgs []).mode of
        StartSession -> pure unit
        _ -> fail "Expected StartSession for no arguments"

  describe "A41: CLI sessions listing" do

    it "A41: 'sessions' → ListSessions" do
      case (parseCLIArgs ["sessions"]).mode of
        ListSessions -> pure unit
        _ -> fail "Expected ListSessions"

  describe "A42: CLI resume" do

    it "A42: 'resume 3' → ResumeSession (SessionId 3)" do
      case (parseCLIArgs ["resume", "3"]).mode of
        ResumeSession sid -> sid `shouldEqual` SessionId 3
        _ -> fail "Expected ResumeSession with ID 3"

    it "A42: 'resume' without session ID → CLIError" do
      case (parseCLIArgs ["resume"]).mode of
        CLIError _ -> pure unit
        _ -> fail "Expected CLIError for missing session ID"

    it "A42: 'resume abc' (non-numeric) → CLIError" do
      case (parseCLIArgs ["resume", "abc"]).mode of
        CLIError _ -> pure unit
        _ -> fail "Expected CLIError for non-numeric session ID"

  describe "A43: CLI MCP mode" do

    it "A43: 'mcp 8080' → McpServer (Port 8080)" do
      case (parseCLIArgs ["mcp", "8080"]).mode of
        McpServer port -> port `shouldEqual` Port 8080
        _ -> fail "Expected McpServer with port 8080"

    it "A43: 'mcp' without port → CLIError" do
      case (parseCLIArgs ["mcp"]).mode of
        CLIError _ -> pure unit
        _ -> fail "Expected CLIError for missing port"

  describe "CLI: unknown command" do

    it "unknown command → CLIError with usage info" do
      case (parseCLIArgs ["unknown"]).mode of
        CLIError msg ->
          shouldEqual true (String.length msg > 0)
        _ -> fail "Expected CLIError for unknown command"

  describe "A44: CLI workspace directory override" do

    it "A44: absolute path → workspace set, StartSession mode" do
      let parsed = parseCLIArgs ["/path/to/project"]
      parsed.workspace `shouldEqual` Just (WorkspacePath "/path/to/project")
      parsed.mode `shouldEqual` StartSession

    it "A44: absolute path + 'sessions' → workspace set, ListSessions mode" do
      let parsed = parseCLIArgs ["/path/to/project", "sessions"]
      parsed.workspace `shouldEqual` Just (WorkspacePath "/path/to/project")
      parsed.mode `shouldEqual` ListSessions

    it "A44: absolute path + 'resume 5' → workspace set, ResumeSession mode" do
      let parsed = parseCLIArgs ["/path/to/project", "resume", "5"]
      parsed.workspace `shouldEqual` Just (WorkspacePath "/path/to/project")
      case parsed.mode of
        ResumeSession sid -> sid `shouldEqual` SessionId 5
        _ -> fail "Expected ResumeSession"

    it "A44: './' prefix recognised as path" do
      let parsed = parseCLIArgs ["./myproject"]
      parsed.workspace `shouldEqual` Just (WorkspacePath "./myproject")
      parsed.mode `shouldEqual` StartSession

    it "A44: '../' prefix recognised as path" do
      let parsed = parseCLIArgs ["../sibling"]
      parsed.workspace `shouldEqual` Just (WorkspacePath "../sibling")
      parsed.mode `shouldEqual` StartSession

    it "A44: '~' prefix recognised as path" do
      let parsed = parseCLIArgs ["~/projects/myproject"]
      parsed.workspace `shouldEqual` Just (WorkspacePath "~/projects/myproject")
      parsed.mode `shouldEqual` StartSession

    it "A44: no path → workspace is Nothing" do
      let parsed = parseCLIArgs []
      shouldEqual true (isNothing parsed.workspace)

    it "A44: non-path first arg → not treated as workspace" do
      let parsed = parseCLIArgs ["sessions"]
      shouldEqual true (isNothing parsed.workspace)
      parsed.mode `shouldEqual` ListSessions
