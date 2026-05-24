-- | Controller integration tests: exercise the actual runner wiring through
-- | mock services to prove the controller follows through on decisions.
-- |
-- | These tests address AP6 (testing the decision but not the outcome) for:
-- | A1 (ReACT loop orchestration), A2 (startup sequence ordering),
-- | A3 (tool dispatch), A8 (terminal display), A19 (startup execution),
-- | A20 (startup error → exit), A20a (sandbox crash → exit),
-- | A28 (serialization execution), A31 (resume def replay),
-- | A48 (round lifecycle via controller).
module Test.ControllerSpec (controllerSpec) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String as String
import Effect.Aff (Aff, attempt)
import Effect.Class (liftEffect)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy, fail)

import Agent.Types (WorkspacePath(..), SessionId(..), TokenCount(..), LlmResponse(..), ToolName(..), ToolCallId(..))
import Agent.Runner.Session (runNewSession, runResumeSession)
import Agent.Runner.Services (RunnerServices)
import Agent.Services.Jupyter as Jupyter
import Agent.Services.Llm as Llm
import Test.Helpers.MockServices (MockState, CallRecord(..), mkMockServices, getCalls, callsMatching)
import Test.Helpers.Workspace (withWorkspace, writeWorkspaceFile, writeSessionLog)
import Test.Helpers.ControllerFixtures (setTestEnv, unsetTestEnv, testConfigToml, minimalSystemPrompt, mockKernelHandle, mockSandboxHandle)

-- | Helper: call index of first occurrence matching a predicate
indexOf :: (CallRecord -> Boolean) -> Array CallRecord -> Maybe Int
indexOf pred arr = Array.findIndex pred arr

-- | Helper: check that call A appears before call B in the log
appearsBeforeIn :: (CallRecord -> Boolean) -> (CallRecord -> Boolean) -> Array CallRecord -> Boolean
appearsBeforeIn predA predB arr =
    case indexOf predA arr, indexOf predB arr of
        Just a, Just b -> a < b
        _, _ -> false

-- | Build a SessionId from an Int
sidFromInt :: Int -> SessionId
sidFromInt = SessionId

-- | An LLM response that is "complete" (no tool calls → PromptUser)
textLlmResult :: String -> Llm.CallLlmResult
textLlmResult content =
    { response: LlmResponse { content, toolCalls: [], inputTokens: TokenCount 100 }
    , usage: { inputTokens: TokenCount 100, cachedInputTokens: TokenCount 0, outputTokens: TokenCount 20 }
    }

-- | An LLM response with a julia_repl tool call
juliaToolLlmResult :: String -> Llm.CallLlmResult
juliaToolLlmResult code =
    { response: LlmResponse
        { content: ""
        , toolCalls:
            [ { name: JuliaRepl, input: "{\"code\": " <> show code <> "}", id: ToolCallId "tc-1" } ]
        , inputTokens: TokenCount 100
        }
    , usage: { inputTokens: TokenCount 100, cachedInputTokens: TokenCount 0, outputTokens: TokenCount 30 }
    }

-- | A reflection response marking the round as complete
reflectionComplete :: Llm.CallLlmResult
reflectionComplete =
    { response: LlmResponse { content: "{\"complete\": true}", toolCalls: [], inputTokens: TokenCount 50 }
    , usage: { inputTokens: TokenCount 50, cachedInputTokens: TokenCount 0, outputTokens: TokenCount 10 }
    }

-- | A reflection response requesting continuation
reflectionContinue :: String -> Llm.CallLlmResult
reflectionContinue feedback =
    { response: LlmResponse
        { content: "{\"complete\": false, \"feedback\": " <> show feedback <> "}"
        , toolCalls: []
        , inputTokens: TokenCount 50
        }
    , usage: { inputTokens: TokenCount 50, cachedInputTokens: TokenCount 0, outputTokens: TokenCount 10 }
    }

-- | Set up a workspace with valid config and run a session with mock services.
-- | Catches exit exceptions (the mock exit throws to abort the Aff).
withTestSession
    :: { llmResponses :: Array (Either String Llm.CallLlmResult)
       , execResponses :: Array String
       , readLineResponses :: Array String
       }
    -> (MockState -> Array CallRecord -> Aff Unit)
    -> Aff Unit
