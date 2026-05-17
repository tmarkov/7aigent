module Agent.Programs.ReactStep
    ( reactStep
    , NextStep(..)
    ) where

import Prelude
import Data.Array as Array
import Data.Maybe (Maybe(..))
import Agent.Types
    ( Config
    , TokenCount(..)
    , ConversationHistory(..)
    , LlmResponse(..)
    , ToolCall
    )

data NextStep
    = ExecuteTool ToolCall
    | PromptUser
    | CompactThenPromptUser
    | ExecuteToolThenCompact ToolCall
    | ExecuteToolThenEndTurn ToolCall

instance Show NextStep where
    show (ExecuteTool tc) =
        "(ExecuteTool " <> show tc.name <> ")"
    show PromptUser = "PromptUser"
    show CompactThenPromptUser =
        "CompactThenPromptUser"
    show (ExecuteToolThenCompact tc) =
        "(ExecuteToolThenCompact "
        <> show tc.name <> ")"
    show (ExecuteToolThenEndTurn tc) =
        "(ExecuteToolThenEndTurn "
        <> show tc.name <> ")"

reactStep
    :: Config
    -> TokenCount
    -> ConversationHistory
    -> LlmResponse
    -> NextStep
reactStep config (TokenCount accumulatedTurnTokens) _history
    (LlmResponse resp) =
    let TokenCount compactThresh =
            config.compactionThreshold
        TokenCount maxPerTurn =
            config.maxTokensPerTurn
        TokenCount preserveInit =
            config.preserveInitial
        TokenCount preserveFin =
            config.preserveFinal
        TokenCount currentRequestTokens =
            resp.inputTokens
        -- Can only compact if there are enough tokens beyond the
        -- preserved initial and final blocks
        canCompact =
            currentRequestTokens > preserveInit + preserveFin
    in  case Array.head resp.toolCalls of
            Just tc ->
                if currentRequestTokens > compactThresh
                then ExecuteToolThenCompact tc
                else if accumulatedTurnTokens > maxPerTurn
                then ExecuteToolThenEndTurn tc
                else ExecuteTool tc
            Nothing ->
                if currentRequestTokens > compactThresh
                    && canCompact
                then CompactThenPromptUser
                else PromptUser
