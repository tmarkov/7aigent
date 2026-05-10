module Agent.Programs.CLI
    ( parseCLIArgs
    , CLIMode(..)
    ) where

import Prelude
import Data.Array as Array
import Data.Int as Int
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
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

parseCLIArgs :: Array String -> { workspace :: Maybe WorkspacePath, mode :: CLIMode, prompt :: Maybe String }
parseCLIArgs args =
    case extractPrompt args of
        Left msg ->
            { workspace: Nothing, mode: CLIError msg, prompt: Nothing }
        Right { remaining, prompt } ->
            case Array.uncons remaining of
                Just { head, tail } | looksLikePath head ->
                    { workspace: Just (WorkspacePath head), mode: parseMode tail, prompt }
                _ ->
                    { workspace: Nothing, mode: parseMode remaining, prompt }

-- | Extract the `-p <prompt>` flag from the argument list, returning the
-- | remaining args and the prompt value (if present).
extractPrompt :: Array String -> Either String { remaining :: Array String, prompt :: Maybe String }
extractPrompt args =
    case Array.findIndex (_ == "-p") args of
        Nothing ->
            Right { remaining: args, prompt: Nothing }
        Just i ->
            case Array.index args (i + 1) of
                Nothing ->
                    Left "-p requires a prompt argument"
                Just p ->
                    let remaining = fromMaybe args do
                            a1 <- Array.deleteAt (i + 1) args
                            Array.deleteAt i a1
                    in Right { remaining, prompt: Just p }

-- | Returns true when a string looks like a filesystem path rather than a
-- | command keyword. A path either starts with '.' or contains '/'.
looksLikePath :: String -> Boolean
looksLikePath s =
    String.take 1 s == "."
    || String.contains (String.Pattern "/") s

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
