-- | Tests for git_stage execution: A5.
module Test.GitStageSpec where

import Prelude

import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldSatisfy, fail)

import Test.Helpers.GitRepo
  ( withGitRepo
  , addTrackedFile
  , modifyTrackedFile
  , addUntrackedFile
  , gitOutput
  )
import Agent.Programs.GitStage (runGitStageAll, runGitStagePlan)

gitStageSpec :: Spec Unit
gitStageSpec = do

  describe "A5: git_stage execution" do

    it "A5: 'all' stages tracked and untracked changes" do
      withGitRepo \ws -> do
        addTrackedFile ws "tracked.txt" "original"
        modifyTrackedFile ws "tracked.txt" "modified"
        addUntrackedFile ws "new.txt" "new content"
        result <- runGitStageAll ws
        case result of
          Right _ -> do
            cached <- gitOutput ws "git diff --cached --name-only"
            cached `shouldSatisfy` contains "tracked.txt"
            cached `shouldSatisfy` contains "new.txt"
          Left err -> fail ("git_stage all failed: " <> show err)

    it "A5: selector staging preserves unselected unstaged changes exactly" do
      withGitRepo \ws -> do
        addTrackedFile ws "a.txt" "one\n"
        addTrackedFile ws "b.txt" "two\n"
        modifyTrackedFile ws "a.txt" "ONE\n"
        modifyTrackedFile ws "b.txt" "TWO\n"
        let plan =
              { wholeFiles: [{ path: "a.txt", oldPath: Nothing }]
              , partialAllPatch: ""
              , partialUnstagedPatch: ""
              }
        result <- runGitStagePlan ws plan
        case result of
          Right _ -> do
            cached <- gitOutput ws "git diff --cached --name-only"
            unstaged <- gitOutput ws "git diff --name-only"
            cached `shouldSatisfy` contains "a.txt"
            cached `shouldSatisfy` notContains "b.txt"
            unstaged `shouldSatisfy` contains "b.txt"
            unstaged `shouldSatisfy` notContains "a.txt"
          Left err -> fail ("selector git_stage failed: " <> show err)

  where
  contains :: String -> String -> Boolean
  contains needle haystack =
    String.contains (String.Pattern needle) haystack

  notContains :: String -> String -> Boolean
  notContains needle haystack = not (contains needle haystack)
