module Agent.Programs.GitWritePlan
    ( WholeFilePlan
    , GitWritePlan
    , EncodedWholeFilePlan
    , encodeWholeFilePlans
    ) where

import Prelude

import Data.Maybe (Maybe, fromMaybe)

type WholeFilePlan =
    { path :: String
    , oldPath :: Maybe String
    }

type GitWritePlan =
    { wholeFiles :: Array WholeFilePlan
    , partialAllPatch :: String
    , partialUnstagedPatch :: String
    }

type EncodedWholeFilePlan =
    { path :: String
    , oldPath :: String
    }

encodeWholeFilePlans :: Array WholeFilePlan -> Array EncodedWholeFilePlan
encodeWholeFilePlans = map \file ->
    { path: file.path
    , oldPath: fromMaybe "" file.oldPath
    }
