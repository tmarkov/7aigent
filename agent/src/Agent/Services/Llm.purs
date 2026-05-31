-- | HTTP streaming LLM client (OpenAI-compatible chat completions API).
-- | Covers A7, A18.
module Agent.Services.Llm
    ( LlmUsage
    , CallLlmResult
    , callLlm
    , callLlmJson
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
    ( ApiEndpoint(..)
    , Config
    , ConversationHistory(..)
    , Message(..)
    , ModelName(..)
    , ToolCall
    , ToolName
    , ToolCallId(..)
    , TokenCount(..)
    , LlmResponse(..)
    , AppError(..)
    , renderToolName
    , toolNameFromString
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

foreign import callJsonLlmImpl
    :: String
    -> String
    -> String
    -> Array Message
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
                let apiErr = classifyApiError err
                in case retryDecision apiErr attempt config.maxApiRetries of
                    Retry ms -> do
                        delay (Milliseconds (Int.toNumber ms))
                        go (attempt + 1)
                    GiveUp _ ->
                        pure (Left (LlmApiError err.message))

    runOnce = makeAff \resolve -> do
        let ApiEndpoint endpoint = config.apiEndpoint
        streamLlmImpl
            endpoint
            apiKey
            modelName
            messages
            (map renderToolDef toolDefinitions)
            onToken
            (\err -> resolve (Right (Left err)))
            (\llmResult -> resolve (Right (Right llmResult)))
        pure nonCanceler

    renderToolDef td =
        { name: renderToolName td.name
        , description: td.description
        , parameters: td.parameters
        }

    toToolCall tc =
        { name: toolNameFromString tc.name
        , input: tc.input
        , id: ToolCallId tc.id
        }

    classifyApiError err =
        case toMaybe err.statusCode of
            Just status -> HttpStatus status
            Nothing | err.isTimeout -> NetworkTimeout
            Nothing | looksLikeTimeout err.message -> NetworkTimeout
            Nothing -> NetworkError

    looksLikeTimeout message =
        let lowered = String.toLower message
        in String.contains (String.Pattern "timeout") lowered
            || String.contains (String.Pattern "timed out") lowered

-- | Call the LLM without tools, requesting a JSON-object response.
-- | Used for reflection calls (A49). Does not stream tokens to the caller.
callLlmJson
    :: Config
    -> String
    -> ConversationHistory
    -> Aff (Either AppError CallLlmResult)
callLlmJson config apiKey (ConversationHistory h) = go 0
  where
    messages = map _.message h.messages
    modelName = let (ModelName m) = config.model in m

    go attempt = do
        result <- runOnce
        case result of
            Right raw -> pure (Right
                { response: LlmResponse
                    { content: raw.content
                    , toolCalls: []
                    , inputTokens: TokenCount raw.inputTokens
                    }
                , usage:
                    { inputTokens: TokenCount raw.inputTokens
                    , cachedInputTokens: TokenCount raw.cachedInputTokens
                    , outputTokens: TokenCount raw.outputTokens
                    }
                })
            Left err ->
                let apiErr = classifyApiError err
                in case retryDecision apiErr attempt config.maxApiRetries of
                    Retry ms -> do
                        delay (Milliseconds (Int.toNumber ms))
                        go (attempt + 1)
                    GiveUp _ ->
                        pure (Left (LlmApiError err.message))

    runOnce = makeAff \resolve -> do
        let ApiEndpoint endpoint = config.apiEndpoint
        callJsonLlmImpl
            endpoint
            apiKey
            modelName
            messages
            (\err -> resolve (Right (Left err)))
            (\llmResult -> resolve (Right (Right llmResult)))
        pure nonCanceler

    classifyApiError err =
        case toMaybe err.statusCode of
            Just status -> HttpStatus status
            Nothing | err.isTimeout -> NetworkTimeout
            Nothing | looksLikeTimeout' err.message -> NetworkTimeout
            Nothing -> NetworkError

    looksLikeTimeout' message =
        let lowered = String.toLower message
        in String.contains (String.Pattern "timeout") lowered
            || String.contains (String.Pattern "timed out") lowered
