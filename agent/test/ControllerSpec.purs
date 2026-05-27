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

import Agent.Types (WorkspacePath(..), ConversationHistory(..), Message(..), SessionId(..), TokenCount(..), LlmResponse(..), ToolName(..), ToolCallId(..))
import Agent.Runner.Session (runNewSession, runResumeSession, runListSessions)
import Agent.Services.Llm as Llm
import Test.Helpers.MockServices
    ( MockState
    , CallRecord(..)
    , mkMockServices
    , getCalls
    , getLlmHistories
    , getLlmInvocations
    )
import Test.Helpers.Workspace
    ( withWorkspace
    , writeWorkspaceFile
    , readWorkspaceFile
    , workspaceFileExists
    , writeSessionLog
    )
import Test.Helpers.ControllerFixtures (setTestEnv, setEmptyTestEnv, unsetTestEnv, testConfigToml, minimalSystemPrompt, mockKernelHandle, mockSandboxHandle)

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

-- | An LLM response with a julia_repl tool call and explicit input-token count.
juliaToolLlmResultHighTokens :: String -> Int -> Llm.CallLlmResult
juliaToolLlmResultHighTokens code tokens =
    { response: LlmResponse
        { content: ""
        , toolCalls:
            [ { name: JuliaRepl, input: "{\"code\": " <> show code <> "}", id: ToolCallId "tc-1" } ]
        , inputTokens: TokenCount tokens
        }
    , usage: { inputTokens: TokenCount tokens, cachedInputTokens: TokenCount 0, outputTokens: TokenCount 30 }
    }

