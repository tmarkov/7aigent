-- | Tests for context compaction: A33, A34, A36.
module Test.CompactionSpec where

import Prelude

import Data.Array as Array
import Data.Array.Partial as Array
import Data.Either (Either(..), isLeft)
import Data.String as String
import Data.Tuple (Tuple(..))
import Partial.Unsafe (unsafePartial)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy, fail)

import Test.Helpers.Conversation (systemMsg, userMsg, assistantMsg, assistantToolCallMsg, toolResultMsg, mkHistory, mkHistoryWithTokens)
import Agent.Programs.Compaction
  ( buildCompactionPlan
  , applyCompaction
  , shouldCompact
  )
import Agent.Types (TokenCount(..), ToolCallId(..), CompactionPlan, ConversationHistory(..), Message(..))

compactionSpec :: Spec Unit
compactionSpec = do

  ---------------------------------------------------------------------------
  -- A33: compaction trigger
  ---------------------------------------------------------------------------

  describe "A33: compaction trigger conditions" do

    it "A33: tokens below threshold → no compaction" do
      shouldCompact (TokenCount 100000) (TokenCount 150000) `shouldEqual` false

    it "A33: tokens at threshold → no compaction (not 'exceed')" do
      shouldCompact (TokenCount 150000) (TokenCount 150000) `shouldEqual` false

    it "A33: tokens above threshold → compaction triggered" do
      shouldCompact (TokenCount 160000) (TokenCount 150000) `shouldEqual` true

  ---------------------------------------------------------------------------
  -- A34: compaction plan building
  ---------------------------------------------------------------------------

  describe "A34: compaction plan — initial block" do

    it "A34: system prompt + first user message always in initial block" do
      let history = mkHistoryWithTokens
            [ Tuple (systemMsg "You are a helpful assistant.") (TokenCount 50000)
            , Tuple (userMsg "Tell me about X") (TokenCount 50000)
            , Tuple (assistantMsg "X is...") (TokenCount 30000)
            , Tuple (userMsg "And Y?") (TokenCount 10000)
            , Tuple (assistantMsg "Y is...") (TokenCount 20000)
            ]
      let plan = buildCompactionPlan (TokenCount 20000) (TokenCount 40000) history
      -- Initial block must include system + first user even though they
      -- exceed preserve_initial (20000)
      Array.length plan.initialBlock `shouldSatisfy` (_ >= 2)

    it "A34: initial block includes consecutive messages up to preserve_initial" do
      let history = mkHistoryWithTokens
            [ Tuple (systemMsg "sys") (TokenCount 5000)
            , Tuple (userMsg "q1") (TokenCount 5000)
            , Tuple (assistantMsg "a1") (TokenCount 5000)
            , Tuple (userMsg "q2") (TokenCount 5000)
            , Tuple (assistantMsg "a2") (TokenCount 5000)
            , Tuple (userMsg "q3") (TokenCount 5000)
            ]
      -- preserve_initial = 18000 → should include sys(5k) + q1(5k) + a1(5k) = 15k
      -- Adding q2(5k) would be 20k > 18k, so stop at 3 messages
      let plan = buildCompactionPlan (TokenCount 18000) (TokenCount 10000) history
      Array.length plan.initialBlock `shouldEqual` 3

  describe "A34: compaction plan — final block" do

    it "A34: final block includes messages from end up to preserve_final" do
      let history = mkHistoryWithTokens
            [ Tuple (systemMsg "sys") (TokenCount 5000)
            , Tuple (userMsg "q1") (TokenCount 5000)
            , Tuple (assistantMsg "a1") (TokenCount 5000)
            , Tuple (userMsg "q2") (TokenCount 5000)
            , Tuple (assistantMsg "a2") (TokenCount 5000)
            , Tuple (userMsg "q3") (TokenCount 5000)
            ]
      -- preserve_final = 12000 → from end: q3(5k) + a2(5k) = 10k
      -- Adding q2(5k) would be 15k > 12k, so stop at 2 messages
      let plan = buildCompactionPlan (TokenCount 10000) (TokenCount 12000) history
      Array.length plan.finalBlock `shouldEqual` 2

  describe "A34: compaction plan — compacted block" do

    it "A34: compacted block is everything between initial and final" do
      let history = mkHistoryWithTokens
            [ Tuple (systemMsg "sys") (TokenCount 1000)
            , Tuple (userMsg "q1") (TokenCount 1000)
            , Tuple (assistantMsg "a1") (TokenCount 1000)
            , Tuple (userMsg "q2") (TokenCount 1000)
            , Tuple (assistantMsg "a2") (TokenCount 1000)
            , Tuple (userMsg "q3") (TokenCount 1000)
            ]
      -- preserve_initial = 2500 → initial: sys(1k) + q1(1k) = 2k (adding a1 would be 3k)
      -- preserve_final = 1500 → final: q3(1k) (adding a2 would be 2k)
      let plan = buildCompactionPlan (TokenCount 2500) (TokenCount 1500) history
      Array.length plan.initialBlock `shouldEqual` 2   -- sys, q1
      Array.length plan.finalBlock `shouldEqual` 1     -- q3
      Array.length plan.compactedBlock `shouldEqual` 3 -- a1, q2, a2

  ---------------------------------------------------------------------------
  -- A34 step 5: new conversation construction
  ---------------------------------------------------------------------------

  describe "A34: new conversation after compaction" do

    it "A34: result is [initial] + [summary message] + [final]" do
      let history = mkHistoryWithTokens
            [ Tuple (systemMsg "sys") (TokenCount 1000)
            , Tuple (userMsg "q1") (TokenCount 1000)
            , Tuple (assistantMsg "middle") (TokenCount 1000)
            , Tuple (userMsg "q2") (TokenCount 1000)
            ]
      let plan = buildCompactionPlan (TokenCount 2500) (TokenCount 1500) history
      let summaryTemplate = "Summary: {{summary}}"
      case applyCompaction plan "The user asked q1 and got an answer." summaryTemplate of
        Right newHistory -> do
          let msgs = historyMessages newHistory
          -- initial(sys, q1) + summary message + final(q2) = 4
          Array.length msgs `shouldEqual` 4
          -- Third message (index 2) is the synthetic summary
          let summaryContent = messageContent (unsafePartial $ Array.unsafeIndex msgs 2)
          contains "The user asked q1" summaryContent `shouldEqual` true
        Left err -> fail ("Compaction apply failed: " <> show err)

  ---------------------------------------------------------------------------
  -- A34 step 6: post-compaction size check
  ---------------------------------------------------------------------------

  describe "A34: post-compaction size check" do

    it "A34: post-compaction within threshold → success" do
      let plan =
            { initialBlock: [systemMsg "sys", userMsg "q"]
            , compactedBlock: [assistantMsg "long middle"]
            , finalBlock: [userMsg "recent"]
            }
      case applyCompaction plan "summary" "{{summary}}" of
        Right _ -> pure unit
        Left _ -> fail "Expected successful compaction"

    it "A34: initial + final blocks overlap → error (context too large)" do
      -- Very short history where initial and final blocks would overlap
      let history = mkHistoryWithTokens
            [ Tuple (systemMsg "sys") (TokenCount 100000)
            , Tuple (userMsg "q") (TokenCount 100000)
            ]
      let plan = buildCompactionPlan (TokenCount 200000) (TokenCount 200000) history
      -- No compactable middle — this should fail post-check
      Array.length plan.compactedBlock `shouldEqual` 0
      -- Applying compaction on an empty compacted block should produce an error
      applyCompaction plan "summary" "{{summary}}" `shouldSatisfy` isLeft

  ---------------------------------------------------------------------------
  -- A36: compaction call properties
  ---------------------------------------------------------------------------

  describe "A36: compaction call properties" do

    it "A36: compaction call is not added to conversation history" do
      -- The compaction summary replaces the middle, but the LLM call
      -- that produced the summary is not in the resulting history.
      let plan =
            { initialBlock: [systemMsg "sys", userMsg "q"]
            , compactedBlock: [assistantMsg "long middle"]
            , finalBlock: [userMsg "recent"]
            }
      case applyCompaction plan "The summary." "Earlier: {{summary}}" of
        Right newHistory -> do
          let msgs = historyMessages newHistory
          -- The result should only contain initial + summary msg + final.
          -- No message should reference the compaction prompt template.
          Array.length msgs `shouldEqual` 4  -- sys, q, summary msg, recent
          -- The summary message should contain the rendered summary
          let summaryMsg = messageContent (unsafePartial $ Array.unsafeIndex msgs 2)
          contains "The summary." summaryMsg `shouldEqual` true
        Left err -> fail ("Compaction failed: " <> show err)

  where
  historyMessages :: ConversationHistory -> Array Message
  historyMessages (ConversationHistory h) = map _.message h.messages

  messageContent :: Message -> String
  messageContent (SystemMessage r) = r.content
  messageContent (UserMessage r) = r.content
  messageContent (AssistantMessage r) = r.content
  messageContent (ToolResultMessage r) = r.output

  contains :: String -> String -> Boolean
  contains needle haystack =
    String.contains (String.Pattern needle) haystack
