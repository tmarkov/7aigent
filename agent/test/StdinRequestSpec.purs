module Test.StdinRequestSpec where

import Prelude

import Data.Either (Either(..), isLeft)
import Data.Maybe (Maybe(..))
import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual, shouldSatisfy)

import Agent.Programs.ExecutionDecision
    ( DecisionFailure(..)
    , StdinDecision(..)
    , decisionRetryDelayMilliseconds
    , parseStdinDecision
    , renderInputAnnotation
    , renderStdinPrompt
    , stdinJsonSchemaPretty
    )

stdinRequestSpec :: Spec Unit
stdinRequestSpec = do
    describe "A53 + A53a: stdin prompt construction" do
        it "A53: substitutes every supported keyword with its defined value" do
            let template = String.joinWith "|"
                    [ "{{julia_source}}"
                    , "{{elapsed_time}}"
                    , "{{output_so_far}}"
                    , "{{prompt}}"
                    , "{{json_schema}}"
                    ]
            let result = renderStdinPrompt template
                    { juliaSource: "readline()"
                    , elapsedSeconds: 12
                    , outputSoFar: "ready"
                    , prompt: "Name: "
                    }
            case result of
                Left err -> fail ("Expected valid prompt, got " <> show err)
                Right prompt -> do
                    prompt `shouldSatisfy` contains "readline()|12|ready|Name: |"
                    prompt `shouldSatisfy` contains "\"additionalProperties\": false"

        it "A21 + A53: accepts a template containing only a subset of keywords" do
            let result = renderStdinPrompt
                    "Reply to: {{prompt}}"
                    { juliaSource: "readline()"
                    , elapsedSeconds: 0
                    , outputSoFar: ""
                    , prompt: "Continue? "
                    }
            case result of
                Left err -> fail ("Expected valid prompt, got " <> show err)
                Right prompt -> prompt `shouldEqual` "Reply to: Continue? "

        it "A53: rejects an unrecognised keyword" do
            renderStdinPrompt "{{missing}}"
                { juliaSource: ""
                , elapsedSeconds: 0
                , outputSoFar: ""
                , prompt: ""
                }
                `shouldSatisfy` isLeft

        it "A53a: exposes the guaranteed pretty-printed schema" do
            stdinJsonSchemaPretty `shouldSatisfy` contains "\"required\": ["
            stdinJsonSchemaPretty `shouldSatisfy` contains "\"value\""
            stdinJsonSchemaPretty `shouldSatisfy` contains "\"interrupt\""

    describe "A54 + A54a: stdin response validation" do
        it "A54: accepts a reply action with a string value" do
            parseStdinDecision "{\"action\":\"reply\",\"value\":\"yes\"}"
                `shouldEqual` Right (ReplyWithInput "yes")

        it "A54: accepts an interrupt action without a value" do
            parseStdinDecision "{\"action\":\"interrupt\"}"
                `shouldEqual` Right InterruptForStdin

        it "A54a: rejects missing fields" do
            parseStdinDecision "{\"value\":\"yes\"}" `shouldSatisfy` isLeft

        it "A54a: rejects extra fields" do
            parseStdinDecision
                "{\"action\":\"reply\",\"value\":\"yes\",\"extra\":1}"
                `shouldSatisfy` isLeft

        it "A54a: rejects incorrectly typed fields" do
            parseStdinDecision "{\"action\":\"reply\",\"value\":1}"
                `shouldSatisfy` isLeft

        it "A54a: rejects non-JSON output" do
            parseStdinDecision "yes" `shouldSatisfy` isLeft

        it "A53a: rejects continue because stdin requires reply or interrupt" do
            parseStdinDecision "{\"action\":\"continue\"}" `shouldSatisfy` isLeft

        it "A53a: rejects a value on interrupt" do
            parseStdinDecision "{\"action\":\"interrupt\",\"value\":\"unused\"}"
                `shouldSatisfy` isLeft

    describe "A54: input annotations" do
        it "A54: JSON-encodes input in the accumulated output" do
            renderInputAnnotation "a\n\"b"
                `shouldEqual` "\n[input: \"a\\n\\\"b\"]"

    describe "A15a + A54a: decision retry timing" do
        it "A15a: API failures use exponential backoff" do
            decisionRetryDelayMilliseconds 1 (DecisionApiFailure "network")
                `shouldEqual` Just 1000
            decisionRetryDelayMilliseconds 2 (DecisionApiFailure "network")
                `shouldEqual` Just 2000

        it "A54a: parse and validation failures retry immediately" do
            decisionRetryDelayMilliseconds 1
                (DecisionResponseFailure "invalid JSON")
                `shouldEqual` Nothing

  where
    contains needle haystack =
        String.contains (String.Pattern needle) haystack
