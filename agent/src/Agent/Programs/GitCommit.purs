-- | Git commit execution.
-- | Covers requirement A6.
module Agent.Programs.GitCommit
    ( runGitCommitAll
    , runGitCommitStaged
    , runGitCommitPlan
    ) where

import Prelude

import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Exception (message, try)

import Agent.Types (WorkspacePath(..), AppError(..))
import Agent.Programs.GitWritePlan (GitWritePlan, encodeWholeFilePlans)

foreign import execGitCommitAll :: String -> String -> Effect String
foreign import execGitCommitStaged :: String -> String -> Effect String
foreign import execGitCommitPlan
    :: String
    -> String
    -> Array { path :: String, oldPath :: String }
    -> String
    -> String
    -> Effect String

runGitCommitAll
    :: WorkspacePath
    -> String
    -> Maybe String
    -> Aff (Either AppError String)
runGitCommitAll (WorkspacePath wp) subject body =
    liftGitCommitEffect (execGitCommitAll wp (buildCommitMessage subject body))

runGitCommitStaged
    :: WorkspacePath
    -> String
    -> Maybe String
    -> Aff (Either AppError String)
runGitCommitStaged (WorkspacePath wp) subject body =
    liftGitCommitEffect (execGitCommitStaged wp (buildCommitMessage subject body))

runGitCommitPlan
    :: WorkspacePath
    -> GitWritePlan
    -> String
    -> Maybe String
    -> Aff (Either AppError String)
runGitCommitPlan (WorkspacePath wp) plan subject body =
    liftGitCommitEffect
        (execGitCommitPlan
            wp
            (buildCommitMessage subject body)
            (encodeWholeFilePlans plan.wholeFiles)
            plan.partialAllPatch
            plan.partialUnstagedPatch)

buildCommitMessage :: String -> Maybe String -> String
buildCommitMessage subject Nothing = subject
buildCommitMessage subject (Just body) = subject <> "\n\n" <> body

liftGitCommitEffect :: Effect String -> Aff (Either AppError String)
liftGitCommitEffect action = liftEffect do
    result <- try action
    pure case result of
        Left err -> Left (GitError (message err))
        Right summary -> Right summary
