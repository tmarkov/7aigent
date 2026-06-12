module Agent.Programs.ExecutionDecision
    ( DecisionFailure(..)
    , StdinDecision(..)
    , TimeoutDecision(..)
    , decisionRetryDelayMilliseconds
    , parseStdinDecision
    , parseTimeoutDecision
    , renderInputAnnotation
    , renderStdinPrompt
    , renderTimeoutPrompt
    , stdinJsonSchemaPretty
    , timeoutJsonSchemaPretty
    ) where

import Prelude

import Data.Argonaut.Core as J
import Data.Argonaut.Parser as JP
import Data.Array as Array
import Data.Either (Either(..))
import Data.Int as Int
import Data.Int (pow)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Foreign.Object as FO

import Agent.Programs.Template (substituteTemplate)
import Agent.Types (AppError)

data StdinDecision
    = InterruptForStdin
    | ReplyWithInput String

derive instance Eq StdinDecision

instance Show StdinDecision where
    show InterruptForStdin = "InterruptForStdin"
    show (ReplyWithInput value) = "(ReplyWithInput " <> show value <> ")"

data TimeoutDecision
    = InterruptForTimeout
    | ContinueAfterTimeout

derive instance Eq TimeoutDecision

instance Show TimeoutDecision where
    show InterruptForTimeout = "InterruptForTimeout"
    show ContinueAfterTimeout = "ContinueAfterTimeout"

data DecisionFailure
    = DecisionApiFailure String
    | DecisionResponseFailure String

derive instance Eq DecisionFailure

decisionRetryDelayMilliseconds :: Int -> DecisionFailure -> Maybe Int
decisionRetryDelayMilliseconds attemptNumber failure =
    case failure of
        DecisionApiFailure _ ->
            Just (1000 * pow 2 (max 0 (attemptNumber - 1)))
        DecisionResponseFailure _ ->
            Nothing

stdinJsonSchemaPretty :: String
stdinJsonSchemaPretty =
    """{
  "oneOf": [
    {
      "type": "object",
      "properties": {
        "action": {
          "const": "reply"
        },
        "value": {
          "type": "string",
          "description": "The text to send to the REPL as input"
        }
      },
      "required": [
        "action",
        "value"
      ],
      "additionalProperties": false
    },
    {
      "type": "object",
      "properties": {
        "action": {
          "const": "interrupt"
        }
      },
      "required": [
        "action"
      ],
      "additionalProperties": false
    }
  ]
}"""

timeoutJsonSchemaPretty :: String
timeoutJsonSchemaPretty =
    """{
  "type": "object",
  "properties": {
    "action": {
      "type": "string",
      "enum": [
        "continue",
        "interrupt"
      ]
    }
  },
  "required": [
    "action"
  ],
  "additionalProperties": false
}"""

renderStdinPrompt
    :: String
    -> { juliaSource :: String
       , elapsedSeconds :: Int
       , outputSoFar :: String
       , prompt :: String
       }
    -> Either AppError String
renderStdinPrompt template input =
    substituteTemplate
        (Map.insert "prompt" input.prompt
            (commonTemplateVars
                input.juliaSource
                input.elapsedSeconds
                input.outputSoFar
                stdinJsonSchemaPretty))
        template

renderTimeoutPrompt
    :: String
    -> { juliaSource :: String
       , elapsedSeconds :: Int
       , outputSoFar :: String
       }
    -> Either AppError String
renderTimeoutPrompt template input =
    substituteTemplate
        (commonTemplateVars
            input.juliaSource
            input.elapsedSeconds
            input.outputSoFar
            timeoutJsonSchemaPretty)
        template

commonTemplateVars
    :: String
    -> Int
    -> String
    -> String
    -> Map.Map String String
commonTemplateVars juliaSource elapsedSeconds outputSoFar jsonSchema =
    Map.fromFoldable
        [ Tuple "julia_source" juliaSource
        , Tuple "elapsed_time" (Int.toStringAs Int.decimal elapsedSeconds)
        , Tuple "output_so_far" outputSoFar
        , Tuple "json_schema" jsonSchema
        ]

parseStdinDecision :: String -> Either String StdinDecision
parseStdinDecision input = do
    obj <- parseObject input
    action <- getAction obj
    case action of
        "reply" -> do
            requireKeys [ "action", "value" ] obj
            value <- case FO.lookup "value" obj >>= J.toString of
                Nothing -> Left "Field value must be a string"
                Just text -> Right text
            Right (ReplyWithInput value)
        "interrupt" -> do
            requireKeys [ "action" ] obj
            Right InterruptForStdin
        _ -> Left "Stdin action must be reply or interrupt"

parseTimeoutDecision :: String -> Either String TimeoutDecision
parseTimeoutDecision input = do
    obj <- parseObject input
    requireKeys [ "action" ] obj
    action <- getAction obj
    case action of
        "continue" -> Right ContinueAfterTimeout
        "interrupt" -> Right InterruptForTimeout
        _ -> Left "Timeout action must be continue or interrupt"

parseObject :: String -> Either String (FO.Object J.Json)
parseObject input = do
    json <- case JP.jsonParser input of
        Left err -> Left ("Invalid JSON: " <> err)
        Right value -> Right value
    case J.toObject json of
        Nothing -> Left "Expected a JSON object"
        Just obj -> Right obj

getAction :: FO.Object J.Json -> Either String String
getAction obj =
    case FO.lookup "action" obj >>= J.toString of
        Nothing -> Left "Field action must be a string"
        Just action -> Right action

requireKeys :: Array String -> FO.Object J.Json -> Either String Unit
requireKeys expected obj =
    if Array.sort (FO.keys obj) == Array.sort expected
        then Right unit
        else Left ("Expected exactly the fields " <> Array.intercalate " and " expected)

renderInputAnnotation :: String -> String
renderInputAnnotation value =
    "\n[input: " <> J.stringify (J.fromString value) <> "]"
