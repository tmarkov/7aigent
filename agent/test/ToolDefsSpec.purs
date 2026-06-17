-- | Tests for tool schema definitions: A3.
module Test.ToolDefsSpec where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, fail)

import Agent.Programs.ToolDefs (toolDefinitions, ToolDef)
import Agent.Types (renderToolName)

toolDefsSpec :: Spec Unit
toolDefsSpec = do

  describe "A3: tool definitions" do

    it "A3: exactly 3 tools are defined" do
      Array.length toolDefinitions `shouldEqual` 3

    it "A3 + A4: julia_repl tool requires 'code' and 'timeout_seconds'" do
      case findTool "julia_repl" of
        Just tool -> do
          renderToolName tool.name `shouldEqual` "julia_repl"
          hasRequiredParam tool "code" `shouldEqual` true
          hasRequiredParam tool "timeout_seconds" `shouldEqual` true
          paramSchemaType tool "code" `shouldEqual` Just "string"
          paramSchemaType tool "timeout_seconds" `shouldEqual` Just "integer"
        Nothing ->
          fail "julia_repl tool not found in definitions"

    it "A3: git_stage tool has the required 'what' parameter" do
      case findTool "git_stage" of
        Just tool -> do
          renderToolName tool.name `shouldEqual` "git_stage"
          hasRequiredParam tool "what" `shouldEqual` true
        Nothing ->
          fail "git_stage tool not found in definitions"

    it "A3: git_commit tool has required 'what' and 'message', optional 'body'" do
      case findTool "git_commit" of
        Just tool -> do
          renderToolName tool.name `shouldEqual` "git_commit"
          hasRequiredParam tool "what" `shouldEqual` true
          hasRequiredParam tool "message" `shouldEqual` true
          hasOptionalParam tool "body" `shouldEqual` true
        Nothing ->
          fail "git_commit tool not found in definitions"

  where
  findTool :: String -> Maybe ToolDef
  findTool name = Array.find (\t -> renderToolName t.name == name) toolDefinitions

  hasRequiredParam :: ToolDef -> String -> Boolean
  hasRequiredParam tool paramName =
    Array.any (\p -> p.name == paramName && p.required) tool.parameters

  hasOptionalParam :: ToolDef -> String -> Boolean
  hasOptionalParam tool paramName =
    Array.any (\p -> p.name == paramName && not p.required) tool.parameters

  paramSchemaType :: ToolDef -> String -> Maybe String
  paramSchemaType tool paramName =
    _.schemaType <$> Array.find (\p -> p.name == paramName) tool.parameters
