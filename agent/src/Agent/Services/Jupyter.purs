-- | Jupyter kernel client over ZMQ IPC sockets.
-- | Covers A4, A16, A19, A20.
module Agent.Services.Jupyter
    ( KernelHandle
    , ExecutionResult
    , InputRequest
    , connectKernel
    , executeCode
    , executeCodeDetailed
    , executeCodeDetailedWithInput
    , executeRequestAllowsStdin
    , sendInputReply
    , interruptKernel
    , closeKernel
    ) where

import Prelude
import Data.Either (Either(..))
import Effect (Effect)
import Effect.Aff (Aff, makeAff, nonCanceler)
import Agent.Types (RawJulia(..), AppError(..))

type SummaryServiceConfig =
    { apiEndpoint :: String
    , apiKey :: String
    , model :: String
    }

type ExecutionResult =
    { output :: String
    , hadError :: Boolean
    }

type InputRequest =
    { prompt :: String
    , reply
        :: String
        -> String
        -> (String -> Effect Unit)
        -> Effect Unit
        -> Effect Unit
    , cancel :: Effect Unit
    }

-- | A live connection to the Jupyter kernel.
type KernelHandle =
    { execute   :: String
                    -> (String -> Effect Unit)
                    -> (InputRequest -> Effect Unit)
                    -> (ExecutionResult -> Effect Unit)
                    -> Effect Unit
    , interrupt :: Effect Unit -> Effect Unit
    , close     :: Effect Unit
    }

foreign import connectKernelImpl
    :: String
    -> SummaryServiceConfig
    -> (String -> String -> Effect Unit)
    -> (String -> Effect Unit)
    -> (KernelHandle -> Effect Unit)
    -> Effect Unit

foreign import executeRequestAllowsStdin :: String -> Boolean

-- | Connect to the Jupyter kernel described by kernel.json.
connectKernel
    :: String
    -> SummaryServiceConfig
    -> (String -> String -> Effect Unit)
    -> Aff (Either AppError KernelHandle)
connectKernel kernelJsonPath summaryConfig onLlmQuery = makeAff \resolve -> do
    connectKernelImpl kernelJsonPath summaryConfig onLlmQuery
        (\msg -> resolve (Right (Left (KernelError msg))))
        (\h   -> resolve (Right (Right h)))
    pure nonCanceler

-- | Execute Julia code in the kernel, streaming partial output via onToken,
-- | and resolving with the full output string when complete.
executeCode :: KernelHandle -> RawJulia -> (String -> Effect Unit) -> Aff String
executeCode kernel (RawJulia code) onToken = makeAff \resolve -> do
    kernel.execute code onToken rejectInput (\result -> resolve (Right result.output))
    pure nonCanceler

executeCodeDetailed :: KernelHandle -> RawJulia -> (String -> Effect Unit) -> Aff ExecutionResult
executeCodeDetailed kernel (RawJulia code) onToken = makeAff \resolve -> do
    kernel.execute code onToken rejectInput (\result -> resolve (Right result))
    pure nonCanceler

executeCodeDetailedWithInput
    :: KernelHandle
    -> RawJulia
    -> (String -> Effect Unit)
    -> (InputRequest -> Effect Unit)
    -> Aff ExecutionResult
executeCodeDetailedWithInput kernel (RawJulia code) onToken onInput = makeAff \resolve -> do
    kernel.execute code onToken onInput (\result -> resolve (Right result))
    pure nonCanceler

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
    kernel.interrupt (resolve (Right unit))
    pure nonCanceler

-- | Close all kernel sockets.
closeKernel :: KernelHandle -> Effect Unit
closeKernel kernel = kernel.close
