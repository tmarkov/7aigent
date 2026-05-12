-- | Domain types for the 7aigent runner.
-- Every domain concept gets its own newtype to prevent accidental
-- substitution across module boundaries.
module Agent.Types
  ( WorkspacePath(..)
  , SessionId(..)
  , ModelName(..)
  , ToolCallId(..)
  , TokenCount(..)
  , HunkId(..)
  , RawJulia(..)
  , Port(..)
  , Config
  , ToolCall
  , CompactionPlan
  , LlmResponse(..)
  , Message(..)
  , ConversationHistory(..)
  , LogEvent(..)
  , AppError(..)
  , LoopState(..)
  , ControllerAction(..)
  , unwrapConversationHistory
  , extractContent
  , isToolResultMessage
  ) where

import Prelude

import Data.Maybe (Maybe)

-- ---------------------------------------------------------------------------
-- Newtypes
-- ---------------------------------------------------------------------------

newtype WorkspacePath = WorkspacePath String

newtype SessionId = SessionId Int

newtype ModelName = ModelName String

newtype ToolCallId = ToolCallId String

newtype TokenCount = TokenCount Int

newtype HunkId = HunkId String

newtype RawJulia = RawJulia String

newtype Port = Port Int

-- Eq / Ord / Show instances via newtype deriving

derive newtype instance Eq WorkspacePath
derive newtype instance Ord WorkspacePath
derive newtype instance Show WorkspacePath

derive newtype instance Eq SessionId
derive newtype instance Ord SessionId
derive newtype instance Show SessionId

derive newtype instance Eq ModelName
derive newtype instance Ord ModelName
derive newtype instance Show ModelName

derive newtype instance Eq ToolCallId
derive newtype instance Ord ToolCallId
derive newtype instance Show ToolCallId

derive newtype instance Eq TokenCount
derive newtype instance Ord TokenCount
derive newtype instance Show TokenCount

derive newtype instance Eq HunkId
derive newtype instance Ord HunkId
derive newtype instance Show HunkId

derive newtype instance Eq RawJulia
derive newtype instance Show RawJulia

derive newtype instance Eq Port
derive newtype instance Show Port

-- ---------------------------------------------------------------------------
-- Type aliases
-- ---------------------------------------------------------------------------

-- | Runner configuration parsed from `.7aigent/config.toml`.
type Config =
  { apiEndpoint :: String
  , model :: ModelName
  , apiKeyEnv :: String
  , outputThresholdChars :: Int
  , maxApiRetries :: Int
  , maxTokensPerTurn :: TokenCount
  , compactionThreshold :: TokenCount
  , preserveInitial :: TokenCount
  , preserveFinal :: TokenCount
  }

-- | A tool call issued by the LLM within a conversation turn.
type ToolCall =
  { name :: String
  , input :: String
  , id :: ToolCallId
  }

-- | The three message-groups identified by the compaction algorithm.
type CompactionPlan =
  { initialBlock :: Array Message
  , compactedBlock :: Array Message
  , finalBlock :: Array Message
  }

-- ---------------------------------------------------------------------------
-- ADTs
-- ---------------------------------------------------------------------------

-- | An LLM API response containing optional text, tool calls, and
-- token usage metadata.
newtype LlmResponse = LlmResponse
  { content :: String
  , toolCalls :: Array ToolCall
  , inputTokens :: TokenCount
  }

derive instance Eq LlmResponse
instance Show LlmResponse where
  show (LlmResponse r) =
    "(LlmResponse { content: " <> show r.content
    <> ", toolCalls: " <> show (map _.name r.toolCalls)
    <> ", inputTokens: " <> show r.inputTokens <> " })"

-- | A single message in the conversation history.
data Message
  = SystemMessage { content :: String }
  | UserMessage { content :: String }
  | AssistantMessage { content :: String, toolCalls :: Array ToolCall }
  | ToolResultMessage { toolCallId :: ToolCallId, output :: String }

instance Show Message where
  show (SystemMessage r) = "(SystemMessage " <> show r.content <> ")"
  show (UserMessage r) = "(UserMessage " <> show r.content <> ")"
  show (AssistantMessage r) =
    "(AssistantMessage " <> show r.content <> ")"
  show (ToolResultMessage r) =
    "(ToolResultMessage " <> show r.toolCallId
    <> " " <> show r.output <> ")"

-- | The full conversation history with per-message token counts.
newtype ConversationHistory = ConversationHistory
  { messages :: Array { message :: Message, tokens :: TokenCount } }

instance Show ConversationHistory where
  show (ConversationHistory h) =
    "(ConversationHistory [" <> show (map (_.message) h.messages) <> "])"

