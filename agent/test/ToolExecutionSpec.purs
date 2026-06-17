module Test.ToolExecutionSpec where

import Prelude

import Control.Alt ((<|>))
import Control.Parallel (parallel, sequential)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), isJust)
import Data.Set as Set
import Effect.Aff
    ( Aff
    , Milliseconds(..)
    , cancelWith
    , delay
    , effectCanceler
    , never
    )
import Effect.Class (liftEffect)
import Effect.Exception as Exception
import Effect.Ref as Ref
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

import Agent.Programs.Config (parseConfig)
import Agent.Programs.SummaryRequest (encodeSummaryError)
import Agent.Programs.SessionLog (allocateSessionId, readLogEvents)
import Agent.Runner.ToolExecution (doTool)
import Agent.Services.Jupyter as Jupyter
import Agent.Services.Llm as Llm
import Agent.Services.Sandbox as Sandbox
import Agent.Types
    ( ConversationHistory(..)
    , Config
    , LogEvent(..)
    , SessionId
    , Timestamp
    , TokenCount(..)
    , ToolCallId(..)
    , ToolName(..)
    , WorkspacePath
    )
import Test.Helpers.ControllerFixtures
    ( mockKernelHandle
    , mockSandboxHandle
    , testConfigToml
    )
import Test.Helpers.LlmResponse (textResponse)
import Test.Helpers.MockServices
    ( CallRecord(..)
    , callsMatching
    , getStdinReplies
    , mkMockServices
    , queueStdinRequests
    )
import Test.Helpers.Workspace (withWorkspace)

