-- | Tests for timeout schedule and interrupt checks: A14, A15, A16, A17.
module Test.TimeoutSpec where

import Prelude

import Data.Array as Array
import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy, fail)

import Agent.Programs.Timeout
  ( timeoutCheckpoints
  , isCheckDue
  , buildTimeoutCheckRequest
  , interpretTimeoutResponse
  , TimeoutDecision(..)
  )
import Agent.Types (RawJulia(..))

timeoutSpec :: Spec Unit
timeoutSpec = do

  ---------------------------------------------------------------------------
  -- A14: exponential backoff schedule
  ---------------------------------------------------------------------------

  describe "A14: timeout check schedule" do

    it "A14: checkpoints follow doubling pattern starting at 30s" do
      let first5 = Array.take 5 timeoutCheckpoints
      first5 `shouldEqual` [30, 60, 120, 240, 480]

    it "A14: 30s elapsed → first check is due" do
      isCheckDue 30 0 `shouldEqual` true

    it "A14: 29s elapsed → no check due yet" do
      isCheckDue 29 0 `shouldEqual` false

    it "A14: 59s elapsed, last check at 30s → no check due" do
      isCheckDue 59 30 `shouldEqual` false

    it "A14: 60s elapsed, last check at 30s → second check due" do
      isCheckDue 60 30 `shouldEqual` true

    it "A14: 120s elapsed, last check at 60s → third check due" do
      isCheckDue 120 60 `shouldEqual` true

    it "A14: 240s elapsed, last check at 120s → fourth check due" do
      isCheckDue 240 120 `shouldEqual` true

    it "A14: 959s elapsed, last check at 480s → no fifth-doubling check yet" do
      isCheckDue 959 480 `shouldEqual` false

    it "A14: 960s elapsed, last check at 480s → next doubled check is due" do
      isCheckDue 960 480 `shouldEqual` true

    it "A14: 1920s elapsed, last check at 960s → schedule keeps doubling" do
      isCheckDue 1920 960 `shouldEqual` true

  ---------------------------------------------------------------------------
  -- A15: interrupt check request construction
  ---------------------------------------------------------------------------

  describe "A15: timeout check request construction" do

    it "A15: request contains the Julia source being executed" do
      let request = buildTimeoutCheckRequest (RawJulia "big_computation()") 30 "partial"
      let rendered = renderMessages request
      rendered `shouldSatisfy` contains "big_computation()"

    it "A15: request contains elapsed time" do
      let request = buildTimeoutCheckRequest (RawJulia "x") 45 ""
      let rendered = renderMessages request
      rendered `shouldSatisfy` contains "45"

    it "A15: request contains partial output" do
      let request = buildTimeoutCheckRequest (RawJulia "x") 30 "some output so far"
      let rendered = renderMessages request
      rendered `shouldSatisfy` contains "some output so far"

    it "A15: request asks a yes/no question about interruption" do
      let request = buildTimeoutCheckRequest (RawJulia "x") 30 ""
      let rendered = renderMessages request
      rendered `shouldSatisfy` \s ->
        contains "interrupt" (String.toLower s)

  ---------------------------------------------------------------------------
  -- A16 + A17: timeout check response handling
  ---------------------------------------------------------------------------

  describe "A16: LLM says yes to interrupt" do

    it "A16: 'yes' response → Interrupt decision" do
      let decision = interpretTimeoutResponse "Yes, interrupt the execution."
      case decision of
        Interrupt -> pure unit
        _ -> fail "Expected Interrupt"

  describe "A17: LLM says no to interrupt" do

    it "A17: 'no' response → ScheduleNext with doubled interval" do
      let decision = interpretTimeoutResponse "No, let it continue running."
      case decision of
        ScheduleNext nextInterval ->
          -- A17 says the interval doubles each time. If current interval
          -- is the base (30s), next should be 60s.
          nextInterval `shouldSatisfy` (_ > 0)
        _ -> fail "Expected ScheduleNext"

    it "A17: ScheduleNext interval is the next checkpoint in the schedule" do
      -- Verify the actual interval value, not just its positivity
      let decision = interpretTimeoutResponse "No, let it continue running."
      case decision of
        ScheduleNext nextInterval ->
          -- The next checkpoint after the first (30s) is 60s
          nextInterval `shouldEqual` 60
        _ -> fail "Expected ScheduleNext"

  where
  contains :: String -> String -> Boolean
  contains needle haystack =
    String.contains (String.Pattern needle) haystack

  -- Render an array of messages to a single string for searching
  renderMessages :: Array _ -> String
  renderMessages msgs = String.joinWith "\n" (map _.content msgs)
