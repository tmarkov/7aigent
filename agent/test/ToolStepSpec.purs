-- | Tests for post-tool control flow: A16, A37a, A48.
module Test.ToolStepSpec where

import Prelude

import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

import Agent.Programs.ToolStep
  ( ToolPostMode(..)
  , ToolStepDecision(..)
  , toolStepDecision
  )

toolStepSpec :: Spec Unit
toolStepSpec = do

  describe "A16 + A48: timeout-interrupted tool results keep normal turn flow" do

    it "A16 + A48: interruption flag does not alter the follow-up mode" do
      toolStepDecision ContinueAfterTool true `shouldEqual`
        toolStepDecision ContinueAfterTool false
      toolStepDecision CompactAfterTool true `shouldEqual`
        toolStepDecision CompactAfterTool false
      toolStepDecision EndTurnAfterTool true `shouldEqual`
        toolStepDecision EndTurnAfterTool false

    it "A16 + A48: interrupted tool with ordinary follow-up → ContinueTurn" do
      toolStepDecision ContinueAfterTool true `shouldEqual` ContinueTurn

    it "A16 + A48: interrupted tool with compaction due → CompactAndContinueTurn" do
      toolStepDecision CompactAfterTool true `shouldEqual` CompactAndContinueTurn

    it "A16 + A37a + A48: interrupted tool at token limit → EndTurnAndReflect" do
      toolStepDecision EndTurnAfterTool true `shouldEqual` EndTurnAndReflect
