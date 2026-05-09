module Agent.Programs.Retry
    ( retryDecision
    , RetryDecision(..)
    , ApiError(..)
    ) where

import Prelude
import Data.Int (pow)

data ApiError
    = HttpStatus Int
    | NetworkTimeout

derive instance Eq ApiError
instance Show ApiError where
    show (HttpStatus n) = "(HttpStatus " <> show n <> ")"
    show NetworkTimeout = "NetworkTimeout"

data RetryDecision
    = Retry Int
    | GiveUp String

derive instance Eq RetryDecision
instance Show RetryDecision where
    show (Retry ms) = "(Retry " <> show ms <> "ms)"
    show (GiveUp reason) =
        "(GiveUp " <> show reason <> ")"

retryDecision :: ApiError -> Int -> Int -> RetryDecision
retryDecision err attempt maxRetries
    | attempt >= maxRetries =
        GiveUp "Maximum retries exhausted"
    | isTransient err =
        let baseMs = 1000
            backoffMs = baseMs * pow 2 attempt
        in  Retry backoffMs
    | otherwise =
        GiveUp ("Non-transient error: " <> show err)

isTransient :: ApiError -> Boolean
isTransient (HttpStatus 429) = true
isTransient (HttpStatus n) = n >= 500 && n < 600
isTransient NetworkTimeout = true
