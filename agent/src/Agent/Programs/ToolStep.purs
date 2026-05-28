module Agent.Programs.ToolStep
    ( ToolPostMode(..)
    , ToolStepDecision(..)
    , toolStepDecision
    ) where

import Prelude

-- | The follow-up the runner would normally perform after a successful tool
-- | step. A timeout-driven Julia interrupt (A16) does not change this mode;
-- | it only changes the tool output returned to the LLM.
data ToolPostMode
    = ContinueAfterTool
    | CompactAfterTool
    | EndTurnAfterTool

derive instance Eq ToolPostMode
instance Show ToolPostMode where
    show ContinueAfterTool = "ContinueAfterTool"
    show CompactAfterTool = "CompactAfterTool"
    show EndTurnAfterTool = "EndTurnAfterTool"

data ToolStepDecision
    = ContinueTurn
    | CompactAndContinueTurn
    | EndTurnAndReflect

derive instance Eq ToolStepDecision
instance Show ToolStepDecision where
    show ContinueTurn = "ContinueTurn"
    show CompactAndContinueTurn = "CompactAndContinueTurn"
    show EndTurnAndReflect = "EndTurnAndReflect"

toolStepDecision
    :: ToolPostMode
    -> Boolean
    -> ToolStepDecision
toolStepDecision postMode _toolInterrupted =
    case postMode of
        ContinueAfterTool -> ContinueTurn
        CompactAfterTool -> CompactAndContinueTurn
        EndTurnAfterTool -> EndTurnAndReflect
