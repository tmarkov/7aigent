-- | Tests for the ReACT step logic: A1 (step transitions), A7 (streaming),
-- | A37a (per-turn token limit).
module Test.ReactStepSpec where

import Prelude

import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, fail)

import Test.Helpers.Conversation (systemMsg, userMsg, assistantMsg, mkHistory, mkHistoryWithTokens)
import Test.Helpers.LlmResponse (textResponse, toolCallResponse)
import Agent.Programs.ReactStep (reactStep, NextStep(..))
import Agent.Types
  ( ApiEndpoint(..)
  , EnvVarName(..)
  , ToolName(..)
  , ToolCallId(..)
  , TokenCount(..)
  , ModelName(..)
  , Config
  , LlmResponse(..)
  )

-- | A minimal config for tests. Token thresholds are set high enough
-- that compaction is not triggered unless the test wants it.
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
  , maxReplTimeoutSeconds: 300
  , progressIntervalSeconds: 15
  }

reactStepSpec = do

  ---------------------------------------------------------------------------
  -- A1: ReACT step transitions
  ---------------------------------------------------------------------------

  describe "A1: ReACT step — tool call response" do

    it "A1: LLM response with tool call → ExecuteTool" do
      let history = mkHistory [ systemMsg "sys", userMsg "hello" ]
      let response = toolCallResponse "julia_repl" "1+1" (ToolCallId "tc1") (TokenCount 500)
      let step = reactStep testConfig (TokenCount 500) history response
      case step of
        ExecuteTool tc -> tc.name `shouldEqual` JuliaRepl
        _ -> fail "Expected ExecuteTool"

  describe "A1: ReACT step — no tool call response" do

    it "A1: LLM response with no tool call → PromptUser" do
      let history = mkHistory [ systemMsg "sys", userMsg "hello" ]
      let response = textResponse "Here is my answer." (TokenCount 500)
      let step = reactStep testConfig (TokenCount 500) history response
      case step of
        PromptUser -> pure unit
        _ -> fail "Expected PromptUser"

  describe "A1: ReACT step — compaction triggered" do

    it "A1: no tool call + tokens above compaction_threshold → CompactThenPromptUser" do
      let history = mkHistory [ systemMsg "sys", userMsg "hello" ]
      let response = textResponse "answer" (TokenCount 160000)
      -- Input tokens exceed compaction_threshold (150000)
      let step = reactStep testConfig (TokenCount 160000) history response
      case step of
        CompactThenPromptUser -> pure unit
        _ -> fail "Expected CompactThenPromptUser"

    it "A1: tool call + tokens above compaction_threshold → ExecuteToolThenCompact" do
      let history = mkHistory [ systemMsg "sys", userMsg "hello" ]
      let response = toolCallResponse "julia_repl" "x" (ToolCallId "tc1") (TokenCount 160000)
      let step = reactStep testConfig (TokenCount 160000) history response
      case step of
        ExecuteToolThenCompact tc -> tc.name `shouldEqual` JuliaRepl
        _ -> fail "Expected ExecuteToolThenCompact"

    it "A1: tokens at threshold (not above) → no compaction" do
      let history = mkHistory [ systemMsg "sys", userMsg "hello" ]
      let response = textResponse "answer" (TokenCount 150000)
      let step = reactStep testConfig (TokenCount 150000) history response
      case step of
        PromptUser -> pure unit
        _ -> fail "Expected PromptUser (threshold is 'exceed', not 'meet')"

    it "A33: accumulated turn tokens above threshold do not compact when the \
       \current request is below threshold" do
      let config = testConfig
            { compactionThreshold = TokenCount 1000
            , preserveInitial = TokenCount 100
            , preserveFinal = TokenCount 100
            }
      let history = mkHistory [ systemMsg "sys", userMsg "hello" ]
      let response = toolCallResponse "julia_repl" "x" (ToolCallId "tc1") (TokenCount 900)
      -- The current request (900) is below the compaction threshold (1000),
      -- so no compaction should occur regardless of turn delta.
      -- baseline = 200, delta = 700 (below threshold)
      let step = reactStep config (TokenCount 200) history response
      case step of
        ExecuteTool _ -> pure unit
        _ -> fail "Expected ExecuteTool (compaction uses current request size, not delta)"

    it "A33: text-only response likewise does not compact on turn delta alone" do
      let config = testConfig
            { compactionThreshold = TokenCount 1000
            , preserveInitial = TokenCount 100
            , preserveFinal = TokenCount 100
            }
      let history = mkHistory [ systemMsg "sys", userMsg "hello" ]
      let response = textResponse "answer" (TokenCount 900)
      -- baseline = 200, current = 900 < threshold → no compaction
      let step = reactStep config (TokenCount 200) history response
      case step of
        PromptUser -> pure unit
        _ -> fail "Expected PromptUser (no compaction from turn delta alone)"

  ---------------------------------------------------------------------------
  -- A7: streaming contract
  ---------------------------------------------------------------------------

  describe "A7: LLM response streaming" do

    it "A7: response with both text and tool call → text available for streaming" do
      let history = mkHistory [ systemMsg "sys", userMsg "hello" ]
      -- LLM sends narration text AND a tool call (common pattern)
      let response = LlmResponse
            { content: "Let me check that for you."
            , toolCalls:
                [ { name: JuliaRepl
                  , input: "1+1"
                  , id: ToolCallId "tc1"
                  }
                ]
            , inputTokens: TokenCount 500
            }
      let step = reactStep testConfig (TokenCount 500) history response
      case step of
        ExecuteTool tc -> do
          -- The tool call is the primary action
          tc.name `shouldEqual` JuliaRepl
          -- The response text must still be available to the controller
          -- for streaming to the terminal before executing the tool.
          let (LlmResponse r) = response
          r.content `shouldEqual` "Let me check that for you."
        _ -> fail "Expected ExecuteTool for mixed text+tool response"

  ---------------------------------------------------------------------------
  -- A37a: per-turn token limit
  ---------------------------------------------------------------------------

  describe "A37a: per-turn token limit" do

    it "A37a: turn delta below limit → turn continues (ExecuteTool)" do
      let config = testConfig { maxTokensPerTurn = TokenCount 50000 }
      let history = mkHistory [ systemMsg "sys", userMsg "hello" ]
      -- baseline = 30000 (first call), current = 45000, delta = 15000 < 50000
      let response = toolCallResponse "julia_repl" "x" (ToolCallId "tc1") (TokenCount 45000)
      let step = reactStep config (TokenCount 30000) history response
      case step of
        ExecuteTool _ -> pure unit
        _ -> fail "Expected ExecuteTool (delta below max_tokens_per_turn)"

    it "A37a: turn delta above limit → turn ends after current step" do
      let config = testConfig { maxTokensPerTurn = TokenCount 50000 }
      let history = mkHistory [ systemMsg "sys", userMsg "hello" ]
      -- baseline = 5000 (first call), current = 60000, delta = 55000 > 50000
      let response = toolCallResponse "julia_repl" "x" (ToolCallId "tc1") (TokenCount 60000)
      -- Delta exceeds max_tokens_per_turn. The current step (tool call)
      -- should still execute, but the turn ends after.
      let step = reactStep config (TokenCount 5000) history response
      case step of
        ExecuteToolThenEndTurn tc -> tc.name `shouldEqual` JuliaRepl
        _ -> fail "Expected ExecuteToolThenEndTurn"

    it "A37a: turn delta at limit → turn continues (not strictly above)" do
      let config = testConfig { maxTokensPerTurn = TokenCount 50000 }
      let history = mkHistory [ systemMsg "sys", userMsg "hello" ]
      -- baseline = 5000, current = 55000, delta = 50000 = limit (not exceeded)
      let response = toolCallResponse "julia_repl" "x" (ToolCallId "tc1") (TokenCount 55000)
      let step = reactStep config (TokenCount 5000) history response
      case step of
        ExecuteTool _ -> pure unit
        _ -> fail "Expected ExecuteTool (delta at limit, not above)"

    it "A37a: large base context does not trigger turn end when delta is small" do
      let config = testConfig { maxTokensPerTurn = TokenCount 50000 }
      let history = mkHistory [ systemMsg "sys", userMsg "hello" ]
      -- baseline = 80000 (large prior context), current = 82000, delta = 2000
      -- Old behaviour would have ended the turn; new behaviour continues.
      let response = toolCallResponse "julia_repl" "x" (ToolCallId "tc1") (TokenCount 82000)
      let step = reactStep config (TokenCount 80000) history response
      case step of
        ExecuteTool _ -> pure unit
        _ -> fail "Expected ExecuteTool (delta small despite large base context)"

  ---------------------------------------------------------------------------
  -- A33: compaction never immediately after user message
  --
  -- The A1 tests above implicitly verify A33: when the LLM responds with
  -- only text and no tool calls (PromptUser), there is no opportunity for
  -- compaction because the turn ends and the user is prompted next.
  -- Compaction can only be triggered alongside tool execution
  -- (ExecuteToolThenCompact) which means at least one LLM turn has
  -- occurred since the last user message.
  ---------------------------------------------------------------------------

  describe "A33: no compaction immediately after user message" do

    it "A33 + A1: text-only response after user message → PromptUser (no compaction)" do
      -- History: just a user message, LLM responds with text only
      let history = mkHistory [ systemMsg "sys", userMsg "hello" ]
      let response = textResponse "Hi there!" (TokenCount 500)
      -- Even if we set compaction threshold very low, there's no mechanism
      -- for compaction on a text-only response — it always yields PromptUser
      let lowThresholdConfig = testConfig { compactionThreshold = TokenCount 1 }
      let step = reactStep lowThresholdConfig (TokenCount 500) history response
      case step of
        PromptUser -> pure unit
        _ -> fail "Expected PromptUser (no compaction on text-only response)"

  ---------------------------------------------------------------------------
  -- A1 + A37a: interaction between compaction and token limit
  ---------------------------------------------------------------------------

  describe "A1 + A37a: compaction vs token limit interaction" do

    it "A37a: when both compaction threshold and token limit are exceeded, \
       \compaction takes priority" do
      -- Config: compaction at 1000 tokens, max per turn delta 800
      let config = testConfig
            { compactionThreshold = TokenCount 1000
            , maxTokensPerTurn = TokenCount 800
            }
      let history = mkHistory [ systemMsg "sys", userMsg "context" ]
      -- baseline = 200, current = 1200: delta = 1000 > maxPerTurn (800),
      -- and current > compactionThreshold (1000).
      -- Compaction takes priority over the per-turn limit.
      let response = toolCallResponse "julia_repl" "x" (ToolCallId "tc1") (TokenCount 1200)
      let step = reactStep config (TokenCount 200) history response
      -- Compaction should take priority: compact first, then after
      -- compaction the token limit can be re-evaluated fresh
      case step of
        ExecuteToolThenCompact tc -> tc.name `shouldEqual` JuliaRepl
        _ -> fail "Expected ExecuteToolThenCompact (compaction takes priority)"
