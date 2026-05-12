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
    , Timestamp(..)
    , ConversationHistory(..)
    , Message(..)
    , ToolCall
    , ToolName(..)
    , SessionEndReason(..)
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
            , logEvents: [Escape { timestamp: Timestamp "" }]
            }
    ExecutingTool history tc _partialOutput ->
        let action =
                if tc.name == JuliaRepl
                then InterruptJulia
                else InterruptHostProcess
        in  { nextState: AwaitingUser history
            , actions: [action]
            , logEvents: [Escape { timestamp: Timestamp "" }]
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
                [ Sigint { timestamp: Timestamp "" }
                , SessionEnd
                    { timestamp: Timestamp ""
                    , reason: SessionEndedSigint
                    }
                ]
            }
    ExecutingTool history tc partialOutput ->
        let action =
                if tc.name == JuliaRepl
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
                [ Sigint { timestamp: Timestamp "" }
                , SessionEnd
                    { timestamp: Timestamp ""
                    , reason: SessionEndedSigint
                    }
                ]
            }
    AwaitingUser _ ->
        { nextState: state
        , actions:
            [ SerializeReplState sid
            , ExitRunner
            ]
        , logEvents:
            [ Sigint { timestamp: Timestamp "" }
            , SessionEnd
                { timestamp: Timestamp ""
                , reason: SessionEndedSigint
                }
            ]
        }

handleEof :: LoopState -> SessionId -> InterruptResult
handleEof = handleSigint
