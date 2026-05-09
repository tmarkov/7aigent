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
    let files =
            [ { name: "config.toml", content: defaultConfigToml }
            , { name: "system_prompt.md", content: defaultSystemPrompt }
            , { name: "compaction_prompt.md", content: defaultCompactionPrompt }
            , { name: "summary_message.md", content: defaultSummaryMessage }
            , { name: "startup.jl", content: defaultStartupJl }
            ]
    results <- traverse
        (\f -> do
            let filePath = configDir <> "/" <> f.name
            exists <- fileExists filePath
            if exists
            then pure Nothing
            else do
                FS.writeTextFile UTF8 filePath f.content
                pure (Just ("Created " <> ".7aigent/" <> f.name))
        ) files
    pure (Array.catMaybes results)

fileExists :: String -> Aff Boolean
fileExists path = do
    result <- FS.access path
    case result of
        Nothing -> pure true
        Just _ -> pure false

-- Default file contents

defaultConfigToml :: String
defaultConfigToml = String.joinWith "\n"
    [ "# 7aigent workspace configuration."
    , "# This file is created on first run. Edit it before starting a session."
    , ""
    , "api_endpoint           = \"YOUR_API_ENDPOINT_HERE\""
    , "model                  = \"YOUR_MODEL_HERE\""
    , "api_key_env            = \"OPENROUTER_API_KEY\""
    , "output_threshold_chars = 20000"
    , "max_api_retries        = 3"
    , "max_tokens_per_turn    = 200000"
    , "compaction_threshold   = 150000"
    , "preserve_initial       = 20000"
    , "preserve_final         = 40000"
    ]

defaultSystemPrompt :: String
defaultSystemPrompt = String.joinWith "\n"
    [ "You are 7aigent, an AI assistant for interactive codebase exploration and editing."
    , ""
    , "**Date/time:** {{datetime}}"
    , "**Model:** {{model}}"
    , ""
    , "## Workspace"
    , ""
    , "The workspace has been indexed into a CodeTree database. Use the `julia_repl`"
    , "tool to query it. The Julia kernel is pre-loaded with `CodeTree` and a database"
    , "bound to `db` in `Main`."
    , ""
    , "**Startup output:**"
    ]

defaultCompactionPrompt :: String
defaultCompactionPrompt = String.joinWith "\n"
    [ "The following is a conversation between an AI assistant and a user. Summarise"
    , "the middle section of the conversation so the key facts, decisions, and code"
    , "changes are preserved, but token usage is reduced."
    , ""
    , "## Initial messages"
    , ""
    , "{{initial_messages}}"
    , ""
    , "## Middle messages to summarise"
    , ""
    , "{{compacted_messages}}"
    , ""
    , "## Recent messages (do not summarise)"
    , ""
    , "{{final_messages}}"
    , ""
    , "Write a concise summary of the middle messages. Focus on: goals discussed,"
    , "findings from tool calls, code written or modified, and any open questions."
    ]

defaultSummaryMessage :: String
defaultSummaryMessage = String.joinWith "\n"
    [ "Earlier in this conversation the following context was summarised to save space:"
    , ""
    , "{{summary}}"
    , ""
    , "The full conversation history from this point forward is included below."
    ]

defaultStartupJl :: String
defaultStartupJl = String.joinWith "\n"
    [ "-- Default startup: index the workspace and bind the database to Main.db."
    , "-- Edit .7aigent/startup.jl in your workspace to customise this behaviour."
    , "db = CodeTree.load(\"/workspace\")"
    ]
