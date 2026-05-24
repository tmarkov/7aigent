-- | Pure round orchestration logic: A48 round lifecycle, A49 reflection
-- | call construction.
-- |
-- | Extracted from Runner.Session so that the decision logic around rounds
-- | (when to continue, when to stop, how to inject feedback) is testable
-- | without mock services.
module Agent.Programs.RoundStep
    ( RoundDecision(..)
    , roundDecision
    , buildReflectionHistory
    ) where

import Prelude

import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.Tuple (Tuple(..))
import Agent.Types
    ( Config
    , ConversationHistory(..)
    , Message(..)
    , TokenCount(..)
    , extractContent
    )
import Agent.Programs.Reflection (ReflectionResult)
import Agent.Programs.Template (substituteTemplate)

-- | The outcome of a round step: after a turn completes and reflection
-- | returns a result, what should the round do next?
data RoundDecision
    = EndRound
    | ContinueWithFeedback String

derive instance Eq RoundDecision
instance Show RoundDecision where
    show EndRound = "EndRound"
    show (ContinueWithFeedback fb) =
        "(ContinueWithFeedback " <> show fb <> ")"

-- | Decide the next round action after a reflection result (A48).
-- |
-- | - If reflection says `complete: true` → EndRound
-- | - If `turnIndex >= maxTurnsPerRound` → EndRound (regardless of reflection)
-- | - Otherwise → ContinueWithFeedback (the feedback text to inject)
roundDecision
    :: Config
    -> Int         -- ^ turnIndex (1-based, the turn that just completed)
    -> ReflectionResult
    -> RoundDecision
roundDecision config turnIndex reflResult
    | reflResult.complete = EndRound
    | turnIndex >= config.maxTurnsPerRound = EndRound
    | otherwise =
        let feedbackMsg = case reflResult.feedback of
                Nothing -> "[Reflection: continue]"
                Just fb -> fb
        in ContinueWithFeedback feedbackMsg

-- | Build the conversation history to send for a reflection LLM call (A49).
-- |
-- | The reflection prompt is appended as a user message to the history,
-- | but this augmented history is ONLY used for the reflection call —
-- | it must NOT be persisted to the main ConversationHistory.
-- |
-- | Returns the augmented history for the call. The caller is responsible
-- | for NOT using this as the ongoing conversation state.
buildReflectionHistory
    :: String  -- ^ reflection template (raw, with {{keyword}} placeholders)
    -> Int     -- ^ turn_index
    -> Int     -- ^ auto_turns_taken
    -> Int     -- ^ max_turns_per_round (from config)
    -> String  -- ^ julia_state (resolved)
    -> ConversationHistory  -- ^ current history (NOT modified)
    -> ConversationHistory  -- ^ augmented history for the reflection call only
buildReflectionHistory template turnIndex autoTurnsTaken maxTurnsPerRound juliaState history =
    let vars = Map.fromFoldable
            [ Tuple "turn_index"          (show turnIndex)
            , Tuple "auto_turns_taken"    (show autoTurnsTaken)
            , Tuple "max_turns_per_round" (show maxTurnsPerRound)
            , Tuple "julia_state"         juliaState
            ]
        prompt = case substituteTemplate vars template of
            Left  _ -> template
            Right p -> p
    in addMsg history (UserMessage { content: prompt })

addMsg :: ConversationHistory -> Message -> ConversationHistory
addMsg (ConversationHistory h) msg =
    ConversationHistory
        { messages: h.messages <>
            [{ message: msg, tokens: estimateTokens (extractContent msg) }]
        }

estimateTokens :: String -> TokenCount
estimateTokens s = TokenCount (max 1 (String.length s / 4))
