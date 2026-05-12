-- | Tests for git_commit validation and execution: A6.
module Test.GitCommitSpec where

import Prelude

import Data.Array.NonEmpty as NEA
import Data.Either (Either(..), isLeft)
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy, fail)

import Test.Helpers.GitRepo (withGitRepo, addTrackedFile, modifyTrackedFile, addUntrackedFile, stageFile)
import Agent.Programs.GitCommit (validateCommitWhat, CommitWhat(..), runGitCommit)
import Agent.Programs.GitDiff (runGitDiff, parseHunkIds)
import Agent.Types (HunkId(..), AppError(..))

gitCommitSpec :: Spec Unit
gitCommitSpec = do

  ---------------------------------------------------------------------------
  -- A6: validation (pure)
  ---------------------------------------------------------------------------

  describe "A6: git_commit validation — CommitAll" do

    it "A6: what = 'all' → valid, stages everything" do
      let knownIds = Set.fromFoldable [ HunkId "H1", HunkId "H2" ]
      case validateCommitWhat knownIds CommitAll of
        Right CommitAll -> pure unit
        _ -> fail "Expected CommitAll to validate"

  describe "A6: git_commit validation — hunk ID list" do

    it "A6: valid hunk IDs → accepted" do
      let knownIds = Set.fromFoldable [ HunkId "H1", HunkId "H2", HunkId "H3" ]
      case NEA.fromArray [ HunkId "H1", HunkId "H3" ] of
        Just hunks ->
          case validateCommitWhat knownIds (CommitHunks hunks) of
            Right _ -> pure unit
            Left err -> fail ("Expected valid, got: " <> show err)
        Nothing -> fail "NEA construction failed"

    it "A6: stale hunk ID → error listing unrecognised IDs" do
      let knownIds = Set.fromFoldable [ HunkId "H1", HunkId "H2" ]
      case NEA.fromArray [ HunkId "H1", HunkId "H99" ] of
        Just hunks ->
          case validateCommitWhat knownIds (CommitHunks hunks) of
            Left (StaleHunkIds ids) ->
              shouldEqual true (Set.member (HunkId "H99") (Set.fromFoldable ids))
            Left _ -> fail "Expected StaleHunkIds error"
            Right _ -> fail "Expected validation to fail for H99"
        Nothing -> fail "NEA construction failed"

    it "A6: multiple unrecognised IDs → all listed in error" do
      let knownIds = Set.fromFoldable [ HunkId "H1" ]
      case NEA.fromArray [ HunkId "H5", HunkId "H9" ] of
        Just hunks ->
          case validateCommitWhat knownIds (CommitHunks hunks) of
            Left (StaleHunkIds ids) -> do
              shouldEqual true (Set.member (HunkId "H5") (Set.fromFoldable ids))
              shouldEqual true (Set.member (HunkId "H9") (Set.fromFoldable ids))
            _ -> fail "Expected StaleHunkIds error listing both H5 and H9"
        Nothing -> fail "NEA construction failed"

    it "A6: empty hunk ID set (no prior git_diff) → all IDs are stale" do
      let knownIds = Set.empty
      case NEA.fromArray [ HunkId "H1" ] of
        Just hunks ->
          validateCommitWhat knownIds (CommitHunks hunks)
            `shouldSatisfy` isLeft
        Nothing -> fail "NEA construction failed"

  ---------------------------------------------------------------------------
  -- A6: execution (effectful)
  ---------------------------------------------------------------------------

  describe "A6: git_commit execution" do

    it "A6: 'all' commits all changes including untracked" do
      withGitRepo \ws -> do
        addTrackedFile ws "tracked.txt" "original"
        modifyTrackedFile ws "tracked.txt" "modified"
        addUntrackedFile ws "new.txt" "new content"
        result <- runGitCommit ws CommitAll "Test commit" Nothing
        case result of
          Right summary -> do
            summary `shouldSatisfy` contains "tracked.txt"
            summary `shouldSatisfy` contains "new.txt"
          Left err -> fail ("Commit failed: " <> show err)

    it "A6: message + body → commit has both subject and body" do
      withGitRepo \ws -> do
        addTrackedFile ws "f.txt" "a"
        modifyTrackedFile ws "f.txt" "b"
        result <- runGitCommit ws CommitAll "Subject line" (Just "Body text here")
        case result of
          Right summary -> do
            summary `shouldSatisfy` contains "Subject line"
            summary `shouldSatisfy` contains "Body text here"
          Left err -> fail ("Expected successful commit, got: " <> show err)

    it "A6: selective hunk staging commits only specified hunks" do
      withGitRepo \ws -> do
        addTrackedFile ws "a.txt"
          "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve\nthirteen\nfourteen\n"
        modifyTrackedFile ws "a.txt"
          "ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve\nthirteen\nFOURTEEN\n"
        diffResult <- runGitDiff ws
        diffResult `shouldSatisfy` contains "H1"
        diffResult `shouldSatisfy` contains "H2"
        case NEA.fromArray [ HunkId "H1" ] of
          Just hunks -> do
            result <- runGitCommit ws (CommitHunks hunks) "Partial" Nothing
            case result of
              Right summary -> do
                summary `shouldSatisfy` contains "a.txt"
                diffAfter <- runGitDiff ws
                diffAfter `shouldSatisfy` contains "H1"
                diffAfter `shouldSatisfy` contains "FOURTEEN"
              Left err ->
                fail ("Selective commit failed: " <> show err)
          Nothing -> fail "NEA construction failed"

    it "A6: selective staging leaves other hunks uncommitted" do
      withGitRepo \ws -> do
        addTrackedFile ws "a.txt"
          "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve\nthirteen\nfourteen\n"
        modifyTrackedFile ws "a.txt"
          "ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve\nthirteen\nFOURTEEN\n"
        _ <- runGitDiff ws
        -- Commit only H1
        case NEA.fromArray [ HunkId "H1" ] of
          Just hunks -> do
            _ <- runGitCommit ws (CommitHunks hunks) "Partial" Nothing
            diffAfter <- runGitDiff ws
            diffAfter `shouldSatisfy` contains "a.txt"
            diffAfter `shouldSatisfy` contains "FOURTEEN"
            shouldEqual false (contains "ONE" diffAfter)
          Nothing -> fail "NEA construction failed"

  where
  contains :: String -> String -> Boolean
  contains needle haystack =
    String.contains (String.Pattern needle) haystack
