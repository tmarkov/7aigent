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
import Agent.Runner.Session (runNewSession, runResumeSession, runListSessions, runMcpServer)
import Agent.Runner.Services (productionServices)
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
            runListSessions productionServices ws
        ResumeSession sid ->
            runResumeSession productionServices ws sid parsed.prompt
        McpServer port ->
            runMcpServer productionServices ws port
        StartSession ->
            runNewSession productionServices ws parsed.prompt
