-- | HTTP streaming LLM client (OpenAI-compatible chat completions API).
-- | Covers A7, A18.
module Agent.Services.Llm
    ( LlmUsage
    , CallLlmResult
    , LlmCallOptions
    , LlmResponseFormat(..)
    , LlmRetryMode(..)
    , callLlm
    , setLlmRequestLogPath
    , writeLlmRequestLogEntry
    ) where

import Prelude

import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Nullable (Nullable, toMaybe)
import Data.String as String
import Effect (Effect)
import Effect.Aff
    ( Aff
    , Milliseconds(..)
    , delay
    , effectCanceler
    , makeAff
    )

import Agent.Programs.Retry (ApiError(..), RetryDecision(..), retryDecision)
import Agent.Programs.ToolDefs (toolDefinitions)
import Agent.Types
    ( ApiEndpoint(..)
    , AppError(..)
    , Config
    , ConversationHistory(..)
    , LlmResponse(..)
    , Message
    , ModelName(..)
    , TokenCount(..)
    , ToolCallId(..)
    , renderToolName
    , toolNameFromString
    )

type LlmResult =
    { content :: String
    , toolCalls :: Array { id :: String, name :: String, input :: String }
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

data LlmResponseFormat
    = TextResponse
    | JsonObjectResponse

derive instance Eq LlmResponseFormat

data LlmRetryMode
    = RetryApiErrors
    | SingleApiAttempt

derive instance Eq LlmRetryMode

type LlmCallOptions =
    { responseFormat :: LlmResponseFormat
    , toolsEnabled :: Boolean
    , retryMode :: LlmRetryMode
    , onToken :: String -> Effect Unit
    }

foreign import streamLlmImpl
    :: String
    -> String
    -> String
    -> Array Message
    -> Array
        { name :: String
        , description :: String
        , parameters ::
            Array
                { name :: String
                , schemaType :: String
                , description :: String
                , required :: Boolean
                }
        }
    -> (String -> Effect Unit)
    -> (StreamError -> Effect Unit)
    -> (LlmResult -> Effect Unit)
    -> Effect (Effect Unit)

foreign import callJsonLlmImpl
    :: String
    -> String
    -> String
    -> Array Message
    -> (StreamError -> Effect Unit)
    -> (LlmResult -> Effect Unit)
    -> Effect (Effect Unit)

foreign import setLlmRequestLogPath :: String -> Effect Unit

foreign import writeLlmRequestLogEntry :: String -> Effect Unit

callLlm
    :: Config
    -> String
    -> ConversationHistory
    -> LlmCallOptions
    -> Aff (Either AppError CallLlmResult)
callLlm config apiKey (ConversationHistory history) options =
    go 0
  where
    messages = map _.message history.messages
    modelName = let (ModelName name) = config.model in name

    go attempt = do
        result <- runOnce
        case result of
            Right raw ->
                pure (Right (toCallResult raw))
            Left err | options.retryMode == SingleApiAttempt ->
                pure (Left (LlmApiError err.message))
            Left err ->
                case retryDecision
                    (classifyApiError err)
                    attempt
                    config.maxApiRetries of
                    Retry milliseconds -> do
                        delay (Milliseconds (Int.toNumber milliseconds))
                        go (attempt + 1)
                    GiveUp _ ->
                        pure (Left (LlmApiError err.message))

    runOnce = makeAff \resolve -> do
        let ApiEndpoint endpoint = config.apiEndpoint
        cancelRequest <- case options.responseFormat of
            TextResponse ->
                streamLlmImpl
                    endpoint
                    apiKey
                    modelName
                    messages
                    (if options.toolsEnabled
                        then map renderToolDef toolDefinitions
                        else [])
                    options.onToken
                    (\err -> resolve (Right (Left err)))
                    (\result -> resolve (Right (Right result)))
            JsonObjectResponse ->
                callJsonLlmImpl
                    endpoint
                    apiKey
                    modelName
                    messages
                    (\err -> resolve (Right (Left err)))
                    (\result -> resolve (Right (Right result)))
        pure (effectCanceler cancelRequest)

    toCallResult raw =
        { response: LlmResponse
            { content: raw.content
            , toolCalls:
                if options.toolsEnabled
                    then map toToolCall raw.toolCalls
                    else []
            , inputTokens: TokenCount raw.inputTokens
            }
        , usage:
            { inputTokens: TokenCount raw.inputTokens
            , cachedInputTokens: TokenCount raw.cachedInputTokens
            , outputTokens: TokenCount raw.outputTokens
            }
        }

    renderToolDef definition =
        { name: renderToolName definition.name
        , description: definition.description
        , parameters: definition.parameters
        }

    toToolCall toolCall =
        { name: toolNameFromString toolCall.name
        , input: toolCall.input
        , id: ToolCallId toolCall.id
        }

classifyApiError :: StreamError -> ApiError
classifyApiError err =
    case toMaybe err.statusCode of
        Just status -> HttpStatus status
        Nothing | err.isTimeout -> NetworkTimeout
        Nothing | looksLikeTimeout err.message -> NetworkTimeout
        Nothing -> NetworkError

looksLikeTimeout :: String -> Boolean
looksLikeTimeout message =
    let lowered = String.toLower message
    in String.contains (String.Pattern "timeout") lowered
        || String.contains (String.Pattern "timed out") lowered
