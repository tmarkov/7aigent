-- | Jupyter kernel client over ZMQ IPC sockets.
-- | Covers A4, A16, A19, A20.
module Agent.Services.Jupyter
    ( KernelHandle
    , ExecutionResult
    , connectKernel
    , executeCode
    , executeCodeDetailed
    , interruptKernel
    , closeKernel
    ) where

import Prelude
import Data.Either (Either(..))
import Effect (Effect)
import Effect.Aff (Aff, makeAff, nonCanceler)
import Agent.Types (RawJulia(..), AppError(..))

type ExecutionResult =
    { output :: String
    , hadError :: Boolean
    }

-- | A live connection to the Jupyter kernel.
type KernelHandle =
    { execute   :: String -> (String -> Effect Unit) -> (ExecutionResult -> Effect Unit) -> Effect Unit
    , interrupt :: Effect Unit -> Effect Unit
    , close     :: Effect Unit
    }

foreign import connectKernelImpl
    :: String
    -> (String -> Effect Unit)
    -> (KernelHandle -> Effect Unit)
    -> Effect Unit

-- | Connect to the Jupyter kernel described by kernel.json.
connectKernel :: String -> Aff (Either AppError KernelHandle)
connectKernel kernelJsonPath = makeAff \resolve -> do
    connectKernelImpl kernelJsonPath
        (\msg -> resolve (Right (Left (KernelError msg))))
        (\h   -> resolve (Right (Right h)))
    pure nonCanceler

-- | Execute Julia code in the kernel, streaming partial output via onToken,
-- | and resolving with the full output string when complete.
executeCode :: KernelHandle -> RawJulia -> (String -> Effect Unit) -> Aff String
executeCode kernel (RawJulia code) onToken = makeAff \resolve -> do
    kernel.execute code onToken (\result -> resolve (Right result.output))
    pure nonCanceler

executeCodeDetailed :: KernelHandle -> RawJulia -> (String -> Effect Unit) -> Aff ExecutionResult
executeCodeDetailed kernel (RawJulia code) onToken = makeAff \resolve -> do
    kernel.execute code onToken (\result -> resolve (Right result))
    pure nonCanceler

-- | Send an interrupt_request to the kernel control channel.
interruptKernel :: KernelHandle -> Aff Unit
interruptKernel kernel = makeAff \resolve -> do
    kernel.interrupt (resolve (Right unit))
    pure nonCanceler

-- | Close all kernel sockets.
closeKernel :: KernelHandle -> Effect Unit
closeKernel kernel = kernel.close
