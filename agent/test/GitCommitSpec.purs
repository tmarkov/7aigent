-- | Tests for git_commit execution: A6.
module Test.GitCommitSpec where

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
  , stageFile
  , gitOutput
  )
import Agent.Programs.GitCommit
  ( runGitCommitAll
  , runGitCommitPlan
  , runGitCommitStaged
  )

gitCommitSpec :: Spec Unit
gitCommitSpec = do

  describe "A6: git_commit execution" do

    it "A6: 'all' commits all changes including untracked" do
      withGitRepo \ws -> do
        addTrackedFile ws "tracked.txt" "original"
        modifyTrackedFile ws "tracked.txt" "modified"
        addUntrackedFile ws "new.txt" "new content"
        result <- runGitCommitAll ws "Test commit" Nothing
        case result of
          Right summary -> do
            summary `shouldSatisfy` contains "tracked.txt"
            summary `shouldSatisfy` contains "new.txt"
          Left err -> fail ("git_commit all failed: " <> show err)

    it "A6: 'staged' commits the current index as-is and leaves unstaged changes alone" do
      withGitRepo \ws -> do
        addTrackedFile ws "a.txt" "one\n"
        addTrackedFile ws "b.txt" "two\n"
        modifyTrackedFile ws "a.txt" "ONE\n"
        modifyTrackedFile ws "b.txt" "TWO\n"
        stageFile ws "a.txt"
        result <- runGitCommitStaged ws "Commit staged only" Nothing
        case result of
          Right summary -> do
            summary `shouldSatisfy` contains "a.txt"
            summary `shouldSatisfy` notContains "b.txt"
            unstaged <- gitOutput ws "git diff --name-only"
            unstaged `shouldSatisfy` contains "b.txt"
          Left err -> fail ("git_commit staged failed: " <> show err)

    it "A6: selector commit preserves other staged and unstaged changes exactly" do
      withGitRepo \ws -> do
        addTrackedFile ws "a.txt" "one\n"
        addTrackedFile ws "b.txt" "two\n"
        addTrackedFile ws "c.txt" "three\n"
        modifyTrackedFile ws "a.txt" "ONE\n"
        modifyTrackedFile ws "b.txt" "TWO\n"
        modifyTrackedFile ws "c.txt" "THREE\n"
        stageFile ws "b.txt"
        let plan =
              { wholeFiles: [{ path: "a.txt", oldPath: Nothing }]
              , partialAllPatch: ""
              , partialUnstagedPatch: ""
              }
        result <- runGitCommitPlan ws plan "Commit selected file" Nothing
        case result of
          Right summary -> do
            summary `shouldSatisfy` contains "a.txt"
            summary `shouldSatisfy` notContains "b.txt"
            summary `shouldSatisfy` notContains "c.txt"
            cached <- gitOutput ws "git diff --cached --name-only"
            unstaged <- gitOutput ws "git diff --name-only"
            cached `shouldSatisfy` contains "b.txt"
            cached `shouldSatisfy` notContains "a.txt"
            unstaged `shouldSatisfy` contains "c.txt"
            unstaged `shouldSatisfy` notContains "a.txt"
          Left err -> fail ("selector git_commit failed: " <> show err)

  where
  contains :: String -> String -> Boolean
  contains needle haystack =
    String.contains (String.Pattern needle) haystack

  notContains :: String -> String -> Boolean
  notContains needle haystack = not (contains needle haystack)
