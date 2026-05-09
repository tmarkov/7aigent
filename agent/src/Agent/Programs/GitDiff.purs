-- | Git diff output formatting with hunk IDs and status markers.
-- | Covers requirement A5.
module Agent.Programs.GitDiff
    ( runGitDiff
    , parseHunkIds
    ) where

import Prelude

import Data.Array as Array
import Data.Array.NonEmpty as NEA
import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set
import Data.String as String
import Data.String.Regex as Regex
import Data.String.Regex.Flags (global)
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)

import Agent.Types (WorkspacePath(..), HunkId(..))

-- FFI import
foreign import execGitSync :: String -> String -> Effect String

----------------------------------------------------------------------------
-- A5: run git diff and format with hunk IDs
----------------------------------------------------------------------------

runGitDiff :: WorkspacePath -> Aff String
runGitDiff (WorkspacePath wp) = liftEffect do
    -- Get staged diff (index vs HEAD)
    stagedDiff <- execGitSync wp "diff --cached"
    -- Get unstaged diff (working tree vs index)
    unstagedDiff <- execGitSync wp "diff"
    -- Get untracked files
    untrackedFiles <- execGitSync wp "ls-files --others --exclude-standard"
    -- Format everything with hunk IDs
    let untrackedList = Array.filter (\s -> s /= "")
            (String.split (String.Pattern "\n") (String.trim untrackedFiles))
    let result = formatDiffs wp stagedDiff unstagedDiff untrackedList
    pure result

formatDiffs :: String -> String -> String -> Array String -> String
formatDiffs wp stagedDiff unstagedDiff untrackedFiles =
    let
        stagedHunks = parseRawDiff stagedDiff true
        unstagedHunks = parseRawDiff unstagedDiff false
        -- Number all hunks sequentially
        allHunks = stagedHunks <> unstagedHunks
        numberedHunks = Array.mapWithIndex
            (\i h -> formatHunk (i + 1) h)
            allHunks
        -- Add untracked files as additional hunks
        untrackedStart = Array.length allHunks + 1
        untrackedHunks = Array.mapWithIndex
            (\i file -> formatUntrackedHunk (untrackedStart + i) file wp)
            untrackedFiles
        allFormatted = numberedHunks <> untrackedHunks
    in
        if Array.null allFormatted
        then ""
        else String.joinWith "\n" allFormatted

type RawHunk =
    { fileName :: String
    , header :: String
    , content :: String
    , staged :: Boolean
    }

parseRawDiff :: String -> Boolean -> Array RawHunk
parseRawDiff diff staged =
    if String.trim diff == ""
    then []
    else
        let
            -- Split by "diff --git" markers
            parts = String.split (String.Pattern "diff --git ") diff
            -- First element is empty or preamble
            diffParts = Array.filter (\s -> s /= "") (Array.drop 1 parts)
        in
            Array.concatMap (parseDiffBlock staged) diffParts

parseDiffBlock :: Boolean -> String -> Array RawHunk
parseDiffBlock staged block =
    let
        allLines = String.split (String.Pattern "\n") block
        -- First line has "a/file b/file"
        fileName = case Array.head allLines of
            Nothing -> "unknown"
            Just firstLine ->
                case String.indexOf (String.Pattern " b/") firstLine of
                    Nothing -> String.trim firstLine
                    Just idx -> String.drop (idx + 3) firstLine
        -- Find hunk headers (lines starting with @@)
        indexedLines = Array.mapWithIndex (\i l -> { idx: i, line: l }) allLines
        hunkStarts = Array.filter
            (\il -> String.take 2 il.line == "@@")
            indexedLines
    in
        if Array.null hunkStarts
        then
            -- No @@ headers — treat entire block as one hunk
            [ { fileName
              , header: ""
              , content: String.joinWith "\n" allLines
              , staged
              } ]
        else
            Array.mapWithIndex
                (\i hs ->
                    let
                        startIdx = hs.idx
                        endIdx = case Array.index hunkStarts (i + 1) of
                            Nothing -> Array.length allLines
                            Just next -> next.idx
                        hunkLines = Array.slice startIdx endIdx allLines
                    in
                        { fileName
                        , header: hs.line
                        , content: String.joinWith "\n" hunkLines
                        , staged
                        }
                ) hunkStarts

formatHunk :: Int -> RawHunk -> String
formatHunk n hunk =
    let
        tag = if hunk.staged then "[staged]" else "[unstaged]"
        hunkId = "H" <> show n
    in
        "--- " <> hunkId <> " " <> tag <> " " <> hunk.fileName <> " ---\n"
            <> hunk.content

formatUntrackedHunk :: Int -> String -> String -> String
formatUntrackedHunk n file _wp =
    let hunkId = "H" <> show n
    in  "--- " <> hunkId <> " [unstaged] new file " <> file <> " ---"

----------------------------------------------------------------------------
-- A5: hunk ID extraction
----------------------------------------------------------------------------

parseHunkIds :: String -> Set HunkId
parseHunkIds input =
    case Regex.regex "H(\\d+)" global of
        Left _ -> Set.empty
        Right re ->
            let
                matches = Regex.match re input
            in
                case matches of
                    Nothing -> Set.empty
                    Just neArr ->
                        let
                            ids = Array.catMaybes (NEA.toArray neArr)
                        in
                            Set.fromFoldable (map HunkId ids)
