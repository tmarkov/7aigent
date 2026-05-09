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
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Exception (try, message)

import Agent.Types (WorkspacePath(..), HunkId(..), AppError(..))

-- FFI imports
foreign import execGitCommitSync :: String -> String -> Effect String
foreign import execGitCommitSafe :: String -> String -> Effect String

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
        Left err -> Left (ConfigFieldMissing (message err))
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
    -- Map hunk IDs to files: run git diff to get the diff output,
    -- then parse it to find which files have which hunks
    diffOutput <- execGitCommitSafe wp "diff"
    let hunkArray = NEA.toArray hunks
    let fileMap = buildHunkFileMap diffOutput
    let filesToStage = Array.nub $ Array.concatMap
            (\hid -> case Array.find (\fm -> fm.hunkId == hid) fileMap of
                Just fm -> [fm.fileName]
                Nothing -> []
            ) hunkArray
    _ <- traverse
        (\f -> execGitCommitSync wp ("add -- " <> shellQuote f))
        filesToStage
    let msg = buildCommitMessage subject body
    _ <- execGitCommitSync wp ("commit -m " <> shellQuote msg)
    summary <- execGitCommitSafe wp "log -1 --stat"
    pure summary

buildCommitMessage :: String -> Maybe String -> String
buildCommitMessage subject Nothing = subject
buildCommitMessage subject (Just b) = subject <> "\n\n" <> b

shellQuote :: String -> String
shellQuote s = "'" <> String.replaceAll
    (String.Pattern "'") (String.Replacement "'\\''") s <> "'"

-- Build a mapping from hunk ID (H1, H2, ...) to file name,
-- using the same sequential numbering as runGitDiff
type HunkFileEntry = { hunkId :: HunkId, fileName :: String }

buildHunkFileMap :: String -> Array HunkFileEntry
buildHunkFileMap diffOutput =
    let
        parts = String.split (String.Pattern "diff --git ") diffOutput
        diffParts = Array.filter (\s -> s /= "")
            (Array.drop 1 parts)
        -- Count hunks per block, assign sequential IDs
        blocks = map parseBlockInfo diffParts
    in
        assignHunkIds blocks 1

type BlockInfo = { fileName :: String, hunkCount :: Int }

parseBlockInfo :: String -> BlockInfo
parseBlockInfo block =
    let
        allLines = String.split (String.Pattern "\n") block
        fileName = case Array.head allLines of
            Nothing -> "unknown"
            Just firstLine ->
                case String.indexOf (String.Pattern " b/") firstLine of
                    Nothing -> String.trim firstLine
                    Just idx -> String.drop (idx + 3) firstLine
        hunkCount = Array.length $
            Array.filter (\l -> String.take 2 l == "@@") allLines
    in
        { fileName
        , hunkCount: max 1 hunkCount
        }

assignHunkIds :: Array BlockInfo -> Int -> Array HunkFileEntry
assignHunkIds blocks startId =
    let
        go :: Int -> Array BlockInfo -> Array HunkFileEntry
        go _ [] = []
        go nextId bs = case Array.uncons bs of
            Nothing -> []
            Just { head: b, tail: rest } ->
                let entries = Array.range nextId (nextId + b.hunkCount - 1)
                        # map (\n ->
                            { hunkId: HunkId ("H" <> show n)
                            , fileName: b.fileName
                            })
                in entries <> go (nextId + b.hunkCount) rest
    in
        go startId blocks
