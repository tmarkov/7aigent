-- | Tests for output threshold handling: A8, A9.
module Test.OutputThresholdSpec where

import Prelude

import Data.Array as Array
import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy)

import Agent.Programs.ToolOutput (processToolOutput)

outputThresholdSpec :: Spec Unit
outputThresholdSpec = do

  describe "A8 + A9: output threshold handling" do

    it "A9: output within threshold → LLM receives full output" do
      let output = "line 1\nline 2\nline 3"
      let result = processToolOutput 1000 output
      result.llmFacing `shouldEqual` output
      result.truncated `shouldEqual` false

    it "A8: output within threshold → display shows first 5 lines" do
      let output = String.joinWith "\n"
            ["line 1", "line 2", "line 3", "line 4", "line 5", "line 6", "line 7"]
      let result = processToolOutput 10000 output
      -- Display should show exactly the first 5 lines of a 7-line output
      let displayLines = Array.filter (_ /= "") (String.split (String.Pattern "\n") result.displayText)
      -- Must show exactly 5 content lines (not 6 or 7)
      Array.length displayLines `shouldEqual` 5

    it "A9: output exceeding threshold → LLM receives error message" do
      let output = String.joinWith "" (Array.replicate 100 "x")  -- 100 chars
      let result = processToolOutput 50 output  -- threshold = 50
      result.truncated `shouldEqual` true
      -- LLM-facing text should be an error, not the output
      result.llmFacing `shouldSatisfy` \s ->
        String.contains (String.Pattern "too large") (String.toLower s)
          || String.contains (String.Pattern "targeted") (String.toLower s)

    it "A9: full output is preserved for session log even when truncated" do
      let output = String.joinWith "" (Array.replicate 100 "y")
      let result = processToolOutput 50 output
      result.fullOutput `shouldEqual` output

    it "A8: output exceeding threshold → display shows the error message" do
      let output = String.joinWith "" (Array.replicate 100 "z")
      let result = processToolOutput 50 output
      -- Display should show the same error the LLM sees
      result.displayText `shouldEqual` result.llmFacing

    it "A9: output exactly at threshold → treated as within (not exceeding)" do
      let output = String.joinWith "" (Array.replicate 50 "a")  -- exactly 50 chars
      let result = processToolOutput 50 output
      result.truncated `shouldEqual` false
      result.llmFacing `shouldEqual` output
