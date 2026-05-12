-- | Git commit validation and execution.
-- | Covers requirement A6.
module Agent.Programs.GitCommit
    ( CommitWhat(..)
    , validateCommitWhat
    , runGitCommit
    ) where

import Prelude

import Data.Array as Array
import Data.Array.NonEmpty (NonEmptyArray)
import Data.Array.NonEmpty as NEA
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set
import Data.String as String
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Exception (try, message)

import Agent.Types (WorkspacePath(..), HunkId(..), AppError(..))
import Agent.Programs.GitHunks
    ( numberDiffBlocks
    , nextHunkId
    , parseDiffBlocks
    , parseUntrackedFiles
    , renderPatch
    )

-- FFI imports
foreign import execGitCommitSync :: String -> String -> Effect String
foreign import execGitCommitSafe :: String -> String -> Effect String
foreign import execSelectiveGitCommit
    :: String
    -> String
    -> String
    -> Array String
    -> String
    -> Effect String

----------------------------------------------------------------------------
-- A6: CommitWhat ADT
----------------------------------------------------------------------------

data CommitWhat
    = CommitAll
    | CommitHunks (NonEmptyArray HunkId)

derive instance Eq CommitWhat

instance Show CommitWhat where
    show CommitAll = "CommitAll"
    show (CommitHunks hunks) =
        "(CommitHunks " <> show (NEA.toArray hunks) <> ")"

----------------------------------------------------------------------------
-- A6: validation (pure)
----------------------------------------------------------------------------

validateCommitWhat
    :: Set HunkId -> CommitWhat -> Either AppError CommitWhat
validateCommitWhat _ CommitAll = Right CommitAll
validateCommitWhat knownIds (CommitHunks hunks) =
    let
        hunkArray = NEA.toArray hunks
        stale = Array.filter
            (\hid -> not (Set.member hid knownIds)) hunkArray
    in
        if Array.null stale
        then Right (CommitHunks hunks)
        else Left (StaleHunkIds stale)

----------------------------------------------------------------------------
-- A6: execution (effectful)
----------------------------------------------------------------------------

runGitCommit
    :: WorkspacePath
    -> CommitWhat
    -> String
    -> Maybe String
    -> Aff (Either AppError String)
runGitCommit (WorkspacePath wp) what subject body = liftEffect do
    result <- try (runGitCommitImpl wp what subject body)
    pure $ case result of
        Left err -> Left (GitError (message err))
        Right summary -> Right summary

runGitCommitImpl
    :: String -> CommitWhat -> String -> Maybe String -> Effect String
runGitCommitImpl wp CommitAll subject body = do
    _ <- execGitCommitSync wp "add -A"
    let msg = buildCommitMessage subject body
    _ <- execGitCommitSync wp ("commit -m " <> shellQuote msg)
    summary <- execGitCommitSafe wp "log -1 --stat"
    pure summary
runGitCommitImpl wp (CommitHunks hunks) subject body = do
    stagedDiff <- execGitCommitSafe wp "diff --cached"
    diffOutput <- execGitCommitSafe wp "diff"
    untrackedOutput <- execGitCommitSafe wp "ls-files --others --exclude-standard"
    let selectedIds = Set.fromFoldable (NEA.toArray hunks)
    let stagedBlocks = numberDiffBlocks (parseDiffBlocks stagedDiff true) 1
    let unstagedStart = nextHunkId stagedBlocks 1
    let unstagedBlocks = numberDiffBlocks (parseDiffBlocks diffOutput false) unstagedStart
    let untrackedFiles = parseUntrackedFiles untrackedOutput
    let trackedBlocks = stagedBlocks <> unstagedBlocks
    let selectedPatch = renderPatch trackedBlocks (\hid -> Set.member hid selectedIds)
    let restorePatch = renderPatch stagedBlocks (\hid -> not (Set.member hid selectedIds))
    let selectedUntracked = selectUntrackedFiles untrackedFiles
            (nextHunkId trackedBlocks 1) selectedIds
    let msg = buildCommitMessage subject body
    summary <- execSelectiveGitCommit wp selectedPatch restorePatch selectedUntracked msg
    pure summary

buildCommitMessage :: String -> Maybe String -> String
buildCommitMessage subject Nothing = subject
buildCommitMessage subject (Just b) = subject <> "\n\n" <> b

shellQuote :: String -> String
shellQuote s = "'" <> String.replaceAll
    (String.Pattern "'") (String.Replacement "'\\''") s <> "'"

selectUntrackedFiles :: Array String -> Int -> Set HunkId -> Array String
selectUntrackedFiles files startId selectedIds =
    Array.mapMaybe
        (\entry -> if Set.member entry.hunkId selectedIds then Just entry.fileName else Nothing)
        (Array.mapWithIndex
            (\idx fileName ->
                { hunkId: HunkId ("H" <> show (startId + idx))
                , fileName
                })
            files)
