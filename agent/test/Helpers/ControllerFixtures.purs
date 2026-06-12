-- | Shared fixtures for controller integration tests.
module Test.Helpers.ControllerFixtures
    ( setTestEnv
    , setEmptyTestEnv
    , unsetTestEnv
    , testConfigToml
    , minimalSystemPrompt
    , mockKernelHandle
    , mockSandboxHandle
    ) where

import Prelude

import Effect (Effect)
import Agent.Services.Jupyter as Jupyter
import Agent.Services.Sandbox as Sandbox

-- | A valid config.toml for testing (non-placeholder values).
testConfigToml :: String
testConfigToml = """
api_endpoint = "http://localhost:9999/v1/messages"
model = "test-model"
api_key_env = "TEST_7AIGENT_KEY"
output_threshold_chars = 5000
max_api_retries = 3
max_tokens_per_turn = 50000
compaction_threshold = 40000
preserve_initial = 5000
preserve_final = 10000
max_turns_per_round = 3
"""

-- | A minimal system_prompt.md that uses all required template keywords.
minimalSystemPrompt :: String
minimalSystemPrompt = """
You are a test agent.
Model: {{model}}
Date: {{datetime}}
Startup output: {{initial_repl_output}}
Startup script: {{startup_jl}}
Project guide: {{agents_md}}
"""

-- | A mock KernelHandle whose functions do nothing.
mockKernelHandle :: Jupyter.KernelHandle
mockKernelHandle =
    { execute: \_ _ _ onDone -> onDone { output: "", hadError: false }
    , interrupt: \onDone -> onDone
    , close: pure unit
    }

-- | A mock SandboxHandle.
mockSandboxHandle :: Sandbox.SandboxHandle
mockSandboxHandle =
    { kernelJsonPath: "/tmp/mock-kernel.json"
    , kill: \onDone -> onDone unit
    , interrupt: pure unit
    }

-- | Set the environment variable that readApiKey will look for.
foreign import setTestEnv :: Effect Unit

-- | Unset the test environment variable.
foreign import unsetTestEnv :: Effect Unit

-- | Set the test API key environment variable to the empty string.
foreign import setEmptyTestEnv :: Effect Unit
