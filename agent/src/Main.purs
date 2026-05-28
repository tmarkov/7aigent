module Main where

import Prelude

import Data.Array as Array
import Effect (Effect)
import Effect.Aff (launchAff_)
import Effect.Class (liftEffect)
import Node.Process as Process

import Data.Maybe (fromMaybe)
import Agent.Types (WorkspacePath(..), SessionId(..))
import Agent.Programs.CLI (parseCLIArgs, CLIMode(..), CLIParseResult(..))
import Agent.Runner.Session (runNewSession, runResumeSession, runListSessions, runMcpServer)
import Agent.Runner.Services (productionServices)
import Agent.Services.Terminal (printErr, printLn)

main :: Effect Unit
main = launchAff_ do
    argv <- liftEffect Process.argv
    let args = Array.drop 2 argv   -- drop "node" and script path
    cwd  <- liftEffect Process.cwd
    case parseCLIArgs args of
        CLIOutput output -> do
            if output.exitCode == 0
            then liftEffect $ printLn output.message
            else liftEffect $ printErr output.message
            liftEffect $ Process.exit' output.exitCode
        CLIParsed parsed -> do
            let ws = fromMaybe (WorkspacePath cwd) parsed.workspace
            case parsed.mode of
                ListSessions ->
                    runListSessions productionServices ws
                ResumeSession sid ->
                    runResumeSession productionServices ws sid parsed.prompt
                McpServer port ->
                    runMcpServer productionServices ws port
                StartSession ->
                    runNewSession productionServices ws parsed.prompt
