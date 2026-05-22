-- | Pure reflection-result parsing for the rounds-and-reflection workflow.
-- | Covers requirement A50.
module Agent.Programs.Reflection
    ( ReflectionResult
    , parseReflectionResponse
    ) where

import Prelude

import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Foreign.Object as FO
import Data.Argonaut.Core as J
import Data.Argonaut.Parser as JP

-- | The structured result returned by a reflection LLM call (A50).
type ReflectionResult = { complete :: Boolean, feedback :: Maybe String }

-- | Parse the JSON body returned by a reflection LLM call.
-- |
-- | Any response that is not parseable JSON, lacks the boolean `complete`
-- | field, or has a non-boolean `complete` is treated as:
-- | `{ complete: false, feedback: Just "Reflection call failed to return valid JSON." }`
parseReflectionResponse :: String -> ReflectionResult
parseReflectionResponse json =
    case JP.jsonParser json of
        Left  _      -> fallback
        Right parsed -> case J.toObject parsed of
            Nothing  -> fallback
            Just obj -> case FO.lookup "complete" obj of
                Nothing -> fallback
                Just cv -> case J.toBoolean cv of
                    Nothing      -> fallback
                    Just complete ->
                        let feedback = FO.lookup "feedback" obj >>= J.toString
                        in  { complete, feedback }
  where
    fallback =
        { complete: false
        , feedback: Just "Reflection call failed to return valid JSON."
        }