-- | Structured events written to the session log (log.jsonl).
data LogEvent
  = SessionStart
      { id :: SessionId
      , timestamp :: String
      , workspace :: String
      , model :: ModelName
      , resumedFrom :: Maybe SessionId
      }
  | EvtUserMessage { timestamp :: String, content :: String }
  | EvtLlmResponse { timestamp :: String, content :: String }
  | EvtToolCall
      { timestamp :: String
      , toolName :: String
      , toolCallId :: ToolCallId
      , input :: String
      }
  | ToolResult
      { timestamp :: String
      , toolCallId :: ToolCallId
      , output :: String
      , truncated :: Boolean
      }
  | TokenUsage
      { timestamp :: String
      , inputTokens :: TokenCount
      , cachedInputTokens :: TokenCount
      , outputTokens :: TokenCount
      , totalSessionInputTokens :: TokenCount
      , totalSessionCachedInputTokens :: TokenCount
      , totalSessionOutputTokens :: TokenCount
      }
  | Compaction
      { timestamp :: String
      , summary :: String
      , initialMessageCount :: Int
      , compactedMessageCount :: Int
      , finalMessageCount :: Int
      , totalTokensBefore :: Int
      }
  | SessionEnd { timestamp :: String, reason :: String }
  | Escape { timestamp :: String }
  | Sigint { timestamp :: String }
  | TimeoutCheck
      { timestamp :: String
      , elapsedSeconds :: Int
      , partialOutput :: String
      }
  | TimeoutResponse { timestamp :: String, interrupt :: Boolean }

instance Show LogEvent where
  show (SessionStart r) = "(SessionStart " <> show r.id <> ")"
  show (EvtUserMessage r) = "(UserMessage " <> show r.content <> ")"
  show (EvtLlmResponse r) = "(LlmResponse " <> show r.content <> ")"
  show (EvtToolCall r) = "(ToolCall " <> show r.toolName <> ")"
  show (ToolResult r) = "(ToolResult " <> show r.toolCallId <> ")"
  show (TokenUsage _) = "(TokenUsage)"
  show (Compaction r) = "(Compaction " <> show r.summary <> ")"
  show (SessionEnd r) = "(SessionEnd " <> show r.reason <> ")"
  show (Escape r) = "(Escape " <> show r.timestamp <> ")"
  show (Sigint r) = "(Sigint " <> show r.timestamp <> ")"
  show (TimeoutCheck r) =
    "(TimeoutCheck " <> show r.elapsedSeconds <> ")"
  show (TimeoutResponse r) =
    "(TimeoutResponse " <> show r.interrupt <> ")"

-- | Errors that can occur during runner operation.
data AppError
  = ConfigFieldMissing String
  | PlaceholderValue String
  | StartupExpressionError String
  | SandboxLaunchError String
  | SandboxCrashed
  | StaleHunkIds (Array HunkId)
  | TemplateError String
  | CompactionError String
  | SessionResumeError String
  | DecodeError String

instance Show AppError where
  show (ConfigFieldMissing s) = "ConfigFieldMissing: " <> s
  show (PlaceholderValue s) = "Placeholder value detected: " <> s
  show (StartupExpressionError s) = "StartupExpressionError: " <> s
  show (SandboxLaunchError s) = "SandboxLaunchError: " <> s
  show SandboxCrashed = "SandboxCrashed"
  show (StaleHunkIds ids) = "StaleHunkIds: " <> show ids
  show (TemplateError s) = "TemplateError: " <> s
  show (CompactionError s) = "CompactionError: " <> s
  show (SessionResumeError s) = "SessionResumeError: " <> s
  show (DecodeError s) = "DecodeError: " <> s

-- | The current state of the ReACT loop, as seen by the controller.
data LoopState
  = AwaitingLlm ConversationHistory
      { text :: String, toolCalls :: Array ToolCall }
  | ExecutingTool ConversationHistory ToolCall String
  | AwaitingUser ConversationHistory

instance Show LoopState where
  show (AwaitingLlm _ p) =
    "(AwaitingLlm { text: " <> show p.text <> " })"
  show (ExecutingTool _ tc _) =
    "(ExecutingTool " <> show tc.name <> ")"
  show (AwaitingUser _) = "(AwaitingUser)"

-- | Actions the controller must execute in response to an event.
data ControllerAction
  = CancelLlmRequest
  | InterruptJulia
  | InterruptHostProcess
  | ExitRunner
  | SerializeReplState SessionId

derive instance Eq ControllerAction
instance Show ControllerAction where
  show CancelLlmRequest = "CancelLlmRequest"
  show InterruptJulia = "InterruptJulia"
  show InterruptHostProcess = "InterruptHostProcess"
  show ExitRunner = "ExitRunner"
  show (SerializeReplState sid) =
    "(SerializeReplState " <> show sid <> ")"

-- ---------------------------------------------------------------------------
-- Utility functions
-- ---------------------------------------------------------------------------

-- | Unwrap a ConversationHistory to its message array.
unwrapConversationHistory
  :: ConversationHistory
  -> Array { message :: Message, tokens :: TokenCount }
unwrapConversationHistory (ConversationHistory h) = h.messages

-- | Extract the textual content from any Message variant.
extractContent :: Message -> String
extractContent (SystemMessage r) = r.content
extractContent (UserMessage r) = r.content
extractContent (AssistantMessage r) = r.content
extractContent (ToolResultMessage r) = r.output

-- | Test whether a Message is a ToolResultMessage.
isToolResultMessage :: Message -> Boolean
isToolResultMessage (ToolResultMessage _) = true
isToolResultMessage _ = false
