-- | Tests for timeout schedule and interrupt checks: A14, A15, A16, A17.
module Test.TimeoutSpec where

import Prelude

import Data.Array as Array
import Data.Either (Either(..), isLeft)
import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy, fail)

import Agent.Programs.Timeout
  ( defaultTimeoutCheckSeconds
  , isCheckDue
  )
import Agent.Programs.ExecutionDecision
  ( TimeoutDecision(..)
  , parseTimeoutDecision
  , renderTimeoutPrompt
  , timeoutJsonSchemaPretty
  )

timeoutSpec :: Spec Unit
timeoutSpec = do

  ---------------------------------------------------------------------------
  -- A14: exponential backoff schedule
  ---------------------------------------------------------------------------

  describe "A14: timeout check schedule" do

    it "A14: default checkpoints follow doubling pattern starting at 30s" do
      let first5 = Array.take 5 defaultTimeoutCheckSeconds
      first5 `shouldEqual` [30, 60, 120, 240, 480]

    it "A14: 30s elapsed → first check is due (default schedule)" do
      isCheckDue defaultTimeoutCheckSeconds 30 0 `shouldEqual` true

    it "A14: 29s elapsed → no check due yet (default schedule)" do
      isCheckDue defaultTimeoutCheckSeconds 29 0 `shouldEqual` false

    it "A14: 59s elapsed, last check at 30s → no check due" do
      isCheckDue defaultTimeoutCheckSeconds 59 30 `shouldEqual` false

    it "A14: 60s elapsed, last check at 30s → second check due" do
      isCheckDue defaultTimeoutCheckSeconds 60 30 `shouldEqual` true

    it "A14: 120s elapsed, last check at 60s → third check due" do
      isCheckDue defaultTimeoutCheckSeconds 120 60 `shouldEqual` true

    it "A14: 240s elapsed, last check at 120s → fourth check due" do
      isCheckDue defaultTimeoutCheckSeconds 240 120 `shouldEqual` true

    it "A14: 959s elapsed, last check at 480s → no fifth-doubling check yet" do
      isCheckDue defaultTimeoutCheckSeconds 959 480 `shouldEqual` false

    it "A14: 960s elapsed, last check at 480s → next doubled check is due" do
      isCheckDue defaultTimeoutCheckSeconds 960 480 `shouldEqual` true

    it "A14: 1920s elapsed, last check at 960s → schedule keeps doubling" do
      isCheckDue defaultTimeoutCheckSeconds 1920 960 `shouldEqual` true

    it "A14: custom schedule [2, 4, 8] → first check at 2s" do
      isCheckDue [2, 4, 8] 2 0 `shouldEqual` true

    it "A14: custom schedule [2, 4, 8] → 1s elapsed → no check" do
      isCheckDue [2, 4, 8] 1 0 `shouldEqual` false

    it "A14: custom schedule [2, 4, 8] → doubles beyond explicit entries" do
      isCheckDue [2, 4, 8] 16 8 `shouldEqual` true

  ---------------------------------------------------------------------------
  -- A15: interrupt check request construction
  ---------------------------------------------------------------------------

  describe "A15 + A15a: timeout prompt construction" do

    it "A15: substitutes every supported timeout keyword" do
      let result = renderTimeoutPrompt
            "{{julia_source}}|{{elapsed_time}}|{{output_so_far}}|{{json_schema}}"
            { juliaSource: "big_computation()"
            , elapsedSeconds: 30
            , outputSoFar: "partial"
            }
      case result of
        Left err -> fail ("Expected valid timeout prompt, got " <> show err)
        Right prompt -> do
          prompt `shouldSatisfy` contains "big_computation()|30|partial|"
          prompt `shouldSatisfy` contains "\"continue\""
          prompt `shouldSatisfy` contains "\"interrupt\""

    it "A15: accepts a template containing only a subset of keywords" do
      let result = renderTimeoutPrompt "Elapsed: {{elapsed_time}}"
            { juliaSource: "x", elapsedSeconds: 45, outputSoFar: "" }
      case result of
        Left err -> fail ("Expected valid timeout prompt, got " <> show err)
        Right prompt -> prompt `shouldEqual` "Elapsed: 45"

    it "A15: rejects stdin-only prompt keyword" do
      renderTimeoutPrompt "{{prompt}}"
        { juliaSource: "x", elapsedSeconds: 30, outputSoFar: "" }
        `shouldSatisfy` isLeft

    it "A15a: exposes the guaranteed pretty-printed timeout schema" do
      timeoutJsonSchemaPretty `shouldSatisfy` contains "\"continue\""
      timeoutJsonSchemaPretty `shouldSatisfy` contains "\"interrupt\""

  ---------------------------------------------------------------------------
  -- A16 + A17: timeout check response handling
  ---------------------------------------------------------------------------

  describe "A16: structured timeout interrupt" do

    it "A16: interrupt action is accepted" do
      parseTimeoutDecision "{\"action\":\"interrupt\"}"
        `shouldEqual` Right InterruptForTimeout

  describe "A17: structured timeout continue" do

    it "A17: continue action is accepted" do
      parseTimeoutDecision "{\"action\":\"continue\"}"
        `shouldEqual` Right ContinueAfterTimeout

    it "A15a: timeout rejects reply actions" do
      parseTimeoutDecision "{\"action\":\"reply\",\"value\":\"x\"}"
        `shouldSatisfy` isLeft

    it "A15a: timeout rejects extra fields" do
      parseTimeoutDecision "{\"action\":\"continue\",\"value\":\"x\"}"
        `shouldSatisfy` isLeft

    it "A15a: timeout rejects legacy yes/no text" do
      parseTimeoutDecision "yes" `shouldSatisfy` isLeft

  where
  contains :: String -> String -> Boolean
  contains needle haystack =
    String.contains (String.Pattern needle) haystack
