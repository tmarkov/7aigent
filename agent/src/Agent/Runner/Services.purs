-- | Service capabilities record for dependency injection.
-- | Production code passes `productionServices`; tests pass mock services.
module Agent.Runner.Services
    ( RunnerServices
    , productionServices
    ) where

import Prelude

import Data.Either (Either)
import Data.Int as Int
import Effect (Effect)
import Effect.Aff (Aff, Milliseconds(..), delay)
import Agent.Types
    ( WorkspacePath
    , RawJulia
    , AppError
    , Config
    , ConversationHistory
    , LlmResponse
    , TokenCount
    )
import Agent.Services.Jupyter as Jupyter
import Agent.Services.Llm as Llm
import Agent.Services.Sandbox as Sandbox
import Agent.Services.Terminal as Terminal
import Agent.Services.Stdin as Stdin

-- | All external capabilities needed by the runner, grouped into a record
-- | to enable testing via mock implementations.
type RunnerServices =
    { spawnSandbox       :: WorkspacePath -> Aff (Either AppError Sandbox.SandboxHandle)
    , killSandbox        :: Sandbox.SandboxHandle -> Aff Unit
    , connectKernel      :: String -> Aff (Either AppError Jupyter.KernelHandle)
    , executeCode        :: Jupyter.KernelHandle -> RawJulia -> (String -> Effect Unit) -> Aff String
    , executeCodeDetailed :: Jupyter.KernelHandle -> RawJulia -> (String -> Effect Unit) -> Aff Jupyter.ExecutionResult
    , executeCodeDetailedWithInput
        :: Jupyter.KernelHandle
        -> RawJulia
        -> (String -> Effect Unit)
        -> (Jupyter.InputRequest -> Effect Unit)
        -> Aff Jupyter.ExecutionResult
    , interruptKernel    :: Jupyter.KernelHandle -> Aff Unit
    , interruptSandbox   :: Sandbox.SandboxHandle -> Effect Unit
    , closeKernel        :: Jupyter.KernelHandle -> Effect Unit
    , callLlm
        :: Config
        -> String
        -> ConversationHistory
        -> Llm.LlmCallOptions
        -> Aff (Either AppError Llm.CallLlmResult)
    , delayMilliseconds :: Int -> Aff Unit
    , setLlmRequestLogPath :: String -> Effect Unit
    , printLn            :: String -> Effect Unit
    , printStr           :: String -> Effect Unit
    , printErr           :: String -> Effect Unit
    , readLine           :: Aff String
    , writePrompt        :: String -> Effect Unit
    , nowIso             :: Effect String
    , exit               :: Int -> Effect Unit
    }

-- | The real service implementations, used in production.
productionServices :: RunnerServices
productionServices =
    { spawnSandbox: Sandbox.spawnSandbox
    , killSandbox: Sandbox.killSandbox
    , connectKernel: Jupyter.connectKernel
    , executeCode: Jupyter.executeCode
    , executeCodeDetailed: Jupyter.executeCodeDetailed
    , executeCodeDetailedWithInput: Jupyter.executeCodeDetailedWithInput
    , interruptKernel: Jupyter.interruptKernel
    , interruptSandbox: Sandbox.interruptSandbox
    , closeKernel: Jupyter.closeKernel
    , callLlm: Llm.callLlm
    , delayMilliseconds: \milliseconds ->
        delay (Milliseconds (Int.toNumber milliseconds))
    , setLlmRequestLogPath: Llm.setLlmRequestLogPath
    , printLn: Terminal.printLn
    , printStr: Terminal.printStr
    , printErr: Terminal.printErr
    , readLine: Stdin.readLine
    , writePrompt: Stdin.writePrompt
    , nowIso: nowIsoImpl
    , exit: exitImpl
    }

foreign import nowIsoImpl :: Effect String
foreign import exitImpl :: Int -> Effect Unit
