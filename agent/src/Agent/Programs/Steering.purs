-- | Pure helper for building the ephemeral turn-steering message (A45, A46).
module Agent.Programs.Steering
    ( buildSteeringMessage
    ) where

import Prelude

import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Agent.Types (TokenCount(..), Config)
import Agent.Programs.Template (substituteTemplate)

-- | Build the ephemeral steering message to inject before a mid-turn LLM call.
-- |
-- | Returns `Nothing` when `accumulated` is zero (no injection on the first
-- | call of a turn) or when template substitution fails.
buildSteeringMessage
    :: String                   -- steering_message.md template
    -> TokenCount               -- accumulated input tokens this turn
    -> Config
    -> String                   -- output of SevenAigentREPL.status()
    -> Int                      -- current turn index (1-based) within the round
    -> Int                      -- number of auto turns taken so far in the round
    -> Maybe String
buildSteeringMessage template (TokenCount acc) config juliaState turnIndex autoTurnsTaken =
    if acc == 0
    then Nothing
    else
        let TokenCount limit   = config.maxTokensPerTurn
            TokenCount compact = config.compactionThreshold
            vars = Map.fromFoldable
                [ Tuple "julia_state"          juliaState
                , Tuple "turn_tokens"          (show acc)
                , Tuple "turn_token_limit"     (show limit)
                , Tuple "compaction_threshold" (show compact)
                , Tuple "turn_index"           (show turnIndex)
                , Tuple "max_turns_per_round"  (show config.maxTurnsPerRound)
                , Tuple "auto_turns_taken"     (show autoTurnsTaken)
                ]
        in case substituteTemplate vars template of
            Left  _   -> Nothing
            Right msg -> Just msg
