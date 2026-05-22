-- | Tests for reflection JSON parsing: A50.
module Test.ReflectionSpec where

import Prelude

import Data.Maybe (Maybe(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy)

import Agent.Programs.Reflection (parseReflectionResponse)

reflectionSpec :: Spec Unit
reflectionSpec = do

  ---------------------------------------------------------------------------
  -- A50: reflection response parsing
  ---------------------------------------------------------------------------

  describe "A50: parseReflectionResponse" do

    it "A50: {complete:true} → complete=true, feedback=Nothing" do
      let r = parseReflectionResponse "{\"complete\":true}"
      r.complete `shouldEqual` true
      r.feedback `shouldEqual` Nothing

    it "A50: {complete:false, feedback:…} → complete=false, feedback=Just" do
      let r = parseReflectionResponse
                "{\"complete\":false,\"feedback\":\"Run the failing tests.\"}"
      r.complete `shouldEqual` false
      r.feedback `shouldEqual` Just "Run the failing tests."

    it "A50: {complete:false} without feedback → complete=false, feedback=Nothing" do
      let r = parseReflectionResponse "{\"complete\":false}"
      r.complete `shouldEqual` false
      r.feedback `shouldEqual` Nothing

    it "A50: {complete:true, feedback:…} → complete=true, feedback present" do
      let r = parseReflectionResponse
                "{\"complete\":true,\"feedback\":\"All done.\"}"
      r.complete `shouldEqual` true
      r.feedback `shouldEqual` Just "All done."

    it "A50: invalid JSON → fallback with complete=false" do
      let r = parseReflectionResponse "not json at all"
      r.complete `shouldEqual` false

    it "A50: invalid JSON → fallback feedback mentions 'valid JSON'" do
      let r = parseReflectionResponse "not json"
      r.feedback `shouldSatisfy` \f -> case f of
        Just s  -> s == "Reflection call failed to return valid JSON."
        Nothing -> false

    it "A50: missing complete field → fallback with complete=false" do
      let r = parseReflectionResponse "{\"feedback\":\"try again\"}"
      r.complete `shouldEqual` false
      r.feedback `shouldEqual` Just "Reflection call failed to return valid JSON."

    it "A50: complete field is not boolean → fallback" do
      let r = parseReflectionResponse "{\"complete\":\"yes\"}"
      r.complete `shouldEqual` false

    it "A50: empty JSON object → fallback" do
      let r = parseReflectionResponse "{}"
      r.complete `shouldEqual` false

    it "A50: JSON array instead of object → fallback" do
      let r = parseReflectionResponse "[true]"
      r.complete `shouldEqual` false
