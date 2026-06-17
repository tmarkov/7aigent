-- | Tests for structured tool input parsing: A4.
module Test.ToolInputSpec where

import Prelude

import Data.Either (Either(..), isLeft)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy)

import Agent.Programs.ToolInput (parseJuliaReplInput)

toolInputSpec :: Spec Unit
toolInputSpec = do

  describe "A4: julia_repl input parsing" do

    it "A4: accepts integer timeout_seconds" do
      parseJuliaReplInput 300 "{\"code\":\"1 + 1\",\"timeout_seconds\":30}"
        `shouldEqual` Right { code: "1 + 1", timeoutSeconds: 30 }

    it "A4: rejects string timeout_seconds" do
      parseJuliaReplInput 300 "{\"code\":\"1 + 1\",\"timeout_seconds\":\"30\"}"
        `shouldSatisfy` isLeft

    it "A4: rejects fractional timeout_seconds" do
      parseJuliaReplInput 300 "{\"code\":\"1 + 1\",\"timeout_seconds\":1.4}"
        `shouldSatisfy` isLeft
