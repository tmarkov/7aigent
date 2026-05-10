module Main where

import Prelude

import Data.Array as Array
import Effect (Effect)
import Effect.Aff (launchAff_)
import Effect.Class (liftEffect)
import Node.Process as Process

import Data.Maybe (fromMaybe)
import Agent.Types (WorkspacePath(..), SessionId(..))
import Agent.Programs.CLI (parseCLIArgs, CLIMode(..))
import Agent.Runner.Session (runNewSession, runResumeSession, runListSessions)
import Agent.Services.Terminal (printErr)

main :: Effect Unit
main = launchAff_ do
    argv <- liftEffect Process.argv
    let args = Array.drop 2 argv   -- drop "node" and script path
    cwd  <- liftEffect Process.cwd
    let parsed = parseCLIArgs args
        ws = fromMaybe (WorkspacePath cwd) parsed.workspace
    case parsed.mode of
        CLIError msg -> do
            liftEffect $ printErr msg
            liftEffect $ Process.exit' 1
        ListSessions ->
            runListSessions ws
        ResumeSession sid ->
            runResumeSession ws sid parsed.prompt
        McpServer _port -> do
            liftEffect $ printErr "MCP server mode is not yet implemented."
            liftEffect $ Process.exit' 1
        StartSession ->
            runNewSession ws parsed.prompt
