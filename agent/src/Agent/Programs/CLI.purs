module Agent.Programs.CLI
    ( parseCLIArgs
    , CLIParseResult(..)
    , CLIMode(..)
    ) where

import Prelude

import Control.Alt ((<|>))
import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.Tuple (Tuple(..))
import ExitCodes as ExitCode
import Options.Applicative
    ( Parser
    , ParserInfo
    , argument
    , command
    , execParserPure
    , fullDesc
    , help
    , helper
    , info
    , int
    , long
    , metavar
    , prefs
    , progDesc
    , renderFailure
    , short
    , showHelpOnError
    , str
    , strOption
    , subparser
    , (<**>)
    )
import Options.Applicative.Types (ParserResult(..))

import Agent.Types (Port(..), SessionId(..), WorkspacePath(..))

data CLIMode
    = StartSession
    | ListSessions
    | ResumeSession SessionId
    | McpServer Port

derive instance Eq CLIMode
instance Show CLIMode where
    show StartSession = "StartSession"
    show ListSessions = "ListSessions"
    show (ResumeSession sid) =
        "(ResumeSession " <> show sid <> ")"
    show (McpServer port) =
        "(McpServer " <> show port <> ")"

data CLIParseResult
    = CLIParsed
        { workspace :: Maybe WorkspacePath
        , mode :: CLIMode
        , prompt :: Maybe String
        }
    | CLIOutput
        { message :: String
        , exitCode :: Int
        }

type ParsedCLI =
    { mode :: CLIMode
    , prompt :: Maybe String
    }

parseCLIArgs :: Array String -> CLIParseResult
parseCLIArgs args =
    let extracted = extractWorkspace args
    in case execParserPure (prefs showHelpOnError) cliParserInfo extracted.remaining of
        Success parsed ->
            CLIParsed
                { workspace: extracted.workspace
                , mode: parsed.mode
                , prompt: parsed.prompt
                }
        Failure failure ->
            let Tuple rendered exitCode = renderFailure failure "7aigent"
            in CLIOutput
                { message:
                    maybeAppendPromptHint extracted.remaining
                        (injectWorkspaceUsage rendered)
                , exitCode: exitCodeToInt exitCode
                }
        CompletionInvoked _ ->
            CLIOutput
                { message: "Shell completion is not supported by this build."
                , exitCode: 0
                }

cliParserInfo :: ParserInfo ParsedCLI
cliParserInfo =
    info (parsedCLI <**> helper)
        ( fullDesc
        <> progDesc "Start a new session, resume a session, list sessions, or run the MCP server."
        )

parsedCLI :: Parser ParsedCLI
parsedCLI = ado
    prompt <- promptParser
    mode <- modeParser
    in { mode, prompt }

promptParser :: Parser (Maybe String)
promptParser =
    (Just <$> strOption
        ( long "prompt"
        <> short 'p'
        <> metavar "PROMPT"
        <> help "Run one prompt-mode round using PROMPT instead of reading from stdin."
        ))
    <|> pure Nothing

modeParser :: Parser CLIMode
modeParser =
    subparser
        ( command "sessions"
            (info (pure ListSessions)
                (progDesc "List sessions for the workspace."))
        <> command "resume"
            (info resumeParser
                (progDesc "Resume the specified session."))
        <> command "mcp"
            (info mcpParser
                (progDesc "Start the MCP server on PORT."))
        )
    <|> pure StartSession

resumeParser :: Parser CLIMode
resumeParser =
    ResumeSession <<< SessionId <$> argument int
        ( metavar "SESSION_ID"
        <> help "Session ID to resume."
        )

mcpParser :: Parser CLIMode
mcpParser =
    McpServer <<< Port <$> argument int
        ( metavar "PORT"
        <> help "Port to listen on."
        )

extractWorkspace
    :: Array String
    -> { workspace :: Maybe WorkspacePath, remaining :: Array String }
extractWorkspace args =
    case Array.uncons args of
        Just { head, tail } | looksLikePath head ->
            { workspace: Just (WorkspacePath head), remaining: tail }
        _ ->
            { workspace: Nothing, remaining: args }

-- | Returns true when a string looks like a filesystem path rather than a
-- | command keyword. A path either starts with '.' or contains '/'.
looksLikePath :: String -> Boolean
looksLikePath s =
    String.take 1 s == "."
    || String.contains (String.Pattern "/") s

injectWorkspaceUsage :: String -> String
injectWorkspaceUsage =
    String.replace
        (String.Pattern "Usage: 7aigent ")
        (String.Replacement "Usage: 7aigent [<dir>] ")

maybeAppendPromptHint :: Array String -> String -> String
maybeAppendPromptHint args rendered =
    if isLikelyPromptMistake args then
        rendered
            <> "\nHint: use -p/--prompt to pass an initial task prompt, e.g.\n"
            <> "  7aigent [<dir>] -p \"Inspect failing tests\"\n"
    else
        rendered
  where
    isLikelyPromptMistake remaining =
        case Array.head remaining, Array.length remaining of
            Just arg, 1 ->
                String.take 1 arg /= "-"
                    && not (looksLikePath arg)
                    && not (isKnownCommand arg)
                    && String.contains (String.Pattern " ") arg
            _, _ ->
                false

    isKnownCommand "sessions" = true
    isKnownCommand "resume" = true
    isKnownCommand "mcp" = true
    isKnownCommand _ = false

exitCodeToInt :: ExitCode.ExitCode -> Int
exitCodeToInt ExitCode.Success = 0
exitCodeToInt _ = 1
