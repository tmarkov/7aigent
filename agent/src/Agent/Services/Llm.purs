-- | HTTP streaming LLM client (OpenAI-compatible chat completions API).
-- | Covers A7, A18.
module Agent.Services.Llm
    ( LlmResult
    , callLlm
    ) where

import Prelude
import Data.Either (Either(..))
import Effect (Effect)
import Effect.Aff (Aff, makeAff, nonCanceler)
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
import Agent.Programs.ToolDefs (toolDefinitions)

-- | The raw result received from the LLM API.
type LlmResult =
    { content     :: String
    , toolCalls   :: Array { id :: String, name :: String, input :: String }
    , inputTokens :: Int
    }

foreign import streamLlmImpl
    :: String
    -> String
    -> String
    -> Array Message
    -> Array { name :: String, description :: String
             , parameters :: Array { name :: String, description :: String, required :: Boolean } }
    -> (String -> Effect Unit)
    -> (String -> Effect Unit)
    -> (LlmResult -> Effect Unit)
    -> Effect Unit

-- | Call the LLM with the current conversation history. Streams tokens via
-- | the terminal as they arrive, then resolves with the full LlmResponse.
callLlm
    :: Config
    -> String
    -> ConversationHistory
    -> (String -> Effect Unit)
    -> Aff (Either AppError LlmResponse)
callLlm config apiKey (ConversationHistory h) onToken = makeAff \resolve -> do
    let messages = map _.message h.messages
    streamLlmImpl
        config.apiEndpoint
        apiKey
        (let (ModelName m) = config.model in m)
        messages
        toolDefinitions
        onToken
        (\errMsg -> resolve (Right (Left (ConfigFieldMissing ("LLM API: " <> errMsg)))))
        (\result -> resolve (Right (Right (LlmResponse
            { content: result.content
            , toolCalls: map toToolCall result.toolCalls
            , inputTokens: TokenCount result.inputTokens
            }))))
    pure nonCanceler
  where
    toToolCall tc =
        { name: tc.name
        , input: tc.input
        , id: ToolCallId tc.id
        }
