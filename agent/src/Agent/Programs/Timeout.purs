module Agent.Programs.Timeout
    ( defaultTimeoutCheckSeconds
    , isCheckDue
    , buildTimeoutCheckRequest
    , interpretTimeoutResponse
    , TimeoutDecision(..)
    ) where

import Prelude
import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.String as String
import Agent.Types (RawJulia(..))

data TimeoutDecision
    = Interrupt
    | ScheduleNext Int

derive instance Eq TimeoutDecision
instance Show TimeoutDecision where
    show Interrupt = "Interrupt"
    show (ScheduleNext n) =
        "(ScheduleNext " <> show n <> ")"

defaultTimeoutCheckSeconds :: Array Int
defaultTimeoutCheckSeconds = [30, 60, 120, 240, 480]

isCheckDue :: Array Int -> Int -> Int -> Boolean
isCheckDue schedule elapsed lastCheckAt =
    nextCheckpointAfter schedule lastCheckAt <= elapsed

nextCheckpointAfter :: Array Int -> Int -> Int
nextCheckpointAfter schedule lastCheckAt =
    case Array.find (_ > lastCheckAt) schedule of
        Just cp -> cp
        Nothing ->
            -- Beyond the explicit schedule: keep doubling from the last entry
            case Array.last schedule of
                Nothing  -> lastCheckAt + 30
                Just top -> go (top * 2)
  where
    go checkpoint
        | checkpoint > lastCheckAt = checkpoint
        | otherwise = go (checkpoint * 2)

buildTimeoutCheckRequest
    :: RawJulia
    -> Int
    -> String
    -> Array { content :: String }
buildTimeoutCheckRequest (RawJulia source) elapsed
    partialOutput =
    [ { content:
            "The following Julia code has been "
            <> "running for " <> show elapsed
            <> " seconds:\n\n```julia\n" <> source
            <> "\n```\n\nPartial output so far:\n"
            <> partialOutput
            <> "\n\nShould I interrupt this execution?"
            <> " Please answer 'yes' to interrupt"
            <> " or 'no' to let it continue."
      }
    ]

interpretTimeoutResponse :: String -> TimeoutDecision
interpretTimeoutResponse response =
    let lower = String.toLower response
    in  if String.contains (String.Pattern "yes") lower
        then Interrupt
        else ScheduleNext 60
