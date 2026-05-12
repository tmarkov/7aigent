module Agent.Programs.GitHunks
    ( DiffBlock
    , NumberedDiffBlock
    , parseDiffBlocks
    , numberDiffBlocks
    , nextHunkId
    , renderPatch
    , parseHunkIds
    , parseUntrackedFiles
    ) where

import Prelude

import Data.Array as Array
import Data.Array.NonEmpty as NEA
import Data.Either (Either(..))
import Data.Foldable (foldl)
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set
import Data.String as String
import Data.String.Regex as Regex
import Data.String.Regex.Flags (global)

import Agent.Types (HunkId(..))

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

numberDiffBlocks :: Array DiffBlock -> Int -> Array NumberedDiffBlock
numberDiffBlocks blocks startId =
    let
        go :: Int -> Array DiffBlock -> Array NumberedDiffBlock
        go _ [] = []
        go nextId bs = case Array.uncons bs of
            Nothing -> []
            Just { head: block, tail: rest } ->
                let count = max 1 (Array.length block.hunkTexts)
                    hunkIds = Array.range nextId (nextId + count - 1)
                        # map (\n -> HunkId ("H" <> show n))
                in
                    [{ block, hunkIds }] <> go (nextId + count) rest
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

parseHunkIds :: String -> Set HunkId
parseHunkIds input =
    case Regex.regex "H(\\d+)" global of
        Left _ -> Set.empty
        Right re ->
            case Regex.match re input of
                Nothing -> Set.empty
                Just neArr ->
                    let ids = Array.catMaybes (NEA.toArray neArr)
                    in Set.fromFoldable (map HunkId ids)

parseUntrackedFiles :: String -> Array String
parseUntrackedFiles output =
    Array.filter (_ /= "")
        (String.split (String.Pattern "\n") (String.trim output))

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
        hunkStarts = Array.filter (\lineInfo -> String.take 2 lineInfo.line == "@@") indexedLines
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