-- | A text-only LLM response with explicit input-token count.
textLlmResultHighTokens :: String -> Int -> Llm.CallLlmResult
textLlmResultHighTokens content tokens =
    { response: LlmResponse { content, toolCalls: [], inputTokens: TokenCount tokens }
    , usage: { inputTokens: TokenCount tokens, cachedInputTokens: TokenCount 0, outputTokens: TokenCount 20 }
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

withTestSessionCustom
    :: { llmResponses :: Array (Either String Llm.CallLlmResult)
       , execResponses :: Array String
       , execDetailedResponses :: Array { output :: String, hadError :: Boolean }
       , readLineResponses :: Array String
       , configToml :: String
       , prompt :: Maybe String
       }
    -> (MockState -> Array CallRecord -> WorkspacePath -> Aff Unit)
    -> Aff Unit
withTestSessionCustom opts check = withWorkspace \ws -> do
    writeWorkspaceFile ws ".7aigent/config.toml" opts.configToml
    writeWorkspaceFile ws ".7aigent/system_prompt.md" minimalSystemPrompt
    writeWorkspaceFile ws ".7aigent/startup.jl" "# empty startup"

    liftEffect setTestEnv
    { svc, state } <- liftEffect $ mkMockServices
        { llmResponses: opts.llmResponses
        , execResponses: opts.execResponses
        , execDetailedResponses: opts.execDetailedResponses
        , readLineResponses: opts.readLineResponses
        , streamingChunks: []
        , spawnResult: Right mockSandboxHandle
        , connectResult: Right mockKernelHandle
        }
    _ <- attempt $ runNewSession svc ws opts.prompt
    calls <- liftEffect $ getCalls state
    check state calls ws
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
        it "A1: LLM tool call → kernel executes code → LLM called again → text → ends turn" do
            withTestSession
                { llmResponses:
                    [ Right (juliaToolLlmResult "1 + 1")     -- first LLM call: tool call
                    , Right (textLlmResult "The answer is 2") -- second LLM call: text (ends turn)
                    , Right reflectionComplete                 -- reflection
                    ]
                , execResponses: ["", "", "2", ""]  -- startup*2, julia_repl, getJuliaState
                , readLineResponses: []
                } \_ calls -> do
                    -- Verify the kernel execution path received the tool's code
                    calls `shouldSatisfy`
                        (Array.any (\c -> case c of
                            CallExecuteCode code -> String.contains (String.Pattern "1 + 1") code
                            CallExecuteCodeDetailed code -> String.contains (String.Pattern "1 + 1") code
                            _ -> false))
                    -- Verify LLM called at least twice (tool call + follow-up)
                    let llmCalls = Array.filter isCallLlm calls
                    Array.length llmCalls `shouldSatisfy` (_ >= 2)

    describe "A3: tool dispatch routes julia_repl to kernel" do
        it "A3: julia_repl tool call → kernel receives the correct code" do
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
                            CallExecuteCodeDetailed code ->
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

    describe "A47: julia_state resolution uses correct expression" do
        it "A47: getJuliaState sends the ans-preserving SevenAigentREPL.status() wrapper" do
            withTestSessionCustom
                { llmResponses:
                    [ Right (juliaToolLlmResult "1 + 1")
                    , Right (textLlmResult "Done")
                    , Right reflectionComplete
                    ]
                , execResponses: ["2", ""]
                , execDetailedResponses:
                    [ { output: "", hadError: false }
                    , { output: "", hadError: false }
                    , { output: "[Tasks: 0]", hadError: false }
                    ]
                , readLineResponses: []
                , configToml: testConfigToml
                , prompt: Just "test prompt"
                } \_ calls _ -> do
                    -- A47 requires the expression to contain both the ans
                    -- preservation wrapper and SevenAigentREPL.status()
                    calls `shouldSatisfy`
                        (Array.any (\c -> case c of
                            CallExecuteCode code ->
                                String.contains (String.Pattern "SevenAigentREPL.status()") code
                                && String.contains (String.Pattern "_ans") code
                                && String.contains (String.Pattern "isdefined(Main, :ans)") code
                            CallExecuteCodeDetailed code ->
                                String.contains (String.Pattern "SevenAigentREPL.status()") code
                                && String.contains (String.Pattern "_ans") code
                                && String.contains (String.Pattern "isdefined(Main, :ans)") code
                            _ -> false))

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

    describe "A9: large tool output is replaced for the LLM but logged in full" do
        it "A9: output above threshold → LLM sees error text and session log keeps full output" do
            let largeOutput = "This output is definitely longer than ten characters and must stay in the log."
            let lowThresholdConfig = String.joinWith "\n"
                    [ "api_endpoint = \"http://localhost:9999/v1/messages\""
                    , "model = \"test-model\""
                    , "api_key_env = \"TEST_7AIGENT_KEY\""
                    , "output_threshold_chars = 10"
                    , "max_api_retries = 3"
                    , "max_tokens_per_turn = 50000"
                    , "compaction_threshold = 40000"
                    , "preserve_initial = 5000"
                    , "preserve_final = 10000"
                    , "max_turns_per_round = 3"
                    ]
            withTestSessionCustom
                { llmResponses:
                    [ Right (juliaToolLlmResult "big_output()")
                    , Right (textLlmResult "Acknowledged")
                    , Right reflectionComplete
                    ]
                , execResponses: [ largeOutput, "", "" ]
                , execDetailedResponses:
                    [ { output: "", hadError: false }
                    , { output: "", hadError: false }
                    ]
                , readLineResponses: []
                , configToml: lowThresholdConfig
                , prompt: Just "test prompt"
                } \state _ ws -> do
                    histories <- liftEffect $ getLlmHistories state
                    case Array.index histories 1 of
                        Nothing -> fail "Expected a follow-up LLM call after tool execution"
                        Just (ConversationHistory h) -> do
                            let llmToolOutputs = Array.mapMaybe (\entry -> case entry.message of
                                    ToolResultMessage r -> Just r.output
                                    _ -> Nothing) h.messages
                            llmToolOutputs `shouldSatisfy`
                                (Array.any (\output ->
                                    String.contains (String.Pattern "Output too large") output
                                    && not (String.contains (String.Pattern largeOutput) output)))

                    logText <- readWorkspaceFile ws ".7aigent/sessions/1/log.jsonl"
                    logText `shouldSatisfy`
                        (\text -> String.contains (String.Pattern largeOutput) text
                            && String.contains (String.Pattern "\"truncated\":true") text)

    describe "A23: unknown template keyword aborts before session start" do
        it "A23: unknown keyword in system_prompt.md → informative exit and no session log" do
            withWorkspace \ws -> do
                writeWorkspaceFile ws ".7aigent/config.toml" testConfigToml
                writeWorkspaceFile ws ".7aigent/system_prompt.md"
                    "Hello {{unknown_nonexistent_keyword}}"
                writeWorkspaceFile ws ".7aigent/startup.jl" ""
                liftEffect setTestEnv
                { svc, state } <- liftEffect $ mkMockServices
                    { llmResponses: []
                    , execResponses: []
                    , execDetailedResponses:
                        [ { output: "", hadError: false }
                        , { output: "", hadError: false }
                        ]
                    , readLineResponses: []
                    , streamingChunks: []
                    , spawnResult: Right mockSandboxHandle
                    , connectResult: Right mockKernelHandle
                    }
                _ <- attempt $ runNewSession svc ws (Just "test")
                calls <- liftEffect $ getCalls state
                liftEffect unsetTestEnv

                calls `shouldSatisfy`
                    (Array.any (\c -> c == CallExit 1))
                calls `shouldSatisfy`
                    (Array.any (\c -> case c of
                        CallPrintErr s ->
                            String.contains (String.Pattern "unknown") (String.toLower s)
                                || String.contains (String.Pattern "keyword") (String.toLower s)
                        _ -> false))

                logExists <- workspaceFileExists ws ".7aigent/sessions/1/log.jsonl"
                logExists `shouldEqual` false

    describe "A29: julia_defs.jl is written from replay-safe julia_repl inputs" do
        it "A29: pure julia definitions are written in execution order" do
            withTestSessionCustom
                { llmResponses:
                    [ Right (juliaToolLlmResult "function alpha(x)\n    x + 1\nend")
                    , Right (juliaToolLlmResult "1 + 1")
                    , Right (juliaToolLlmResult "struct Beta\n    x::Int\nend")
                    , Right (textLlmResult "Done")
                    , Right reflectionComplete
                    ]
                , execResponses: [ "", "2", "", "", "" ]
                , execDetailedResponses:
                    [ { output: "", hadError: false }
                    , { output: "", hadError: false }
                    ]
                , readLineResponses: []
                , configToml: testConfigToml
                , prompt: Just "test prompt"
                } \_ _ ws -> do
                    defsExists <- workspaceFileExists ws ".7aigent/sessions/1/julia_defs.jl"
                    defsExists `shouldEqual` true
                    defsText <- readWorkspaceFile ws ".7aigent/sessions/1/julia_defs.jl"
                    defsText `shouldSatisfy`
                        (\text ->
                            String.contains (String.Pattern "function alpha") text
                                && String.contains (String.Pattern "struct Beta") text
                                && not (String.contains (String.Pattern "1 + 1") text)
                                && case String.indexOf (String.Pattern "function alpha") text
                                    , String.indexOf (String.Pattern "struct Beta") text of
                                    Just alphaIx, Just betaIx -> alphaIx < betaIx
                                    _, _ -> false)

    describe "A13: EOF when idle behaves like SIGINT teardown" do
        it "A13: interactive EOF → serialize, write session_end(eof), exit(0)" do
            withTestSessionCustom
                { llmResponses:
                    [ Right (textLlmResult "Hello!")
                    , Right reflectionComplete
                    ]
                , execResponses: [ "", "" ]
                , execDetailedResponses:
                    [ { output: "", hadError: false }
                    , { output: "", hadError: false }
                    ]
                , readLineResponses: [ "hi", "" ]
                , configToml: testConfigToml
                , prompt: Nothing
                } \_ calls ws -> do
                    calls `shouldSatisfy`
                        (Array.any (\c -> case c of
                            CallExecuteCode code ->
                                String.contains (String.Pattern "serialize") (String.toLower code)
                                    || String.contains (String.Pattern "julia_state") code
                            _ -> false))
                    calls `shouldSatisfy`
                        (Array.any (\c -> c == CallExit 0))

                    logExists <- workspaceFileExists ws ".7aigent/sessions/1/log.jsonl"
                    logExists `shouldEqual` true
                    logText <- readWorkspaceFile ws ".7aigent/sessions/1/log.jsonl"
                    logText `shouldSatisfy`
                        (\text ->
                            String.contains (String.Pattern "\"type\":\"session_end\"") text
                                && String.contains (String.Pattern "\"reason\":\"eof\"") text)

    describe "A20a: sandbox crash during a session" do
        it "A20a: tool execution crash → session_end(error), informative error, exit(1)" do
            withTestSessionCustom
                { llmResponses: [ Right (juliaToolLlmResult "crash()") ]
                , execResponses: [ "__CRASH__kernel connection lost" ]
                , execDetailedResponses:
                    [ { output: "", hadError: false }
                    , { output: "", hadError: false }
                    ]
                , readLineResponses: []
                , configToml: testConfigToml
                , prompt: Just "test prompt"
                } \_ calls ws -> do
                    calls `shouldSatisfy`
                        (Array.any (\c -> c == CallExit 1))
                    calls `shouldSatisfy`
                        (Array.any (\c -> case c of
                            CallPrintErr s ->
                                String.contains (String.Pattern "kernel") (String.toLower s)
                                    || String.contains (String.Pattern "sandbox") (String.toLower s)
                            _ -> false))

                    logExists <- workspaceFileExists ws ".7aigent/sessions/1/log.jsonl"
                    logExists `shouldEqual` true
                    logText <- readWorkspaceFile ws ".7aigent/sessions/1/log.jsonl"
                    logText `shouldSatisfy`
                        (\text ->
                            String.contains (String.Pattern "\"type\":\"session_end\"") text
                                && String.contains (String.Pattern "\"reason\":\"error\"") text)

    describe "A38: api_key_env failures abort startup" do
        it "A38: missing env var → informative exit before session start" do
            withWorkspace \ws -> do
                let badKeyConfig = String.joinWith "\n"
                        [ "api_endpoint = \"http://localhost:9999/v1/messages\""
                        , "model = \"test-model\""
                        , "api_key_env = \"NONEXISTENT_7AIGENT_KEY_XYZ\""
                        , "output_threshold_chars = 5000"
                        , "max_api_retries = 3"
                        , "max_tokens_per_turn = 50000"
                        , "compaction_threshold = 40000"
                        , "preserve_initial = 5000"
                        , "preserve_final = 10000"
                        , "max_turns_per_round = 3"
                        ]
                writeWorkspaceFile ws ".7aigent/config.toml" badKeyConfig
                writeWorkspaceFile ws ".7aigent/system_prompt.md" minimalSystemPrompt
                writeWorkspaceFile ws ".7aigent/startup.jl" ""
                liftEffect unsetTestEnv
                { svc, state } <- liftEffect $ mkMockServices
                    { llmResponses: []
                    , execResponses: []
                    , execDetailedResponses: []
                    , readLineResponses: []
                    , streamingChunks: []
                    , spawnResult: Right mockSandboxHandle
                    , connectResult: Right mockKernelHandle
                    }
                _ <- attempt $ runNewSession svc ws (Just "test")
                calls <- liftEffect $ getCalls state
                calls `shouldSatisfy`
                    (Array.any (\c -> c == CallExit 1))
                calls `shouldSatisfy`
                    (Array.any (\c -> case c of
                        CallPrintErr s ->
                            String.contains (String.Pattern "env") (String.toLower s)
                                || String.contains (String.Pattern "variable") (String.toLower s)
                                || String.contains (String.Pattern "not set") (String.toLower s)
                        _ -> false))
                logExists <- workspaceFileExists ws ".7aigent/sessions/1/log.jsonl"
                logExists `shouldEqual` false

        it "A38: empty env var → informative exit before session start" do
            withWorkspace \ws -> do
                let emptyKeyConfig = String.joinWith "\n"
                        [ "api_endpoint = \"http://localhost:9999/v1/messages\""
                        , "model = \"test-model\""
                        , "api_key_env = \"TEST_7AIGENT_KEY\""
                        , "output_threshold_chars = 5000"
                        , "max_api_retries = 3"
                        , "max_tokens_per_turn = 50000"
                        , "compaction_threshold = 40000"
                        , "preserve_initial = 5000"
                        , "preserve_final = 10000"
                        , "max_turns_per_round = 3"
                        ]
                writeWorkspaceFile ws ".7aigent/config.toml" emptyKeyConfig
                writeWorkspaceFile ws ".7aigent/system_prompt.md" minimalSystemPrompt
                writeWorkspaceFile ws ".7aigent/startup.jl" ""
                liftEffect setEmptyTestEnv
                { svc, state } <- liftEffect $ mkMockServices
                    { llmResponses: []
                    , execResponses: []
                    , execDetailedResponses: []
                    , readLineResponses: []
                    , streamingChunks: []
                    , spawnResult: Right mockSandboxHandle
                    , connectResult: Right mockKernelHandle
                    }
                _ <- attempt $ runNewSession svc ws (Just "test")
                calls <- liftEffect $ getCalls state
                liftEffect unsetTestEnv
                calls `shouldSatisfy`
                    (Array.any (\c -> c == CallExit 1))
                calls `shouldSatisfy`
                    (Array.any (\c -> case c of
                        CallPrintErr s ->
                            String.contains (String.Pattern "empty") (String.toLower s)
                                || String.contains (String.Pattern "api key") (String.toLower s)
                        _ -> false))
                calls `shouldSatisfy` (not <<< Array.any isSpawnSandbox)
                logExists <- workspaceFileExists ws ".7aigent/sessions/1/log.jsonl"
                logExists `shouldEqual` false
                liftEffect unsetTestEnv

    describe "A39: config errors abort before session start" do
        it "A39: missing config.toml → informative exit and no session log" do
            withWorkspace \ws -> do
                writeWorkspaceFile ws ".7aigent/system_prompt.md" minimalSystemPrompt
                writeWorkspaceFile ws ".7aigent/startup.jl" ""
                liftEffect setTestEnv
                { svc, state } <- liftEffect $ mkMockServices
                    { llmResponses: []
                    , execResponses: []
                    , execDetailedResponses: []
                    , readLineResponses: []
                    , streamingChunks: []
                    , spawnResult: Right mockSandboxHandle
                    , connectResult: Right mockKernelHandle
                    }
                _ <- attempt $ runNewSession svc ws (Just "test")
                calls <- liftEffect $ getCalls state
                liftEffect unsetTestEnv
                calls `shouldSatisfy`
                    (Array.any (\c -> c == CallExit 1))
                calls `shouldSatisfy`
                    (Array.any (\c -> case c of
                        CallPrintErr s -> String.contains (String.Pattern "config.toml") s
                        _ -> false))
                logExists <- workspaceFileExists ws ".7aigent/sessions/1/log.jsonl"
                logExists `shouldEqual` false

        it "A39: required field missing → informative exit and no session log" do
            withWorkspace \ws -> do
                let missingFieldConfig = String.joinWith "\n"
                        [ "api_endpoint = \"http://localhost:9999/v1/messages\""
                        , "model = \"test-model\""
                        , "output_threshold_chars = 5000"
                        , "max_api_retries = 3"
                        , "max_tokens_per_turn = 50000"
                        , "compaction_threshold = 40000"
                        , "preserve_initial = 5000"
                        , "preserve_final = 10000"
                        , "max_turns_per_round = 3"
                        ]
                writeWorkspaceFile ws ".7aigent/config.toml" missingFieldConfig
                writeWorkspaceFile ws ".7aigent/system_prompt.md" minimalSystemPrompt
                writeWorkspaceFile ws ".7aigent/startup.jl" ""
                liftEffect setTestEnv
                { svc, state } <- liftEffect $ mkMockServices
                    { llmResponses: []
                    , execResponses: []
                    , execDetailedResponses: []
                    , readLineResponses: []
                    , streamingChunks: []
                    , spawnResult: Right mockSandboxHandle
                    , connectResult: Right mockKernelHandle
                    }
                _ <- attempt $ runNewSession svc ws (Just "test")
                calls <- liftEffect $ getCalls state
                liftEffect unsetTestEnv
                calls `shouldSatisfy`
                    (Array.any (\c -> c == CallExit 1))
                calls `shouldSatisfy`
                    (Array.any (\c -> case c of
                        CallPrintErr s ->
                            String.contains (String.Pattern "config") (String.toLower s)
                                && String.contains (String.Pattern "api") (String.toLower s)
                        _ -> false))
                calls `shouldSatisfy` (not <<< Array.any isSpawnSandbox)
                logExists <- workspaceFileExists ws ".7aigent/sessions/1/log.jsonl"
                logExists `shouldEqual` false

    describe "A41: sessions listing shows duration and open-session marker" do
        it "A41: ended sessions show computed duration and open sessions show —" do
            withWorkspace \ws -> do
                writeWorkspaceFile ws ".7aigent/config.toml" testConfigToml
                let session1 = String.joinWith "\n"
                        [ "{\"type\":\"session_start\",\"id\":1,\"timestamp\":\"2025-01-01T00:00:00Z\",\"workspace\":\"/tmp\",\"model\":\"test-model\",\"resumed_from\":null}"
                        , "{\"type\":\"user_message\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"content\":\"Add R14b absorption rule to CodeTree.jl\"}"
                        , "{\"type\":\"session_end\",\"timestamp\":\"2025-01-01T00:01:05Z\",\"reason\":\"eof\"}"
                        ]
                let session2 = String.joinWith "\n"
                        [ "{\"type\":\"session_start\",\"id\":2,\"timestamp\":\"2025-01-01T02:00:00Z\",\"workspace\":\"/tmp\",\"model\":\"test-model\",\"resumed_from\":null}"
                        , "{\"type\":\"user_message\",\"timestamp\":\"2025-01-01T02:00:00Z\",\"content\":\"Resume me later\"}"
                        ]
                writeSessionLog ws (sidFromInt 1) session1
                writeSessionLog ws (sidFromInt 2) session2

                liftEffect setTestEnv
                { svc, state } <- liftEffect $ mkMockServices
                    { llmResponses: []
                    , execResponses: []
                    , execDetailedResponses: []
                    , readLineResponses: []
                    , streamingChunks: []
                    , spawnResult: Right mockSandboxHandle
                    , connectResult: Right mockKernelHandle
                    }
                _ <- attempt $ runListSessions svc ws
                calls <- liftEffect $ getCalls state
                liftEffect unsetTestEnv

                let printed = Array.mapMaybe (\c -> case c of
                        CallPrintLn s -> Just s
                        _ -> Nothing) calls
                printed `shouldSatisfy`
                    (Array.any (\s ->
                        String.contains (String.Pattern "ID") s
                            && String.contains (String.Pattern "Started") s
                            && String.contains (String.Pattern "Duration") s
                            && String.contains (String.Pattern "Description") s
                            && String.contains (String.Pattern "1m 05s") s
                            && String.contains (String.Pattern "Resume me later") s
                            && String.contains (String.Pattern "—") s))

    describe "A33: controller triggers real compaction at the right times" do
        it "A33: tool round-trip with oversized request → compaction call and compaction event" do
            let compactConfig = String.joinWith "\n"
                    [ "api_endpoint = \"http://localhost:9999/v1/messages\""
                    , "model = \"test-model\""
                    , "api_key_env = \"TEST_7AIGENT_KEY\""
                    , "output_threshold_chars = 5000"
                    , "max_api_retries = 3"
                    , "max_tokens_per_turn = 50000"
                    , "compaction_threshold = 200"
                    , "preserve_initial = 50"
                    , "preserve_final = 50"
                    , "max_turns_per_round = 3"
                    ]
            withTestSessionCustom
                { llmResponses:
                    [ Right (juliaToolLlmResultHighTokens "compute()" 300)
                    , Right (textLlmResult "Summary of conversation so far")
                    , Right (textLlmResult "Done with compacted context")
                    , Right reflectionComplete
                    ]
                , execResponses: [ "42", "[Tasks: 0]", "[Tasks: 0]", "" ]
                , execDetailedResponses:
                    [ { output: "", hadError: false }
                    , { output: "", hadError: false }
                    ]
                , readLineResponses: []
                , configToml: compactConfig
                , prompt: Just "test prompt"
                } \state calls ws -> do
                    let llmCalls = Array.filter isCallLlm calls
                    Array.length llmCalls `shouldEqual` 3

                    invocations <- liftEffect $ getLlmInvocations state
                    case Array.index invocations 1 of
                        Nothing -> fail "Expected a separate compaction LLM call"
                        Just inv -> case inv.history of
                            ConversationHistory h ->
                                Array.length h.messages `shouldEqual` 1

                    logText <- readWorkspaceFile ws ".7aigent/sessions/1/log.jsonl"
                    logText `shouldSatisfy`
                        (String.contains (String.Pattern "\"type\":\"compaction\""))

        it "A33: oversized no-tool response → compaction still runs" do
            let compactConfig = String.joinWith "\n"
                    [ "api_endpoint = \"http://localhost:9999/v1/messages\""
                    , "model = \"test-model\""
                    , "api_key_env = \"TEST_7AIGENT_KEY\""
                    , "output_threshold_chars = 5000"
                    , "max_api_retries = 3"
                    , "max_tokens_per_turn = 50000"
                    , "compaction_threshold = 200"
                    , "preserve_initial = 50"
                    , "preserve_final = 50"
                    , "max_turns_per_round = 3"
                    ]
            withTestSessionCustom
                { llmResponses:
                    [ Right (textLlmResultHighTokens "Long answer" 300)
                    , Right (textLlmResult "Summary of the conversation")
                    , Right reflectionComplete
                    ]
                , execResponses: [ "[Tasks: 0]", "[Tasks: 0]", "" ]
                , execDetailedResponses:
                    [ { output: "", hadError: false }
                    , { output: "", hadError: false }
                    ]
                , readLineResponses: []
                , configToml: compactConfig
                , prompt: Just "test prompt"
                } \_ calls ws -> do
                    let llmCalls = Array.filter isCallLlm calls
                    Array.length llmCalls `shouldEqual` 2

                    logText <- readWorkspaceFile ws ".7aigent/sessions/1/log.jsonl"
                    logText `shouldSatisfy`
                        (String.contains (String.Pattern "\"type\":\"compaction\""))

        it "A33: cumulative tokens alone do not trigger compaction" do
            let compactConfig = String.joinWith "\n"
                    [ "api_endpoint = \"http://localhost:9999/v1/messages\""
                    , "model = \"test-model\""
                    , "api_key_env = \"TEST_7AIGENT_KEY\""
                    , "output_threshold_chars = 5000"
                    , "max_api_retries = 3"
                    , "max_tokens_per_turn = 50000"
                    , "compaction_threshold = 200"
                    , "preserve_initial = 50"
                    , "preserve_final = 50"
                    , "max_turns_per_round = 3"
                    ]
            withTestSessionCustom
                { llmResponses:
                    [ Right (juliaToolLlmResultHighTokens "step1()" 150)
                    , Right (juliaToolLlmResultHighTokens "step2()" 180)
                    , Right (textLlmResult "Done")
                    , Right reflectionComplete
                    ]
                , execResponses: [ "first", "[Tasks: 0]", "second", "[Tasks: 0]", "[Tasks: 0]", "" ]
                , execDetailedResponses:
                    [ { output: "", hadError: false }
                    , { output: "", hadError: false }
                    ]
                , readLineResponses: []
                , configToml: compactConfig
                , prompt: Just "test prompt"
                } \_ calls ws -> do
                    let llmCalls = Array.filter isCallLlm calls
                    Array.length llmCalls `shouldEqual` 3
                    calls `shouldSatisfy`
                        (not <<< Array.any (\c -> case c of
                            CallPrintStr s -> String.contains (String.Pattern "[Compacting context...]") s
                            _ -> false))

                    logText <- readWorkspaceFile ws ".7aigent/sessions/1/log.jsonl"
                    logText `shouldSatisfy`
                        (not <<< String.contains (String.Pattern "\"type\":\"compaction\""))

        it "A33: oversized user prompt alone does not compact before the first LLM response" do
            let compactConfig = String.joinWith "\n"
                    [ "api_endpoint = \"http://localhost:9999/v1/messages\""
                    , "model = \"test-model\""
                    , "api_key_env = \"TEST_7AIGENT_KEY\""
                    , "output_threshold_chars = 5000"
                    , "max_api_retries = 3"
                    , "max_tokens_per_turn = 50000"
                    , "compaction_threshold = 200"
                    , "preserve_initial = 50"
                    , "preserve_final = 50"
                    , "max_turns_per_round = 3"
                    ]
            let hugePrompt = String.joinWith "" (Array.replicate 400 "very-large-user-prompt ")
            withTestSessionCustom
                { llmResponses:
                    [ Right (textLlmResultHighTokens "Initial answer" 100)
                    , Right reflectionComplete
                    ]
                , execResponses: [ "[Tasks: 0]", "[Tasks: 0]", "" ]
                , execDetailedResponses:
                    [ { output: "", hadError: false }
                    , { output: "", hadError: false }
                    ]
                , readLineResponses: []
                , configToml: compactConfig
                , prompt: Just hugePrompt
                } \_ calls ws -> do
                    let llmCalls = Array.filter isCallLlm calls
                    Array.length llmCalls `shouldEqual` 1
                    calls `shouldSatisfy`
                        (not <<< Array.any (\c -> case c of
                            CallPrintStr s -> String.contains (String.Pattern "[Compacting context...]") s
                            _ -> false))

                    logText <- readWorkspaceFile ws ".7aigent/sessions/1/log.jsonl"
                    logText `shouldSatisfy`
                        (not <<< String.contains (String.Pattern "\"type\":\"compaction\""))

    describe "A34: post-compaction overflow aborts the session" do
        it "A34: compacted history still too large → informative error, session_end(error), exit(1)" do
            let compactConfig = String.joinWith "\n"
                    [ "api_endpoint = \"http://localhost:9999/v1/messages\""
                    , "model = \"test-model\""
                    , "api_key_env = \"TEST_7AIGENT_KEY\""
                    , "output_threshold_chars = 5000"
                    , "max_api_retries = 3"
                    , "max_tokens_per_turn = 50000"
                    , "compaction_threshold = 200"
                    , "preserve_initial = 50"
                    , "preserve_final = 50"
                    , "max_turns_per_round = 3"
                    ]
            withTestSessionCustom
                { llmResponses:
                    [ Right (juliaToolLlmResultHighTokens "work()" 300)
                    , Right (textLlmResult (String.joinWith "" (Array.replicate 500 "word ")))
                    , Right (textLlmResult "should not reach here")
                    , Right reflectionComplete
                    ]
                , execResponses: [ "result", "[Tasks: 0]", "" ]
                , execDetailedResponses:
                    [ { output: "", hadError: false }
                    , { output: "", hadError: false }
                    ]
                , readLineResponses: []
                , configToml: compactConfig
                , prompt: Just "test prompt"
                } \_ calls ws -> do
                    calls `shouldSatisfy`
                        (Array.any (\c -> c == CallExit 1))
                    calls `shouldSatisfy`
                        (Array.any (\c -> case c of
                            CallPrintErr s ->
                                String.contains (String.Pattern "compact") (String.toLower s)
                                    || String.contains (String.Pattern "context") (String.toLower s)
                                    || String.contains (String.Pattern "large") (String.toLower s)
                            _ -> false))

                    logText <- readWorkspaceFile ws ".7aigent/sessions/1/log.jsonl"
                    logText `shouldSatisfy`
                        (\text ->
                            String.contains (String.Pattern "\"type\":\"session_end\"") text
                                && String.contains (String.Pattern "\"reason\":\"error\"") text)

        it "A34: runner rebuilds history as initial block + summary user message + final block" do
            let compactConfig = String.joinWith "\n"
                    [ "api_endpoint = \"http://localhost:9999/v1/messages\""
                    , "model = \"test-model\""
                    , "api_key_env = \"TEST_7AIGENT_KEY\""
                    , "output_threshold_chars = 5000"
                    , "max_api_retries = 3"
                    , "max_tokens_per_turn = 50000"
                    , "compaction_threshold = 200"
                    , "preserve_initial = 1"
                    , "preserve_final = 5"
                    , "max_turns_per_round = 3"
                    ]
            withTestSessionCustom
                { llmResponses:
                    [ Right (juliaToolLlmResultHighTokens "step1()" 100)
                    , Right (juliaToolLlmResultHighTokens "step2()" 300)
                    , Right (textLlmResult "Compacted earlier work.")
                    , Right (textLlmResult "Done with compacted context")
                    , Right reflectionComplete
                    ]
                , execResponses: []
                , execDetailedResponses:
                    [ { output: "", hadError: false }
                    , { output: "", hadError: false }
                    , { output: "old-result", hadError: false }
                    , { output: "[Tasks: 0]", hadError: false }
                    , { output: "recent-result", hadError: false }
                    , { output: "[Tasks: 0]", hadError: false }
                    , { output: "[Tasks: 0]", hadError: false }
                    ]
                , readLineResponses: []
                , configToml: compactConfig
                , prompt: Just "test prompt"
                } \state _ _ -> do
                    invocations <- liftEffect $ getLlmInvocations state
                    case Array.index invocations 3 of
                        Just continuation -> case continuation.history of
                            ConversationHistory h -> do
                                case Array.index h.messages 0, Array.index h.messages 1, Array.index h.messages 2 of
                                    Just first, Just second, Just third -> do
                                        case first.message of
                                            SystemMessage _ -> pure unit
                                            _ -> fail "Expected the preserved system prompt first"
                                        case second.message of
                                            UserMessage r ->
                                                String.contains (String.Pattern "test prompt") r.content
                                                    `shouldEqual` true
                                            _ ->
                                                fail "Expected the preserved initial user message second"
                                        case third.message of
                                            UserMessage r ->
                                                String.contains (String.Pattern "Compacted earlier work.") r.content
                                                    `shouldEqual` true
                                            _ ->
                                                fail "Expected the synthetic summary user message third"
                                    _, _, _ ->
                                        fail "Expected system prompt, initial user message, and summary user message"
                                h.messages `shouldSatisfy`
                                    (Array.any (\entry -> case entry.message of
                                        ToolResultMessage r ->
                                            String.contains (String.Pattern "recent-result") r.output
                                        _ -> false))
                                h.messages `shouldSatisfy`
                                    (not <<< Array.any (\entry -> case entry.message of
                                        ToolResultMessage r ->
                                            String.contains (String.Pattern "old-result") r.output
                                        _ -> false))
                        Nothing ->
                            fail "Expected a continuation LLM call after compaction"

    describe "A36: compaction call properties at controller level" do
        it "A36: compaction uses the same model, is logged, and its prompt stays out of conversation history" do
            let compactConfig = String.joinWith "\n"
                    [ "api_endpoint = \"http://localhost:9999/v1/messages\""
                    , "model = \"test-model\""
                    , "api_key_env = \"TEST_7AIGENT_KEY\""
                    , "output_threshold_chars = 5000"
                    , "max_api_retries = 3"
                    , "max_tokens_per_turn = 50000"
                    , "compaction_threshold = 200"
                    , "preserve_initial = 50"
                    , "preserve_final = 50"
                    , "max_turns_per_round = 3"
                    ]
            withTestSessionCustom
                { llmResponses:
                    [ Right (juliaToolLlmResultHighTokens "compute()" 300)
                    , Right (textLlmResult "Summary: user asked to compute something")
                    , Right (textLlmResult "Done")
                    , Right reflectionComplete
                    ]
                , execResponses: [ "42", "[Tasks: 0]", "[Tasks: 0]", "" ]
                , execDetailedResponses:
                    [ { output: "", hadError: false }
                    , { output: "", hadError: false }
                    ]
                , readLineResponses: []
                , configToml: compactConfig
                , prompt: Just "test prompt"
                } \state _ ws -> do
                    invocations <- liftEffect $ getLlmInvocations state
                    case Array.index invocations 0, Array.index invocations 1, Array.index invocations 2 of
                        Just initial, Just compactCall, Just continuation -> do
                            compactCall.config.model `shouldEqual` initial.config.model
                            case continuation.history of
                                ConversationHistory h -> do
                                    let allContent = String.joinWith " "
                                            (map (\entry -> case entry.message of
                                                UserMessage r -> r.content
                                                SystemMessage r -> r.content
                                                AssistantMessage r -> r.content
                                                ToolResultMessage r -> r.output) h.messages)
                                    allContent `shouldSatisfy`
                                        (\text ->
                                            String.contains (String.Pattern "Summary: user asked to compute something") text
                                                && not (String.contains (String.Pattern "Summarise:") text))
                        _, _, _ ->
                            fail "Expected initial, compaction, and continuation LLM calls"

                    logText <- readWorkspaceFile ws ".7aigent/sessions/1/log.jsonl"
                    logText `shouldSatisfy`
                        (\text ->
                            String.contains (String.Pattern "\"type\":\"compaction\"") text
                                && String.contains (String.Pattern "Summary: user asked to compute something") text)

        it "A36: compaction prompt is recorded only via the compaction event, not persisted history" do
            let compactConfig = String.joinWith "\n"
                    [ "api_endpoint = \"http://localhost:9999/v1/messages\""
                    , "model = \"test-model\""
                    , "api_key_env = \"TEST_7AIGENT_KEY\""
                    , "output_threshold_chars = 5000"
                    , "max_api_retries = 3"
                    , "max_tokens_per_turn = 50000"
                    , "compaction_threshold = 200"
                    , "preserve_initial = 50"
                    , "preserve_final = 50"
                    , "max_turns_per_round = 3"
                    ]
            withWorkspace \ws -> do
                writeWorkspaceFile ws ".7aigent/config.toml" compactConfig
                writeWorkspaceFile ws ".7aigent/system_prompt.md" minimalSystemPrompt
                writeWorkspaceFile ws ".7aigent/startup.jl" "# empty startup"
                writeWorkspaceFile ws ".7aigent/compaction_prompt.md"
                    "COMPACTION_PROMPT_SENTINEL\n{{initial_messages}}\n{{compacted_messages}}\n{{final_messages}}\n{{julia_state}}"
                writeWorkspaceFile ws ".7aigent/summary_message.md" "Summary: {{summary}}"
                liftEffect setTestEnv
                { svc, state } <- liftEffect $ mkMockServices
                    { llmResponses:
                        [ Right (juliaToolLlmResultHighTokens "step1()" 100)
                        , Right (juliaToolLlmResultHighTokens "step2()" 300)
                        , Right (textLlmResult "Compacted earlier work.")
                        , Right (textLlmResult "Done")
                        , Right reflectionComplete
                        ]
                    , execResponses:
                        [ "old-result"
                        , "recent-result"
                        , ""
                        ]
                    , execDetailedResponses:
                        [ { output: "", hadError: false }
                        , { output: "", hadError: false }
                        , { output: "[Tasks: 0]", hadError: false }
                        , { output: "[Tasks: 0]", hadError: false }
                        , { output: "[Tasks: 0]", hadError: false }
                        ]
                    , readLineResponses: []
                    , streamingChunks: []
                    , spawnResult: Right mockSandboxHandle
                    , connectResult: Right mockKernelHandle
                    }
                _ <- attempt $ runNewSession svc ws (Just "test prompt")
                histories <- liftEffect $ getLlmHistories state
                logText <- readWorkspaceFile ws ".7aigent/sessions/1/log.jsonl"
                liftEffect unsetTestEnv

                logText `shouldSatisfy`
                    (\text ->
                        String.contains (String.Pattern "\"type\":\"compaction\"") text
                            && not (String.contains (String.Pattern "COMPACTION_PROMPT_SENTINEL") text))

                case Array.index histories 3 of
                    Just (ConversationHistory continuation) ->
                        continuation.messages `shouldSatisfy`
                            (not <<< Array.any (\entry -> case entry.message of
                                UserMessage r ->
                                    String.contains (String.Pattern "COMPACTION_PROMPT_SENTINEL") r.content
                                AssistantMessage r ->
                                    String.contains (String.Pattern "COMPACTION_PROMPT_SENTINEL") r.content
                                SystemMessage r ->
                                    String.contains (String.Pattern "COMPACTION_PROMPT_SENTINEL") r.content
                                ToolResultMessage r ->
                                    String.contains (String.Pattern "COMPACTION_PROMPT_SENTINEL") r.output))
                    Nothing ->
                        fail "Expected a continuation history after compaction"

        it "A36: compaction does not consume turn budget for later LLM calls" do
            let compactConfig = String.joinWith "\n"
                    [ "api_endpoint = \"http://localhost:9999/v1/messages\""
                    , "model = \"test-model\""
                    , "api_key_env = \"TEST_7AIGENT_KEY\""
                    , "output_threshold_chars = 5000"
                    , "max_api_retries = 3"
                    , "max_tokens_per_turn = 50"
                    , "compaction_threshold = 200"
                    , "preserve_initial = 50"
                    , "preserve_final = 50"
                    , "max_turns_per_round = 3"
                    ]
            withTestSessionCustom
                { llmResponses:
                    [ Right (juliaToolLlmResultHighTokens "step1()" 300)
                    , Right (textLlmResultHighTokens "Summary" 500)
                    , Right (juliaToolLlmResultHighTokens "step2()" 210)
                    , Right (textLlmResultHighTokens "Done" 180)
                    , Right reflectionComplete
                    ]
                , execResponses: [ "first", "[Tasks: 0]", "second", "[Tasks: 0]", "[Tasks: 0]", "" ]
                , execDetailedResponses:
                    [ { output: "", hadError: false }
                    , { output: "", hadError: false }
                    ]
                , readLineResponses: []
                , configToml: compactConfig
                , prompt: Just "test prompt"
                } \_ calls _ -> do
                    let llmCalls = Array.filter isCallLlm calls
                    Array.length llmCalls `shouldSatisfy` (_ >= 4)
                    calls `shouldSatisfy`
                        (not <<< Array.any (\c -> case c of
                            CallPrintLn s -> String.contains (String.Pattern "Token limit reached") s
                            _ -> false))

    describe "A37a: controller enforces turn budget after the current step completes" do
        it "A37a: second oversized call executes its tool, then ends turn and reflects" do
            let turnLimitConfig = String.joinWith "\n"
                    [ "api_endpoint = \"http://localhost:9999/v1/messages\""
                    , "model = \"test-model\""
                    , "api_key_env = \"TEST_7AIGENT_KEY\""
                    , "output_threshold_chars = 5000"
                    , "max_api_retries = 3"
                    , "max_tokens_per_turn = 50"
                    , "compaction_threshold = 400000"
                    , "preserve_initial = 5000"
                    , "preserve_final = 10000"
                    , "max_turns_per_round = 3"
                    ]
            withTestSessionCustom
                { llmResponses:
                    [ Right (juliaToolLlmResult "step1()")
                    , Right (juliaToolLlmResultHighTokens "step2()" 300)
                    , Right reflectionComplete
                    ]
                , execResponses: []
                , execDetailedResponses:
                    [ { output: "", hadError: false }
                    , { output: "", hadError: false }
                    , { output: "one", hadError: false }
                    , { output: "[Tasks: 0]", hadError: false }
                    , { output: "two", hadError: false }
                    , { output: "[Tasks: 0]", hadError: false }
                    ]
                , readLineResponses: []
                , configToml: turnLimitConfig
                , prompt: Just "test prompt"
                } \_ calls _ -> do
                    let llmCalls = Array.filter isCallLlm calls
                    Array.length llmCalls `shouldEqual` 2
                    appearsBeforeIn
                        (\c -> case c of
                            CallExecuteCode code -> String.contains (String.Pattern "step2()") code
                            CallExecuteCodeDetailed code -> String.contains (String.Pattern "step2()") code
                            _ -> false)
                        (\c -> case c of
                            CallPrintLn s -> String.contains (String.Pattern "Token limit reached") s
                            _ -> false)
                        calls `shouldEqual` true
                    appearsBeforeIn
                        (\c -> case c of
                            CallPrintLn s -> String.contains (String.Pattern "Token limit reached") s
                            _ -> false)
                        isCallLlmJson
                        calls `shouldEqual` true

        it "A37a: opening call sets the baseline and later calls compare against the delta" do
            let turnLimitConfig = String.joinWith "\n"
                    [ "api_endpoint = \"http://localhost:9999/v1/messages\""
                    , "model = \"test-model\""
                    , "api_key_env = \"TEST_7AIGENT_KEY\""
                    , "output_threshold_chars = 5000"
                    , "max_api_retries = 3"
                    , "max_tokens_per_turn = 50"
                    , "compaction_threshold = 400000"
                    , "preserve_initial = 5000"
                    , "preserve_final = 10000"
                    , "max_turns_per_round = 3"
                    ]
            withTestSessionCustom
                { llmResponses:
                    [ Right (juliaToolLlmResultHighTokens "step1()" 300)
                    , Right (juliaToolLlmResultHighTokens "step2()" 340)
                    , Right (juliaToolLlmResultHighTokens "step3()" 370)
                    , Right reflectionComplete
                    ]
                , execResponses: []
                , execDetailedResponses:
                    [ { output: "", hadError: false }
                    , { output: "", hadError: false }
                    , { output: "one", hadError: false }
                    , { output: "[Tasks: 0]", hadError: false }
                    , { output: "two", hadError: false }
                    , { output: "[Tasks: 0]", hadError: false }
                    , { output: "three", hadError: false }
                    , { output: "[Tasks: 0]", hadError: false }
                    ]
                , readLineResponses: []
                , configToml: turnLimitConfig
                , prompt: Just "test prompt"
                } \_ calls _ -> do
                    let llmCalls = Array.filter isCallLlm calls
                    Array.length llmCalls `shouldEqual` 3

                    case indexOf (\c -> case c of
                            CallExecuteCode code -> String.contains (String.Pattern "step3()") code
                            CallExecuteCodeDetailed code -> String.contains (String.Pattern "step3()") code
                            _ -> false) calls
                        , indexOf (\c -> case c of
                            CallPrintLn s -> String.contains (String.Pattern "Token limit reached") s
                            _ -> false) calls of
                        Just step3Ix, Just tokenIx ->
                            (step3Ix < tokenIx) `shouldEqual` true
                        _, _ ->
                            fail "Expected the token-limit notice after the third tool execution"

                    appearsBeforeIn
                        (\c -> case c of
                            CallPrintLn s -> String.contains (String.Pattern "Token limit reached") s
                            _ -> false)
                        isCallLlmJson
                        calls `shouldEqual` true

    describe "A46: steering messages are ephemeral and regenerated" do
        it "A46: steering is injected into later calls only, not persisted or logged" do
            withWorkspace \ws -> do
                writeWorkspaceFile ws ".7aigent/config.toml" testConfigToml
                writeWorkspaceFile ws ".7aigent/system_prompt.md" minimalSystemPrompt
                writeWorkspaceFile ws ".7aigent/startup.jl" "# empty startup"
                writeWorkspaceFile ws ".7aigent/steering_message.md"
                    "**Turn status:** {{turn_tokens}}/{{turn_token_limit}} tokens | {{julia_state}}"
                liftEffect setTestEnv
                { svc, state } <- liftEffect $ mkMockServices
                    { llmResponses:
                        [ Right (juliaToolLlmResult "step1()")
                        , Right (juliaToolLlmResultHighTokens "step2()" 300)
                        , Right (textLlmResult "All done")
                        , Right reflectionComplete
                        ]
                    , execResponses: []
                    , execDetailedResponses:
                        [ { output: "", hadError: false }
                        , { output: "", hadError: false }
                        , { output: "result1", hadError: false }
                        , { output: "[Tasks: 0]", hadError: false }
                        , { output: "result2", hadError: false }
                        , { output: "[Tasks: 0]", hadError: false }
                        , { output: "[Tasks: 0]", hadError: false }
                        ]
                    , readLineResponses: []
                    , streamingChunks: []
                    , spawnResult: Right mockSandboxHandle
                    , connectResult: Right mockKernelHandle
                    }
                _ <- attempt $ runNewSession svc ws (Just "test prompt")
                histories <- liftEffect $ getLlmHistories state
                liftEffect unsetTestEnv

                case Array.index histories 0, Array.index histories 1, Array.index histories 2 of
                    Just (ConversationHistory first), Just (ConversationHistory second), Just (ConversationHistory third) -> do
                        let firstContent = String.joinWith " "
                                (map (\entry -> case entry.message of
                                    UserMessage r -> r.content
                                    SystemMessage r -> r.content
                                    AssistantMessage r -> r.content
                                    ToolResultMessage r -> r.output) first.messages)
                        let secondContent = String.joinWith " "
                                (map (\entry -> case entry.message of
                                    UserMessage r -> r.content
                                    SystemMessage r -> r.content
                                    AssistantMessage r -> r.content
                                    ToolResultMessage r -> r.output) second.messages)
                        let thirdContent = String.joinWith " "
                                (map (\entry -> case entry.message of
                                    UserMessage r -> r.content
                                    SystemMessage r -> r.content
                                    AssistantMessage r -> r.content
                                    ToolResultMessage r -> r.output) third.messages)
                        let secondSteering = Array.mapMaybe (\entry -> case entry.message of
                                UserMessage r ->
                                    if String.contains (String.Pattern "**Turn status:**") r.content then
                                        Just r.content
                                    else
                                        Nothing
                                _ -> Nothing) second.messages
                        let thirdSteering = Array.mapMaybe (\entry -> case entry.message of
                                UserMessage r ->
                                    if String.contains (String.Pattern "**Turn status:**") r.content then
                                        Just r.content
                                    else
                                        Nothing
                                _ -> Nothing) third.messages
                        firstContent `shouldSatisfy`
                            (not <<< String.contains (String.Pattern "**Turn status:**"))
                        Array.length secondSteering `shouldEqual` 1
                        Array.length thirdSteering `shouldEqual` 1
                        secondContent `shouldSatisfy`
                            (String.contains (String.Pattern "**Turn status:** 0/50000 tokens | [Tasks: 0]"))
                        thirdContent `shouldSatisfy`
                            (\text ->
                                String.contains (String.Pattern "**Turn status:** 200/50000 tokens | [Tasks: 0]") text
                                    && not (String.contains (String.Pattern "**Turn status:** 0/50000 tokens | [Tasks: 0]") text))
                        second.messages `shouldSatisfy`
                            (not <<< Array.any (\entry -> case entry.message of
                                SystemMessage r ->
                                    String.contains (String.Pattern "**Turn status:**") r.content
                                AssistantMessage r ->
                                    String.contains (String.Pattern "**Turn status:**") r.content
                                ToolResultMessage r ->
                                    String.contains (String.Pattern "**Turn status:**") r.output
                                UserMessage _ -> false))
                        third.messages `shouldSatisfy`
                            (not <<< Array.any (\entry -> case entry.message of
                                SystemMessage r ->
                                    String.contains (String.Pattern "**Turn status:**") r.content
                                AssistantMessage r ->
                                    String.contains (String.Pattern "**Turn status:**") r.content
                                ToolResultMessage r ->
                                    String.contains (String.Pattern "**Turn status:**") r.output
                                UserMessage _ -> false))
                    _, _, _ ->
                        fail "Expected first, second, and third LLM histories"

                logText <- readWorkspaceFile ws ".7aigent/sessions/1/log.jsonl"
                logText `shouldSatisfy`
                    (not <<< String.contains (String.Pattern "Turn status"))

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
