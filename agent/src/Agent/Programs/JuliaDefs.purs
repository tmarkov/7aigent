-- | Julia definition extraction: identifies pure definitions and
-- | extracts them from session log events.
-- | Covers requirements A29, A30.
module Agent.Programs.JuliaDefs
    ( isPureDefinition
    , extractDefs
    ) where

import Prelude

import Data.Array as Array

import Agent.Types (LogEvent(..), ToolCallId)

-- FFI: uses Julia's Meta.parse to classify expressions
foreign import isPureDefinitionImpl :: String -> Boolean

----------------------------------------------------------------------------
-- A30: pure definition classification
----------------------------------------------------------------------------

isPureDefinition :: String -> Boolean
isPureDefinition = isPureDefinitionImpl

----------------------------------------------------------------------------
-- A29: extract pure definitions from session log events
----------------------------------------------------------------------------

extractDefs :: Array LogEvent -> Array String
extractDefs events =
    let
        juliaInputs = Array.concatMap extractJuliaInput events
    in
        Array.filter isPureDefinition juliaInputs

extractJuliaInput :: LogEvent -> Array String
extractJuliaInput (EvtToolCall r)
    | r.toolName == "julia_repl" = [r.input]
extractJuliaInput _ = []
