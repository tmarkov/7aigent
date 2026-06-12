-- | Tests for configuration: A2a (file placement), A37 (parsing),
-- | A38 (API key from env), A39 (missing fields).
module Test.ConfigSpec where

import Prelude

import Data.Array (length, any)
import Data.Either (Either(..), isLeft)
import Data.String as String
import Effect (Effect)
import Effect.Class (liftEffect)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy, fail)

import Test.Helpers.Workspace (withWorkspace, withPopulatedWorkspace, readWorkspaceFile, workspaceFileExists, writeWorkspaceFile)
import Agent.Programs.Config (parseConfig, readApiKey, placeDefaultConfigs)
import Agent.Types (ApiEndpoint(..), EnvVarName(..), WorkspacePath(..), AppError(..), ModelName(..))

foreign import setEnv :: String -> String -> Effect Unit
foreign import unsetEnv :: String -> Effect Unit

configSpec :: Spec Unit
configSpec = do

  ---------------------------------------------------------------------------
  -- A2a: config file placement
  ---------------------------------------------------------------------------

  describe "A2a: config file placement" do

    it "A2a: places all 9 default files and the state dir into an empty workspace" do
      withWorkspace \ws -> do
        notices <- placeDefaultConfigs ws
        -- All seven workspace config files should now exist
        configExists    <- workspaceFileExists ws ".7aigent/config.toml"
        sysPromptExists <- workspaceFileExists ws ".7aigent/system_prompt.md"
        compPromptExists <- workspaceFileExists ws ".7aigent/compaction_prompt.md"
        summaryExists   <- workspaceFileExists ws ".7aigent/summary_message.md"
        startupExists   <- workspaceFileExists ws ".7aigent/startup.jl"
        steeringExists  <- workspaceFileExists ws ".7aigent/steering_message.md"
        reflectionExists <- workspaceFileExists ws ".7aigent/reflection_prompt.md"
        timeoutPromptExists <- workspaceFileExists ws ".7aigent/timeout_prompt.md"
        stdinPromptExists <- workspaceFileExists ws ".7aigent/stdin_prompt.md"
        stateExists     <- workspaceFileExists ws ".7aigent/state/"
        configExists `shouldEqual` true
        sysPromptExists `shouldEqual` true
        compPromptExists `shouldEqual` true
        summaryExists `shouldEqual` true
        startupExists `shouldEqual` true
        steeringExists `shouldEqual` true
        reflectionExists `shouldEqual` true
        timeoutPromptExists `shouldEqual` true
        stdinPromptExists `shouldEqual` true
        stateExists `shouldEqual` true
        -- Should have 10 notices (nine files plus the state dir)
        (length notices) `shouldEqual` 10
        configContent <- readWorkspaceFile ws ".7aigent/config.toml"
        systemPrompt <- readWorkspaceFile ws ".7aigent/system_prompt.md"
        startupContent <- readWorkspaceFile ws ".7aigent/startup.jl"
        String.contains (String.Pattern "YOUR_API_ENDPOINT_HERE") configContent
          `shouldEqual` true
        String.contains (String.Pattern "You are 7aigent") systemPrompt
          `shouldEqual` true

    it "A2a: preserves existing files and only places missing ones" do
      withWorkspace \ws -> do
        -- Pre-create config.toml with custom content
        writeWorkspaceFile ws ".7aigent/config.toml" "custom = true"
        notices <- placeDefaultConfigs ws
        -- config.toml should keep custom content
        content <- readWorkspaceFile ws ".7aigent/config.toml"
        content `shouldEqual` "custom = true"
        -- Only 9 items were placed (config.toml was skipped, state was created)
        (length notices) `shouldEqual` 9

    it "A2a: each notice names the placed file" do
      withWorkspace \ws -> do
        notices <- placeDefaultConfigs ws
        -- Each notice should mention the file path
        let hasConfigNotice = any (String.contains (String.Pattern "config.toml")) notices
        let hasStateNotice = any (String.contains (String.Pattern ".7aigent/state")) notices
        hasConfigNotice `shouldEqual` true
        hasStateNotice `shouldEqual` true

  ---------------------------------------------------------------------------
  -- A37: config parsing
  ---------------------------------------------------------------------------

  describe "A37: config parsing" do

    it "A37: parses valid config with all required fields" do
      let toml = String.joinWith "\n"
            [ "api_endpoint           = \"https://api.example.com/v1\""
            , "model                  = \"test-model\""
            , "api_key_env            = \"TEST_API_KEY\""
            , "output_threshold_chars = 20000"
            , "max_api_retries        = 3"
            , "max_tokens_per_turn    = 200000"
            , "compaction_threshold   = 150000"
            , "preserve_initial       = 20000"
            , "preserve_final         = 40000"
            , "max_turns_per_round    = 5"
            ]
      case parseConfig toml of
        Right config -> do
          config.apiEndpoint `shouldEqual` ApiEndpoint "https://api.example.com/v1"
          config.model `shouldEqual` ModelName "test-model"
          config.outputThresholdChars `shouldEqual` 20000
          config.maxApiRetries `shouldEqual` 3
          config.timeoutCheckSeconds `shouldEqual` [30, 60, 120, 240, 480]
          config.progressIntervalSeconds `shouldEqual` 15
        Left err ->
          fail ("Expected successful parse, got error: " <> show err)

    it "A37: parses custom timeout_check_seconds and progress_interval_seconds" do
      let toml = String.joinWith "\n"
            [ "api_endpoint             = \"https://api.example.com/v1\""
            , "model                    = \"test-model\""
            , "api_key_env              = \"TEST_API_KEY\""
            , "output_threshold_chars   = 20000"
            , "max_api_retries          = 3"
            , "max_tokens_per_turn      = 200000"
            , "compaction_threshold     = 150000"
            , "preserve_initial         = 20000"
            , "preserve_final           = 40000"
            , "max_turns_per_round      = 5"
            , "timeout_check_seconds    = [2, 4, 8]"
            , "progress_interval_seconds = 3"
            ]
      case parseConfig toml of
        Right config -> do
          config.timeoutCheckSeconds `shouldEqual` [2, 4, 8]
          config.progressIntervalSeconds `shouldEqual` 3
        Left err ->
          fail ("Expected successful parse, got error: " <> show err)

    it "A37: parses numeric fields as correct types" do
      let toml = String.joinWith "\n"
            [ "api_endpoint           = \"https://api.example.com/v1\""
            , "model                  = \"test-model\""
            , "api_key_env            = \"TEST_API_KEY\""
            , "output_threshold_chars = 15000"
            , "max_api_retries        = 5"
            , "max_tokens_per_turn    = 100000"
            , "compaction_threshold   = 80000"
            , "preserve_initial       = 10000"
            , "preserve_final         = 30000"
            , "max_turns_per_round    = 3"
            ]
      case parseConfig toml of
        Right config -> do
          config.maxApiRetries `shouldEqual` 5
          config.outputThresholdChars `shouldEqual` 15000
        Left err ->
          fail ("Expected successful parse, got error: " <> show err)

    it "A37: parses max_turns_per_round into maxTurnsPerRound" do
      let toml = String.joinWith "\n"
            [ "api_endpoint           = \"https://api.example.com/v1\""
            , "model                  = \"test-model\""
            , "api_key_env            = \"TEST_API_KEY\""
            , "output_threshold_chars = 20000"
            , "max_api_retries        = 3"
            , "max_tokens_per_turn    = 200000"
            , "compaction_threshold   = 150000"
            , "preserve_initial       = 20000"
            , "preserve_final         = 40000"
            , "max_turns_per_round    = 7"
            ]
      case parseConfig toml of
        Right config -> config.maxTurnsPerRound `shouldEqual` 7
        Left err -> fail ("Expected successful parse, got error: " <> show err)

  ---------------------------------------------------------------------------
  -- A38: API key from environment
  ---------------------------------------------------------------------------

  describe "A38: API key from environment variable" do

    it "A38: reads key from a set, non-empty env var" do
      liftEffect $ setEnv "TEST_7AIGENT_KEY_SET" "sk-test-key-12345"
      result <- readApiKey (EnvVarName "TEST_7AIGENT_KEY_SET")
      liftEffect $ unsetEnv "TEST_7AIGENT_KEY_SET"
      case result of
        Right key -> key `shouldEqual` "sk-test-key-12345"
        Left err -> fail ("Expected successful read, got: " <> show err)

    it "A38: fails with informative error when env var is unset" do
      liftEffect $ unsetEnv "TEST_7AIGENT_KEY_UNSET_SURELY"
      result <- readApiKey (EnvVarName "TEST_7AIGENT_KEY_UNSET_SURELY")
      result `shouldSatisfy` isLeft

    it "A38: fails when env var is set to empty string" do
      liftEffect $ setEnv "TEST_7AIGENT_KEY_EMPTY" ""
      result <- readApiKey (EnvVarName "TEST_7AIGENT_KEY_EMPTY")
      liftEffect $ unsetEnv "TEST_7AIGENT_KEY_EMPTY"
      result `shouldSatisfy` isLeft

  ---------------------------------------------------------------------------
  -- A39: missing config fields
  ---------------------------------------------------------------------------

  describe "A39: missing config fields" do

    it "A39: error when api_endpoint is missing" do
      let toml = String.joinWith "\n"
            [ "model                  = \"test-model\""
            , "api_key_env            = \"KEY\""
            , "output_threshold_chars = 20000"
            , "max_api_retries        = 3"
            , "max_tokens_per_turn    = 200000"
            , "compaction_threshold   = 150000"
            , "preserve_initial       = 20000"
            , "preserve_final         = 40000"
            , "max_turns_per_round    = 5"
            ]
      parseConfig toml `shouldSatisfy` isLeft

    it "A39: error when model is missing" do
      let toml = String.joinWith "\n"
            [ "api_endpoint           = \"https://api.example.com/v1\""
            , "api_key_env            = \"KEY\""
            , "output_threshold_chars = 20000"
            , "max_api_retries        = 3"
            , "max_tokens_per_turn    = 200000"
            , "compaction_threshold   = 150000"
            , "preserve_initial       = 20000"
            , "preserve_final         = 40000"
            , "max_turns_per_round    = 5"
            ]
      parseConfig toml `shouldSatisfy` isLeft

    it "A39: error names the missing field" do
      let toml = "model = \"test\""
      case parseConfig toml of
        Left (ConfigError field) ->
          String.contains (String.Pattern "api_endpoint") field
            `shouldEqual` true
        Left _ ->
          fail "Expected ConfigError"
        Right _ ->
          fail "Expected parse to fail for incomplete config"

    it "A39: error when config is completely empty" do
      parseConfig "" `shouldSatisfy` isLeft

    it "A39: error when max_turns_per_round is missing" do
      let toml = String.joinWith "\n"
            [ "api_endpoint           = \"https://api.example.com/v1\""
            , "model                  = \"test-model\""
            , "api_key_env            = \"TEST_API_KEY\""
            , "output_threshold_chars = 20000"
            , "max_api_retries        = 3"
            , "max_tokens_per_turn    = 200000"
            , "compaction_threshold   = 150000"
            , "preserve_initial       = 20000"
            , "preserve_final         = 40000"
            ]
      parseConfig toml `shouldSatisfy` isLeft

  ---------------------------------------------------------------------------
  -- A2a: placeholder value rejection
  ---------------------------------------------------------------------------

  describe "A2a: placeholder value rejection" do

    it "A2a: placeholder api_endpoint → error" do
      let toml = String.joinWith "\n"
            [ "api_endpoint           = \"YOUR_API_ENDPOINT_HERE\""
            , "model                  = \"test-model\""
            , "api_key_env            = \"TEST_API_KEY\""
            , "output_threshold_chars = 20000"
            , "max_api_retries        = 3"
            , "max_tokens_per_turn    = 200000"
            , "compaction_threshold   = 150000"
            , "preserve_initial       = 20000"
            , "preserve_final         = 40000"
            , "max_turns_per_round    = 5"
            ]
      parseConfig toml `shouldSatisfy` isLeft

    it "A2a: placeholder model → error" do
      let toml = String.joinWith "\n"
            [ "api_endpoint           = \"https://api.example.com/v1\""
            , "model                  = \"YOUR_MODEL_HERE\""
            , "api_key_env            = \"TEST_API_KEY\""
            , "output_threshold_chars = 20000"
            , "max_api_retries        = 3"
            , "max_tokens_per_turn    = 200000"
            , "compaction_threshold   = 150000"
            , "preserve_initial       = 20000"
            , "preserve_final         = 40000"
            , "max_turns_per_round    = 5"
            ]
      parseConfig toml `shouldSatisfy` isLeft

    it "A2a: error message mentions placeholder value" do
      let toml = String.joinWith "\n"
            [ "api_endpoint           = \"YOUR_API_ENDPOINT_HERE\""
            , "model                  = \"test-model\""
            , "api_key_env            = \"TEST_API_KEY\""
            , "output_threshold_chars = 20000"
            , "max_api_retries        = 3"
            , "max_tokens_per_turn    = 200000"
            , "compaction_threshold   = 150000"
            , "preserve_initial       = 20000"
            , "preserve_final         = 40000"
            , "max_turns_per_round    = 5"
            ]
      case parseConfig toml of
        Left err ->
          String.contains (String.Pattern "placeholder") (String.toLower (show err))
            `shouldEqual` true
        Right _ ->
          fail "Expected error for placeholder value"
