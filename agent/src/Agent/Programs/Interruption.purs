module Agent.Programs.Interruption
    ( handleEscape
    , handleSigint
    , handleEof
    , InterruptResult
    ) where

import Prelude
import Data.Array as Array
import Agent.Types
    ( LoopState(..)
    , ControllerAction(..)
    , LogEvent(..)
    , ConversationHistory(..)
    , Message(..)
    , ToolCall
    , ToolCallId(..)
    , TokenCount(..)
    , SessionId
    )

type InterruptResult =
    { nextState :: LoopState
    , actions :: Array ControllerAction
    , logEvents :: Array LogEvent
    }

handleEscape :: LoopState -> InterruptResult
handleEscape state = case state of
    AwaitingLlm history partial ->
        let newMsg = AssistantMessage
                { content: partial.text
                , toolCalls: []
                }
            ConversationHistory h = history
            newHistory = ConversationHistory
                { messages: h.messages <>
                    [ { message: newMsg
                      , tokens: TokenCount 0
                      } ]
                }
        in  { nextState: AwaitingUser newHistory
            , actions: [CancelLlmRequest]
            , logEvents: [Escape { timestamp: "" }]
            }
    ExecutingTool history tc _partialOutput ->
        let action =
                if tc.name == "julia_repl"
                then InterruptJulia
                else InterruptHostProcess
        in  { nextState: AwaitingUser history
            , actions: [action]
            , logEvents: [Escape { timestamp: "" }]
            }
    AwaitingUser _ ->
        { nextState: state
        , actions: []
        , logEvents: []
        }

handleSigint :: LoopState -> SessionId -> InterruptResult
handleSigint state sid = case state of
    AwaitingLlm history partial ->
        let newMsg = AssistantMessage
                { content: partial.text
                , toolCalls: []
                }
            ConversationHistory h = history
            newHistory = ConversationHistory
                { messages: h.messages <>
                    [ { message: newMsg
                      , tokens: TokenCount 0
                      } ]
                }
        in  { nextState: AwaitingUser newHistory
            , actions:
                [ CancelLlmRequest
                , SerializeReplState sid
                , ExitRunner
                ]
            , logEvents:
                [ Sigint { timestamp: "" }
                , SessionEnd { timestamp: "", reason: "sigint" }
                ]
            }
    ExecutingTool history tc partialOutput ->
        let action =
                if tc.name == "julia_repl"
                then InterruptJulia
                else InterruptHostProcess
            toolResult = ToolResultMessage
                { toolCallId: tc.id
                , output: partialOutput <> "\n[interrupted]"
                }
            ConversationHistory h = history
            newHistory = ConversationHistory
                { messages: h.messages <>
                    [ { message: toolResult
                      , tokens: TokenCount 0
                      } ]
                }
        in  { nextState: AwaitingUser newHistory
            , actions:
                [ action
                , SerializeReplState sid
                , ExitRunner
                ]
            , logEvents:
                [ Sigint { timestamp: "" }
                , SessionEnd { timestamp: "", reason: "sigint" }
                ]
            }
    AwaitingUser _ ->
        { nextState: state
        , actions:
            [ SerializeReplState sid
            , ExitRunner
            ]
        , logEvents:
            [ Sigint { timestamp: "" }
            , SessionEnd { timestamp: "", reason: "sigint" }
            ]
        }

handleEof :: LoopState -> SessionId -> InterruptResult
handleEof = handleSigint
