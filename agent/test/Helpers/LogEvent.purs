-- | Pure builders for LogEvent values and JSONL round-trip helpers.
module Test.Helpers.LogEvent
  ( sessionStartEvent
  , systemPromptEvent
  , userMessageEvent
  , llmResponseEvent
  , llmQueryEvent
  , toolCallEvent
  , toolResultEvent
  , tokenUsageEvent
  , compactionEvent
  , sessionEndEvent
  , escapeEvent
  , sigintEvent
  , timeoutCheckEvent
  , timeoutResponseEvent
  , renderEvents
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe)
import Data.String as String
import Agent.Types
  ( LogEvent(..)
  , Timestamp(..)
  , SessionId(..)
  , ModelName(..)
  , ToolCallId(..)
  , TokenCount(..)
  , toolNameFromString
  , sessionEndReasonFromString
  )
import Agent.Programs.SessionLog (encodeLogEvent)

sessionStartEvent
  :: { id :: SessionId
     , timestamp :: String
     , workspace :: String
     , model :: ModelName
     , resumedFrom :: Maybe SessionId
     }
  -> LogEvent
sessionStartEvent r = SessionStart (r { timestamp = Timestamp r.timestamp })

systemPromptEvent :: String -> String -> LogEvent
systemPromptEvent timestamp content =
  EvtSystemPrompt { timestamp: Timestamp timestamp, content }

userMessageEvent :: String -> String -> LogEvent
userMessageEvent timestamp content =
  EvtUserMessage { timestamp: Timestamp timestamp, content }

llmResponseEvent :: String -> String -> LogEvent
llmResponseEvent timestamp content =
  EvtLlmResponse { timestamp: Timestamp timestamp, content }

llmQueryEvent :: String -> String -> String -> LogEvent
llmQueryEvent timestamp purpose input =
  EvtLlmQuery { timestamp: Timestamp timestamp, purpose, input }

toolCallEvent :: String -> String -> ToolCallId -> String -> LogEvent
toolCallEvent timestamp toolName toolCallId input =
  EvtToolCall
    { timestamp: Timestamp timestamp
    , toolName: toolNameFromString toolName
    , toolCallId
    , input
    }

toolResultEvent :: String -> ToolCallId -> String -> Boolean -> LogEvent
toolResultEvent timestamp toolCallId output truncated =
  ToolResult { timestamp: Timestamp timestamp, toolCallId, output, truncated }

tokenUsageEvent :: String -> TokenCount -> TokenCount -> LogEvent
tokenUsageEvent timestamp inputTokens outputTokens = TokenUsage
  { timestamp: Timestamp timestamp
  , inputTokens
  , cachedInputTokens: TokenCount 0
  , outputTokens
  , totalSessionInputTokens: TokenCount 0
  , totalSessionCachedInputTokens: TokenCount 0
  , totalSessionOutputTokens: TokenCount 0
  }

compactionEvent
  :: { timestamp :: String
     , summary :: String
     , initialMessageCount :: Int
     , compactedMessageCount :: Int
     , finalMessageCount :: Int
     , totalTokensBefore :: Int
     }
  -> LogEvent
compactionEvent r = Compaction (r { timestamp = Timestamp r.timestamp })

sessionEndEvent :: String -> String -> LogEvent
sessionEndEvent timestamp reason =
  SessionEnd
    { timestamp: Timestamp timestamp
    , reason: sessionEndReasonFromString reason
    }

escapeEvent :: String -> LogEvent
escapeEvent timestamp = Escape { timestamp: Timestamp timestamp }

sigintEvent :: String -> LogEvent
sigintEvent timestamp = Sigint { timestamp: Timestamp timestamp }

timeoutCheckEvent :: String -> Int -> String -> LogEvent
timeoutCheckEvent timestamp elapsedSeconds partialOutput =
  TimeoutCheck
    { timestamp: Timestamp timestamp
    , elapsedSeconds
    , partialOutput
    }

timeoutResponseEvent :: String -> Boolean -> LogEvent
timeoutResponseEvent timestamp interrupt =
  TimeoutResponse { timestamp: Timestamp timestamp, interrupt }

-- | Render an array of log events as a JSONL string (one JSON object
-- per line), using the same encoding the runner uses for `log.jsonl`.
renderEvents :: Array LogEvent -> String
renderEvents events =
  String.joinWith "\n" (map encodeLogEvent events)
