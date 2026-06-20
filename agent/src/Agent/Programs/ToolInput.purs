module Agent.Programs.ToolInput
    ( summarizeToolInput
    , parseJuliaReplInput
    , parseJuliaCodeInput
    , parseGitStageInput
    , parseGitCommitInput
    ) where

import Prelude

import Data.Argonaut.Core as J
import Data.Argonaut.Parser as JP
import Data.Array as Array
import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as String
import Foreign.Object as FO

import Agent.Types (ToolName(..))

foreign import decodeJsonStringLiteral :: String -> String
foreign import parseJuliaReplInputImpl
    :: String
    -> { parsed :: Boolean
       , isObject :: Boolean
       , hasCodeString :: Boolean
       , code :: String
       , hasTimeoutNumber :: Boolean
       , timeoutSeconds :: Number
       }

type JuliaReplInput =
    { code :: String
    , timeoutSeconds :: Int
    }

type GitStageInput =
    { what :: String
    }

type GitCommitInput =
    { what :: String
    , message :: String
    , body :: Maybe String
    }

summarizeToolInput :: ToolName -> String -> String
summarizeToolInput JuliaRepl input =
    let code = parseJuliaCodeInput input
        ls = String.split (String.Pattern "\n") code
        kept = Array.take 10 ls
        more = Array.length ls > 10
    in String.joinWith "\n" kept <> if more then "\n..." else ""
summarizeToolInput GitStage input =
    let parsed = parseGitStageInput input
        what = map _.what parsed
    in "what: " <> fromMaybe "all" what
summarizeToolInput GitCommit input =
    let parsed = parseGitCommitInput input
        msg = map _.message parsed
        what = map _.what parsed
    in "message: " <> fromMaybe "(none)" msg
       <> "  what: " <> fromMaybe "all" what
summarizeToolInput _ input = input

parseJuliaReplInput :: Int -> String -> Either String JuliaReplInput
parseJuliaReplInput maxTimeoutSeconds input = do
    let parsed = parseJuliaReplInputImpl input
    if not parsed.parsed || not parsed.isObject then
        Left "Invalid julia_repl input: expected a JSON object"
    else
        Right unit
    if not parsed.hasCodeString then
        Left "Invalid julia_repl input: field code must be a string"
    else
        Right unit
    let code = parsed.code
    timeoutSeconds <- case parsed.hasTimeoutNumber of
        false ->
            Left "Invalid julia_repl input: field timeout_seconds must be a number"
        true ->
            let rounded = Int.round parsed.timeoutSeconds
            in if Int.toNumber rounded /= parsed.timeoutSeconds
                then Left "Invalid julia_repl input: timeout_seconds must be an integer"
                else Right rounded
    if timeoutSeconds <= 0 then
        Left "Invalid julia_repl input: timeout_seconds must be positive"
    else if timeoutSeconds > maxTimeoutSeconds then
        Left
            ( "Invalid julia_repl input: timeout_seconds exceeds max_repl_timeout_seconds "
                <> show maxTimeoutSeconds
            )
    else
        Right { code, timeoutSeconds }

parseJuliaCodeInput :: String -> String
parseJuliaCodeInput input =
    let parsed = parseJuliaReplInputImpl input
    in if parsed.parsed && parsed.isObject && parsed.hasCodeString
        then parsed.code
        else fromMaybe input do
            obj <- parseJsonObject input
            val <- FO.lookup "code" obj
            J.toString val $> decodeJsonStringLiteral (J.stringify val)

parseGitStageInput :: String -> Maybe GitStageInput
parseGitStageInput input = do
    obj <- parseJsonObject input
    whatJson <- FO.lookup "what" obj
    let what = fromMaybe (J.stringify whatJson) (J.toString whatJson)
    pure { what }

parseGitCommitInput :: String -> Maybe GitCommitInput
parseGitCommitInput input = do
    obj <- parseJsonObject input
    whatJson <- FO.lookup "what" obj
    let what = fromMaybe (J.stringify whatJson) (J.toString whatJson)
    let message = fromMaybe "Commit" do
            msgJson <- FO.lookup "message" obj
            J.toString msgJson
    let body = do
            bodyJson <- FO.lookup "body" obj
            J.toString bodyJson
    pure { what, message, body }

parseJsonObject :: String -> Maybe (FO.Object J.Json)
parseJsonObject input = do
    json <- case JP.jsonParser input of
        Right parsed -> Just parsed
        Left _ -> Nothing
    J.toObject json
