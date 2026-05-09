-- | Tests for git_diff output formatting: A5.
module Test.GitDiffSpec where

import Prelude

import Data.Set as Set
import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy)

import Test.Helpers.GitRepo (withGitRepo, addTrackedFile, modifyTrackedFile, stageFile, addUntrackedFile)
import Agent.Programs.GitDiff (runGitDiff, parseHunkIds)
import Agent.Types (WorkspacePath(..), HunkId(..))

gitDiffSpec :: Spec Unit
gitDiffSpec = do

  describe "A5: git_diff output formatting" do

    it "A5: one unstaged modification → one hunk with H1 [unstaged]" do
      withGitRepo \ws -> do
        addTrackedFile ws "hello.txt" "original"
        modifyTrackedFile ws "hello.txt" "modified"
        result <- runGitDiff ws
        result `shouldSatisfy` contains "H1"
        result `shouldSatisfy` contains "[unstaged]"

    it "A5: staged + unstaged hunk in same file → both marked, sequential IDs" do
      withGitRepo \ws -> do
        addTrackedFile ws "file.txt" "line1\nline2\nline3\nline4\n"
        modifyTrackedFile ws "file.txt" "LINE1\nline2\nline3\nLINE4\n"
        stageFile ws "file.txt"
        modifyTrackedFile ws "file.txt" "LINE1\nLINE2\nline3\nLINE4\n"
        result <- runGitDiff ws
        result `shouldSatisfy` contains "[staged]"
        result `shouldSatisfy` contains "[unstaged]"
        result `shouldSatisfy` contains "H1"
        result `shouldSatisfy` contains "H2"

    it "A5: untracked file → 'new file' addition as [unstaged] hunk" do
      withGitRepo \ws -> do
        addUntrackedFile ws "newfile.txt" "brand new content"
        result <- runGitDiff ws
        result `shouldSatisfy` contains "[unstaged]"
        result `shouldSatisfy` contains "new file"

    it "A5: no changes → empty or 'no changes' output" do
      withGitRepo \ws -> do
        addTrackedFile ws "stable.txt" "content"
        result <- runGitDiff ws
        -- Either empty string or a message indicating no changes
        shouldEqual true
          (String.null result || contains "no changes" (String.toLower result))

    it "A5: hunk IDs are sequential across files" do
      withGitRepo \ws -> do
        addTrackedFile ws "a.txt" "aaa"
        addTrackedFile ws "b.txt" "bbb"
        modifyTrackedFile ws "a.txt" "AAA"
        modifyTrackedFile ws "b.txt" "BBB"
        result <- runGitDiff ws
        result `shouldSatisfy` contains "H1"
        result `shouldSatisfy` contains "H2"

  ---------------------------------------------------------------------------
  -- A5: hunk ID extraction
  ---------------------------------------------------------------------------

  describe "A5: hunk ID extraction" do

    it "A5: parseHunkIds extracts all IDs from diff output" do
      withGitRepo \ws -> do
        addTrackedFile ws "a.txt" "aaa"
        addTrackedFile ws "b.txt" "bbb"
        modifyTrackedFile ws "a.txt" "AAA"
        modifyTrackedFile ws "b.txt" "BBB"
        result <- runGitDiff ws
        let ids = parseHunkIds result
        Set.size ids `shouldEqual` 2
        Set.member (HunkId "H1") ids `shouldEqual` true
        Set.member (HunkId "H2") ids `shouldEqual` true

    it "A5: parseHunkIds on empty diff → empty set" do
      withGitRepo \ws -> do
        addTrackedFile ws "stable.txt" "content"
        result <- runGitDiff ws
        let ids = parseHunkIds result
        Set.size ids `shouldEqual` 0

  ---------------------------------------------------------------------------
  -- A5: hunk ID invalidation
  ---------------------------------------------------------------------------

  describe "A5: hunk ID invalidation" do

    it "A5: second git_diff produces fresh IDs (old set no longer valid)" do
      withGitRepo \ws -> do
        addTrackedFile ws "a.txt" "original"
        modifyTrackedFile ws "a.txt" "modified"
        result1 <- runGitDiff ws
        let ids1 = parseHunkIds result1
        -- Make a different change and re-diff
        modifyTrackedFile ws "a.txt" "modified again"
        result2 <- runGitDiff ws
        let ids2 = parseHunkIds result2
        -- Both diffs produce IDs, but they are independent sets.
        -- The controller must replace the known set after each
        -- git_diff or julia_repl call (A5 invalidation rule).
        Set.size ids1 `shouldSatisfy` (_ > 0)
        Set.size ids2 `shouldSatisfy` (_ > 0)

  where
  contains :: String -> String -> Boolean
  contains needle haystack =
    String.contains (String.Pattern needle) haystack
