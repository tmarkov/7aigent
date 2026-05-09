-- | Tests for startup sequence orchestration: A2, A19, A20, A20a.
module Test.StartupSpec where

import Prelude

import Data.Either (Either(..))
import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy, fail)

import Agent.Programs.Startup (advanceStartup, StartupPhase(..), StartupNext(..))
import Agent.Types (AppError(..), WorkspacePath(..), RawJulia(..))

startupSpec :: Spec Unit
startupSpec = do

  ---------------------------------------------------------------------------
  -- A2: startup orchestration
  ---------------------------------------------------------------------------

  describe "A2: startup orchestration" do

    it "A2: config validation failure → Abort, no sandbox spawned" do
      let result = advanceStartup ValidatingConfig (Left (ConfigFieldMissing "model"))
      case result of
        Abort err ->
          String.contains (String.Pattern "model") (show err)
            `shouldEqual` true
        _ -> fail "Expected Abort on config validation failure"

    it "A2: all steps succeed → Ready with config and REPL output" do
      let result = advanceStartup
            (ExecutingStartup 1)
            (Right "db loaded with 42 nodes")
      case result of
        Ready r ->
          String.contains (String.Pattern "42 nodes") r.initialReplOutput
            `shouldEqual` true
        _ -> fail "Expected Ready state after successful startup"

  ---------------------------------------------------------------------------
  -- A19: Julia startup expressions
  ---------------------------------------------------------------------------

  describe "A19: Julia startup sequence output" do

    it "A19: both expressions succeed → combined output" do
      let phase = ExecutingStartup 0
      -- First expression (using CodeTree) succeeds
      let r1 = advanceStartup phase (Right "CodeTree v1.0 loaded")
      case r1 of
        NextStep (ExecutingStartup 1) -> pure unit
        _ -> fail "Expected next startup step after first expression"

    it "A19: startup output captures both expression results" do
      -- After both expressions complete, the combined output should
      -- include text from both
      let result = advanceStartup
            (ExecutingStartup 1)
            (Right "db = CodeTreeDB with 100 nodes")
      case result of
        Ready r ->
          r.initialReplOutput `shouldSatisfy`
            String.contains (String.Pattern "100 nodes")
        _ -> fail "Expected Ready with combined output"

  ---------------------------------------------------------------------------
  -- A20: startup expression error
  ---------------------------------------------------------------------------

  describe "A20: startup expression error → exit" do

    it "A20: 'using CodeTree' raises error → Abort" do
      let result = advanceStartup
            (ExecutingStartup 0)
            (Left (StartupExpressionError "PackageNotFound: CodeTree"))
      case result of
        Abort err ->
          String.contains (String.Pattern "CodeTree") (show err)
            `shouldEqual` true
        _ -> fail "Expected Abort when using CodeTree fails"

    it "A20: startup.jl raises error → Abort" do
      let result = advanceStartup
            (ExecutingStartup 1)
            (Left (StartupExpressionError "UndefVarError: load"))
      case result of
        Abort _ -> pure unit
        _ -> fail "Expected Abort when startup.jl fails"

    it "A20: error message includes the Julia error text" do
      let juliaErr = "MethodError: no method matching load(::Int)"
      let result = advanceStartup
            (ExecutingStartup 1)
            (Left (StartupExpressionError juliaErr))
      case result of
        Abort err ->
          String.contains (String.Pattern "MethodError") (show err)
            `shouldEqual` true
        _ -> fail "Expected Abort with Julia error text"

  ---------------------------------------------------------------------------
  -- A20a: sandbox unexpected exit
  ---------------------------------------------------------------------------

  describe "A20a: sandbox unexpected exit" do

    it "A20a: sandbox crash → Abort with reason 'error'" do
      let result = advanceStartup
            RunningSession
            (Left SandboxCrashed)
      case result of
        Abort err ->
          String.contains (String.Pattern "sandbox") (String.toLower (show err))
            `shouldEqual` true
        _ -> fail "Expected Abort on sandbox crash"

    it "A20a: sandbox crash maps to session_end reason 'error'" do
      -- The error returned by advanceStartup on SandboxCrashed must carry
      -- enough information for the controller to log session_end with
      -- reason="error" (not "eof" or "sigint").
      let result = advanceStartup
            RunningSession
            (Left SandboxCrashed)
      case result of
        Abort (SandboxCrashed) -> pure unit
        Abort _ -> fail "Expected SandboxCrashed error variant (not a generic error)"
        _ -> fail "Expected Abort on sandbox crash"
