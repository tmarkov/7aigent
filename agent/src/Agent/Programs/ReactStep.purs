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
    , ToolCallId(..)
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
reactStep config (TokenCount accumulated) _history
    (LlmResponse resp) =
    let TokenCount compactThresh =
            config.compactionThreshold
        TokenCount maxPerTurn =
            config.maxTokensPerTurn
        TokenCount preserveInit =
            config.preserveInitial
        TokenCount preserveFin =
            config.preserveFinal
        hasToolCalls =
            not (Array.null resp.toolCalls)
        -- Can only compact if there are enough tokens beyond the
        -- preserved initial and final blocks
        canCompact =
            accumulated > preserveInit + preserveFin
    in  if hasToolCalls
        then
            let tc = unsafeFirstToolCall resp.toolCalls
            in  if accumulated > compactThresh
                then ExecuteToolThenCompact tc
                else if accumulated > maxPerTurn
                then ExecuteToolThenEndTurn tc
                else ExecuteTool tc
        else
            -- Text-only: only compact if there are enough tokens
            -- beyond preserved initial+final blocks
            if accumulated > compactThresh
                && canCompact
            then CompactThenPromptUser
            else PromptUser

unsafeFirstToolCall :: Array ToolCall -> ToolCall
unsafeFirstToolCall tcs = case Array.head tcs of
    Nothing -> { name: "", input: ""
               , id: ToolCallId "" }
    Just tc -> tc
