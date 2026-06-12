module Agent.Programs.SummaryRequest
    ( SummaryResult
    , buildSummaryHistory
    , encodeSummaryError
    , encodeSummaryResult
    , parseSummaryResponse
    ) where

import Prelude

import Data.Argonaut.Core as J
import Data.Argonaut.Parser as JP
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldMap, traverse_)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Foreign.Object as FO

import Agent.Types
    ( ConversationHistory(..)
    , Message(..)
    , TokenCount(..)
    )

type SummaryResult =
    Array { id :: String, summary :: String }

buildSummaryHistory
    :: String
    -> Either String
        { history :: ConversationHistory
        , targetIds :: Array String
        }
buildSummaryHistory requestJson = do
    request <- parseObject "Summary request" requestJson
    requireKeys [ "request_id", "target_ids", "evidence" ] request
    requestId <- requireRequestString "request_id" request
    if String.trim requestId == ""
        then Left "Summary request field request_id must be non-empty"
        else pure unit
    targetIds <- parseTargetIds request
    validateEvidence request
    let systemPrompt =
            "You summarize CodeTree rows from structured evidence. Return strict JSON only. "
            <> "Each summary must be 1-3 sentences and grounded only in the supplied evidence."
    let userPrompt =
            "Summarize the requested CodeTree rows.\n\n"
            <> "Return exactly this JSON shape:\n"
            <> "{\"summaries\":[{\"id\":\"<requested id>\","
            <> "\"summary\":\"<1-3 sentence summary>\"}]}\n\n"
            <> "Include every requested id exactly once, preserve the provided target order, "
            <> "and do not include markdown fences or any extra prose.\n\n"
            <> "Request JSON:\n"
            <> requestJson
    pure
        { history: ConversationHistory
            { messages:
                [ historyMessage (SystemMessage { content: systemPrompt })
                , historyMessage (UserMessage { content: userPrompt })
                ]
            }
        , targetIds
        }

parseSummaryResponse :: Array String -> String -> Either String SummaryResult
parseSummaryResponse targetIds responseText = do
    response <- parseObject "Summary response" responseText
    summaries <- case FO.lookup "summaries" response >>= J.toArray of
        Just entries ->
            traverse parseSummaryEntry entries
        Nothing ->
            parseSummaryMap targetIds response
    let responseIds = map _.id summaries
    if Array.sort responseIds == Array.sort targetIds
        then pure unit
        else Left "Summary response must contain each requested id exactly once"
    let byId = Map.fromFoldable (map (\entry -> Tuple entry.id entry.summary) summaries)
    traverse (requireSummary byId) targetIds

encodeSummaryResult :: SummaryResult -> String
encodeSummaryResult summaries =
    "ok" <> foldMap encodeEntry summaries
  where
    encodeEntry entry =
        "\n" <> entry.id <> "\t" <> encodeBase64Utf8 entry.summary

encodeSummaryError :: String -> String
encodeSummaryError err =
    "error\t" <> encodeBase64Utf8 err

foreign import encodeBase64Utf8 :: String -> String

historyMessage :: Message -> { message :: Message, tokens :: TokenCount }
historyMessage message =
    { message
    , tokens: TokenCount 0
    }

parseTargetIds :: FO.Object J.Json -> Either String (Array String)
parseTargetIds request =
    case FO.lookup "target_ids" request >>= J.toArray of
        Nothing ->
            Left "Summary request field target_ids must be an array"
        Just values -> do
            targetIds <- traverse parseTargetId values
            if Array.null targetIds
                then Left "Summary request field target_ids must be non-empty"
                else pure unit
            if Array.any (String.null <<< String.trim) targetIds
                then Left "Summary request target_ids must contain non-empty strings"
                else pure unit
            if Array.length (Array.nub targetIds) /= Array.length targetIds
                then Left "Summary request target_ids must be unique"
                else Right targetIds
  where
    parseTargetId value =
        case J.toString value of
            Nothing -> Left "Summary request target_ids must contain only strings"
            Just targetId -> Right targetId

validateEvidence :: FO.Object J.Json -> Either String Unit
validateEvidence request = do
    evidence <- case FO.lookup "evidence" request >>= J.toObject of
        Nothing -> Left "Summary request field evidence must be an object"
        Just value -> Right value
    requireKeys [ "nodes", "witnesses", "targets" ] evidence
    traverse_ (requireArray evidence) [ "nodes", "witnesses", "targets" ]
  where
    requireArray evidence key =
        case FO.lookup key evidence >>= J.toArray of
            Nothing -> Left ("Summary request evidence field " <> key <> " must be an array")
            Just _ -> Right unit

requireRequestString :: String -> FO.Object J.Json -> Either String String
requireRequestString key obj =
    case FO.lookup key obj >>= J.toString of
        Nothing -> Left ("Summary request field " <> key <> " must be a string")
        Just value -> Right value

parseSummaryEntry :: J.Json -> Either String { id :: String, summary :: String }
parseSummaryEntry value = do
    obj <- case J.toObject value of
        Nothing -> Left "Summary response contained an invalid entry"
        Just entry -> Right entry
    id <- requireString "id" obj
    summary <- requireString "summary" obj
    pure { id, summary }

parseSummaryMap
    :: Array String
    -> FO.Object J.Json
    -> Either String SummaryResult
parseSummaryMap targetIds response =
    if Array.sort (FO.keys response) == Array.sort targetIds
        then traverse parseTarget targetIds
        else Left "Summary response must contain each requested id exactly once"
  where
    parseTarget id =
        case FO.lookup id response >>= J.toString of
            Nothing -> Left ("Summary response omitted requested id '" <> id <> "'")
            Just summary -> Right { id, summary }

requireSummary
    :: Map.Map String String
    -> String
    -> Either String { id :: String, summary :: String }
requireSummary summaries id =
    case Map.lookup id summaries of
        Nothing -> Left ("Summary response omitted requested id '" <> id <> "'")
        Just summary -> Right { id, summary }

requireString :: String -> FO.Object J.Json -> Either String String
requireString key obj =
    case FO.lookup key obj >>= J.toString of
        Nothing -> Left ("Summary response field " <> key <> " must be a string")
        Just value -> Right value

requireKeys :: Array String -> FO.Object J.Json -> Either String Unit
requireKeys expected obj =
    if Array.sort (FO.keys obj) == Array.sort expected
        then Right unit
        else Left
            ( "Expected exactly the fields "
                <> Array.intercalate ", " expected
            )

parseObject :: String -> String -> Either String (FO.Object J.Json)
parseObject label input = do
    json <- case JP.jsonParser input of
        Left err -> Left (label <> " was not valid JSON: " <> err)
        Right value -> Right value
    case J.toObject json of
        Nothing -> Left (label <> " must be a JSON object")
        Just obj -> Right obj
