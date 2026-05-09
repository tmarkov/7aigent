module Agent.Programs.Mcp
    ( buildMcpRunConfig
    , handleMcpResult
    , isProgressDue
    , McpRunResult(..)
    ) where

import Prelude

data McpRunResult
    = McpSuccess String
    | McpFailure String

derive instance Eq McpRunResult
instance Show McpRunResult where
    show (McpSuccess s) =
        "(McpSuccess " <> show s <> ")"
    show (McpFailure s) =
        "(McpFailure " <> show s <> ")"

buildMcpRunConfig
    :: String -> { initialMessage :: String }
buildMcpRunConfig prompt =
    { initialMessage: prompt }

handleMcpResult
    :: McpRunResult
    -> { isError :: Boolean, content :: String }
handleMcpResult (McpSuccess output) =
    { isError: false, content: output }
handleMcpResult (McpFailure err) =
    { isError: true, content: err }

isProgressDue :: Int -> Boolean
isProgressDue elapsed =
    elapsed > 0 && mod elapsed 15 == 0