withTestSession opts check = withWorkspace \ws -> do
    -- Write required config files
    writeWorkspaceFile ws ".7aigent/config.toml" testConfigToml
    writeWorkspaceFile ws ".7aigent/system_prompt.md" minimalSystemPrompt
    writeWorkspaceFile ws ".7aigent/startup.jl" "# empty startup"

    liftEffect setTestEnv
    { svc, state } <- liftEffect $ mkMockServices
        { llmResponses: opts.llmResponses
        , execResponses: opts.execResponses
        , execDetailedResponses: []
        , readLineResponses: opts.readLineResponses
        , streamingChunks: []
        , spawnResult: Right mockSandboxHandle
        , connectResult: Right mockKernelHandle
        }
    _ <- attempt $ runNewSession svc ws (Just "test prompt")
    calls <- liftEffect $ getCalls state
    check state calls
    liftEffect unsetTestEnv

controllerSpec :: Spec Unit
controllerSpec = do
    describe "A2: startup sequence ordering" do
        it "A2: spawnSandbox is called before connectKernel" do
            withTestSession
                { llmResponses: [ Right (textLlmResult "Hello!"), Right reflectionComplete ]
                , execResponses: ["", "", ""]  -- using CodeTree, startup.jl, julia_state
                , readLineResponses: []
                } \_ calls -> do
                    appearsBeforeIn isSpawnSandbox isConnectKernel calls
                        `shouldEqual` true

        it "A2: connectKernel is called before startup expression execution" do
            withTestSession
                { llmResponses: [ Right (textLlmResult "Hello!"), Right reflectionComplete ]
                , execResponses: ["", "", ""]
                , readLineResponses: []
                } \_ calls -> do
                    appearsBeforeIn isConnectKernel isExecuteCodeDetailed calls
                        `shouldEqual` true

    describe "A19: startup expressions executed in kernel" do
        it "A19: 'using CodeTree' is executed in the kernel during startup" do
            withTestSession
                { llmResponses: [ Right (textLlmResult "Done"), Right reflectionComplete ]
                , execResponses: ["loaded", "", ""]
                , readLineResponses: []
                } \_ calls -> do
                    let execCalls = Array.filter isExecuteCodeDetailed calls
                    -- First executeCodeDetailed should be "using CodeTree"
                    case Array.head execCalls of
                        Just (CallExecuteCodeDetailed code) ->
                            String.contains (String.Pattern "using CodeTree") code
                                `shouldEqual` true
                        _ -> fail "Expected executeCodeDetailed with 'using CodeTree'"

        it "A19: startup.jl is executed after 'using CodeTree'" do
            withTestSession
                { llmResponses: [ Right (textLlmResult "Done"), Right reflectionComplete ]
                , execResponses: ["", "startup done", ""]
                , readLineResponses: []
                } \_ calls -> do
                    let execCalls = Array.filter isExecuteCodeDetailed calls
                    -- Second executeCodeDetailed should be the startup.jl content
                    case Array.index execCalls 1 of
                        Just (CallExecuteCodeDetailed code) ->
                            String.contains (String.Pattern "# empty startup") code
                                `shouldEqual` true
                        _ -> fail "Expected second executeCodeDetailed with startup.jl content"

    describe "A20: startup error leads to exit" do
        it "A20: kernel error during 'using CodeTree' → exit(1) called" do
            withWorkspace \ws -> do
                writeWorkspaceFile ws ".7aigent/config.toml" testConfigToml
                writeWorkspaceFile ws ".7aigent/system_prompt.md" minimalSystemPrompt
                writeWorkspaceFile ws ".7aigent/startup.jl" "error_code()"
                liftEffect setTestEnv
                { svc, state } <- liftEffect $ mkMockServices
                    { llmResponses: []
                    , execResponses: []
                    , execDetailedResponses:
                        [ { output: "ERROR: LoadError: package not found", hadError: true } ]
                    , readLineResponses: []
                    , streamingChunks: []
                    , spawnResult: Right mockSandboxHandle
                    , connectResult: Right mockKernelHandle
                    }
                _ <- attempt $ runNewSession svc ws Nothing
                calls <- liftEffect $ getCalls state
                liftEffect unsetTestEnv
                calls `shouldSatisfy`
                    (Array.any (\c -> c == CallExit 1))

    describe "A20a: sandbox spawn failure leads to exit" do
        it "A20a: spawnSandbox error → printErr + exit(1)" do
            withWorkspace \ws -> do
                writeWorkspaceFile ws ".7aigent/config.toml" testConfigToml
                writeWorkspaceFile ws ".7aigent/system_prompt.md" minimalSystemPrompt
                writeWorkspaceFile ws ".7aigent/startup.jl" ""
                liftEffect setTestEnv
                { svc, state } <- liftEffect $ mkMockServices
                    { llmResponses: []
                    , execResponses: []
                    , execDetailedResponses: []
                    , readLineResponses: []
                    , streamingChunks: []
                    , spawnResult: Left "sandbox failed to start"
                    , connectResult: Right mockKernelHandle
                    }
                _ <- attempt $ runNewSession svc ws Nothing
                calls <- liftEffect $ getCalls state
                liftEffect unsetTestEnv
                calls `shouldSatisfy`
                    (Array.any (\c -> c == CallExit 1))
                calls `shouldSatisfy`
                    (Array.any (\c -> case c of
                        CallPrintErr s -> String.contains (String.Pattern "sandbox") (String.toLower s)
                        _ -> false))

    describe "A1: ReACT loop orchestration" do
        it "A1: LLM tool call → executeCode → LLM called again → text → ends turn" do
            withTestSession
                { llmResponses:
                    [ Right (juliaToolLlmResult "1 + 1")     -- first LLM call: tool call
                    , Right (textLlmResult "The answer is 2") -- second LLM call: text (ends turn)
                    , Right reflectionComplete                 -- reflection
                    ]
                , execResponses: ["", "", "2", ""]  -- startup*2, julia_repl, getJuliaState
                , readLineResponses: []
                } \_ calls -> do
                    -- Verify executeCode called with the tool's code
                    calls `shouldSatisfy`
                        (Array.any (\c -> case c of
                            CallExecuteCode code -> String.contains (String.Pattern "1 + 1") code
                            _ -> false))
                    -- Verify LLM called at least twice (tool call + follow-up)
                    let llmCalls = Array.filter isCallLlm calls
                    Array.length llmCalls `shouldSatisfy` (_ >= 2)

    describe "A3: tool dispatch routes julia_repl to kernel" do
        it "A3: julia_repl tool call → executeCode called with correct code" do
            withTestSession
                { llmResponses:
                    [ Right (juliaToolLlmResult "println(\"hello\")")
                    , Right (textLlmResult "Done")
                    , Right reflectionComplete
                    ]
                , execResponses: ["", "", "hello\n", ""]
                , readLineResponses: []
                } \_ calls -> do
                    calls `shouldSatisfy`
                        (Array.any (\c -> case c of
                            CallExecuteCode code ->
                                String.contains (String.Pattern "println(\"hello\")") code
                            _ -> false))

    describe "A8: tool output displayed to terminal" do
        it "A8: tool execution output appears in printLn calls" do
            withTestSession
                { llmResponses:
                    [ Right (juliaToolLlmResult "42")
                    , Right (textLlmResult "Done")
                    , Right reflectionComplete
                    ]
                , execResponses: ["", "", "42", ""]
                , readLineResponses: []
                } \_ calls -> do
                    -- The tool output "42" should appear in terminal output
                    calls `shouldSatisfy`
                        (Array.any (\c -> case c of
                            CallPrintLn s -> String.contains (String.Pattern "42") s
                            _ -> false))

    describe "A7: LLM streaming callback wired to terminal" do
        it "A7: streaming chunks are delivered to printStr during LLM call" do
            withWorkspace \ws -> do
                writeWorkspaceFile ws ".7aigent/config.toml" testConfigToml
                writeWorkspaceFile ws ".7aigent/system_prompt.md" minimalSystemPrompt
                writeWorkspaceFile ws ".7aigent/startup.jl" "# startup"
                liftEffect setTestEnv
                { svc, state } <- liftEffect $ mkMockServices
                    { llmResponses:
                        [ Right (textLlmResult "Hello world")
                        , Right reflectionComplete
                        ]
                    , execResponses: ["", "", ""]
                    , execDetailedResponses:
                        [ { output: "", hadError: false }
                        , { output: "", hadError: false }
                        ]
                    , readLineResponses: []
                    , streamingChunks: [ ["Hel", "lo ", "world"] ]
                    , spawnResult: Right mockSandboxHandle
                    , connectResult: Right mockKernelHandle
                    }
                _ <- attempt $ runNewSession svc ws (Just "hi")
                calls <- liftEffect $ getCalls state
                liftEffect unsetTestEnv
                -- Each streaming chunk must appear as a CallPrintStr call
                calls `shouldSatisfy`
                    (Array.any (\c -> c == CallPrintStr "Hel"))
                calls `shouldSatisfy`
                    (Array.any (\c -> c == CallPrintStr "lo "))
                calls `shouldSatisfy`
                    (Array.any (\c -> c == CallPrintStr "world"))

    describe "A48: round lifecycle through controller" do
        it "A48: reflection complete=false → LLM called again with feedback (multi-turn)" do
            withTestSession
                { llmResponses:
                    [ Right (textLlmResult "Working on it...")  -- turn 1
                    , Right (reflectionContinue "Try harder")   -- reflection says continue
                    , Right (textLlmResult "Done!")             -- turn 2
                    , Right reflectionComplete                  -- reflection says complete
                    ]
                , execResponses: ["", "", "", ""]  -- startup*2 + getJuliaState*2
                , readLineResponses: []
                } \_ calls -> do
                    -- LLM should be called for streaming at least twice (two turns)
                    let llmCalls = Array.filter isCallLlm calls
                    Array.length llmCalls `shouldSatisfy` (_ >= 2)
                    -- Reflection JSON calls should also fire
                    let jsonCalls = Array.filter isCallLlmJson calls
                    Array.length jsonCalls `shouldSatisfy` (_ >= 2)

    describe "A28: serialization snippet executed on session end" do
        it "A28: finishSession triggers executeCode with serialization code" do
            withTestSession
                { llmResponses:
                    [ Right (textLlmResult "All done!")
                    , Right reflectionComplete
                    ]
                , execResponses: ["", "", "", ""]  -- startup*2, getJuliaState, serialize
                , readLineResponses: []
                } \_ calls -> do
                    -- Serialization uses Serialization.serialize
                    calls `shouldSatisfy`
                        (Array.any (\c -> case c of
                            CallExecuteCode code ->
                                String.contains (String.Pattern "Serialization") code
                                || String.contains (String.Pattern "serialize") code
                            _ -> false))

    describe "A31: session resume replays definitions in kernel" do
        it "A31: resuming a session executes saved julia_defs in the kernel" do
            withWorkspace \ws -> do
                -- Set up a prior session (session 1) with a log and julia_defs.jl
                writeWorkspaceFile ws ".7aigent/config.toml" testConfigToml
                writeWorkspaceFile ws ".7aigent/system_prompt.md" minimalSystemPrompt
                writeWorkspaceFile ws ".7aigent/startup.jl" "# startup"
                -- Write a session_start log event so loadSessionForResume can parse it
                let sessionLog = String.joinWith "\n"
                        [ "{\"type\":\"session_start\",\"id\":1,\"timestamp\":\"2025-01-01T00:00:00Z\",\"workspace\":\"/tmp\",\"model\":\"test-model\",\"resumed_from\":null}"
                        , "{\"type\":\"system_prompt\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"content\":\"You are a test agent.\"}"
                        , "{\"type\":\"user_message\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"content\":\"hello\"}"
                        , "{\"type\":\"llm_response\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"content\":\"hi there\"}"
                        , "{\"type\":\"session_end\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"reason\":\"eof\"}"
                        ]
                writeSessionLog ws (sidFromInt 1) sessionLog
                writeWorkspaceFile ws ".7aigent/sessions/1/julia_defs.jl"
                    "function foo(x)\n    x + 1\nend"

                liftEffect setTestEnv
                { svc, state } <- liftEffect $ mkMockServices
                    { llmResponses: [ Right (textLlmResult "Resumed!"), Right reflectionComplete ]
                    , execResponses:
                        [ ""  -- foo def replay
                        , ""  -- using CodeTree
                        , ""  -- startup.jl
                        , ""  -- getJuliaState
                        , ""  -- serialize
                        ]
                    , execDetailedResponses:
                        [ { output: "", hadError: false }   -- using CodeTree
                        , { output: "", hadError: false }   -- startup.jl
                        ]
                    , readLineResponses: []
                    , streamingChunks: []
                    , spawnResult: Right mockSandboxHandle
                    , connectResult: Right mockKernelHandle
                    }
                _ <- attempt $ runResumeSession svc ws (sidFromInt 1) (Just "continue")
                calls <- liftEffect $ getCalls state
                liftEffect unsetTestEnv
                -- The def "function foo(x)" should be replayed via executeCode
                calls `shouldSatisfy`
                    (Array.any (\c -> case c of
                        CallExecuteCode code ->
                            String.contains (String.Pattern "foo") code
                        _ -> false))

-- ---------------------------------------------------------------------------
-- Predicates for filtering call records
-- ---------------------------------------------------------------------------

isSpawnSandbox :: CallRecord -> Boolean
isSpawnSandbox CallSpawnSandbox = true
isSpawnSandbox _ = false

isConnectKernel :: CallRecord -> Boolean
isConnectKernel (CallConnectKernel _) = true
isConnectKernel _ = false

isExecuteCode :: CallRecord -> Boolean
isExecuteCode (CallExecuteCode _) = true
isExecuteCode _ = false

isExecuteCodeDetailed :: CallRecord -> Boolean
isExecuteCodeDetailed (CallExecuteCodeDetailed _) = true
isExecuteCodeDetailed _ = false

isCallLlm :: CallRecord -> Boolean
isCallLlm (CallLlm _) = true
isCallLlm _ = false

isCallLlmJson :: CallRecord -> Boolean
isCallLlmJson (CallLlmJson _) = true
isCallLlmJson _ = false
