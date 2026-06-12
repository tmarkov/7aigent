module Test.SummaryRequestSpec where

import Prelude

import Data.Either (Either(..), isLeft)
import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual, shouldSatisfy)

import Agent.Programs.SummaryRequest
    ( buildSummaryHistory
    , encodeSummaryError
    , encodeSummaryResult
    , parseSummaryResponse
    )
import Agent.Types (ConversationHistory(..), Message(..))

summaryRequestSpec :: Spec Unit
summaryRequestSpec = do
    describe "A20b: summary requests use the common structured LLM path" do
        it "A20b: builds an out-of-band history from the evidence request" do
            let request =
                    ( "{\"request_id\":\"r1\",\"target_ids\":[\"a\",\"b\"],"
                        <> "\"evidence\":{\"nodes\":[],\"witnesses\":[],"
                        <> "\"targets\":[]}}"
                    )
            case buildSummaryHistory request of
                Left err -> fail err
                Right result -> do
                    result.targetIds `shouldEqual` [ "a", "b" ]
                    let (ConversationHistory history) = result.history
                    case map _.message history.messages of
                        [ SystemMessage _, UserMessage user ] ->
                            user.content `shouldSatisfy`
                                String.contains (String.Pattern request)
                        _ ->
                            fail "Expected a system and user message"

        it "A20b: rejects malformed requests before building LLM history" do
            buildSummaryHistory
                ( "{\"request_id\":\"\",\"target_ids\":[\"a\"],"
                    <> "\"evidence\":{\"nodes\":[],\"witnesses\":[],"
                    <> "\"targets\":[]}}"
                )
                `shouldSatisfy` isLeft
            buildSummaryHistory
                ( "{\"request_id\":\"r1\",\"target_ids\":[\"a\",\"a\"],"
                    <> "\"evidence\":{\"nodes\":[],\"witnesses\":[],"
                    <> "\"targets\":[]}}"
                )
                `shouldSatisfy` isLeft
            buildSummaryHistory
                ( "{\"request_id\":\"r1\",\"target_ids\":[\"\"],"
                    <> "\"evidence\":{\"nodes\":[],\"witnesses\":[],"
                    <> "\"targets\":[]}}"
                )
                `shouldSatisfy` isLeft
            buildSummaryHistory
                ( "{\"request_id\":\"r1\",\"target_ids\":[\"a\"],"
                    <> "\"evidence\":{\"nodes\":[],\"witnesses\":[]}}"
                )
                `shouldSatisfy` isLeft
            buildSummaryHistory
                ( "{\"request_id\":\"r1\",\"target_ids\":[\"a\"],"
                    <> "\"evidence\":{\"nodes\":[],\"witnesses\":[],"
                    <> "\"targets\":[]},\"extra\":true}"
                )
                `shouldSatisfy` isLeft

        it "A20b: preserves requested order in a valid response" do
            parseSummaryResponse [ "b", "a" ]
                ( "{\"summaries\":[{\"id\":\"a\",\"summary\":\"A\"},"
                    <> "{\"id\":\"b\",\"summary\":\"B\"}]}"
                )
                `shouldEqual` Right
                    [ { id: "b", summary: "B" }
                    , { id: "a", summary: "A" }
                    ]

        it "A20b: rejects duplicate, omitted, and extra ids" do
            parseSummaryResponse [ "a" ]
                ( "{\"summaries\":[{\"id\":\"a\",\"summary\":\"A\"},"
                    <> "{\"id\":\"a\",\"summary\":\"Again\"}]}"
                )
                `shouldSatisfy` isLeft
            parseSummaryResponse [ "a", "b" ]
                "{\"summaries\":[{\"id\":\"a\",\"summary\":\"A\"}]}"
                `shouldSatisfy` isLeft
            parseSummaryResponse [ "a" ]
                ( "{\"summaries\":[{\"id\":\"a\",\"summary\":\"A\"},"
                    <> "{\"id\":\"b\",\"summary\":\"B\"}]}"
                )
                `shouldSatisfy` isLeft

        it "A20b: encodes successful and failed replies for Julia" do
            encodeSummaryResult [ { id: "a", summary: "Hello" } ]
                `shouldEqual` "ok\na\tSGVsbG8="
            encodeSummaryError "bad"
                `shouldEqual` "error\tYmFk"
