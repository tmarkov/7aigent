module Agent.Programs.InitialMessage
    ( ParsedInitialMessage
    , parseInitialMessage
    ) where

import Prelude

import Data.Argonaut.Core as J
import Data.Argonaut.Parser as JP
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.String.CodeUnits as CU

import Agent.Programs.ToolInput (parseJuliaReplInput)
import Agent.Types (ToolCallId(..), ToolName(..), ToolCall)

type ParsedInitialMessage =
    { assistantContent :: String
    , toolCall :: ToolCall
    }

parseInitialMessage
    :: Int
    -> String
    -> Either String (Maybe ParsedInitialMessage)
parseInitialMessage maxTimeoutSeconds input
    | String.trim input == "" =
        Right Nothing
    | otherwise = do
        marker <- extractSingleMarker input
        toolCall <- parseMarker maxTimeoutSeconds marker.inner
        Right $ Just
            { assistantContent: marker.before <> marker.after
            , toolCall
            }

parseMarker :: Int -> String -> Either String ToolCall
parseMarker maxTimeoutSeconds inner = do
    let trimmed = String.trim inner
    afterName <- case String.stripPrefix (String.Pattern "julia_repl") trimmed of
        Nothing ->
            Left "initial_message.md marker must start with julia_repl"
        Just rest ->
            Right (String.trim rest)
    parenBody <- stripWrappedParens afterName
    parsed <- parseToolArgs maxTimeoutSeconds parenBody
    Right
        { name: JuliaRepl
        , input: parsed.input
        , id: ToolCallId "initial_seed"
        }

parseToolArgs
    :: Int
    -> String
    -> Either String { input :: String }
parseToolArgs maxTimeoutSeconds body = do
    { literal, rest } <- consumeJsonStringLiteral (String.trim body)
    afterComma <- case String.stripPrefix (String.Pattern ",") (String.trim rest) of
        Nothing ->
            Left "initial_message.md marker must contain a comma after the JSON string"
        Just tailText ->
            Right (String.trim tailText)
    let timeoutText = String.trim afterComma
    if timeoutText == "" then
        Left "initial_message.md marker timeout is missing"
    else if not (allDigits timeoutText) then
        Left "initial_message.md marker timeout must be a positive base-10 integer"
    else do
        parsed <- parseJuliaReplInput maxTimeoutSeconds
            ("{\"code\":" <> literal <> ",\"timeout_seconds\":" <> timeoutText <> "}")
        Right
            { input:
                "{\"code\":"
                    <> literal
                    <> ",\"timeout_seconds\":"
                    <> show parsed.timeoutSeconds
                    <> "}"
            }

extractSingleMarker
    :: String
    -> Either String { before :: String, inner :: String, after :: String }
extractSingleMarker input =
    case findToolMarkerStart input of
        Nothing ->
            Left "initial_message.md must contain exactly one <<julia_repl(...)>> marker"
        Just start -> do
            let afterOpen = CU.drop (start + 2) input
            close <- findMarkerClose afterOpen
            let afterClose = CU.drop (close + 2) afterOpen
            case findToolMarkerStart afterClose of
                Just _ ->
                    Left "initial_message.md must contain exactly one marker"
                Nothing ->
                    Right
                        { before: CU.take start input
                        , inner: CU.take close afterOpen
                        , after: afterClose
                        }

findToolMarkerStart :: String -> Maybe Int
findToolMarkerStart text =
    go 0
  where
    len = CU.length text

    go idx
        | idx >= len - 1 =
            Nothing
        | CU.take 2 (CU.drop idx text) == "<<" =
            if isToolLikeStart (CU.drop (idx + 2) text) then
                Just idx
            else
                go (idx + 1)
        | otherwise =
            go (idx + 1)

isToolLikeStart :: String -> Boolean
isToolLikeStart text =
    case String.stripPrefix (String.Pattern "julia_repl") (String.trim text) of
        Just _ -> true
        Nothing -> false

findMarkerClose :: String -> Either String Int
findMarkerClose text =
    go 0
  where
    len = CU.length text

    go idx
        | idx >= len =
            Left "initial_message.md marker is missing closing >>"
        | otherwise =
            let remaining = CU.drop idx text
                nextTwo =
                    if idx + 1 < len then
                        CU.take 2 remaining
                    else
                        CU.take 1 remaining
            in if nextTwo == ">>" then
                Right idx
            else
                go (idx + 1)

stripWrappedParens :: String -> Either String String
stripWrappedParens text =
    let trimmed = String.trim text
        len = CU.length trimmed
    in if len < 2 || CU.take 1 trimmed /= "(" || CU.drop (len - 1) trimmed /= ")"
        then Left "initial_message.md marker must use julia_repl(<json string>, <timeout>)"
        else Right (CU.take (len - 2) (CU.drop 1 trimmed))

consumeJsonStringLiteral
    :: String
    -> Either String { literal :: String, rest :: String }
consumeJsonStringLiteral text
    | CU.take 1 text /= "\"" =
        Left "initial_message.md marker code must be a JSON string literal"
    | otherwise =
        go "\"" (CU.drop 1 text) false
  where
    go acc remaining escaped
        | CU.length remaining == 0 =
            Left "initial_message.md marker code string is unterminated"
        | otherwise =
            let ch = CU.take 1 remaining
                rest = CU.drop 1 remaining
                nextAcc = acc <> ch
            in if escaped then
                go nextAcc rest false
            else if ch == "\\" then
                go nextAcc rest true
            else if ch == "\"" then
                case JP.jsonParser nextAcc of
                    Right json -> case J.toString json of
                        Just _ -> Right { literal: nextAcc, rest }
                        Nothing -> Left "initial_message.md marker code must decode to a JSON string"
                    Left _ ->
                        Left "initial_message.md marker code must be a valid JSON string literal"
            else
                go nextAcc rest false

allDigits :: String -> Boolean
allDigits text =
    CU.length text > 0
        && Array.all isDigit (explodeOneChar text)
  where
    digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
    isDigit ch = Array.elem ch digits

explodeOneChar :: String -> Array String
explodeOneChar text
    | CU.length text == 0 = []
    | otherwise =
        [CU.take 1 text] <> explodeOneChar (CU.drop 1 text)
