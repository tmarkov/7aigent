module Agent.Programs.SessionListing
    ( formatSessionListing
    , SessionMeta
    ) where

import Prelude
import Data.Array as Array
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as String
import Agent.Types (SessionId(..))

type SessionMeta =
    { id :: SessionId
    , started :: String
    , duration :: Maybe String
    , description :: String
    }

formatSessionListing :: Array SessionMeta -> String
formatSessionListing sessions
    | Array.null sessions =
        "No sessions found."
    | otherwise =
        let header =
                padRight 8 "ID"
                <> padRight 24 "Started"
                <> padRight 14 "Duration"
                <> "Description"
            separator = String.joinWith ""
                (Array.replicate 70 "─")
            rows = map formatRow sessions
        in  String.joinWith "\n"
                ([header, separator] <> rows)
  where
    formatRow :: SessionMeta -> String
    formatRow s =
        let SessionId sid = s.id
            dur = fromMaybe "—" s.duration
        in  padRight 8 (show sid)
            <> padRight 24 s.started
            <> padRight 14 dur
            <> s.description

    padRight :: Int -> String -> String
    padRight width str =
        let len = String.length str
            padding =
                if len >= width then " "
                else String.joinWith ""
                    (Array.replicate (width - len) " ")
        in  str <> padding
