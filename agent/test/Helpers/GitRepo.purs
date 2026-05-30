-- | Temporary git repo scaffolding for testing git_diff and git_commit.
module Test.Helpers.GitRepo
  ( withGitRepo
  , addTrackedFile
  , modifyTrackedFile
  , stageFile
  , addUntrackedFile
  , commitAll
  , gitOutput
  ) where

import Prelude

import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Node.Encoding (Encoding(..))
import Node.FS.Aff as FSA
import Node.FS.Perms as Perms
import Node.Path as Path
import Agent.Types (WorkspacePath(..))
import Test.Helpers.Workspace (withWorkspace)

foreign import execSync :: String -> String -> Unit
foreign import execOutputSync :: String -> String -> String

-- | Run a shell command synchronously in a given directory.
runGit :: WorkspacePath -> String -> Aff Unit
runGit (WorkspacePath dir) cmd =
  liftEffect $ pure (execSync cmd dir)

gitOutput :: WorkspacePath -> String -> Aff String
gitOutput (WorkspacePath dir) cmd =
  liftEffect $ pure (execOutputSync cmd dir)

-- | Initialise a temp git repo with an initial empty commit.
withGitRepo :: forall a. (WorkspacePath -> Aff a) -> Aff a
withGitRepo action = withWorkspace \ws -> do
  runGit ws "git init"
  runGit ws "git config user.name 'Test'"
  runGit ws "git config user.email 'test@test.com'"
  runGit ws "git commit --allow-empty -m 'initial'"
  action ws

-- | Create a file, add it, and commit it.
addTrackedFile :: WorkspacePath -> String -> String -> Aff Unit
addTrackedFile ws@(WorkspacePath dir) relPath content = do
  let fullPath = Path.concat [dir, relPath]
      parentDir = Path.dirname fullPath
  FSA.mkdir' parentDir
    { recursive: true, mode: Perms.mkPerms Perms.all Perms.all Perms.all }
  FSA.writeTextFile UTF8 fullPath content
  runGit ws ("git add " <> relPath)
  runGit ws ("git commit -m 'Add " <> relPath <> "'")

-- | Overwrite a tracked file with new content (unstaged).
modifyTrackedFile :: WorkspacePath -> String -> String -> Aff Unit
modifyTrackedFile (WorkspacePath dir) relPath newContent =
  FSA.writeTextFile UTF8 (Path.concat [dir, relPath]) newContent

-- | Stage a specific file.
stageFile :: WorkspacePath -> String -> Aff Unit
stageFile ws relPath = runGit ws ("git add " <> relPath)

-- | Create a file without adding it to git.
addUntrackedFile :: WorkspacePath -> String -> String -> Aff Unit
addUntrackedFile (WorkspacePath dir) relPath content = do
  let fullPath = Path.concat [dir, relPath]
      parentDir = Path.dirname fullPath
  FSA.mkdir' parentDir
    { recursive: true, mode: Perms.mkPerms Perms.all Perms.all Perms.all }
  FSA.writeTextFile UTF8 fullPath content

-- | Stage everything and commit.
commitAll :: WorkspacePath -> String -> Aff Unit
commitAll ws msg = do
  runGit ws "git add -A"
  runGit ws ("git commit -m '" <> msg <> "'")
