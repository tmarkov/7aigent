-- | Configuration parsing, API key reading, and default config placement.
-- | Covers requirements A2a, A37, A38, A39.
module Agent.Programs.Config
    ( parseConfig
    , readApiKey
    , placeDefaultConfigs
    ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Nullable (Nullable, toMaybe)
import Data.String as String
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Node.Encoding (Encoding(..))
import Node.FS.Aff as FS
import Node.FS.Perms (permsAll)

import Agent.Types
    ( WorkspacePath(..)
    , ModelName(..)
    , TokenCount(..)
    , Config
    , AppError(..)
    )

-- FFI imports
foreign import parseTomlPure
    :: String
    -> { success :: Boolean
       , error :: String
       , api_endpoint :: String
       , model :: String
       , api_key_env :: String
       , output_threshold_chars :: Number
       , max_api_retries :: Number
       , max_tokens_per_turn :: Number
       , compaction_threshold :: Number
       , preserve_initial :: Number
       , preserve_final :: Number
       }

foreign import lookupEnvImpl :: String -> Effect (Nullable String)

foreign import lookupEnvSync :: String -> Nullable String

----------------------------------------------------------------------------
-- A37: config parsing (pure)
----------------------------------------------------------------------------

parseConfig :: String -> Either AppError Config
parseConfig input
    | String.trim input == "" = Left (ConfigFieldMissing "config is empty")
    | otherwise =
        let r = parseTomlPure input
        in
            if not r.success
            then Left (ConfigFieldMissing r.error)
            else
                -- Check for placeholder values
                if r.api_endpoint == "YOUR_API_ENDPOINT_HERE"
                then Left (PlaceholderValue "api_endpoint contains a placeholder value")
                else if r.model == "YOUR_MODEL_HERE"
                then Left (PlaceholderValue "model contains a placeholder value")
                else Right
                    { apiEndpoint: r.api_endpoint
                    , model: ModelName r.model
                    , apiKeyEnv: r.api_key_env
                    , outputThresholdChars: Int.round r.output_threshold_chars
                    , maxApiRetries: Int.round r.max_api_retries
                    , maxTokensPerTurn: TokenCount (Int.round r.max_tokens_per_turn)
                    , compactionThreshold: TokenCount (Int.round r.compaction_threshold)
                    , preserveInitial: TokenCount (Int.round r.preserve_initial)
                    , preserveFinal: TokenCount (Int.round r.preserve_final)
                    }

----------------------------------------------------------------------------
-- A38: API key from environment
----------------------------------------------------------------------------

readApiKey :: String -> Aff (Either AppError String)
readApiKey envVarName = liftEffect do
    mVal <- toMaybe <$> lookupEnvImpl envVarName
    pure $ case mVal of
        Nothing -> Left (ConfigFieldMissing
            ("Environment variable " <> envVarName <> " is not set"))
        Just val
            | val == "" -> Left (ConfigFieldMissing
                ("Environment variable " <> envVarName <> " is empty"))
            | otherwise -> Right val

----------------------------------------------------------------------------
-- A2a: default config placement
----------------------------------------------------------------------------

placeDefaultConfigs :: WorkspacePath -> Aff (Array String)
placeDefaultConfigs (WorkspacePath wp) = do
    let configDir = wp <> "/.7aigent"
    FS.mkdir' configDir { recursive: true, mode: permsAll }
    let fileNames = [ "config.toml", "system_prompt.md", "compaction_prompt.md"
                    , "summary_message.md", "startup.jl" ]
    let mSrcDir = toMaybe (lookupEnvSync "AGENT_CONFIG_DIR")
    results <- traverse
        (\name -> do
            let destPath = configDir <> "/" <> name
            exists <- fileExists destPath
            if exists
            then pure Nothing
            else do
                content <- case mSrcDir of
                    Just srcDir -> FS.readTextFile UTF8 (srcDir <> "/" <> name)
                    Nothing     -> pure ""
                FS.writeTextFile UTF8 destPath content
                pure (Just ("Created " <> ".7aigent/" <> name))
        ) fileNames
    pure (Array.catMaybes results)

fileExists :: String -> Aff Boolean
fileExists path = do
    result <- FS.access path
    case result of
        Nothing -> pure true
        Just _ -> pure false
