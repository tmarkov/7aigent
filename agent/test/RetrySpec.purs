-- | Tests for LLM API retry logic: A18.
module Test.RetrySpec where

import Prelude

import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy, fail)

import Agent.Programs.Retry (retryDecision, RetryDecision(..), ApiError(..))

retrySpec :: Spec Unit
retrySpec = do

  describe "A18: LLM API retry with exponential backoff" do

    it "A18: HTTP 429 on first attempt → retry with backoff" do
      case retryDecision (HttpStatus 429) 0 3 of
        Retry ms -> ms `shouldSatisfy` (_ > 0)
        GiveUp _ -> fail "Expected retry on 429"

    it "A18: HTTP 500 on first attempt → retry" do
      case retryDecision (HttpStatus 500) 0 3 of
        Retry _ -> pure unit
        GiveUp _ -> fail "Expected retry on 500"

    it "A18: HTTP 502 → retry (5xx)" do
      case retryDecision (HttpStatus 502) 0 3 of
        Retry _ -> pure unit
        GiveUp _ -> fail "Expected retry on 502"

    it "A18: HTTP 503 → retry (5xx)" do
      case retryDecision (HttpStatus 503) 0 3 of
        Retry _ -> pure unit
        GiveUp _ -> fail "Expected retry on 503"

    it "A18: HTTP 400 → do not retry (non-transient)" do
      case retryDecision (HttpStatus 400) 0 3 of
        GiveUp _ -> pure unit
        Retry _ -> fail "Expected give-up on 400"

    it "A18: HTTP 401 → do not retry (non-transient)" do
      case retryDecision (HttpStatus 401) 0 3 of
        GiveUp _ -> pure unit
        Retry _ -> fail "Expected give-up on 401"

    it "A18: HTTP 404 → do not retry" do
      case retryDecision (HttpStatus 404) 0 3 of
        GiveUp _ -> pure unit
        Retry _ -> fail "Expected give-up on 404"

    it "A18: retries exhausted → give up" do
      -- 3 max retries, currently on attempt 3 (0-indexed)
      case retryDecision (HttpStatus 429) 3 3 of
        GiveUp _ -> pure unit
        Retry _ -> fail "Expected give-up after max retries exhausted"

    it "A18: backoff intervals increase with attempt number" do
      case retryDecision (HttpStatus 429) 0 5, retryDecision (HttpStatus 429) 1 5, retryDecision (HttpStatus 429) 2 5 of
        Retry ms1, Retry ms2, Retry ms3 ->
          shouldEqual true (ms1 < ms2 && ms2 < ms3)
        _, _, _ ->
          fail "Expected all three attempts to produce Retry"

  describe "A18: network timeout retry" do

    it "A18: network timeout → retry (transient error)" do
      case retryDecision NetworkTimeout 0 3 of
        Retry ms -> ms `shouldSatisfy` (_ > 0)
        GiveUp _ -> fail "Expected retry on NetworkTimeout"

    it "A18: network timeout retries exhausted → give up" do
      case retryDecision NetworkTimeout 3 3 of
        GiveUp _ -> pure unit
        Retry _ -> fail "Expected give-up after max retries exhausted"
