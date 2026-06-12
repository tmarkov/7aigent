-- | Jupyter kernel client over ZMQ IPC sockets.
-- | Covers A4, A16, A19, A20.
module Agent.Services.Jupyter
    ( KernelHandle
    , ExecutionResult
    , InputRequest
    , InputRequestWire
    , SummaryRequestLoader
    , connectKernel
    , executeCode
    , executeCodeDetailed
    , executeCodeDetailedWithInput
    , executeRequestAllowsStdin
    , summaryCorrelationTimeoutMilliseconds
    , classifySummaryInputPrompt
    , decodeSummaryCommContent
    , sendInputReply
    , interruptKernel
    , closeKernel
    ) where

import Prelude
import Data.Either (Either(..))
import Data.Maybe (Maybe)
import Data.Nullable (Nullable, toMaybe)
import Effect (Effect)
import Effect.Aff (Aff, effectCanceler, makeAff, nonCanceler)
import Effect.Exception (error)
import Agent.Types (RawJulia(..), AppError(..))

type ExecutionResult =
    { output :: String
    , hadError :: Boolean
    }

type InputRequest =
    { prompt :: String
    , summaryRequest :: Maybe (Aff String)
    , reply
        :: String
        -> String
        -> (String -> Effect Unit)
        -> Effect Unit
        -> Effect Unit
    , cancel :: Effect Unit
    }

type InputRequestWire =
    { prompt :: String
    , summaryRequest :: Nullable SummaryRequestLoader
    , reply
        :: String
        -> String
        -> (String -> Effect Unit)
        -> Effect Unit
        -> Effect Unit
    , cancel :: Effect Unit
    }

type SummaryRequestLoader =
    (String -> Effect Unit)
    -> (String -> Effect Unit)
    -> Effect (Effect Unit)

-- | A live connection to the Jupyter kernel.
type KernelHandle =
    { execute   :: String
                    -> (String -> Effect Unit)
                    -> (InputRequestWire -> Effect Unit)
                    -> (ExecutionResult -> Effect Unit)
                    -> Effect Unit
    , interrupt
        :: (String -> Effect Unit)
        -> Effect Unit
        -> Effect Unit
    , close     :: Effect Unit
    }

foreign import connectKernelImpl
    :: String
    -> (String -> Effect Unit)
    -> (KernelHandle -> Effect Unit)
    -> Effect Unit

foreign import executeRequestAllowsStdin :: String -> Boolean
foreign import summaryCorrelationTimeoutMilliseconds :: Int
foreign import classifySummaryInputPrompt :: String -> String
foreign import decodeSummaryCommContent :: String -> String

-- | Connect to the Jupyter kernel described by kernel.json.
connectKernel
    :: String
    -> Aff (Either AppError KernelHandle)
connectKernel kernelJsonPath = makeAff \resolve -> do
    connectKernelImpl kernelJsonPath
        (\msg -> resolve (Right (Left (KernelError msg))))
        (\h   -> resolve (Right (Right h)))
    pure nonCanceler

-- | Execute Julia code in the kernel, streaming partial output via onToken,
-- | and resolving with the full output string when complete.
executeCode :: KernelHandle -> RawJulia -> (String -> Effect Unit) -> Aff String
executeCode kernel (RawJulia code) onToken = makeAff \resolve -> do
    kernel.execute code onToken (rejectInput <<< toInputRequest)
        (\result -> resolve (Right result.output))
    pure nonCanceler

executeCodeDetailed :: KernelHandle -> RawJulia -> (String -> Effect Unit) -> Aff ExecutionResult
executeCodeDetailed kernel (RawJulia code) onToken = makeAff \resolve -> do
    kernel.execute code onToken (rejectInput <<< toInputRequest)
        (\result -> resolve (Right result))
    pure nonCanceler

executeCodeDetailedWithInput
    :: KernelHandle
    -> RawJulia
    -> (String -> Effect Unit)
    -> (InputRequest -> Effect Unit)
    -> Aff ExecutionResult
executeCodeDetailedWithInput kernel (RawJulia code) onToken onInput = makeAff \resolve -> do
    kernel.execute code onToken (onInput <<< toInputRequest)
        (\result -> resolve (Right result))
    pure nonCanceler

toInputRequest :: InputRequestWire -> InputRequest
toInputRequest request =
    { prompt: request.prompt
    , summaryRequest: map loadSummaryRequest (toMaybe request.summaryRequest)
    , reply: request.reply
    , cancel: request.cancel
    }

loadSummaryRequest :: SummaryRequestLoader -> Aff String
loadSummaryRequest loader = makeAff \resolve -> do
    cancel <- loader
        (\err -> resolve (Left (error err)))
        (\requestJson -> resolve (Right requestJson))
    pure (effectCanceler cancel)

rejectInput :: InputRequest -> Effect Unit
rejectInput request =
    request.reply
        "7aigent does not support stdin for this internal execution."
        "\n[input: <unavailable>]"
        (const (pure unit))
        (pure unit)

sendInputReply
    :: InputRequest
    -> String
    -> String
    -> Aff (Either String Unit)
sendInputReply request value annotation = makeAff \resolve -> do
    request.reply
        value
        annotation
        (\err -> resolve (Right (Left err)))
        (resolve (Right (Right unit)))
    pure nonCanceler

-- | Send an interrupt_request to the kernel control channel.
interruptKernel :: KernelHandle -> Aff Unit
interruptKernel kernel = makeAff \resolve -> do
    kernel.interrupt
        (\err -> resolve (Left (error err)))
        (resolve (Right unit))
    pure nonCanceler

-- | Close all kernel sockets.
closeKernel :: KernelHandle -> Effect Unit
closeKernel kernel = kernel.close
