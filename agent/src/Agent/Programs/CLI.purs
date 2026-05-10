module Agent.Programs.CLI
    ( parseCLIArgs
    , CLIMode(..)
    ) where

import Prelude
import Data.Array as Array
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.String as String
import Agent.Types (SessionId(..), Port(..), WorkspacePath(..))

data CLIMode
    = StartSession
    | ListSessions
    | ResumeSession SessionId
    | McpServer Port
    | CLIError String

derive instance Eq CLIMode
instance Show CLIMode where
    show StartSession = "StartSession"
    show ListSessions = "ListSessions"
    show (ResumeSession sid) =
        "(ResumeSession " <> show sid <> ")"
    show (McpServer port) =
        "(McpServer " <> show port <> ")"
    show (CLIError msg) =
        "(CLIError " <> show msg <> ")"

parseCLIArgs :: Array String -> { workspace :: Maybe WorkspacePath, mode :: CLIMode }
parseCLIArgs args =
    case Array.uncons args of
        Just { head, tail } | looksLikePath head ->
            { workspace: Just (WorkspacePath head), mode: parseMode tail }
        _ ->
            { workspace: Nothing, mode: parseMode args }

-- | Returns true when a string looks like a filesystem path rather than a
-- | command keyword. Paths start with '/', './', '../', or '~'.
looksLikePath :: String -> Boolean
looksLikePath s =
    String.take 1 s == "/"
    || String.take 2 s == "./"
    || String.take 3 s == "../"
    || String.take 1 s == "~"

parseMode :: Array String -> CLIMode
parseMode args = case Array.uncons args of
    Nothing -> StartSession
    Just { head: "sessions", tail: _ } -> ListSessions
    Just { head: "resume", tail } ->
        case Array.head tail of
            Nothing ->
                CLIError "resume requires a session ID"
            Just s -> case Int.fromString s of
                Just n -> ResumeSession (SessionId n)
                Nothing ->
                    CLIError ("Invalid session ID: " <> s)
    Just { head: "mcp", tail } ->
        case Array.head tail of
            Nothing ->
                CLIError "mcp requires a port number"
            Just s -> case Int.fromString s of
                Just n -> McpServer (Port n)
                Nothing ->
                    CLIError ("Invalid port: " <> s)
    Just { head: cmd } ->
        CLIError
            ( "Unknown command: " <> cmd
            <> ". Usage: 7aigent "
            <> "[<dir>] [sessions|resume <id>|mcp <port>]"
            )
