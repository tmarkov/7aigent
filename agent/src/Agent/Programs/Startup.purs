module Agent.Programs.Startup
    ( advanceStartup
    , StartupPhase(..)
    , StartupNext(..)
    ) where

import Prelude
import Data.Either (Either(..))
import Data.String as String
import Agent.Types (AppError(..))

data StartupPhase
    = ValidatingConfig
    | ExecutingStartup Int
    | RunningSession

derive instance Eq StartupPhase
instance Show StartupPhase where
    show ValidatingConfig = "ValidatingConfig"
    show (ExecutingStartup n) =
        "(ExecutingStartup " <> show n <> ")"
    show RunningSession = "RunningSession"

data StartupNext
    = NextStep StartupPhase
    | Ready { initialReplOutput :: String }
    | Abort AppError

instance Show StartupNext where
    show (NextStep phase) =
        "(NextStep " <> show phase <> ")"
    show (Ready r) =
        "(Ready { initialReplOutput: "
        <> show r.initialReplOutput <> " })"
    show (Abort err) =
        "(Abort " <> show err <> ")"

advanceStartup
    :: StartupPhase
    -> Either AppError String
    -> StartupNext
advanceStartup ValidatingConfig (Left err) = Abort err
advanceStartup ValidatingConfig (Right _) =
    NextStep (ExecutingStartup 0)
advanceStartup (ExecutingStartup idx) (Left err) =
    Abort err
advanceStartup (ExecutingStartup idx) (Right output) =
    if idx >= 1
    then Ready { initialReplOutput: output }
    else NextStep (ExecutingStartup (idx + 1))
advanceStartup RunningSession (Left err) =
    Abort err
advanceStartup RunningSession (Right _) =
    Abort (StartupExpressionError
        "advanceStartup called in RunningSession")
