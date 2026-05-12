module Agent.Programs.SandboxPreflight
    ( GitMetadataKind(..)
    , GitMetadataInfo
    , SandboxPreflight(..)
    , SandboxPreflightResult(..)
    , inspectSandboxPreflight
    , renderNogitConflictPrompt
    , runSandboxPreflight
    ) where

import Prelude

import Data.Maybe (Maybe(..))
import Data.String as String
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)

import Agent.Types (WorkspacePath(..))

data GitMetadataKind
    = GitDirectory
    | GitSymlink
    | GitFile
    | OtherGitObject

derive instance Eq GitMetadataKind

instance Show GitMetadataKind where
    show GitDirectory = "GitDirectory"
    show GitSymlink = "GitSymlink"
    show GitFile = "GitFile"
    show OtherGitObject = "OtherGitObject"

type GitMetadataInfo =
    { kind :: GitMetadataKind
    , detail :: String
    }

data SandboxPreflight
    = NoSandboxConflict
    | NogitConflict GitMetadataInfo

derive instance Eq SandboxPreflight

instance Show SandboxPreflight where
    show NoSandboxConflict = "NoSandboxConflict"
    show (NogitConflict info) =
        "(NogitConflict " <> show info.kind <> " " <> show info.detail <> ")"

data SandboxPreflightResult
    = ContinueStartup
    | HaltStartup

derive instance Eq SandboxPreflightResult

instance Show SandboxPreflightResult where
    show ContinueStartup = "ContinueStartup"
    show HaltStartup = "HaltStartup"

foreign import inspectSandboxPreflightImpl
    :: String
    -> Effect
        { nogitExists :: Boolean
        , gitExists :: Boolean
        , gitKind :: String
        , gitDetail :: String
        }

foreign import removeNogitImpl :: String -> Effect Unit

inspectSandboxPreflight :: WorkspacePath -> Aff SandboxPreflight
inspectSandboxPreflight (WorkspacePath wp) = liftEffect do
    probe <- inspectSandboxPreflightImpl wp
    pure $
        if probe.nogitExists && probe.gitExists
        then NogitConflict
            { kind: decodeGitMetadataKind probe.gitKind
            , detail: probe.gitDetail
            }
        else NoSandboxConflict

renderNogitConflictPrompt :: GitMetadataInfo -> String
renderNogitConflictPrompt info =
    String.joinWith "\n"
        ([ "Workspace trust-state conflict detected."
         , ".7aigent/state/nogit exists, but "
            <> describeGitMetadata info
         , "Proceeding re-trusts the current .git metadata for this and future launches."
         , "Type 'halt' to stop, or 'proceed' to remove .7aigent/state/nogit and proceed."
         ] <> detailLines)
  where
    detailLines =
        if String.null (String.trim info.detail)
        then []
        else [ "Details: " <> info.detail ]

runSandboxPreflight
    :: WorkspacePath
    -> (String -> Aff String)
    -> Aff SandboxPreflightResult
runSandboxPreflight ws@(WorkspacePath wp) askUser = do
    state <- inspectSandboxPreflight ws
    case state of
        NoSandboxConflict -> pure ContinueStartup
        NogitConflict info -> promptLoop info
  where
    promptLoop info = do
        response <- askUser (renderNogitConflictPrompt info)
        case interpretChoice response of
            Just HaltStartup ->
                pure HaltStartup
            Just ContinueStartup -> do
                liftEffect $ removeNogitImpl (wp <> "/.7aigent/state/nogit")
                pure ContinueStartup
            Nothing ->
                promptLoop
                    { kind: info.kind
                    , detail:
                        info.detail
                            <> if String.null (String.trim info.detail)
                                then "Please answer with 'halt' or 'proceed'."
                                else "\nPlease answer with 'halt' or 'proceed'."
                    }

decodeGitMetadataKind :: String -> GitMetadataKind
decodeGitMetadataKind raw =
    case String.toLower raw of
        "directory" -> GitDirectory
        "symlink" -> GitSymlink
        "gitfile" -> GitFile
        _ -> OtherGitObject

describeGitMetadata :: GitMetadataInfo -> String
describeGitMetadata info =
    "the current .git is " <> article <> " " <> noun <> "."
  where
    noun = case info.kind of
        GitDirectory -> "git directory"
        GitSymlink -> "git symlink"
        GitFile -> "gitfile"
        OtherGitObject -> "other git object"

    article = case info.kind of
        OtherGitObject -> "an"
        _ -> "a"

interpretChoice :: String -> Maybe SandboxPreflightResult
interpretChoice response =
    case String.toLower (String.trim response) of
        "" -> Just HaltStartup
        "halt" -> Just HaltStartup
        "stop" -> Just HaltStartup
        "no" -> Just HaltStartup
        "proceed" -> Just ContinueStartup
        "continue" -> Just ContinueStartup
        "yes" -> Just ContinueStartup
        _ -> Nothing
