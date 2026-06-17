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
    obj <- case parseJsonObject input of
        Nothing -> Left "Invalid julia_repl input: expected a JSON object"
        Just parsed -> Right parsed
    code <- case FO.lookup "code" obj >>= J.toString of
        Nothing -> Left "Invalid julia_repl input: field code must be a string"
        Just value -> Right value
    timeoutSeconds <- case FO.lookup "timeout_seconds" obj >>= J.toNumber of
        Nothing ->
            Left "Invalid julia_repl input: field timeout_seconds must be a number"
        Just value ->
            let rounded = Int.round value
            in if Int.toNumber rounded /= value
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
    fromMaybe input do
        obj <- parseJsonObject input
        val <- FO.lookup "code" obj
        J.toString val

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
