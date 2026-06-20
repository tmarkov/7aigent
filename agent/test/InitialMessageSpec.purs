module Test.InitialMessageSpec where

import Prelude

import Data.Either (Either(..), isLeft)
import Data.Maybe (Maybe(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy, fail)

import Agent.Programs.InitialMessage (parseInitialMessage)
import Agent.Programs.ToolInput (parseJuliaReplInput)
import Agent.Types (ToolCallId(..), ToolName(..))

initialMessageSpec :: Spec Unit
initialMessageSpec = do

  describe "A22b: initial_message parser" do

    it "A22b: valid marker with escaped newlines, whitespace, and literal {{...}} parses into one julia_repl tool call" do
      let input = """
I'll inspect the initial code tree.

Literal braces stay: {{user_message}}

<<  julia_repl (
  "db.code\n|> first",
  30
)  >>
"""
      case parseInitialMessage 300 input of
        Right (Just parsed) -> do
          parsed.assistantContent `shouldEqual`
            """
I'll inspect the initial code tree.

Literal braces stay: {{user_message}}


"""
          parsed.toolCall.name `shouldEqual` JuliaRepl
          parsed.toolCall.id `shouldEqual` ToolCallId "initial_seed"
          case parseJuliaReplInput 300 parsed.toolCall.input of
            Right toolInput -> do
              toolInput.code `shouldEqual` "db.code\n|> first"
              toolInput.timeoutSeconds `shouldEqual` 30
            Left err -> fail err
        Right Nothing -> fail "Expected parsed initial seed"
        Left err -> fail err

    it "A22b: whitespace-only file means no initial seed" do
      parseInitialMessage 300 " \n\t\r\n " `shouldEqual` Right Nothing

    it "A22b: rejects >> inside the Julia source JSON string literal" do
      parseInitialMessage 300 "<<julia_repl(\"println(\\\">>\\\")\", 30)>>"
        `shouldSatisfy` isLeft

    it "A22b: literal <<...>> text outside the real marker is preserved" do
      let input = """
Note: <<draft>>

<<julia_repl("db.code", 3)>>
"""
      case parseInitialMessage 300 input of
        Right (Just parsed) -> do
          parsed.assistantContent `shouldEqual`
            """
Note: <<draft>>


"""
          case parseJuliaReplInput 300 parsed.toolCall.input of
            Right toolInput -> do
              toolInput.code `shouldEqual` "db.code"
              toolInput.timeoutSeconds `shouldEqual` 3
            Left err -> fail err
        Right Nothing -> fail "Expected parsed initial seed"
        Left err -> fail err

    it "A22b: rejects zero markers" do
      parseInitialMessage 300 "Hello without a tool call." `shouldSatisfy` isLeft

    it "A22b: rejects multiple markers" do
      let input = """
Before
<<julia_repl("x", 10)>>
Middle
<<julia_repl("y", 10)>>
"""
      parseInitialMessage 300 input `shouldSatisfy` isLeft

    it "A22b: rejects malformed JSON string literal" do
      parseInitialMessage 300 "<<julia_repl(not-a-json-string, 10)>>"
        `shouldSatisfy` isLeft

    it "A22b: rejects non-positive timeout" do
      parseInitialMessage 300 "<<julia_repl(\"x\", 0)>>"
        `shouldSatisfy` isLeft

    it "A22b: rejects timeout above max_repl_timeout_seconds" do
      parseInitialMessage 30 "<<julia_repl(\"x\", 31)>>"
        `shouldSatisfy` isLeft
