-- | HTTP streaming LLM client (OpenAI-compatible chat completions API).
-- | Covers A7, A18.
module Agent.Services.Llm
    ( LlmUsage
    , CallLlmResult
    , callLlm
    ) where

import Prelude
import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Nullable (Nullable, toMaybe)
import Data.String as String
import Effect (Effect)
import Effect.Aff (Aff, Milliseconds(..), delay, makeAff, nonCanceler)
import Agent.Types
    ( Config
    , ConversationHistory(..)
    , Message(..)
    , ModelName(..)
    , ToolCall
    , ToolCallId(..)
    , TokenCount(..)
    , LlmResponse(..)
    , AppError(..)
    )
import Agent.Programs.Retry (ApiError(..), RetryDecision(..), retryDecision)
import Agent.Programs.ToolDefs (toolDefinitions)

-- | The raw result received from the LLM API.
type LlmResult =
    { content     :: String
    , toolCalls   :: Array { id :: String, name :: String, input :: String }
    , inputTokens :: Int
    , cachedInputTokens :: Int
    , outputTokens :: Int
    }

type StreamError =
    { statusCode :: Nullable Int
    , isTimeout :: Boolean
    , message :: String
    }

type LlmUsage =
    { inputTokens :: TokenCount
    , cachedInputTokens :: TokenCount
    , outputTokens :: TokenCount
    }

type CallLlmResult =
    { response :: LlmResponse
    , usage :: LlmUsage
    }

foreign import streamLlmImpl
    :: String
    -> String
    -> String
    -> Array Message
    -> Array { name :: String, description :: String
             , parameters :: Array { name :: String, description :: String, required :: Boolean } }
    -> (String -> Effect Unit)
    -> (StreamError -> Effect Unit)
    -> (LlmResult -> Effect Unit)
    -> Effect Unit

-- | Call the LLM with the current conversation history. Streams tokens via
-- | the terminal as they arrive, then resolves with the full LlmResponse.
callLlm
    :: Config
    -> String
    -> ConversationHistory
    -> (String -> Effect Unit)
    -> Aff (Either AppError CallLlmResult)
callLlm config apiKey (ConversationHistory h) onToken = go 0
  where
    messages = map _.message h.messages
    modelName = let (ModelName m) = config.model in m

    go attempt = do
        result <- runOnce
        case result of
            Right raw -> pure (Right
                { response: LlmResponse
                    { content: raw.content
                    , toolCalls: map toToolCall raw.toolCalls
                    , inputTokens: TokenCount raw.inputTokens
                    }
                , usage:
                    { inputTokens: TokenCount raw.inputTokens
                    , cachedInputTokens: TokenCount raw.cachedInputTokens
                    , outputTokens: TokenCount raw.outputTokens
                    }
                })
            Left err ->
                case classifyApiError err of
                    Just apiErr ->
                        case retryDecision apiErr attempt config.maxApiRetries of
                            Retry ms -> do
                                delay (Milliseconds (Int.toNumber ms))
                                go (attempt + 1)
                            GiveUp _ ->
                                pure (Left (ConfigFieldMissing ("LLM API: " <> err.message)))
                    Nothing ->
                        pure (Left (ConfigFieldMissing ("LLM API: " <> err.message)))

    runOnce = makeAff \resolve -> do
        streamLlmImpl
            config.apiEndpoint
            apiKey
            modelName
            messages
            toolDefinitions
            onToken
            (\err -> resolve (Right (Left err)))
            (\llmResult -> resolve (Right (Right llmResult)))
        pure nonCanceler

    toToolCall tc =
        { name: tc.name
        , input: tc.input
        , id: ToolCallId tc.id
        }

    classifyApiError err =
        case toMaybe err.statusCode of
            Just status -> Just (HttpStatus status)
            Nothing | err.isTimeout -> Just NetworkTimeout
            Nothing | looksLikeTimeout err.message -> Just NetworkTimeout
            Nothing -> Nothing

    looksLikeTimeout message =
        let lowered = String.toLower message
        in String.contains (String.Pattern "timeout") lowered
            || String.contains (String.Pattern "timed out") lowered
