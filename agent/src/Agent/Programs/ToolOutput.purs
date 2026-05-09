module Agent.Programs.ToolOutput
    ( processToolOutput
    ) where

import Prelude
import Data.Array as Array
import Data.String as String

type ProcessedOutput =
    { llmFacing :: String
    , displayText :: String
    , fullOutput :: String
    , truncated :: Boolean
    }

processToolOutput :: Int -> String -> ProcessedOutput
processToolOutput threshold output
    | String.length output > threshold =
        let msg =
                "Output too large ("
                <> show (String.length output)
                <> " chars, threshold "
                <> show threshold
                <> "). Please use more targeted commands."
        in  { llmFacing: msg
            , displayText: msg
            , fullOutput: output
            , truncated: true
            }
    | otherwise =
        let lines = String.split (String.Pattern "\n") output
            displayLines = Array.take 5 lines
            displayText =
                String.joinWith "\n" displayLines
        in  { llmFacing: output
            , displayText
            , fullOutput: output
            , truncated: false
            }
