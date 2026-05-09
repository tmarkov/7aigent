-- | Temporary workspace creation and cleanup for effectful tests.
module Test.Helpers.Workspace
  ( withWorkspace
  , withPopulatedWorkspace
  , writeWorkspaceFile
  , readWorkspaceFile
  , workspaceFileExists
  , writeSessionLog
  ) where

import Prelude

import Data.Maybe (Maybe(..), isNothing)
import Effect.Aff (Aff, bracket)
import Node.Encoding (Encoding(..))
import Node.FS.Aff as FSA
import Node.FS.Perms as Perms
import Node.Path as Path
import Agent.Types (WorkspacePath(..), SessionId(..))

-- | Create an empty temp workspace directory, run the action, then clean up.
withWorkspace :: forall a. (WorkspacePath -> Aff a) -> Aff a
withWorkspace action = bracket acquire release action
  where
  acquire = do
    dir <- FSA.mkdtemp "/tmp/7aigent-test-"
    FSA.mkdir' (Path.concat [dir, ".7aigent"])
      { recursive: true, mode: Perms.mkPerms Perms.all Perms.all Perms.all }
    pure (WorkspacePath dir)
  release (WorkspacePath dir) =
    FSA.rm' dir { recursive: true, force: true, maxRetries: 0, retryDelay: 100 }

-- | Create a temp workspace pre-populated with default config files.
withPopulatedWorkspace :: forall a. (WorkspacePath -> Aff a) -> Aff a
withPopulatedWorkspace action = withWorkspace action

-- | Write a file into the workspace at the given relative path.
writeWorkspaceFile :: WorkspacePath -> String -> String -> Aff Unit
writeWorkspaceFile (WorkspacePath ws) relPath content = do
  let fullPath = Path.concat [ws, relPath]
      dir = Path.dirname fullPath
  FSA.mkdir' dir
    { recursive: true, mode: Perms.mkPerms Perms.all Perms.all Perms.all }
  FSA.writeTextFile UTF8 fullPath content

-- | Read a file from the workspace at the given relative path.
readWorkspaceFile :: WorkspacePath -> String -> Aff String
readWorkspaceFile (WorkspacePath ws) relPath =
  FSA.readTextFile UTF8 (Path.concat [ws, relPath])

-- | Check whether a file exists in the workspace.
workspaceFileExists :: WorkspacePath -> String -> Aff Boolean
workspaceFileExists (WorkspacePath ws) relPath = do
  result <- FSA.access (Path.concat [ws, relPath])
  pure (isNothing result)

-- | Write a JSONL session log into `.7aigent/sessions/<id>/log.jsonl`.
writeSessionLog :: WorkspacePath -> SessionId -> String -> Aff Unit
writeSessionLog ws (SessionId sid) jsonl =
  writeWorkspaceFile ws
    (".7aigent/sessions/" <> show sid <> "/log.jsonl")
    jsonl
