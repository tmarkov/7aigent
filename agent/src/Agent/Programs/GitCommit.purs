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
import Data.Foldable (foldl)
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set
import Data.String as String
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Exception (try, message)

import Agent.Types (WorkspacePath(..), HunkId(..), AppError(..))

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
    stagedDiff <- execGitCommitSafe wp "diff --cached"
    diffOutput <- execGitCommitSafe wp "diff"
    untrackedOutput <- execGitCommitSafe wp "ls-files --others --exclude-standard"
    let selectedIds = Set.fromFoldable (NEA.toArray hunks)
    let stagedBlocks = numberDiffBlocks (parseDiffBlocks stagedDiff true) 1
    let unstagedStart = nextHunkId stagedBlocks 1
    let unstagedBlocks = numberDiffBlocks (parseDiffBlocks diffOutput false) unstagedStart
    let untrackedFiles = Array.filter (_ /= "")
            (String.split (String.Pattern "\n") (String.trim untrackedOutput))
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

type DiffBlock =
    { fileName :: String
    , headerLines :: Array String
    , hunkTexts :: Array String
    , fullBlock :: String
    , staged :: Boolean
    }

type NumberedDiffBlock =
    { block :: DiffBlock
    , hunkIds :: Array HunkId
    }

parseDiffBlocks :: String -> Boolean -> Array DiffBlock
parseDiffBlocks diff staged =
    if String.trim diff == ""
    then []
    else
        let
            parts = String.split (String.Pattern "diff --git ") diff
            diffParts = Array.filter (_ /= "") (Array.drop 1 parts)
        in
            map (\part -> parseDiffBlock ("diff --git " <> part) staged) diffParts

parseDiffBlock :: String -> Boolean -> DiffBlock
parseDiffBlock fullBlock staged =
    let
        allLines = String.split (String.Pattern "\n") fullBlock
        fileName = case Array.head allLines of
            Nothing -> "unknown"
            Just firstLine ->
                case String.indexOf (String.Pattern " b/") firstLine of
                    Nothing -> String.trim firstLine
                    Just idx -> String.drop (idx + 3) firstLine
        indexedLines = Array.mapWithIndex (\idx line -> { idx, line }) allLines
        hunkStarts = Array.filter (\l -> String.take 2 l.line == "@@") indexedLines
        headerLines = case Array.head hunkStarts of
            Nothing -> allLines
            Just firstHunk -> Array.slice 0 firstHunk.idx allLines
        hunkTexts = if Array.null hunkStarts
            then []
            else Array.mapWithIndex
                (\i hunk ->
                    let
                        endIdx = case Array.index hunkStarts (i + 1) of
                            Nothing -> Array.length allLines
                            Just next -> next.idx
                    in
                        String.joinWith "\n" (Array.slice hunk.idx endIdx allLines)
                )
                hunkStarts
    in
        { fileName
        , headerLines
        , hunkTexts
        , fullBlock
        , staged
        }

numberDiffBlocks :: Array DiffBlock -> Int -> Array NumberedDiffBlock
numberDiffBlocks blocks startId =
    let
        go :: Int -> Array DiffBlock -> Array NumberedDiffBlock
        go _ [] = []
        go nextId bs = case Array.uncons bs of
            Nothing -> []
            Just { head: b, tail: rest } ->
                let count = max 1 (Array.length b.hunkTexts)
                    hunkIds = Array.range nextId (nextId + count - 1)
                        # map (\n -> HunkId ("H" <> show n))
                in
                    [ { block: b, hunkIds } ] <> go (nextId + count) rest
    in
        go startId blocks

nextHunkId :: Array NumberedDiffBlock -> Int -> Int
nextHunkId blocks startId =
    foldl
        (\next block -> next + Array.length block.hunkIds)
        startId
        blocks

renderPatch :: Array NumberedDiffBlock -> (HunkId -> Boolean) -> String
renderPatch blocks includeHunk =
    let
        rendered = map ensureTrailingNewline (Array.mapMaybe renderBlock blocks)
    in
        String.joinWith "" rendered
  where
    ensureTrailingNewline text
        | String.null text = text
        | String.drop (String.length text - 1) text == "\n" = text
        | otherwise = text <> "\n"

    renderBlock { block, hunkIds } =
        if Array.null block.hunkTexts
        then case Array.head hunkIds of
            Just hid | includeHunk hid -> Just block.fullBlock
            _ -> Nothing
        else
            let
                selectedHunks = Array.mapMaybe
                    (\entry -> if includeHunk entry.hunkId then Just entry.hunkText else Nothing)
                    (Array.zipWith
                        (\hunkId hunkText -> { hunkId, hunkText })
                        hunkIds
                        block.hunkTexts)
            in
                if Array.null selectedHunks
                then Nothing
                else Just (String.joinWith "\n" (block.headerLines <> selectedHunks))

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
