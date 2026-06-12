-- | Tests for Jupyter iopub message processing: A4.
module Test.JupyterSpec where

import Prelude

import Data.Either (Either(..))
import Data.Map as Map
import Data.String as String
import Data.Tuple (Tuple(..))
import Effect.Aff (attempt)
import Effect.Class (liftEffect)
import Effect.Exception (message)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

import Agent.Programs.Jupyter (collectOutput, IopubMessage(..))
import Agent.Services.Jupyter
  ( classifySummaryInputPrompt
  , decodeSummaryCommContent
  , executeRequestAllowsStdin
  , interruptKernel
  , summaryCorrelationTimeoutMilliseconds
  )

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

  describe "A20b + A52: summary RPC protocol classification" do

    it "A20b: extracts the reserved summary input correlation id" do
      classifySummaryInputPrompt "7aigent.summary.reply:comm-42"
        `shouldEqual` "comm-42"
      classifySummaryInputPrompt "Name: "
        `shouldEqual` ""

    it "A20b: extracts only summary comm payloads" do
      decodeSummaryCommContent
        ( "{\"target_name\":\"7aigent.summary\",\"comm_id\":\"c1\","
          <> "\"data\":{\"target_ids\":[\"n1\"]}}"
        )
        `shouldEqual` "{\"target_ids\":[\"n1\"]}"
      decodeSummaryCommContent
        "{\"target_name\":\"other\",\"comm_id\":\"c1\",\"data\":{}}"
        `shouldEqual` ""

    it "A20b: uses a short timeout only for unmatched correlation" do
      summaryCorrelationTimeoutMilliseconds `shouldEqual` 10000

  describe "A16: interrupt completion" do

    it "A16: reports control-channel send failure as a kernel error" do
      let kernel =
            { execute: \_ _ _ onDone ->
                onDone { output: "", hadError: false }
            , interrupt: \onError _ -> onError "control socket closed"
            , close: pure unit
            }
      result <- attempt (interruptKernel kernel)
      case result of
        Left err ->
          message err `shouldEqual` "control socket closed"
        Right _ ->
          liftEffect $ shouldEqual "an interrupt failure" "success"

  where
  contains :: String -> String -> Boolean
  contains needle haystack =
    String.contains (String.Pattern needle) haystack
