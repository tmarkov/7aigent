-- | Tests for round orchestration: A48 round lifecycle, A49 reflection
-- | call construction.
module Test.RoundStepSpec where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy, fail)

import Test.Helpers.Conversation (systemMsg, userMsg, assistantMsg, mkHistory)
import Agent.Programs.RoundStep
    ( RoundDecision(..)
    , roundDecision
    , buildReflectionHistory
    )
import Agent.Types
    ( ApiEndpoint(..)
    , EnvVarName(..)
    , ModelName(..)
    , TokenCount(..)
    , Config
    , ConversationHistory(..)
    , Message(..)
    , extractContent
    , unwrapConversationHistory
    )

-- | Config for round lifecycle tests.
testConfig :: Config
testConfig =
    { apiEndpoint: ApiEndpoint "https://example.com"
    , model: ModelName "test"
    , apiKeyEnv: EnvVarName "KEY"
    , outputThresholdChars: 20000
    , maxApiRetries: 3
    , maxTokensPerTurn: TokenCount 200000
    , compactionThreshold: TokenCount 150000
    , preserveInitial: TokenCount 20000
    , preserveFinal: TokenCount 40000
    , maxTurnsPerRound: 3
    , timeoutCheckSeconds: [30, 60, 120, 240, 480]
    , progressIntervalSeconds: 15
    }

