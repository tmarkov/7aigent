-- | Tests for REPL serialization snippet construction: A28.
module Test.ReplSerializeSpec where

import Prelude

import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy)

import Agent.Programs.ReplSerialize (buildRestoreSnippet, buildSerializationSnippet)
import Agent.Types (SessionId(..))

replSerializeSpec :: Spec Unit
replSerializeSpec = do

  ---------------------------------------------------------------------------
  -- A28: REPL state serialization snippet
  ---------------------------------------------------------------------------

  describe "A28: serialization snippet construction" do

    it "A28: snippet iterates names(Main, all=false)" do
      let snippet = buildSerializationSnippet (SessionId 1) "/workspace"
      snippet `shouldSatisfy` contains "names(Main"

    it "A28: snippet calls Serialization.serialize" do
      let snippet = buildSerializationSnippet (SessionId 1) "/workspace"
      snippet `shouldSatisfy` contains "Serialization.serialize"

    it "A28: snippet serializes each binding through an IOBuffer payload" do
      let snippet = buildSerializationSnippet (SessionId 1) "/workspace"
      snippet `shouldSatisfy` contains "IOBuffer()"
      snippet `shouldSatisfy` contains "take!(_buf)"

    it "A28: snippet writes to correct session path" do
      let snippet = buildSerializationSnippet (SessionId 5) "/workspace"
      snippet `shouldSatisfy` contains ".7aigent/sessions/5/julia_state.jls"

    it "A28: snippet skips failed serializations without error" do
      let snippet = buildSerializationSnippet (SessionId 1) "/workspace"
      -- The snippet should use try/catch to skip failures
      snippet `shouldSatisfy` contains "try"

    it "A28: snippet uses workspace path from argument" do
      let snippet = buildSerializationSnippet (SessionId 1) "/home/user/project"
      snippet `shouldSatisfy` contains "/home/user/project"

  describe "A31 + A32: restore snippet construction" do

    it "A31: snippet deserializes entries and rebinds them in Main" do
      let snippet = buildRestoreSnippet (SessionId 3) "/workspace"
      snippet `shouldSatisfy` contains "Serialization.deserialize"
      snippet `shouldSatisfy` contains "Core.eval(Main"

    it "A32: snippet catches per-binding restore failures" do
      let snippet = buildRestoreSnippet (SessionId 3) "/workspace"
      snippet `shouldSatisfy` contains "failed to restore"
      snippet `shouldSatisfy` contains "catch e"

  where
  contains :: String -> String -> Boolean
  contains needle haystack =
    String.contains (String.Pattern needle) haystack
