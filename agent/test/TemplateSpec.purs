-- | Tests for template substitution: A21 (system prompt), A22 (placeholders),
-- | A23 (unknown keyword), A35 (compaction templates), A45 (steering keywords).
module Test.TemplateSpec where

import Prelude

import Data.Either (Either(..), isLeft)
import Data.Map as Map
import Data.String as String
import Data.Tuple (Tuple(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy, fail)

import Agent.Programs.Template (substituteTemplate)

templateSpec :: Spec Unit
templateSpec = do

  ---------------------------------------------------------------------------
  -- A21: system prompt template substitution
  ---------------------------------------------------------------------------

  describe "A21: system prompt template substitution" do

    it "A21: replaces {{datetime}} with provided value" do
      let subs = Map.singleton "datetime" "2026-01-15T12:00:00Z"
      let template = "Current time: {{datetime}}"
      case substituteTemplate subs template of
        Right result -> result `shouldEqual` "Current time: 2026-01-15T12:00:00Z"
        Left err -> fail (show err)

    it "A21: replaces {{model}} with model name" do
      let subs = Map.singleton "model" "claude-opus"
      let template = "Model: {{model}}"
      case substituteTemplate subs template of
        Right result -> result `shouldEqual` "Model: claude-opus"
        Left err -> fail (show err)

    it "A21: replaces {{initial_repl_output}} with REPL output" do
      let subs = Map.singleton "initial_repl_output" "db loaded, 42 nodes"
      let template = "Startup:\n```\n{{initial_repl_output}}\n```"
      case substituteTemplate subs template of
        Right result ->
          String.contains (String.Pattern "db loaded, 42 nodes") result
            `shouldEqual` true
        Left err -> fail (show err)

    it "A22: replaces {{agents_md}} with file content or empty string" do
      let subs = Map.singleton "agents_md" ""
      let template = "Guide: {{agents_md}}"
      case substituteTemplate subs template of
        Right result -> result `shouldEqual` "Guide: "
        Left err -> fail (show err)

    it "A22: replaces {{startup_jl}} with startup file contents" do
      let subs = Map.singleton "startup_jl" "using CodeTree\nglobal db = CodeTree.load(\"/workspace\")"
      let template = "Startup:\n```julia\n{{startup_jl}}\n```"
      case substituteTemplate subs template of
        Right result ->
          String.contains
            (String.Pattern "global db = CodeTree.load(\"/workspace\")")
            result
            `shouldEqual` true
        Left err -> fail (show err)

    it "A21: preserves single { and } literally" do
      let subs = Map.singleton "model" "test"
      let template = "JSON: {\"key\": \"value\"} model={{model}}"
      case substituteTemplate subs template of
        Right result ->
          String.contains (String.Pattern "{\"key\": \"value\"}") result
            `shouldEqual` true
        Left err -> fail (show err)

    it "A21: substitutes multiple placeholders in one template" do
      let subs = Map.fromFoldable
            [ Tuple "datetime" "2026-01-15"
            , Tuple "model" "test-model"
            , Tuple "initial_repl_output" "ok"
            , Tuple "agents_md" "# Guide"
            , Tuple "startup_jl" "using CodeTree"
            ]
      let template = "{{datetime}} {{model}} {{initial_repl_output}} {{agents_md}} {{startup_jl}}"
      case substituteTemplate subs template of
        Right result ->
          result `shouldEqual`
            "2026-01-15 test-model ok # Guide using CodeTree"
        Left err -> fail (show err)

  ---------------------------------------------------------------------------
  -- A23: unknown keyword
  ---------------------------------------------------------------------------

  describe "A23: unknown keyword in template" do

    it "A23: error on unrecognised {{keyword}}" do
      let subs = Map.singleton "model" "test"
      let template = "Hello {{unknown_keyword}}"
      substituteTemplate subs template `shouldSatisfy` isLeft

    it "A23: error names the unrecognised keyword" do
      let subs = Map.singleton "model" "test"
      let template = "{{bogus_placeholder}}"
      case substituteTemplate subs template of
        Left err ->
          String.contains (String.Pattern "bogus_placeholder") (show err)
            `shouldEqual` true
        Right _ ->
          fail "Expected error for unknown keyword"

    it "A23: one valid + one invalid keyword → error (no partial substitution)" do
      let subs = Map.singleton "model" "test"
      let template = "{{model}} and {{nonexistent}}"
      substituteTemplate subs template `shouldSatisfy` isLeft

  ---------------------------------------------------------------------------
  -- A35: compaction templates
  ---------------------------------------------------------------------------

  describe "A35: compaction prompt template" do

    it "A35: substitutes {{initial_messages}}, {{compacted_messages}}, {{final_messages}}" do
      let subs = Map.fromFoldable
            [ Tuple "initial_messages" "[system prompt, first user msg]"
            , Tuple "compacted_messages" "[tool calls, responses]"
            , Tuple "final_messages" "[last exchange]"
            ]
      let template = "Initial:\n{{initial_messages}}\n\nMiddle:\n{{compacted_messages}}\n\nRecent:\n{{final_messages}}"
      case substituteTemplate subs template of
        Right result -> do
          String.contains (String.Pattern "[system prompt, first user msg]") result
            `shouldEqual` true
          String.contains (String.Pattern "[tool calls, responses]") result
            `shouldEqual` true
          String.contains (String.Pattern "[last exchange]") result
            `shouldEqual` true
        Left err -> fail (show err)

  describe "A35: summary message template" do

    it "A35: substitutes {{summary}} into synthetic user message" do
      let subs = Map.singleton "summary" "The user asked about X and we found Y."
      let template = "Earlier in this conversation:\n\n{{summary}}\n\nFull history follows."
      case substituteTemplate subs template of
        Right result ->
          String.contains (String.Pattern "The user asked about X and we found Y.") result
            `shouldEqual` true
        Left err -> fail (show err)

    it "A35: unrecognised keyword in compaction template → error" do
      let subs = Map.singleton "summary" "text"
      let template = "{{summary}} and {{bad_keyword}}"
      substituteTemplate subs template `shouldSatisfy` isLeft

  ---------------------------------------------------------------------------
  -- A35: {{julia_state}} keyword in compaction templates
  ---------------------------------------------------------------------------

  describe "A35: {{julia_state}} in compaction prompt template" do

    it "A35: {{julia_state}} substitutes task-state text in compaction prompt" do
      let subs = Map.fromFoldable
            [ Tuple "initial_messages" "[sys]"
            , Tuple "compacted_messages" "[msgs]"
            , Tuple "final_messages" "[last]"
            , Tuple "julia_state" "[Tasks: 1 done · 1 in progress · 0 pending]"
            ]
      let template = "{{compacted_messages}}\n{{julia_state}}"
      case substituteTemplate subs template of
        Right result ->
          String.contains (String.Pattern "[Tasks: 1 done") result `shouldEqual` true
        Left err -> fail (show err)

    it "A35: {{julia_state}} as empty string is valid" do
      let subs = Map.fromFoldable
            [ Tuple "initial_messages" ""
            , Tuple "compacted_messages" ""
            , Tuple "final_messages" ""
            , Tuple "julia_state" ""
            ]
      let template = "{{compacted_messages}}{{julia_state}}"
      case substituteTemplate subs template of
        Right result -> result `shouldEqual` ""
        Left err -> fail (show err)

  ---------------------------------------------------------------------------
  -- A21: malformed template syntax
  ---------------------------------------------------------------------------

  describe "A21: malformed template syntax" do

    it "A21: unclosed {{ without }} → error" do
      let subs = Map.singleton "model" "test"
      let template = "Hello {{broken"
      substituteTemplate subs template `shouldSatisfy` isLeft

    it "A21: empty placeholder {{}} → error" do
      let subs = Map.singleton "model" "test"
      let template = "Hello {{}} world"
      substituteTemplate subs template `shouldSatisfy` isLeft

    it "A21: nested braces {{{{x}}}} → error" do
      let subs = Map.singleton "x" "val"
      let template = "Hello {{{{x}}}} world"
      substituteTemplate subs template `shouldSatisfy` isLeft
