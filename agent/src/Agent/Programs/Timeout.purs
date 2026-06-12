module Agent.Programs.Timeout
    ( defaultTimeoutCheckSeconds
    , isCheckDue
    ) where

import Prelude
import Data.Array as Array
import Data.Maybe (Maybe(..))

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