toolExecutionSpec :: Spec Unit
toolExecutionSpec = do
    describe "A14-A17: model-selected julia_repl timeout workflow" do
        it "A14 + A17: wait decision records the next timeout and continues" do
            withWorkspace \ws -> do
                sessionId <- allocateSessionId ws
                mock <- liftEffect $ mkMockServices
                    (mockOptions
                        [ llmResult "{\"action\":\"wait\",\"timeout_seconds\":1}" 5 1 ])
                let svc = mock.svc
                        { executeCodeDetailedWithInput =
                            \_ _ _ _ -> do
                                delay (Milliseconds 1200.0)
                                pure { output: "done", hadError: false }
                        }
                config <- requireConfig
                result <- doTool
                    svc ws sessionId
                    (config { maxApiRetries = 0 })
                    "key" mockKernelHandle mockSandboxHandle
                    "{{json_schema}}" "{{prompt}}"
                    emptyHistory
                    { name: JuliaRepl
                    , input: "{\"code\":\"sleep(2)\",\"timeout_seconds\":1}"
                    , id: ToolCallId "tc-timeout-wait"
                    }
                    Set.empty
                    zeroUsage
                result.toolInterrupted `shouldEqual` false
                events <- requireEvents ws sessionId
                let responses = Array.mapMaybe asTimeoutResponse events
                map _.action responses `shouldEqual` [ "wait" ]
                map _.timeoutSeconds responses `shouldEqual` [ Just 1 ]

        it "A16: interrupt decision interrupts the active timeout" do
            withWorkspace \ws -> do
                sessionId <- allocateSessionId ws
                mock <- liftEffect $ mkMockServices
                    (mockOptions [ llmResult "{\"action\":\"interrupt\"}" 4 1 ])
                interruptCount <- liftEffect $ Ref.new 0
                let svc = mock.svc
                        { executeCodeDetailedWithInput =
                            \_ _ _ _ -> do
                                waitUntilInterrupt interruptCount
                                pure { output: "partial", hadError: false }
                        , interruptKernel = \_ -> do
                            liftEffect $ Ref.modify_ (_ + 1) interruptCount
                        }
                config <- requireConfig
                result <- doTool
                    svc ws sessionId
                    (config { maxApiRetries = 0 })
                    "key" mockKernelHandle mockSandboxHandle
                    "{{json_schema}}" "{{prompt}}"
                    emptyHistory
                    { name: JuliaRepl
                    , input: "{\"code\":\"while true; sleep(1); end\",\"timeout_seconds\":1}"
                    , id: ToolCallId "tc-timeout-interrupt"
                    }
                    Set.empty
                    zeroUsage
                result.toolInterrupted `shouldEqual` true
                interrupts <- liftEffect $ Ref.read interruptCount
                interrupts `shouldEqual` 1
                events <- requireEvents ws sessionId
                let responses = Array.mapMaybe asTimeoutResponse events
                map _.action responses `shouldEqual` [ "interrupt" ]
                map _.timeoutSeconds responses `shouldEqual` [ Nothing ]

        it "A17a: send_input decision is logged and waits when no sink is available" do
            withWorkspace \ws -> do
                sessionId <- allocateSessionId ws
                mock <- liftEffect $ mkMockServices
                    (mockOptions
                        [ llmResult "{\"action\":\"send_input\",\"value\":\"123\\n\"}" 5 1 ])
                let svc = mock.svc
                        { executeCodeDetailedWithInput =
                            \_ _ _ _ -> do
                                delay (Milliseconds 1200.0)
                                pure { output: "done", hadError: false }
                        }
                config <- requireConfig
                result <- doTool
                    svc ws sessionId
                    (config { maxApiRetries = 0 })
                    "key" mockKernelHandle mockSandboxHandle
                    "{{json_schema}}" "{{prompt}}"
                    emptyHistory
                    { name: JuliaRepl
                    , input: "{\"code\":\"run(`python -c 'input()'`)\",\"timeout_seconds\":1}"
                    , id: ToolCallId "tc-timeout-input"
                    }
                    Set.empty
                    zeroUsage
                result.toolInterrupted `shouldEqual` false
                events <- requireEvents ws sessionId
                let responses = Array.mapMaybe asTimeoutResponse events
                map _.action responses `shouldEqual` [ "send_input" ]
                map _.value responses `shouldEqual` [ Just "123\n" ]
                map _.error responses
                    `shouldEqual` [ Just "timeout input sink unavailable" ]

    describe "A52-A56: julia_repl input request workflow" do
        it "A52a: stdin arrival cancels an in-flight timeout decision" do
            withWorkspace \ws -> do
                sessionId <- allocateSessionId ws
                mock <- liftEffect $ mkMockServices (mockOptions [])
                timeoutCancelled <- liftEffect $ Ref.new false
                decisionCalls <- liftEffect $ Ref.new 0
                inputReplied <- liftEffect $ Ref.new false
                let svc = mock.svc
                        { executeCodeDetailedWithInput =
                            \_ _ _ onInput -> do
                                delay (Milliseconds 1100.0)
                                liftEffect $ onInput
                                    { prompt: "Name: "
                                    , summaryRequest: Nothing
                                    , reply: \_ _ _ onSuccess -> do
                                        Ref.write true inputReplied
                                        onSuccess
                                    , cancel: pure unit
                                    }
                                waitUntil inputReplied
                                pure { output: "done", hadError: false }
                        , callLlm = \_ _ _ _ -> do
                            callNumber <- liftEffect $
                                Ref.modify (\n -> n + 1) decisionCalls
                            if callNumber == 1
                                then cancelWith never
                                    (effectCanceler
                                        (Ref.write true timeoutCancelled))
                                else pure (Right
                                    (llmResult
                                        "{\"action\":\"reply\",\"value\":\"Ada\"}"
                                        6
                                        1))
                        }
                baseConfig <- requireConfig
                let config = baseConfig { maxApiRetries = 0 }
                maybeResult <- sequential $
                    parallel
                        (Just <$> doTool
                            svc ws sessionId config "key" mockKernelHandle
                            mockSandboxHandle "{{json_schema}}" "{{prompt}}"
                            emptyHistory
                            { name: JuliaRepl
                            , input: "{\"code\":\"readline()\",\"timeout_seconds\":1}"
                            , id: ToolCallId "tc-cancel-timeout"
                            }
                            Set.empty
                            zeroUsage)
                    <|>
                    parallel
                        (delay (Milliseconds 2500.0) $> Nothing)
                map _.toolInterrupted maybeResult `shouldEqual` Just false
                wasCancelled <- liftEffect $ Ref.read timeoutCancelled
                wasCancelled `shouldEqual` true
                callCount <- liftEffect $ Ref.read decisionCalls
                callCount `shouldEqual` 2
                events <- requireEvents ws sessionId
                Array.length (Array.mapMaybe asTimeoutResponse events)
                    `shouldEqual` 0

        it "A52: cancelling stdin service releases the pending request" do
            withWorkspace \ws -> do
                sessionId <- allocateSessionId ws
                mock <- liftEffect $ mkMockServices (mockOptions [])
                inputStarted <- liftEffect $ Ref.new false
                inputCancelled <- liftEffect $ Ref.new false
                let svc = mock.svc
                        { executeCodeDetailedWithInput =
                            \_ _ _ onInput -> do
                                liftEffect $ onInput
                                    { prompt: "Name: "
                                    , summaryRequest: Nothing
                                    , reply: \_ _ _ _ -> pure unit
                                    , cancel: Ref.write true inputCancelled
                                    }
                                waitUntil inputCancelled
                                pure { output: "", hadError: false }
                        , callLlm = \_ _ _ _ -> do
                            liftEffect $ Ref.write true inputStarted
                            never
                        }
                config <- requireConfig
                maybeResult <- sequential $
                    parallel
                        (Just <$> doTool
                            svc ws sessionId config "key" mockKernelHandle
                            mockSandboxHandle "{{json_schema}}" "{{prompt}}"
                            emptyHistory
                            { name: JuliaRepl
                            , input: "{\"code\":\"readline()\",\"timeout_seconds\":30}"
                            , id: ToolCallId "tc-cancel-input"
                            }
                            Set.empty
                            zeroUsage)
                    <|>
                    parallel
                        (waitUntil inputStarted *>
                            delay (Milliseconds 50.0) $> Nothing)
                map _.toolInterrupted maybeResult `shouldEqual` Nothing
                wasCancelled <- liftEffect $ Ref.read inputCancelled
                wasCancelled `shouldEqual` true

        it "A20b + A52a: summary input uses common LLM transport and pauses timeout" do
            withWorkspace \ws -> do
                sessionId <- allocateSessionId ws
                mock <- liftEffect $ mkMockServices (mockOptions [])
                timeoutCancelled <- liftEffect $ Ref.new false
                decisionCalls <- liftEffect $ Ref.new 0
                inputReplied <- liftEffect $ Ref.new false
                summaryReply <- liftEffect $ Ref.new ""
                let requestJson =
                        ( "{\"request_id\":\"r1\",\"target_ids\":[\"node-1\"],"
                            <> "\"evidence\":{\"nodes\":[],\"witnesses\":[],"
                            <> "\"targets\":[]}}"
                        )
                let svc = mock.svc
                        { executeCodeDetailedWithInput =
                            \_ _ _ onInput -> do
                                delay (Milliseconds 1100.0)
                                liftEffect $ onInput
                                    { prompt: "7aigent.summary.reply:comm-1"
                                    , summaryRequest: Just
                                        (delay (Milliseconds 200.0) $> requestJson)
                                    , reply: \value _ _ onSuccess -> do
                                        Ref.write value summaryReply
                                        Ref.write true inputReplied
                                        onSuccess
                                    , cancel: pure unit
                                    }
                                waitUntil inputReplied
                                pure { output: "done", hadError: false }
                        , callLlm = \_ _ _ options -> do
                            callNumber <- liftEffect $
                                Ref.modify (\n -> n + 1) decisionCalls
                            if callNumber == 1
                                then cancelWith never
                                    (effectCanceler
                                        (Ref.write true timeoutCancelled))
                                else if callNumber == 2
                                    then pure (Right
                                        (llmResult "{}" 5 1))
                                else do
                                    (options.responseFormat == Llm.JsonObjectResponse)
                                        `shouldEqual` true
                                    pure (Right
                                        (llmResult
                                            ( "{\"summaries\":[{\"id\":\"node-1\","
                                                <> "\"summary\":\"Generated.\"}]}"
                                            )
                                            9
                                            2))
                        }
                baseConfig <- requireConfig
                let config = baseConfig { maxApiRetries = 1 }
                maybeResult <- sequential $
                    parallel
                        (Just <$> doTool
                            svc ws sessionId config "key" mockKernelHandle
                            mockSandboxHandle "{{json_schema}}" "{{prompt}}"
                            emptyHistory
                            { name: JuliaRepl
                            , input: "{\"code\":\"summarize!([\\\"node-1\\\"])\",\"timeout_seconds\":1}"
                            , id: ToolCallId "tc-summary"
                            }
                            Set.empty
                            zeroUsage)
                    <|>
                    parallel
                        (delay (Milliseconds 2500.0) $> Nothing)
                map _.toolInterrupted maybeResult `shouldEqual` Just false
                wasCancelled <- liftEffect $ Ref.read timeoutCancelled
                wasCancelled `shouldEqual` true
                map (_.usageTotals.inputTokens) maybeResult
                    `shouldEqual` Just (TokenCount 14)
                replyValue <- liftEffect $ Ref.read summaryReply
                replyValue `shouldEqual` "ok\nnode-1\tR2VuZXJhdGVkLg=="
                events <- requireEvents ws sessionId
                Array.length (Array.mapMaybe asTimeoutResponse events)
                    `shouldEqual` 0
                Array.length (Array.mapMaybe asTokenUsage events)
                    `shouldEqual` 2
                Array.length (Array.mapMaybe asLlmQuery events)
                    `shouldEqual` 1

        it "A20b: summary retry exhaustion returns the final validation error" do
            withWorkspace \ws -> do
                sessionId <- allocateSessionId ws
                mock <- liftEffect $ mkMockServices
                    (mockOptions
                        [ llmResult "{}" 5 1
                        , llmResult "{\"summaries\":[]}" 6 1
                        ])
                inputReplied <- liftEffect $ Ref.new false
                summaryReply <- liftEffect $ Ref.new ""
                let requestJson =
                        ( "{\"request_id\":\"r1\",\"target_ids\":[\"node-1\"],"
                            <> "\"evidence\":{\"nodes\":[],\"witnesses\":[],"
                            <> "\"targets\":[]}}"
                        )
                let svc = mock.svc
                        { executeCodeDetailedWithInput =
                            \_ _ _ onInput -> do
                                liftEffect $ onInput
                                    { prompt: "7aigent.summary.reply:comm-1"
                                    , summaryRequest: Just (pure requestJson)
                                    , reply: \value _ _ onSuccess -> do
                                        Ref.write value summaryReply
                                        Ref.write true inputReplied
                                        onSuccess
                                    , cancel: pure unit
                                    }
                                waitUntil inputReplied
                                pure { output: "done", hadError: false }
                        }
                baseConfig <- requireConfig
                let config = baseConfig { maxApiRetries = 1 }
                result <- doTool
                    svc ws sessionId config "key" mockKernelHandle
                    mockSandboxHandle "{{json_schema}}" "{{prompt}}"
                    emptyHistory
                    { name: JuliaRepl
                    , input: "{\"code\":\"summarize!([\\\"node-1\\\"])\",\"timeout_seconds\":30}"
                    , id: ToolCallId "tc-summary-error"
                    }
                    Set.empty
                    zeroUsage
                result.toolInterrupted `shouldEqual` false
                replyValue <- liftEffect $ Ref.read summaryReply
                replyValue `shouldEqual` encodeSummaryError
                    "Summary response must contain each requested id exactly once"

        it "A20b: malformed summary request returns an error without an LLM call" do
            withWorkspace \ws -> do
                sessionId <- allocateSessionId ws
                mock <- liftEffect $ mkMockServices (mockOptions [])
                inputReplied <- liftEffect $ Ref.new false
                summaryReply <- liftEffect $ Ref.new ""
                let svc = mock.svc
                        { executeCodeDetailedWithInput =
                            \_ _ _ onInput -> do
                                liftEffect $ onInput
                                    { prompt: "7aigent.summary.reply:comm-1"
                                    , summaryRequest: Just
                                        (pure "{\"target_ids\":[\"node-1\"]}")
                                    , reply: \value _ _ onSuccess -> do
                                        Ref.write value summaryReply
                                        Ref.write true inputReplied
                                        onSuccess
                                    , cancel: pure unit
                                    }
                                waitUntil inputReplied
                                pure { output: "done", hadError: false }
                        }
                config <- requireConfig
                result <- doTool
                    svc ws sessionId config "key" mockKernelHandle
                    mockSandboxHandle "{{json_schema}}" "{{prompt}}"
                    emptyHistory
                    { name: JuliaRepl
                    , input: "{\"code\":\"malformed direct summary RPC\",\"timeout_seconds\":30}"
                    , id: ToolCallId "tc-summary-invalid-request"
                    }
                    Set.empty
                    zeroUsage
                result.toolInterrupted `shouldEqual` false
                replyValue <- liftEffect $ Ref.read summaryReply
                replyValue `shouldEqual` encodeSummaryError
                    "Expected exactly the fields request_id, target_ids, evidence"
                llmCalls <- liftEffect $ callsMatching isLlmCall mock.state
                llmCalls `shouldEqual` []

        it "A52 + A54 + A55: services sequential requests and preserves annotations" do
            withWorkspace \ws -> do
                sessionId <- allocateSessionId ws
                mock <- liftEffect $ mkMockServices
                    (mockOptions
                        [ llmResult "{\"action\":\"reply\",\"value\":\"Ada\"}" 10 2
                        , llmResult "{\"action\":\"reply\",\"value\":\"yes\"}" 11 3
                        ])
                liftEffect $ queueStdinRequests mock.state
                    [ { prompt: "Name: " }
                    , { prompt: "Continue? " }
                    ]
                config <- requireConfig
                result <- doTool
                    mock.svc ws sessionId config "key" mockKernelHandle
                    mockSandboxHandle "{{json_schema}}"
                    "{{prompt}}\n{{json_schema}}"
                    emptyHistory
                    { name: JuliaRepl
                    , input: "{\"code\":\"readline(); readline()\",\"timeout_seconds\":30}"
                    , id: ToolCallId "tc-stdin"
                    }
                    Set.empty
                    zeroUsage
                replies <- liftEffect $ getStdinReplies mock.state
                map _.value replies `shouldEqual` [ "Ada", "yes" ]
                result.usageTotals.inputTokens `shouldEqual` TokenCount 21
                events <- requireEvents ws sessionId
                let stdinEvents = Array.mapMaybe asStdinRequest events
                map _.sequence stdinEvents `shouldEqual` [ 1, 2 ]
                map _.attempt stdinEvents `shouldEqual` [ 1, 1 ]
                requestLogs <- liftEffect $
                    callsMatching isRequestLog mock.state
                Array.length requestLogs `shouldEqual` 2

        it "A54a + A56: parse failures consume the shared retry budget" do
            withWorkspace \ws -> do
                sessionId <- allocateSessionId ws
                mock <- liftEffect $ mkMockServices
                    (mockOptions
                        [ llmResult "not json" 5 1
                        , llmResult "{\"action\":\"reply\",\"value\":\"ok\"}" 7 2
                        ])
                liftEffect $ queueStdinRequests mock.state
                    [ { prompt: "Value: " } ]
                config <- requireConfig
                _ <- doTool
                    mock.svc ws sessionId config "key" mockKernelHandle
                    mockSandboxHandle "{{json_schema}}" "{{prompt}}"
                    emptyHistory
                    { name: JuliaRepl
                    , input: "{\"code\":\"readline()\",\"timeout_seconds\":30}"
                    , id: ToolCallId "tc-retry"
                    }
                    Set.empty
                    zeroUsage
                events <- requireEvents ws sessionId
                let stdinEvents = Array.mapMaybe asStdinRequest events
                map _.attempt stdinEvents `shouldEqual` [ 1, 2 ]
                map (isJust <<< _.error) stdinEvents `shouldEqual` [ true, false ]
                Array.length (Array.mapMaybe asTokenUsage events) `shouldEqual` 2
                delays <- liftEffect $
                    callsMatching isRetryDelay mock.state
                delays `shouldEqual` []

        it "A15a + A54a: API failures wait before using the shared retry" do
            withWorkspace \ws -> do
                sessionId <- allocateSessionId ws
                mock <- liftEffect $ mkMockServices
                    ((mockOptions [])
                        { llmResponses =
                            [ Left "network unavailable"
                            , Right
                                (llmResult
                                    "{\"action\":\"reply\",\"value\":\"ok\"}"
                                    7
                                    2)
                            ]
                        })
                liftEffect $ queueStdinRequests mock.state
                    [ { prompt: "Value: " } ]
                config <- requireConfig
                _ <- doTool
                    mock.svc ws sessionId config "key" mockKernelHandle
                    mockSandboxHandle "{{json_schema}}" "{{prompt}}"
                    emptyHistory
                    { name: JuliaRepl
                    , input: "{\"code\":\"readline()\",\"timeout_seconds\":30}"
                    , id: ToolCallId "tc-api-retry"
                    }
                    Set.empty
                    zeroUsage
                delays <- liftEffect $
                    callsMatching isRetryDelay mock.state
                delays `shouldEqual` [ CallDelayMilliseconds 1000 ]

        it "A54 + A56: all replies are visible in output and logs" do
            withWorkspace \ws -> do
                sessionId <- allocateSessionId ws
                mock <- liftEffect $ mkMockServices
                    (mockOptions
                        [ llmResult "{\"action\":\"reply\",\"value\":\"secret\"}" 4 1 ])
                liftEffect $ queueStdinRequests mock.state
                    [ { prompt: "Password: " } ]
                config <- requireConfig
                _ <- doTool
                    mock.svc ws sessionId config "key" mockKernelHandle
                    mockSandboxHandle "{{json_schema}}" "{{prompt}}"
                    emptyHistory
                    { name: JuliaRepl
                    , input: "{\"code\":\"readline()\",\"timeout_seconds\":30}"
                    , id: ToolCallId "tc-visible-input"
                    }
                    Set.empty
                    zeroUsage
                replies <- liftEffect $ getStdinReplies mock.state
                map _.annotation replies `shouldEqual` [ "\n[input: \"secret\"]" ]
                events <- requireEvents ws sessionId
                let stdinEvents = Array.mapMaybe asStdinRequest events
                map _.value stdinEvents `shouldEqual` [ Just "secret" ]

        it "A54: failed input_reply transmission interrupts execution" do
            withWorkspace \ws -> do
                sessionId <- allocateSessionId ws
                mock <- liftEffect $ mkMockServices
                    (mockOptions
                        [ llmResult "{\"action\":\"reply\",\"value\":\"Ada\"}" 4 1 ])
                inputCancelled <- liftEffect $ Ref.new false
                let svc = mock.svc
                        { executeCodeDetailedWithInput =
                            \_ _ _ onInput -> do
                                liftEffect $ onInput
                                    { prompt: "Name: "
                                    , summaryRequest: Nothing
                                    , reply: \_ _ onError _ ->
                                        onError "stdin socket closed"
                                    , cancel: Ref.write true inputCancelled
                                    }
                                never
                        }
                config <- requireConfig
                result <- doTool
                    svc ws sessionId config "key" mockKernelHandle
                    mockSandboxHandle "{{json_schema}}" "{{prompt}}"
                    emptyHistory
                    { name: JuliaRepl
                    , input: "{\"code\":\"readline()\",\"timeout_seconds\":30}"
                    , id: ToolCallId "tc-reply-failed"
                    }
                    Set.empty
                    zeroUsage
                result.toolInterrupted `shouldEqual` true
                cancelled <- liftEffect $ Ref.read inputCancelled
                cancelled `shouldEqual` true

        it "A54: interrupt action interrupts without sending an input reply" do
            withWorkspace \ws -> do
                sessionId <- allocateSessionId ws
                mock <- liftEffect $ mkMockServices
                    (mockOptions
                        [ llmResult "{\"action\":\"interrupt\"}" 4 1 ])
                liftEffect $ queueStdinRequests mock.state
                    [ { prompt: "Continue? " } ]
                config <- requireConfig
                result <- doTool
                    mock.svc ws sessionId config "key" mockKernelHandle
                    mockSandboxHandle "{{json_schema}}" "{{prompt}}"
                    emptyHistory
                    { name: JuliaRepl
                    , input: "{\"code\":\"readline()\",\"timeout_seconds\":30}"
                    , id: ToolCallId "tc-interrupt"
                    }
                    Set.empty
                    zeroUsage
                result.toolInterrupted `shouldEqual` true
                replies <- liftEffect $ getStdinReplies mock.state
                replies `shouldEqual` []
                interrupts <- liftEffect $
                    callsMatching (_ == CallInterruptKernel) mock.state
                Array.length interrupts `shouldEqual` 1

        it "A54b: retry exhaustion interrupts instead of supplying input" do
            withWorkspace \ws -> do
                sessionId <- allocateSessionId ws
                mock <- liftEffect $ mkMockServices
                    (mockOptions
                        [ llmResult "{}" 1 1
                        , llmResult "{}" 1 1
                        , llmResult "{}" 1 1
                        , llmResult "{}" 1 1
                        ])
                liftEffect $ queueStdinRequests mock.state
                    [ { prompt: "Value: " } ]
                config <- requireConfig
                result <- doTool
                    mock.svc ws sessionId config "key" mockKernelHandle
                    mockSandboxHandle "{{json_schema}}" "{{prompt}}"
                    emptyHistory
                    { name: JuliaRepl
                    , input: "{\"code\":\"readline()\",\"timeout_seconds\":30}"
                    , id: ToolCallId "tc-exhausted"
                    }
                    Set.empty
                    zeroUsage
                result.toolInterrupted `shouldEqual` true
                replies <- liftEffect $ getStdinReplies mock.state
                replies `shouldEqual` []
                events <- requireEvents ws sessionId
                let stdinEvents = Array.mapMaybe asStdinRequest events
                map _.attempt stdinEvents `shouldEqual` [ 1, 2, 3, 4 ]

