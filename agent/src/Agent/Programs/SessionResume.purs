-- | Session resumption: loads a previous session for replay.
-- | Covers requirements A31, A32.
module Agent.Programs.SessionResume
    ( loadSessionForResume
    , ResumeResult(..)
    ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String as String
import Effect.Aff (Aff, attempt)
import Node.Encoding (Encoding(..))
import Node.FS.Aff as FS

import Agent.Types
    ( WorkspacePath(..)
    , SessionId(..)
    , ConversationHistory
    , AppError(..)
    )
import Agent.Programs.SessionLog (readLogEvents, reconstructHistory)

----------------------------------------------------------------------------
-- A31: ResumeResult
----------------------------------------------------------------------------

data ResumeResult
    = ResumeReady
        { history :: ConversationHistory
        , juliaDefs :: Array String
        , hasStateFile :: Boolean
        , warnings :: Array String
        , resumedFrom :: Maybe SessionId
        }
    | ResumeError String

----------------------------------------------------------------------------
-- A31: load session for resumption
----------------------------------------------------------------------------

loadSessionForResume :: WorkspacePath -> SessionId -> Aff ResumeResult
loadSessionForResume ws@(WorkspacePath wp) sid@(SessionId sidNum) = do
    let sessionDir = wp <> "/.7aigent/sessions/" <> show sidNum

    -- Read and decode log events
    eventsResult <- readLogEvents ws sid
    case eventsResult of
        Left err -> pure $ ResumeError ("Failed to read log: " <> show err)
        Right events -> do
            -- Reconstruct conversation history
            case reconstructHistory events of
                Left err -> pure $ ResumeError
                    ("Failed to reconstruct history: " <> show err)
                Right history -> do
                    -- Load julia_defs.jl
                    defsResult <- attempt
                        (FS.readTextFile UTF8 (sessionDir <> "/julia_defs.jl"))
                    let defsAndWarnings = case defsResult of
                            Left _ ->
                                { defs: []
                                , warnings: ["Julia defs file missing for session "
                                    <> show sidNum
                                    <> "; definitions will not be replayed"]
                                }
                            Right content ->
                                let defs = Array.filter (\l -> l /= "")
                                        (String.split (String.Pattern "\n")
                                            (String.trim content))
                                in { defs, warnings: [] }

                    stateResult <- FS.access (sessionDir <> "/julia_state.jls")
                    let hasStateFile = case stateResult of
                            Nothing -> true
                            Just _ -> false
                    let stateWarnings = if hasStateFile
                            then []
                            else ["Julia state file missing for session "
                                <> show sidNum
                                <> "; globals will not be restored"]

                    pure $ ResumeReady
                        { history
                        , juliaDefs: defsAndWarnings.defs
                        , hasStateFile
                        , warnings: defsAndWarnings.warnings <> stateWarnings
                        , resumedFrom: Just sid
                        }
