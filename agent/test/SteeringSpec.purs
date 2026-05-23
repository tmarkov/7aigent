-- | Tests for the pure steering message builder: A45 (keywords), A46 (injection condition).
module Test.SteeringSpec where

import Prelude

import Data.Maybe (Maybe(..), isNothing)
import Data.String as String
import Data.Tuple (Tuple(..))
import Data.Map as Map
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy)

import Agent.Types (TokenCount(..), Config, ApiEndpoint(..), ModelName(..), EnvVarName(..))
import Agent.Programs.Steering (buildSteeringMessage)

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
    , maxTurnsPerRound: 5
    }

steeringSpec :: Spec Unit
steeringSpec = do

  ---------------------------------------------------------------------------
  -- A46: injection condition
  ---------------------------------------------------------------------------

  describe "A46: steering message injection condition" do

    it "A46: returns Nothing when turn baseline is zero (first call of turn)" do
      -- Both baseline and lastCallTokens are 0: no steering on first call
      let result = buildSteeringMessage "{{turn_tokens}}" (TokenCount 0) (TokenCount 0) testConfig "" 1 0
      result `shouldSatisfy` isNothing

    it "A46: returns Just when turn baseline is greater than zero" do
      -- baseline = 1000, lastCall = 1000 → delta = 0, but steering is injected
      let result = buildSteeringMessage "{{turn_tokens}}" (TokenCount 1000) (TokenCount 1000) testConfig "" 1 0
      result `shouldSatisfy` (_ /= Nothing)

    it "A46: {{turn_tokens}} shows delta (lastCall - baseline), not raw token count" do
      -- baseline = 1000, lastCall = 1500 → delta = 500
      let result = buildSteeringMessage "{{turn_tokens}}" (TokenCount 1000) (TokenCount 1500) testConfig "" 1 0
      result `shouldEqual` Just "500"

    it "A46: delta is clamped to zero when lastCall < baseline (e.g. after compaction)" do
      -- baseline = 2000, lastCall = 1000 → delta clamped to 0
      let result = buildSteeringMessage "{{turn_tokens}}" (TokenCount 2000) (TokenCount 1000) testConfig "" 1 0
      result `shouldEqual` Just "0"

  ---------------------------------------------------------------------------
  -- A45: keyword substitution
  ---------------------------------------------------------------------------

  describe "A45: steering message keyword substitution" do

    it "A45: substitutes {{turn_tokens}} with delta (lastCall - baseline)" do
      -- baseline = 30000, lastCall = 35000, delta = 5000
      let result = buildSteeringMessage "tokens={{turn_tokens}}" (TokenCount 30000) (TokenCount 35000) testConfig "" 1 0
      result `shouldEqual` Just "tokens=5000"

    it "A45: substitutes {{turn_token_limit}} from config" do
      let result = buildSteeringMessage "limit={{turn_token_limit}}" (TokenCount 100) (TokenCount 200) testConfig "" 1 0
      result `shouldEqual` Just "limit=200000"

    it "A45: substitutes {{compaction_threshold}} from config" do
      let result = buildSteeringMessage "compact={{compaction_threshold}}" (TokenCount 100) (TokenCount 200) testConfig "" 1 0
      result `shouldEqual` Just "compact=150000"

    it "A45: substitutes {{julia_state}} with provided state string" do
      let result = buildSteeringMessage "state={{julia_state}}" (TokenCount 100) (TokenCount 200) testConfig "status output" 1 0
      result `shouldEqual` Just "state=status output"

    it "A45: substitutes all four keywords in one template" do
      let tmpl = "t={{turn_tokens}} l={{turn_token_limit}} c={{compaction_threshold}} j={{julia_state}}"
      -- baseline = 30000, lastCall = 31000, delta = 1000
      let result = buildSteeringMessage tmpl (TokenCount 30000) (TokenCount 31000) testConfig "task info" 1 0
      result `shouldEqual` Just "t=1000 l=200000 c=150000 j=task info"

    it "A45: empty julia_state is substituted as empty string" do
      let result = buildSteeringMessage "[{{julia_state}}]" (TokenCount 100) (TokenCount 200) testConfig "" 1 0
      result `shouldEqual` Just "[]"

    it "A45: template with no placeholders passes through unchanged" do
      let result = buildSteeringMessage "no placeholders here" (TokenCount 100) (TokenCount 200) testConfig "" 1 0
      result `shouldEqual` Just "no placeholders here"

    it "A45: unknown keyword in template → Nothing (silenced error)" do
      let result = buildSteeringMessage "{{unknown_key}}" (TokenCount 100) (TokenCount 200) testConfig "" 1 0
      result `shouldSatisfy` isNothing

    it "A45: substitutes {{turn_index}} with provided turn index" do
      let result = buildSteeringMessage "turn={{turn_index}}" (TokenCount 100) (TokenCount 200) testConfig "" 3 0
      result `shouldEqual` Just "turn=3"

    it "A45: substitutes {{max_turns_per_round}} from config" do
      let result = buildSteeringMessage "max={{max_turns_per_round}}" (TokenCount 100) (TokenCount 200) testConfig "" 1 0
      result `shouldEqual` Just "max=5"

    it "A45: substitutes {{auto_turns_taken}} with provided count" do
      let result = buildSteeringMessage "auto={{auto_turns_taken}}" (TokenCount 100) (TokenCount 200) testConfig "" 1 2
      result `shouldEqual` Just "auto=2"

    it "A45: substitutes all seven keywords in one template" do
      let tmpl = "t={{turn_tokens}} l={{turn_token_limit}} c={{compaction_threshold}} j={{julia_state}} i={{turn_index}} m={{max_turns_per_round}} a={{auto_turns_taken}}"
      -- baseline = 30000, lastCall = 31000, delta = 1000
      let result = buildSteeringMessage tmpl (TokenCount 30000) (TokenCount 31000) testConfig "info" 2 1
      result `shouldEqual` Just "t=1000 l=200000 c=150000 j=info i=2 m=5 a=1"
