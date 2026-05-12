-- | Pure builders for LlmResponse values used in tests.
module Test.Helpers.LlmResponse
  ( textResponse
  , toolCallResponse
  , multiToolCallResponse
  ) where

import Agent.Types
  ( LlmResponse(..)
  , ToolCall
  , ToolCallId(..)
  , TokenCount(..)
  , toolNameFromString
  )

-- | An LLM response containing only text (no tool calls).
textResponse :: String -> TokenCount -> LlmResponse
textResponse content inputTokens = LlmResponse
  { content
  , toolCalls: []
  , inputTokens
  }

-- | An LLM response containing a single tool call.
toolCallResponse :: String -> String -> ToolCallId -> TokenCount -> LlmResponse
toolCallResponse toolName input tcId inputTokens = LlmResponse
  { content: ""
  , toolCalls: [ { name: toolNameFromString toolName, input, id: tcId } ]
  , inputTokens
  }

-- | An LLM response containing multiple tool calls.
multiToolCallResponse :: Array ToolCall -> TokenCount -> LlmResponse
multiToolCallResponse toolCalls inputTokens = LlmResponse
  { content: ""
  , toolCalls
  , inputTokens
  }
