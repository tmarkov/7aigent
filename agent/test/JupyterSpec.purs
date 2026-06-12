-- | Tests for Jupyter iopub message processing: A4.
module Test.JupyterSpec where

import Prelude

import Data.Map as Map
import Data.String as String
import Data.Tuple (Tuple(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

import Agent.Programs.Jupyter (collectOutput, IopubMessage(..))
import Agent.Services.Jupyter (executeRequestAllowsStdin)

jupyterSpec :: Spec Unit
jupyterSpec = do

  describe "A4: iopub message concatenation" do

    it "A4: single execute_result → output is text/plain content" do
      let msgs =
            [ IopubExecuteResult
                { data: Map.singleton "text/plain" "42" }
            ]
      collectOutput msgs `shouldEqual` "42"

    it "A4: multiple stream messages → concatenated in order" do
      let msgs =
            [ IopubStream { name: "stdout", text: "hello " }
            , IopubStream { name: "stdout", text: "world" }
            ]
      collectOutput msgs `shouldEqual` "hello world"

    it "A4: stderr stream messages are included and concatenated in order" do
      let msgs =
            [ IopubStream { name: "stdout", text: "out" }
            , IopubStream { name: "stderr", text: "err" }
            ]
      let output = collectOutput msgs
      -- Both streams concatenated in receipt order
      collectOutput msgs `shouldEqual` "outerr"

    it "A4: error message → traceback lines joined" do
      let msgs =
            [ IopubError
                { traceback: [ "ERROR: UndefVarError: x not defined"
                             , "Stacktrace:"
                             , " [1] top-level scope"
                             ]
                }
            ]
      let output = collectOutput msgs
      shouldEqual true (contains "UndefVarError" output)

    it "A4: mixed stream + execute_result → all concatenated" do
      let msgs =
            [ IopubStream { name: "stdout", text: "printed\n" }
            , IopubExecuteResult
                { data: Map.singleton "text/plain" "result" }
            ]
      let output = collectOutput msgs
      shouldEqual true (contains "printed" output)
      shouldEqual true (contains "result" output)

    it "A4: display_data with text/plain → included" do
      let msgs =
            [ IopubDisplayData
                { data: Map.singleton "text/plain" "displayed value" }
            ]
      collectOutput msgs `shouldEqual` "displayed value"

    it "A4: empty message sequence → empty string" do
      collectOutput [] `shouldEqual` ""

  describe "A4: execute_request stdin support" do

    it "A4: enables stdin for ordinary Julia source" do
      executeRequestAllowsStdin "name = readline()" `shouldEqual` true

    it "A4: enables stdin even when source does not mention summarize!" do
      executeRequestAllowsStdin "readline()" `shouldEqual` true

  where
  contains :: String -> String -> Boolean
  contains needle haystack =
    String.contains (String.Pattern needle) haystack
