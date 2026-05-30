module Agent.Programs.ToolInput
    ( summarizeToolInput
    , parseJuliaCodeInput
    , parseGitStageInput
    , parseGitCommitInput
    ) where

import Prelude

import Data.Argonaut.Core as J
import Data.Argonaut.Parser as JP
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as String
import Foreign.Object as FO

import Agent.Types (ToolName(..))

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
