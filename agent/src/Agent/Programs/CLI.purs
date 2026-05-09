module Agent.Programs.CLI
    ( parseCLIArgs
    , CLIMode(..)
    ) where

import Prelude
import Data.Array as Array
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Agent.Types (SessionId(..), Port(..))

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

parseCLIArgs :: Array String -> CLIMode
parseCLIArgs args = case Array.uncons args of
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
            <> "[sessions|resume <id>|mcp <port>]"
            )
