-- | Tests for model-selected timeout checks: A14, A15, A16, A17.
module Test.TimeoutSpec where

import Prelude

import Data.Either (Either(..), isLeft)
import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy, fail)

import Agent.Programs.ExecutionDecision
  ( TimeoutDecision(..)
  , parseTimeoutDecision
  , renderTimeoutPrompt
  , timeoutJsonSchemaPretty
  )

timeoutSpec :: Spec Unit
timeoutSpec = do

  ---------------------------------------------------------------------------
  -- A15: timeout check request construction
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
          prompt `shouldSatisfy` contains "\"wait\""
          prompt `shouldSatisfy` contains "\"send_input\""
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
      timeoutJsonSchemaPretty `shouldSatisfy` contains "\"wait\""
      timeoutJsonSchemaPretty `shouldSatisfy` contains "\"timeout_seconds\""
      timeoutJsonSchemaPretty `shouldSatisfy` contains "\"send_input\""
      timeoutJsonSchemaPretty `shouldSatisfy` contains "\"value\""
      timeoutJsonSchemaPretty `shouldSatisfy` contains "\"interrupt\""

  ---------------------------------------------------------------------------
  -- A16 + A17: timeout check response handling
  ---------------------------------------------------------------------------

  describe "A16: structured timeout interrupt" do

    it "A16: interrupt action is accepted" do
      parseTimeoutDecision "{\"action\":\"interrupt\"}"
        `shouldEqual` Right InterruptForTimeout

  describe "A17: structured timeout wait" do

    it "A17: wait action with next timeout is accepted" do
      parseTimeoutDecision "{\"action\":\"wait\",\"timeout_seconds\":10}"
        `shouldEqual` Right (WaitAfterTimeout 10)

    it "A17a: send_input action with a value is accepted" do
      parseTimeoutDecision "{\"action\":\"send_input\",\"value\":\"123\\n\"}"
        `shouldEqual` Right (SendInputForTimeout "123\n")

    it "A15a: timeout rejects reply actions" do
      parseTimeoutDecision "{\"action\":\"reply\",\"value\":\"x\"}"
        `shouldSatisfy` isLeft

    it "A15a: timeout rejects extra fields" do
      parseTimeoutDecision "{\"action\":\"wait\",\"timeout_seconds\":10,\"value\":\"x\"}"
        `shouldSatisfy` isLeft

    it "A15a: timeout rejects send_input without value" do
      parseTimeoutDecision "{\"action\":\"send_input\"}"
        `shouldSatisfy` isLeft

    it "A15a: timeout rejects wait without a next timeout" do
      parseTimeoutDecision "{\"action\":\"wait\"}"
        `shouldSatisfy` isLeft

    it "A15a: timeout rejects non-positive wait timeouts" do
      parseTimeoutDecision "{\"action\":\"wait\",\"timeout_seconds\":0}"
        `shouldSatisfy` isLeft

    it "A15a: timeout rejects legacy yes/no text" do
      parseTimeoutDecision "yes" `shouldSatisfy` isLeft

  where
  contains :: String -> String -> Boolean
  contains needle haystack =
    String.contains (String.Pattern needle) haystack
