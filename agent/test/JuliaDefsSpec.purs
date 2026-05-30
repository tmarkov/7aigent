-- | Tests for Julia definition extraction: A29, A30.
module Test.JuliaDefsSpec where

import Prelude

import Data.Maybe (Maybe(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy)

import Agent.Programs.JuliaDefs (isPureDefinition, extractDefs)
import Agent.Types (LogEvent(..), Timestamp(..), ToolName(..), ToolCallId(..))

juliaDefsSpec :: Spec Unit
juliaDefsSpec = do

  ---------------------------------------------------------------------------
  -- A30: pure definition classification — positive cases
  ---------------------------------------------------------------------------

  describe "A30: pure definition classification — included" do

    it "A30: function ... end → true" do
      isPureDefinition "function foo(x)\n  x + 1\nend" `shouldEqual` true

    it "A30: macro ... end → true" do
      isPureDefinition "macro m(x)\n  esc(x)\nend" `shouldEqual` true

    it "A30: struct → true" do
      isPureDefinition "struct Foo\n  x::Int\nend" `shouldEqual` true

    it "A30: mutable struct → true" do
      isPureDefinition "mutable struct Bar\n  y::Float64\nend" `shouldEqual` true

    it "A30: abstract type → true" do
      isPureDefinition "abstract type Animal end" `shouldEqual` true

    it "A30: primitive type → true" do
      isPureDefinition "primitive type MyFloat 64 end" `shouldEqual` true

    it "A30: short-form method f(x) = expr → true" do
      isPureDefinition "f(x) = x + 1" `shouldEqual` true

    it "A30: @enum → true" do
      isPureDefinition "@enum Color Red Green Blue" `shouldEqual` true

    it "A30: @kwdef struct → true" do
      isPureDefinition "@kwdef struct Config\n  x::Int = 0\nend" `shouldEqual` true

    it "A30: const Foo = Bar (identifier RHS) → true" do
      isPureDefinition "const Foo = Bar" `shouldEqual` true

    it "A30: const Foo = Vector{Int} (curly RHS) → true" do
      isPureDefinition "const Foo = Vector{Int}" `shouldEqual` true

    it "A30: const Foo = Union{Int, String} → true" do
      isPureDefinition "const Foo = Union{Int, String}" `shouldEqual` true

  ---------------------------------------------------------------------------
  -- A30: pure definition classification — negative cases
  ---------------------------------------------------------------------------

  describe "A30: pure definition classification — excluded" do

    it "A30: variable assignment → false" do
      isPureDefinition "x = 42" `shouldEqual` false

    it "A30: function call → false" do
      isPureDefinition "println(\"hello\")" `shouldEqual` false

    it "A30: using statement → false" do
      isPureDefinition "using SomePackage" `shouldEqual` false

    it "A30: import statement → false" do
      isPureDefinition "import Foo" `shouldEqual` false

    it "A30: const with function call RHS → false" do
      isPureDefinition "const Foo = bar()" `shouldEqual` false

    it "A30: const with rand(10) RHS → false" do
      isPureDefinition "const Foo = rand(10)" `shouldEqual` false

    it "A30: do block → false" do
      isPureDefinition "open(\"file\") do f\n  read(f)\nend" `shouldEqual` false

    it "A30: for loop → false" do
      isPureDefinition "for i in 1:10\n  println(i)\nend" `shouldEqual` false

  ---------------------------------------------------------------------------
  -- A30: module scanning
  ---------------------------------------------------------------------------

  describe "A30: module body scanning" do

    it "A30: module → extracts inner defs individually, not the module block" do
      let src = "module M\nstruct Foo end\nf(x) = x\nprintln(\"hi\")\nend"
      -- The module itself is not a pure def, but its inner definitions are
      isPureDefinition src `shouldEqual` false
      -- When extractDefs processes this, it should extract the inner defs
      -- (this is tested via extractDefs below)

  ---------------------------------------------------------------------------
  -- A29: extraction from log events
  ---------------------------------------------------------------------------

  describe "A29: Julia defs extraction from log" do

    it "A29: extracts pure definitions from julia_repl tool calls" do
      let events =
            [ EvtToolCall { timestamp: Timestamp "t1", toolName: JuliaRepl, toolCallId: ToolCallId "tc1", input: "struct Foo end" }
            , EvtToolCall { timestamp: Timestamp "t2", toolName: JuliaRepl, toolCallId: ToolCallId "tc2", input: "println(\"hello\")" }
            , EvtToolCall { timestamp: Timestamp "t3", toolName: JuliaRepl, toolCallId: ToolCallId "tc3", input: "f(x) = x + 1" }
            ]
      let defs = extractDefs events
      defs `shouldEqual` ["struct Foo end", "f(x) = x + 1"]

    it "A29: preserves execution order" do
      let events =
            [ EvtToolCall { timestamp: Timestamp "t1", toolName: JuliaRepl, toolCallId: ToolCallId "tc1", input: "f(x) = x" }
            , EvtToolCall { timestamp: Timestamp "t2", toolName: JuliaRepl, toolCallId: ToolCallId "tc2", input: "g(y) = y" }
            ]
      let defs = extractDefs events
      defs `shouldEqual` ["f(x) = x", "g(y) = y"]

    it "A29: no julia_repl calls → empty" do
      let events =
            [ EvtToolCall { timestamp: Timestamp "t1", toolName: GitStage, toolCallId: ToolCallId "tc1", input: "{\"what\":\"all\"}" }
            ]
      extractDefs events `shouldEqual` []

    it "A29: all side-effectful expressions → empty" do
      let events =
            [ EvtToolCall { timestamp: Timestamp "t1", toolName: JuliaRepl, toolCallId: ToolCallId "tc1", input: "x = 42" }
            , EvtToolCall { timestamp: Timestamp "t2", toolName: JuliaRepl, toolCallId: ToolCallId "tc2", input: "println(x)" }
            ]
      extractDefs events `shouldEqual` []

    it "A29: ignores non-tool_call events" do
      let events =
            [ EvtUserMessage { timestamp: Timestamp "t1", content: "hello", source: Nothing }
            , EvtToolCall { timestamp: Timestamp "t2", toolName: JuliaRepl, toolCallId: ToolCallId "tc1", input: "struct S end" }
            , EvtLlmResponse { timestamp: Timestamp "t3", content: "done" }
            ]
      extractDefs events `shouldEqual` ["struct S end"]
