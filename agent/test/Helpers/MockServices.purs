-- | Mock implementation of RunnerServices for controller integration tests.
-- | Records all service calls and returns scripted responses.
module Test.Helpers.MockServices
    ( MockState
    , LlmInvocation
    , CallRecord(..)
    , mkMockServices
    , getCalls
    , callsMatching
    , getLlmInvocations
    , getLlmHistories
    ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Maybe (Maybe(..))
import Data.String as String
import Effect (Effect)
import Effect.Class (liftEffect)
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Effect.Exception as Exception

import Agent.Types
    ( WorkspacePath
    , RawJulia(..)
    , AppError(..)
    , Config
    , ConversationHistory
    , TokenCount(..)
    )
import Agent.Runner.Services (RunnerServices)
import Agent.Services.Jupyter as Jupyter
import Agent.Services.Llm as Llm
import Agent.Services.Sandbox as Sandbox

-- | All observable service calls made by the controller.
data CallRecord
    = CallSpawnSandbox
    | CallConnectKernel String
    | CallExecuteCode String
    | CallExecuteCodeDetailed String
    | CallInterruptKernel
    | CallCloseKernel
    | CallLlm String
    | CallLlmJson String
    | CallPrintLn String
    | CallPrintStr String
    | CallPrintErr String
    | CallReadLine
    | CallWritePrompt String
    | CallExit Int

derive instance eqCallRecord :: Eq CallRecord

instance showCallRecord :: Show CallRecord where
    show CallSpawnSandbox = "CallSpawnSandbox"
    show (CallConnectKernel p) = "CallConnectKernel(" <> p <> ")"
    show (CallExecuteCode c) = "CallExecuteCode(" <> c <> ")"
    show (CallExecuteCodeDetailed c) = "CallExecuteCodeDetailed(" <> c <> ")"
    show CallInterruptKernel = "CallInterruptKernel"
    show CallCloseKernel = "CallCloseKernel"
    show (CallLlm purpose) = "CallLlm(" <> purpose <> ")"
    show (CallLlmJson purpose) = "CallLlmJson(" <> purpose <> ")"
    show (CallPrintLn s) = "CallPrintLn(" <> s <> ")"
    show (CallPrintStr s) = "CallPrintStr(" <> s <> ")"
    show (CallPrintErr s) = "CallPrintErr(" <> s <> ")"
    show CallReadLine = "CallReadLine"
    show (CallWritePrompt s) = "CallWritePrompt(" <> s <> ")"
    show (CallExit n) = "CallExit(" <> show n <> ")"

type LlmInvocation =
    { kind :: String
    , config :: Config
    , history :: ConversationHistory
    }

-- | Mutable state shared between mock service functions and the test.
type MockState =
    { calls :: Ref (Array CallRecord)
    , llmResponses :: Ref (Array (Either String Llm.CallLlmResult))
    , execResponses :: Ref (Array String)
    , execDetailedResponses :: Ref (Array Jupyter.ExecutionResult)
    , readLineResponses :: Ref (Array String)
    , streamingChunks :: Ref (Array (Array String))
    , llmInvocations :: Ref (Array LlmInvocation)
    , spawnResult :: Either String Sandbox.SandboxHandle
    , connectResult :: Either String Jupyter.KernelHandle
    }

-- | Get all recorded calls.
getCalls :: MockState -> Effect (Array CallRecord)
getCalls st = Ref.read st.calls

getLlmInvocations :: MockState -> Effect (Array LlmInvocation)
getLlmInvocations st = Ref.read st.llmInvocations

getLlmHistories :: MockState -> Effect (Array ConversationHistory)
getLlmHistories st = map _.history <$> getLlmInvocations st

-- | Filter recorded calls matching a predicate.
callsMatching :: (CallRecord -> Boolean) -> MockState -> Effect (Array CallRecord)
callsMatching pred st = Array.filter pred <$> getCalls st

-- | Create a mock services record that records all calls and returns scripted responses.
-- | The `svc.exit` implementation throws an exception to abort the Aff computation,
-- | simulating process termination.
mkMockServices
    :: { llmResponses :: Array (Either String Llm.CallLlmResult)
       , execResponses :: Array String
       , execDetailedResponses :: Array Jupyter.ExecutionResult
       , readLineResponses :: Array String
       , spawnResult :: Either String Sandbox.SandboxHandle
       , connectResult :: Either String Jupyter.KernelHandle
       , streamingChunks :: Array (Array String)
       }
    -> Effect { svc :: RunnerServices, state :: MockState }
mkMockServices opts = do
    calls <- Ref.new []
    llmResponses <- Ref.new opts.llmResponses
    execResponses <- Ref.new opts.execResponses
    execDetailedResponses <- Ref.new opts.execDetailedResponses
    readLineResponses <- Ref.new opts.readLineResponses
    streamingChunks <- Ref.new opts.streamingChunks
    llmInvocations <- Ref.new []
    let state =
            { calls
            , llmResponses
            , execResponses
            , execDetailedResponses
            , readLineResponses
            , streamingChunks
            , llmInvocations
            , spawnResult: opts.spawnResult
            , connectResult: opts.connectResult
            }
    let record c = Ref.modify_ (\cs -> cs <> [c]) calls
    let popStr ref def = do
            arr <- Ref.read ref
            case Array.uncons arr of
                Nothing -> pure def
                Just { head: h, tail: t } -> do
                    Ref.write t ref
                    pure h
    let popLlm ref def = do
            arr <- Ref.read ref
            case Array.uncons arr of
                Nothing -> pure def
                Just { head: h, tail: t } -> do
                    Ref.write t ref
                    pure h
    let popChunks ref = do
            arr <- Ref.read ref
            case Array.uncons arr of
                Nothing -> pure []
                Just { head: h, tail: t } -> do
                    Ref.write t ref
                    pure h
    let svc =
            { spawnSandbox: \_ -> do
                liftEffect $ record CallSpawnSandbox
                pure $ case opts.spawnResult of
                    Left e -> Left (SandboxLaunchError e)
                    Right s -> Right s
            , killSandbox: \_ -> pure unit
            , connectKernel: \path _ _ -> do
                liftEffect $ record (CallConnectKernel path)
                pure $ case opts.connectResult of
                    Left e -> Left (KernelError e)
                    Right k -> Right k
            , executeCode: \_ (RawJulia code) _ -> do
                liftEffect $ record (CallExecuteCode code)
                result <- liftEffect $ popStr execResponses ""
                case String.stripPrefix (String.Pattern "__CRASH__") result of
                    Just msg -> liftEffect $ Exception.throw ("Sandbox crashed: " <> msg)
                    Nothing -> pure result
            , executeCodeDetailed: \_ (RawJulia code) _ -> do
                liftEffect $ record (CallExecuteCodeDetailed code)
                detailedQueue <- liftEffect $ Ref.read execDetailedResponses
                case Array.uncons detailedQueue of
                    Just { head: h, tail: t } -> do
                        liftEffect $ Ref.write t execDetailedResponses
                        pure h
                    Nothing -> do
                        result <- liftEffect $ popStr execResponses ""
                        case String.stripPrefix (String.Pattern "__CRASH__") result of
                            Just msg -> liftEffect $ Exception.throw ("Sandbox crashed: " <> msg)
                            Nothing -> pure { output: result, hadError: false }
            , interruptKernel: \_ -> do
                liftEffect $ record CallInterruptKernel
            , closeKernel: \_ -> record CallCloseKernel
            , callLlm: \config _ history onChunk -> do
                liftEffect $ record (CallLlm "stream")
                liftEffect $ Ref.modify_ (_ <> [{ kind: "stream", config, history }]) llmInvocations
                -- A7: invoke the streaming callback with scripted chunks
                chunks <- liftEffect $ popChunks streamingChunks
                liftEffect $ for_ chunks onChunk
                r <- liftEffect $ popLlm llmResponses (Left "no more LLM responses")
                pure $ case r of
                    Left e -> Left (LlmApiError e)
                    Right v -> Right v
            , callLlmJson: \config _ history -> do
                liftEffect $ record (CallLlmJson "json")
                liftEffect $ Ref.modify_ (_ <> [{ kind: "json", config, history }]) llmInvocations
                r <- liftEffect $ popLlm llmResponses (Left "no more LLM JSON responses")
                pure $ case r of
                    Left e -> Left (LlmApiError e)
                    Right v -> Right v
            , printLn: \s -> record (CallPrintLn s)
            , printStr: \s -> record (CallPrintStr s)
            , printErr: \s -> record (CallPrintErr s)
            , readLine: do
                liftEffect $ record CallReadLine
                liftEffect $ popStr readLineResponses ""
            , writePrompt: \s -> record (CallWritePrompt s)
            , nowIso: pure "2025-01-01T00:00:00Z"
            , exit: \n -> do
                record (CallExit n)
                Exception.throw ("MockExit:" <> show n)
            }
    pure { svc, state }