type MockOptions =
    { llmResponses :: Array (Either String Llm.CallLlmResult)
    , execResponses :: Array String
    , execDetailedResponses :: Array Jupyter.ExecutionResult
    , readLineResponses :: Array String
    , spawnResult :: Either String Sandbox.SandboxHandle
    , connectResult :: Either String Jupyter.KernelHandle
    , streamingChunks :: Array (Array String)
    }

type StdinRequestEvent =
    { timestamp :: Timestamp
    , toolCallId :: ToolCallId
    , sequence :: Int
    , attempt :: Int
    , elapsedSeconds :: Int
    , prompt :: String
    , value :: Maybe String
    , interrupt :: Maybe Boolean
    , error :: Maybe String
    }

type TokenUsageEvent =
    { timestamp :: Timestamp
    , inputTokens :: TokenCount
    , cachedInputTokens :: TokenCount
    , outputTokens :: TokenCount
    , totalSessionInputTokens :: TokenCount
    , totalSessionCachedInputTokens :: TokenCount
    , totalSessionOutputTokens :: TokenCount
    }

type TimeoutResponseEvent =
    { timestamp :: Timestamp
    , action :: String
    , timeoutSeconds :: Maybe Int
    , value :: Maybe String
    , error :: Maybe String
    }

type LlmQueryEvent =
    { timestamp :: Timestamp
    , purpose :: String
    , input :: String
    }

