-- | Tests for CLI argument parsing: A40-A44a.
module Test.CLISpec where

import Prelude

import Data.Maybe (Maybe(..), isNothing)
import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, fail)

import Agent.Programs.CLI (parseCLIArgs, CLIMode(..), CLIParseResult(..))
import Agent.Types (SessionId(..), Port(..), WorkspacePath(..))

cliSpec :: Spec Unit
cliSpec = do

  describe "A40: CLI start session" do

    it "A40: no arguments → StartSession" do
      expectParsed [] \parsed ->
        parsed.mode `shouldEqual` StartSession

  describe "A41: CLI sessions listing" do

    it "A41: 'sessions' → ListSessions" do
      expectParsed ["sessions"] \parsed ->
        parsed.mode `shouldEqual` ListSessions

  describe "A42: CLI resume" do

    it "A42: 'resume 3' → ResumeSession (SessionId 3)" do
      expectParsed ["resume", "3"] \parsed ->
        case parsed.mode of
          ResumeSession sid -> sid `shouldEqual` SessionId 3
          _ -> fail "Expected ResumeSession with ID 3"

    it "A42: 'resume' without session ID → CLIError" do
      expectOutput ["resume"] \output -> do
        output.exitCode `shouldEqual` 1
        String.contains (String.Pattern "resume SESSION_ID") output.message
          `shouldEqual` true

    it "A42: 'resume abc' (non-numeric) → CLIError" do
      expectOutput ["resume", "abc"] \output -> do
        output.exitCode `shouldEqual` 1
        String.contains (String.Pattern "Can't parse as Int") output.message
          `shouldEqual` true
        String.contains (String.Pattern "resume SESSION_ID") output.message
          `shouldEqual` true

  describe "A43: CLI MCP mode" do

    it "A43: 'mcp 8080' → McpServer (Port 8080)" do
      expectParsed ["mcp", "8080"] \parsed ->
        case parsed.mode of
          McpServer port -> port `shouldEqual` Port 8080
          _ -> fail "Expected McpServer with port 8080"

    it "A43: 'mcp' without port → CLIError" do
      expectOutput ["mcp"] \output -> do
        output.exitCode `shouldEqual` 1
        String.contains (String.Pattern "mcp PORT") output.message
          `shouldEqual` true

  describe "CLI: unknown command" do

    it "unknown command → CLIError with usage info including prompt flag" do
      expectOutput ["unknown"] \output -> do
        output.exitCode `shouldEqual` 1
        String.contains (String.Pattern "--prompt PROMPT") output.message
          `shouldEqual` true

    it "A44a: prompt-like positional argument gets a targeted hint" do
      expectOutput ["Add a new tool for the agent to restart the Julia REPL."] \output ->
        String.contains (String.Pattern "use -p/--prompt") output.message
          `shouldEqual` true

  describe "A44: CLI workspace directory override" do

    it "A44: absolute path → workspace set, StartSession mode" do
      expectParsed ["/path/to/project"] \parsed -> do
        parsed.workspace `shouldEqual` Just (WorkspacePath "/path/to/project")
        parsed.mode `shouldEqual` StartSession

    it "A44: absolute path + 'sessions' → workspace set, ListSessions mode" do
      expectParsed ["/path/to/project", "sessions"] \parsed -> do
        parsed.workspace `shouldEqual` Just (WorkspacePath "/path/to/project")
        parsed.mode `shouldEqual` ListSessions

    it "A44: absolute path + 'resume 5' → workspace set, ResumeSession mode" do
      expectParsed ["/path/to/project", "resume", "5"] \parsed -> do
        parsed.workspace `shouldEqual` Just (WorkspacePath "/path/to/project")
        case parsed.mode of
          ResumeSession sid -> sid `shouldEqual` SessionId 5
          _ -> fail "Expected ResumeSession"

    it "A44: relative path with slash recognised as path" do
      expectParsed ["relative/path"] \parsed -> do
        parsed.workspace `shouldEqual` Just (WorkspacePath "relative/path")
        parsed.mode `shouldEqual` StartSession

    it "A44: './' prefix recognised as path" do
      expectParsed ["./myproject"] \parsed -> do
        parsed.workspace `shouldEqual` Just (WorkspacePath "./myproject")
        parsed.mode `shouldEqual` StartSession

    it "A44: '../' prefix recognised as path" do
      expectParsed ["../sibling"] \parsed -> do
        parsed.workspace `shouldEqual` Just (WorkspacePath "../sibling")
        parsed.mode `shouldEqual` StartSession

    it "A44: '.' alone recognised as path" do
      expectParsed ["."] \parsed -> do
        parsed.workspace `shouldEqual` Just (WorkspacePath ".")
        parsed.mode `shouldEqual` StartSession

    it "A44: no path → workspace is Nothing" do
      expectParsed [] \parsed ->
        shouldEqual true (isNothing parsed.workspace)

    it "A44: non-path first arg → not treated as workspace" do
      expectParsed ["sessions"] \parsed -> do
        shouldEqual true (isNothing parsed.workspace)
        parsed.mode `shouldEqual` ListSessions

  describe "A44a: CLI single-turn prompt flag" do

    it "A44a: '-p prompt' alone → StartSession with prompt" do
      expectParsed ["-p", "hello world"] \parsed -> do
        parsed.mode `shouldEqual` StartSession
        parsed.prompt `shouldEqual` Just "hello world"

    it "A44a: '--prompt prompt' alone → StartSession with prompt" do
      expectParsed ["--prompt", "hello world"] \parsed -> do
        parsed.mode `shouldEqual` StartSession
        parsed.prompt `shouldEqual` Just "hello world"

    it "A44a: '-p prompt' + 'resume 7' → ResumeSession with prompt" do
      expectParsed ["resume", "7", "-p", "do the thing"] \parsed -> do
        case parsed.mode of
          ResumeSession sid -> sid `shouldEqual` SessionId 7
          _ -> fail "Expected ResumeSession"
        parsed.prompt `shouldEqual` Just "do the thing"

    it "A44a: '-p' before subcommand is parsed correctly" do
      expectParsed ["-p", "hi", "resume", "2"] \parsed -> do
        case parsed.mode of
          ResumeSession sid -> sid `shouldEqual` SessionId 2
          _ -> fail "Expected ResumeSession"
        parsed.prompt `shouldEqual` Just "hi"

    it "A44a: no prompt flag → prompt is Nothing" do
      expectParsed [] \parsed ->
        shouldEqual true (isNothing parsed.prompt)

    it "A44a: '-p' without argument → CLIError" do
      expectOutput ["-p"] \output -> do
        output.exitCode `shouldEqual` 1
        String.contains (String.Pattern "--prompt PROMPT") output.message
          `shouldEqual` true

    it "A44a: '-p prompt' with workspace path → workspace and prompt set" do
      expectParsed ["/my/project", "-p", "go"] \parsed -> do
        parsed.workspace `shouldEqual` Just (WorkspacePath "/my/project")
        parsed.mode `shouldEqual` StartSession
        parsed.prompt `shouldEqual` Just "go"

    it "A44a: '--help' shows the prompt flag in generated help" do
      expectOutput ["--help"] \output -> do
        output.exitCode `shouldEqual` 0
        String.contains (String.Pattern "--prompt PROMPT") output.message
          `shouldEqual` true

  where
  expectParsed args assertParsed =
    case parseCLIArgs args of
      CLIParsed parsed -> assertParsed parsed
      CLIOutput output ->
        fail ("Expected successful parse, got CLI output: " <> output.message)

  expectOutput args assertOutput =
    case parseCLIArgs args of
      CLIParsed parsed ->
        fail ("Expected CLI output, got parsed result: " <> show parsed.mode)
      CLIOutput output ->
        assertOutput output
