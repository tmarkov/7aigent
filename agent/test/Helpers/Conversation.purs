-- | Pure builders for ConversationHistory and Message values.
module Test.Helpers.Conversation
  ( systemMsg
  , userMsg
  , assistantMsg
  , assistantToolCallMsg
  , toolResultMsg
  , mkHistory
  , mkHistoryWithTokens
  ) where

import Prelude

import Data.Tuple (Tuple(..))
import Agent.Types
  ( Message(..)
  , ConversationHistory(..)
  , ToolCallId(..)
  , TokenCount(..)
  )

-- | Construct a system message.
systemMsg :: String -> Message
systemMsg content = SystemMessage { content }

-- | Construct a user message.
userMsg :: String -> Message
userMsg content = UserMessage { content }

-- | Construct an assistant message with text, no tool calls.
assistantMsg :: String -> Message
assistantMsg content = AssistantMessage { content, toolCalls: [] }

-- | Construct an assistant message that contains a single tool call.
assistantToolCallMsg :: String -> String -> ToolCallId -> Message
assistantToolCallMsg toolName input tcId =
  AssistantMessage
    { content: ""
    , toolCalls: [ { name: toolName, input, id: tcId } ]
    }

-- | Construct a tool result message.
toolResultMsg :: ToolCallId -> String -> Message
toolResultMsg tcId output = ToolResultMessage { toolCallId: tcId, output }

-- | Build a ConversationHistory from an array of messages, all with
-- token count 100 (useful when token counts don't matter for the test).
mkHistory :: Array Message -> ConversationHistory
mkHistory msgs = ConversationHistory
  { messages: map (\m -> { message: m, tokens: TokenCount 100 }) msgs }

-- | Build a ConversationHistory with explicit per-message token counts.
mkHistoryWithTokens :: Array (Tuple Message TokenCount) -> ConversationHistory
mkHistoryWithTokens pairs = ConversationHistory
  { messages: map (\(Tuple m t) -> { message: m, tokens: t }) pairs }
