-- | Sandbox process management: spawns 7aigent-sandbox and returns a handle.
module Agent.Services.Sandbox
    ( SandboxHandle
    , spawnSandbox
    , killSandbox
    ) where

import Prelude
import Data.Either (Either(..))
import Effect (Effect)
import Effect.Aff (Aff, makeAff, nonCanceler)
import Agent.Types (WorkspacePath(..), AppError(..))

-- | A handle to a running sandbox process.
type SandboxHandle =
    { kernelJsonPath :: String
    , kill           :: (Unit -> Effect Unit) -> Effect Unit
    }

foreign import spawnSandboxImpl
    :: String
    -> (String -> Effect Unit)
    -> ({ kernelJsonPath :: String, kill :: (Unit -> Effect Unit) -> Effect Unit } -> Effect Unit)
    -> Effect Unit

-- | Spawn the sandbox for the given workspace. Resolves with the path to
-- | kernel.json once the launcher has printed it.
spawnSandbox :: WorkspacePath -> Aff (Either AppError SandboxHandle)
spawnSandbox (WorkspacePath wp) = makeAff \resolve -> do
    spawnSandboxImpl wp
        (\msg -> resolve (Right (Left (SandboxLaunchError msg))))
        (\h   -> resolve (Right (Right h)))
    pure nonCanceler

killSandbox :: SandboxHandle -> Aff Unit
killSandbox sandbox = makeAff \resolve -> do
    sandbox.kill (\_ -> resolve (Right unit))
    pure nonCanceler