mockOptions :: Array Llm.CallLlmResult -> MockOptions
mockOptions responses =
    { llmResponses: map Right responses
    , execResponses: [ "done" ]
    , execDetailedResponses: []
    , readLineResponses: []
    , spawnResult: Right mockSandboxHandle
    , connectResult: Right mockKernelHandle
    , streamingChunks: []
    }

llmResult :: String -> Int -> Int -> Llm.CallLlmResult
llmResult content inputTokens outputTokens =
    { response: textResponse content (TokenCount inputTokens)
    , usage:
        { inputTokens: TokenCount inputTokens
        , cachedInputTokens: TokenCount 0
        , outputTokens: TokenCount outputTokens
        }
    }

requireConfig :: Aff Config
requireConfig = case parseConfig testConfigToml of
    Left err -> liftEffect $ Exception.throw ("Invalid test config: " <> show err)
    Right config -> pure config

requireEvents :: WorkspacePath -> SessionId -> Aff (Array LogEvent)
requireEvents ws sessionId = do
    result <- readLogEvents ws sessionId
    case result of
        Left err -> liftEffect $ Exception.throw ("Could not read events: " <> show err)
        Right events -> pure events

asStdinRequest :: LogEvent -> Maybe StdinRequestEvent
asStdinRequest (StdinRequest event) = Just event
asStdinRequest _ = Nothing

