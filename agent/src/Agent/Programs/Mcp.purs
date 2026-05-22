module Agent.Programs.Mcp
    ( buildMcpRunConfig
    , handleMcpResult
    , isProgressDue
    , extractFinalMessage
    , startMcpServerImpl
    , McpRunResult(..)
    ) where

import Prelude

import Data.Foldable (foldl)
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Agent.Types (ConversationHistory(..), Message(..))

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

-- | Extract the content of the last AssistantMessage in the conversation
-- | history. Returns Nothing if there is no assistant message.
-- | Used by the MCP server to build the tool response (A43).
extractFinalMessage :: ConversationHistory -> Maybe String
extractFinalMessage (ConversationHistory h) =
    foldl step Nothing h.messages
  where
    step _ { message: AssistantMessage { content } } = Just content
    step acc _                                        = acc

-- | FFI: start the MCP HTTP server on the given port.
-- | For each `run` tool invocation, `onToolCall` is called with the message
-- | and a continuation; the continuation must be called exactly once with the
-- | tool result. Progress notifications are sent every 15 seconds by the JS
-- | side while the continuation is pending.
foreign import startMcpServerImpl
    :: Int
    -> (String -> ({ isError :: Boolean, content :: String } -> Effect Unit) -> Effect Unit)
    -> Effect Unit
