-- | Tests for tool schema definitions: A3.
module Test.ToolDefsSpec where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy, fail)

import Agent.Programs.ToolDefs (toolDefinitions, ToolDef)

toolDefsSpec :: Spec Unit
toolDefsSpec = do

  describe "A3: tool definitions" do

    it "A3: exactly 3 tools are defined" do
      Array.length toolDefinitions `shouldEqual` 3

    it "A3: julia_repl tool is defined with a required 'code' parameter" do
      case findTool "julia_repl" of
        Just tool -> do
          tool.name `shouldEqual` "julia_repl"
          hasRequiredParam tool "code" `shouldEqual` true
        Nothing ->
          fail "julia_repl tool not found in definitions"

    it "A3: git_diff tool is defined with no parameters" do
      case findTool "git_diff" of
        Just tool -> do
          tool.name `shouldEqual` "git_diff"
          Array.length tool.parameters `shouldEqual` 0
        Nothing ->
          fail "git_diff tool not found in definitions"

    it "A3: git_commit tool has required 'what' and 'message', optional 'body'" do
      case findTool "git_commit" of
        Just tool -> do
          tool.name `shouldEqual` "git_commit"
          hasRequiredParam tool "what" `shouldEqual` true
          hasRequiredParam tool "message" `shouldEqual` true
          hasOptionalParam tool "body" `shouldEqual` true
        Nothing ->
          fail "git_commit tool not found in definitions"

  where
  findTool :: String -> Maybe ToolDef
  findTool name = Array.find (\t -> t.name == name) toolDefinitions

  hasRequiredParam :: ToolDef -> String -> Boolean
  hasRequiredParam tool paramName =
    Array.any (\p -> p.name == paramName && p.required) tool.parameters

  hasOptionalParam :: ToolDef -> String -> Boolean
  hasOptionalParam tool paramName =
    Array.any (\p -> p.name == paramName && not p.required) tool.parameters