roundStepSpec :: Spec Unit
roundStepSpec = do

  ---------------------------------------------------------------------------
  -- A48: round lifecycle — roundDecision
  ---------------------------------------------------------------------------

  describe "A48: round lifecycle — reflection reports complete" do

    it "A48: complete=true → EndRound (first turn)" do
      let result = roundDecision testConfig 1
            { complete: true, feedback: Nothing }
      result `shouldEqual` EndRound

    it "A48: complete=true with feedback → EndRound (feedback ignored)" do
      let result = roundDecision testConfig 1
            { complete: true, feedback: Just "Keep going" }
      result `shouldEqual` EndRound

    it "A48: complete=true at max_turns → EndRound" do
      let result = roundDecision testConfig 3
            { complete: true, feedback: Nothing }
      result `shouldEqual` EndRound

  describe "A48: round lifecycle — max_turns_per_round enforcement" do

    it "A48: turnIndex == maxTurnsPerRound, complete=false → EndRound" do
      let result = roundDecision testConfig 3
            { complete: false, feedback: Just "Not done yet" }
      result `shouldEqual` EndRound

    it "A48: turnIndex > maxTurnsPerRound → EndRound" do
      let result = roundDecision testConfig 4
            { complete: false, feedback: Just "Still going" }
      result `shouldEqual` EndRound

    it "A48: turnIndex < maxTurnsPerRound, complete=false → ContinueWithFeedback" do
      let result = roundDecision testConfig 2
            { complete: false, feedback: Just "Try harder" }
      result `shouldEqual` ContinueWithFeedback "Try harder"

  describe "A48: round lifecycle — turn succession via feedback injection" do

    it "A48: complete=false with feedback → ContinueWithFeedback carries the text" do
      let result = roundDecision testConfig 1
            { complete: false, feedback: Just "Run the failing tests." }
      result `shouldEqual` ContinueWithFeedback "Run the failing tests."

    it "A48: complete=false without feedback → ContinueWithFeedback default message" do
      let result = roundDecision testConfig 1
            { complete: false, feedback: Nothing }
      result `shouldEqual` ContinueWithFeedback "[Reflection: continue]"

    it "A48: maxTurnsPerRound=1 → always EndRound after first turn" do
      let config = testConfig { maxTurnsPerRound = 1 }
      let result = roundDecision config 1
            { complete: false, feedback: Just "More work" }
      result `shouldEqual` EndRound

    it "A48: maxTurnsPerRound=5, turnIndex=4 → still continues" do
      let config = testConfig { maxTurnsPerRound = 5 }
      let result = roundDecision config 4
            { complete: false, feedback: Just "Almost done" }
      result `shouldEqual` ContinueWithFeedback "Almost done"

  ---------------------------------------------------------------------------
  -- A49: reflection call construction — buildReflectionHistory
  ---------------------------------------------------------------------------

  describe "A49: reflection prompt template substitution" do

    it "A49: template keywords are substituted" do
      let template = "Turn: {{turn_index}}, Auto: {{auto_turns_taken}}, Max: {{max_turns_per_round}}"
      let history = mkHistory [ systemMsg "sys", userMsg "hello" ]
      let result = buildReflectionHistory template 2 1 5 "" history
      let msgs = unwrapConversationHistory result
      let lastMsg = Array.last msgs
      case lastMsg of
          Just entry -> case entry.message of
              UserMessage r ->
                  String.contains (String.Pattern "Turn: 2") r.content
                      `shouldEqual` true
              _ -> fail "Expected last message to be UserMessage"
          Nothing -> fail "Expected non-empty history"

    it "A49: julia_state keyword is substituted" do
      let template = "State: {{julia_state}}"
      let history = mkHistory [ systemMsg "sys" ]
      let result = buildReflectionHistory template 1 0 5 "db has 42 nodes" history
      let msgs = unwrapConversationHistory result
      let lastMsg = Array.last msgs
      case lastMsg of
          Just entry -> case entry.message of
              UserMessage r ->
                  String.contains (String.Pattern "db has 42 nodes") r.content
                      `shouldEqual` true
              _ -> fail "Expected UserMessage"
          Nothing -> fail "Expected non-empty history"

  describe "A49: reflection history is augmented, not the original" do

    it "A49: original history is not modified (augmented copy returned)" do
      let template = "Reflect: {{turn_index}}"
      let history = mkHistory [ systemMsg "sys", userMsg "hello" ]
      let originalLen = Array.length (unwrapConversationHistory history)
      let augmented = buildReflectionHistory template 1 0 3 "" history
      let augmentedLen = Array.length (unwrapConversationHistory augmented)
      -- Augmented has one more message than original
      augmentedLen `shouldEqual` (originalLen + 1)
      -- Original is unchanged (still 2 messages)
      originalLen `shouldEqual` 2

    it "A49: the appended message is a UserMessage with the substituted prompt" do
      let template = "Are we done? Turn {{turn_index}} of {{max_turns_per_round}}"
      let history = mkHistory [ systemMsg "sys", userMsg "task", assistantMsg "working on it" ]
      let augmented = buildReflectionHistory template 2 1 5 "state info" history
      let msgs = unwrapConversationHistory augmented
      let lastMsg = Array.last msgs
      case lastMsg of
          Just entry -> case entry.message of
              UserMessage r -> do
                  String.contains (String.Pattern "Turn 2") r.content
                      `shouldEqual` true
                  String.contains (String.Pattern "of 5") r.content
                      `shouldEqual` true
              _ -> fail "Expected appended message to be UserMessage"
          Nothing -> fail "Expected non-empty augmented history"

    it "A49: reflection history preserves all original messages" do
      let template = "{{turn_index}}"
      let history = mkHistory
            [ systemMsg "system prompt"
            , userMsg "user input"
            , assistantMsg "response"
            ]
      let augmented = buildReflectionHistory template 1 0 3 "" history
      let msgs = unwrapConversationHistory augmented
      -- First 3 messages should be the original ones
      case Array.index msgs 0 of
          Just entry -> extractContent entry.message `shouldEqual` "system prompt"
          Nothing -> fail "Missing message 0"
      case Array.index msgs 1 of
          Just entry -> extractContent entry.message `shouldEqual` "user input"
          Nothing -> fail "Missing message 1"
      case Array.index msgs 2 of
          Just entry -> extractContent entry.message `shouldEqual` "response"
          Nothing -> fail "Missing message 2"

    it "A49: invalid template keyword → template used as-is (not an error)" do
      let template = "{{unknown_keyword}}"
      let history = mkHistory [ systemMsg "sys" ]
      let augmented = buildReflectionHistory template 1 0 3 "" history
      let msgs = unwrapConversationHistory augmented
      let lastMsg = Array.last msgs
      case lastMsg of
          Just entry -> case entry.message of
              UserMessage r ->
                  -- Template is used as-is when substitution fails
                  r.content `shouldEqual` "{{unknown_keyword}}"
              _ -> fail "Expected UserMessage"
          Nothing -> fail "Expected non-empty history"