asTokenUsage :: LogEvent -> Maybe TokenUsageEvent
asTokenUsage (TokenUsage event) = Just event
asTokenUsage _ = Nothing

asTimeoutResponse :: LogEvent -> Maybe TimeoutResponseEvent
asTimeoutResponse (TimeoutResponse event) = Just event
asTimeoutResponse _ = Nothing

asLlmQuery :: LogEvent -> Maybe LlmQueryEvent
asLlmQuery (EvtLlmQuery event) = Just event
asLlmQuery _ = Nothing

isRequestLog :: CallRecord -> Boolean
isRequestLog (CallLlmRequestLog _) = true
isRequestLog _ = false

isLlmCall :: CallRecord -> Boolean
isLlmCall (CallLlm _) = true
isLlmCall (CallLlmJson _) = true
isLlmCall _ = false

isRetryDelay :: CallRecord -> Boolean
isRetryDelay (CallDelayMilliseconds _) = true
isRetryDelay _ = false

emptyHistory :: ConversationHistory
emptyHistory =
    ConversationHistory { messages: [] }

zeroUsage :: Llm.LlmUsage
zeroUsage =
    { inputTokens: TokenCount 0
    , cachedInputTokens: TokenCount 0
    , outputTokens: TokenCount 0
    }

waitUntil :: Ref.Ref Boolean -> Aff Unit
waitUntil ref = do
    ready <- liftEffect $ Ref.read ref
    if ready
        then pure unit
        else do
            delay (Milliseconds 10.0)
            waitUntil ref

waitUntilInterrupt :: Ref.Ref Int -> Aff Unit
waitUntilInterrupt ref = do
    count <- liftEffect $ Ref.read ref
    if count > 0
        then pure unit
        else do
            delay (Milliseconds 10.0)
            waitUntilInterrupt ref
