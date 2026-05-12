-- | Git diff output formatting with hunk IDs and status markers.
-- | Covers requirement A5.
module Agent.Programs.GitDiff
    ( runGitDiff
    , parseHunkIds
    ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.String as String
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)

import Agent.Types (WorkspacePath(..), HunkId(..))
import Agent.Programs.GitHunks
    ( parseDiffBlocks
    , numberDiffBlocks
    , nextHunkId
    , parseUntrackedFiles
    )
import Agent.Programs.GitHunks as GitHunks

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
    let untrackedList = parseUntrackedFiles untrackedFiles
    let result = formatDiffs wp stagedDiff unstagedDiff untrackedList
    pure result

formatDiffs :: String -> String -> String -> Array String -> String
formatDiffs wp stagedDiff unstagedDiff untrackedFiles =
    let
        stagedBlocks = numberDiffBlocks (parseDiffBlocks stagedDiff true) 1
        unstagedStart = nextHunkId stagedBlocks 1
        unstagedBlocks = numberDiffBlocks (parseDiffBlocks unstagedDiff false) unstagedStart
        numberedHunks = Array.concatMap formatNumberedBlock (stagedBlocks <> unstagedBlocks)
        -- Add untracked files as additional hunks
        untrackedStart = nextHunkId (stagedBlocks <> unstagedBlocks) 1
        untrackedHunks = Array.mapWithIndex
            (\i file -> formatUntrackedHunk (untrackedStart + i) file wp)
            untrackedFiles
        allFormatted = numberedHunks <> untrackedHunks
    in
        if Array.null allFormatted
        then ""
        else String.joinWith "\n" allFormatted

formatUntrackedHunk :: Int -> String -> String -> String
formatUntrackedHunk n file _wp =
    let hunkId = "H" <> show n
    in  "--- " <> hunkId <> " [unstaged] new file " <> file <> " ---"

parseHunkIds :: String -> Set HunkId
parseHunkIds = GitHunks.parseHunkIds

formatNumberedBlock { block, hunkIds } =
    if Array.null block.hunkTexts
    then case Array.head hunkIds of
        Nothing -> []
        Just hid -> [formatHunk hid block.staged block.fileName ""]
    else Array.zipWith
        (\hid hunkText -> formatHunk hid block.staged block.fileName hunkText)
        hunkIds
        block.hunkTexts

formatHunk :: HunkId -> Boolean -> String -> String -> String
formatHunk (HunkId hunkId) staged fileName content =
    let tag = if staged then "[staged]" else "[unstaged]"
    in
        "--- " <> hunkId <> " " <> tag <> " " <> fileName <> " ---\n"
            <> content
