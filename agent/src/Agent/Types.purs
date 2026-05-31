-- | Domain types for the 7aigent runner.
-- Every domain concept gets its own newtype to prevent accidental
-- substitution across module boundaries.
module Agent.Types
  ( WorkspacePath(..)
  , SessionId(..)
  , ModelName(..)
  , ApiEndpoint(..)
  , EnvVarName(..)
  , Timestamp(..)
  , ToolName(..)
  , ToolCallId(..)
  , TokenCount(..)
  , HunkId(..)
  , RawJulia(..)
  , Port(..)
  , SessionEndReason(..)
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
  , renderTimestamp
  , renderToolName
  , toolNameFromString
  , renderSessionEndReason
  , sessionEndReasonFromString
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

newtype ApiEndpoint = ApiEndpoint String

newtype EnvVarName = EnvVarName String

newtype Timestamp = Timestamp String

data ToolName
  = JuliaRepl
  | GitStage
  | GitCommit
  | UnknownToolName String

newtype ToolCallId = ToolCallId String

newtype TokenCount = TokenCount Int

newtype HunkId = HunkId String

newtype RawJulia = RawJulia String

newtype Port = Port Int

data SessionEndReason
  = SessionEndedEof
  | SessionEndedSigint
  | SessionEndedError
  | SessionEndedPrompt
  | SessionEndedOther String

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

derive newtype instance Eq ApiEndpoint
derive newtype instance Ord ApiEndpoint
derive newtype instance Show ApiEndpoint

derive newtype instance Eq EnvVarName
derive newtype instance Ord EnvVarName
derive newtype instance Show EnvVarName

derive newtype instance Eq Timestamp
derive newtype instance Ord Timestamp
derive newtype instance Show Timestamp

derive instance Eq ToolName
derive instance Ord ToolName
instance Show ToolName where
  show = renderToolName

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

derive instance Eq SessionEndReason
derive instance Ord SessionEndReason
instance Show SessionEndReason where
  show = renderSessionEndReason

-- ---------------------------------------------------------------------------
-- Type aliases
-- ---------------------------------------------------------------------------

-- | Runner configuration parsed from `.7aigent/config.toml`.
type Config =
  { apiEndpoint :: ApiEndpoint
  , model :: ModelName
  , apiKeyEnv :: EnvVarName
  , outputThresholdChars :: Int
  , maxApiRetries :: Int
  , maxTokensPerTurn :: TokenCount
  , compactionThreshold :: TokenCount
  , preserveInitial :: TokenCount
  , preserveFinal :: TokenCount
  , maxTurnsPerRound :: Int
  , timeoutCheckSeconds :: Array Int
  , progressIntervalSeconds :: Int
  }

-- | A tool call issued by the LLM within a conversation turn.
type ToolCall =
  { name :: ToolName
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
    <> ", toolCalls: " <> show (map renderToolName (map _.name r.toolCalls))
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
      , timestamp :: Timestamp
      , workspace :: String
      , model :: ModelName
      , resumedFrom :: Maybe SessionId
      }
  | EvtSystemPrompt { timestamp :: Timestamp, content :: String }
  | EvtUserMessage { timestamp :: Timestamp, content :: String, source :: Maybe String }
  | EvtLlmResponse { timestamp :: Timestamp, content :: String }
  | EvtLlmQuery
      { timestamp :: Timestamp
      , purpose :: String
      , input :: String
      }
  | EvtToolCall
      { timestamp :: Timestamp
      , toolName :: ToolName
      , toolCallId :: ToolCallId
      , input :: String
      }
  | ToolResult
      { timestamp :: Timestamp
      , toolCallId :: ToolCallId
      , output :: String
      , truncated :: Boolean
      }
  | TokenUsage
      { timestamp :: Timestamp
      , inputTokens :: TokenCount
      , cachedInputTokens :: TokenCount
      , outputTokens :: TokenCount
      , totalSessionInputTokens :: TokenCount
      , totalSessionCachedInputTokens :: TokenCount
      , totalSessionOutputTokens :: TokenCount
      }
  | Compaction
      { timestamp :: Timestamp
      , summary :: String
      , initialMessageCount :: Int
      , compactedMessageCount :: Int
      , finalMessageCount :: Int
      , totalTokensBefore :: Int
      }
  | SessionEnd { timestamp :: Timestamp, reason :: SessionEndReason }
  | Escape { timestamp :: Timestamp }
  | Sigint { timestamp :: Timestamp }
  | TimeoutCheck
      { timestamp :: Timestamp
      , elapsedSeconds :: Int
      , partialOutput :: String
      }
  | TimeoutResponse { timestamp :: Timestamp, interrupt :: Boolean }
  | EvtReflection
      { timestamp :: Timestamp
      , turnIndex :: Int
      , autoTurnsTaken :: Int
      , complete :: Boolean
      , feedback :: Maybe String
      }

instance Show LogEvent where
  show (SessionStart r) = "(SessionStart " <> show r.id <> ")"
  show (EvtSystemPrompt r) = "(SystemPrompt " <> show r.content <> ")"
  show (EvtUserMessage r) = "(UserMessage " <> show r.content <> ")"
  show (EvtLlmResponse r) = "(LlmResponse " <> show r.content <> ")"
  show (EvtLlmQuery r) = "(LlmQuery " <> show r.purpose <> ")"
  show (EvtToolCall r) = "(ToolCall " <> renderToolName r.toolName <> ")"
  show (ToolResult r) = "(ToolResult " <> show r.toolCallId <> ")"
  show (TokenUsage _) = "(TokenUsage)"
  show (Compaction r) = "(Compaction " <> show r.summary <> ")"
  show (SessionEnd r) = "(SessionEnd " <> renderSessionEndReason r.reason <> ")"
  show (Escape r) = "(Escape " <> renderTimestamp r.timestamp <> ")"
  show (Sigint r) = "(Sigint " <> renderTimestamp r.timestamp <> ")"
  show (TimeoutCheck r) =
    "(TimeoutCheck " <> show r.elapsedSeconds <> ")"
  show (TimeoutResponse r) =
    "(TimeoutResponse " <> show r.interrupt <> ")"
  show (EvtReflection r) =
    "(EvtReflection turn=" <> show r.turnIndex <> " complete=" <> show r.complete <> ")"

-- | Errors that can occur during runner operation.
data AppError
  = ConfigError String
  | PlaceholderValue String
  | StartupExpressionError String
  | SandboxLaunchError String
  | KernelError String
  | LlmApiError String
  | GitError String
  | SandboxCrashed
  | StaleHunkIds (Array HunkId)
  | TemplateError String
  | CompactionError String
  | SessionResumeError String
  | JsonDecodeError String

instance Show AppError where
  show (ConfigError s) = "ConfigError: " <> s
  show (PlaceholderValue s) = "Placeholder value detected: " <> s
  show (StartupExpressionError s) = "StartupExpressionError: " <> s
  show (SandboxLaunchError s) = "SandboxLaunchError: " <> s
  show (KernelError s) = "KernelError: " <> s
  show (LlmApiError s) = "LlmApiError: " <> s
  show (GitError s) = "GitError: " <> s
  show SandboxCrashed = "SandboxCrashed"
  show (StaleHunkIds ids) = "StaleHunkIds: " <> show ids
  show (TemplateError s) = "TemplateError: " <> s
  show (CompactionError s) = "CompactionError: " <> s
  show (SessionResumeError s) = "SessionResumeError: " <> s
  show (JsonDecodeError s) = "JsonDecodeError: " <> s

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
    "(ExecutingTool " <> renderToolName tc.name <> ")"
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

renderTimestamp :: Timestamp -> String
renderTimestamp (Timestamp timestamp) = timestamp

renderToolName :: ToolName -> String
renderToolName JuliaRepl = "julia_repl"
renderToolName GitStage = "git_stage"
renderToolName GitCommit = "git_commit"
renderToolName (UnknownToolName name) = name

toolNameFromString :: String -> ToolName
toolNameFromString "julia_repl" = JuliaRepl
toolNameFromString "git_stage" = GitStage
toolNameFromString "git_commit" = GitCommit
toolNameFromString other = UnknownToolName other

renderSessionEndReason :: SessionEndReason -> String
renderSessionEndReason SessionEndedEof = "eof"
renderSessionEndReason SessionEndedSigint = "sigint"
renderSessionEndReason SessionEndedError = "error"
renderSessionEndReason SessionEndedPrompt = "prompt"
renderSessionEndReason (SessionEndedOther reason) = reason

sessionEndReasonFromString :: String -> SessionEndReason
sessionEndReasonFromString "eof" = SessionEndedEof
sessionEndReasonFromString "sigint" = SessionEndedSigint
sessionEndReasonFromString "error" = SessionEndedError
sessionEndReasonFromString "prompt" = SessionEndedPrompt
sessionEndReasonFromString other = SessionEndedOther other

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
