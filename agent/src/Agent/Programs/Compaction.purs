module Agent.Programs.Compaction
    ( shouldCompact
    , buildCompactionPlan
    , applyCompaction
    ) where

import Prelude
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.Map as Map
import Agent.Types
    ( TokenCount(..)
    , ConversationHistory(..)
    , CompactionPlan
    , Message(..)
    , AppError(..)
    )
import Agent.Programs.Template (substituteTemplate)

shouldCompact :: TokenCount -> TokenCount -> Boolean
shouldCompact (TokenCount current) (TokenCount threshold) =
    current > threshold

buildCompactionPlan
    :: TokenCount
    -> TokenCount
    -> ConversationHistory
    -> CompactionPlan
buildCompactionPlan (TokenCount preserveInitialBudget)
    (TokenCount preserveFinalBudget)
    (ConversationHistory h) =
    let msgs = h.messages
        n = Array.length msgs
        initialEnd = greedyForward msgs
            preserveInitialBudget 0 2
        finalStart = greedyBackward msgs
            preserveFinalBudget (n - 1) (n - 1)
        safeEnd = min initialEnd finalStart
        initial = Array.take safeEnd msgs
        final = Array.drop finalStart msgs
        compacted =
            Array.slice safeEnd finalStart msgs
    in  { initialBlock:
            map _.message initial
        , compactedBlock:
            map _.message compacted
        , finalBlock:
            map _.message final
        }
  where
    greedyForward
        :: Array { message :: Message
                 , tokens :: TokenCount }
        -> Int -> Int -> Int -> Int
    greedyForward msgs budget idx minCount
        | idx >= Array.length msgs = idx
        | idx < minCount =
            case Array.index msgs idx of
                Nothing -> idx
                Just entry ->
                    let TokenCount t = entry.tokens
                    in  greedyForward msgs
                            (budget - t) (idx + 1)
                            minCount
        | budget <= 0 = idx
        | otherwise =
            case Array.index msgs idx of
                Nothing -> idx
                Just entry ->
                    let TokenCount t = entry.tokens
                    in  if t > budget then idx
                        else greedyForward msgs
                            (budget - t) (idx + 1)
                            minCount

    greedyBackward
        :: Array { message :: Message
                 , tokens :: TokenCount }
        -> Int -> Int -> Int -> Int
    greedyBackward msgs budget idx minIdx
        | idx < 0 = 0
        | budget <= 0 = idx + 1
        | otherwise =
            case Array.index msgs idx of
                Nothing -> idx + 1
                Just entry ->
                    let TokenCount t = entry.tokens
                    in  if t > budget then idx + 1
                        else greedyBackward msgs
                            (budget - t) (idx - 1)
                            minIdx

applyCompaction
    :: CompactionPlan
    -> String
    -> String
    -> Either AppError ConversationHistory
applyCompaction plan summaryText summaryTemplate
    | Array.null plan.compactedBlock =
        Left (CompactionError
            "Nothing to compact: compacted block is empty")
    | otherwise =
        let vars = Map.singleton "summary" summaryText
        in  case substituteTemplate vars summaryTemplate of
            Left err -> Left err
            Right rendered ->
                let summaryMsg = AssistantMessage
                        { content: rendered
                        , toolCalls: []
                        }
                    allMsgs =
                        map wrapMsg plan.initialBlock
                        <> [ { message: summaryMsg
                             , tokens: TokenCount 0
                             } ]
                        <> map wrapMsg plan.finalBlock
                in  Right (ConversationHistory
                        { messages: allMsgs })
  where
    wrapMsg :: Message -> { message :: Message
                          , tokens :: TokenCount }
    wrapMsg m =
        { message: m, tokens: TokenCount 0 }
