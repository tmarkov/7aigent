-- | Git staging execution.
-- | Covers requirement A5.
module Agent.Programs.GitStage
    ( runGitStageAll
    , runGitStagePlan
    ) where

import Prelude

import Data.Either (Either(..))
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Exception (message, try)

import Agent.Types (WorkspacePath(..), AppError(..))
import Agent.Programs.GitWritePlan (GitWritePlan, encodeWholeFilePlans)

foreign import execGitStageAll :: String -> Effect String
foreign import execGitStagePlan
    :: String
    -> Array { path :: String, oldPath :: String }
    -> String
    -> Effect String

runGitStageAll :: WorkspacePath -> Aff (Either AppError String)
runGitStageAll (WorkspacePath wp) =
    liftGitStageEffect (execGitStageAll wp)

runGitStagePlan :: WorkspacePath -> GitWritePlan -> Aff (Either AppError String)
runGitStagePlan (WorkspacePath wp) plan =
    liftGitStageEffect
        (execGitStagePlan wp (encodeWholeFilePlans plan.wholeFiles) plan.partialUnstagedPatch)

liftGitStageEffect :: Effect String -> Aff (Either AppError String)
liftGitStageEffect action = liftEffect do
    result <- try action
    pure case result of
        Left err -> Left (GitError (message err))
        Right summary -> Right summary
