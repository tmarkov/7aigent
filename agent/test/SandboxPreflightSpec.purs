module Test.SandboxPreflightSpec where

import Prelude

import Data.String as String
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Node.Path as Path
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

import Agent.Programs.SandboxPreflight
  ( GitMetadataKind(..)
  , SandboxPreflight(..)
  , SandboxPreflightResult(..)
  , inspectSandboxPreflight
  , renderNogitConflictPrompt
  , runSandboxPreflight
  )
import Agent.Types (WorkspacePath(..))
import Test.Helpers.Workspace
  ( withWorkspace
  , writeWorkspaceFile
  , workspaceFileExists
  )

foreign import createSymlink :: String -> String -> Effect Unit

sandboxPreflightSpec :: Spec Unit
sandboxPreflightSpec = do

  describe "A2b + A2c: sandbox preflight trust-state inspection" do

    it "A2b: no nogit sentinel means no conflict even when .git is a directory" do
      withWorkspace \ws -> do
        createGitDirectory ws
        result <- inspectSandboxPreflight ws
        result `shouldEqual` NoSandboxConflict

    it "A2b + A2c: nogit plus a git directory is reported as a git directory" do
      withWorkspace \ws -> do
        writeNogit ws
        createGitDirectory ws
        result <- inspectSandboxPreflight ws
        case result of
          NogitConflict info -> do
            info.kind `shouldEqual` GitDirectory
            String.contains (String.Pattern "git directory")
              (renderNogitConflictPrompt info)
              `shouldEqual` true
          _ -> fail "Expected a nogit conflict for a git directory"

    it "A2c: nogit plus a git symlink is reported as a git symlink" do
      withWorkspace \ws -> do
        writeNogit ws
        createGitSymlink ws
        result <- inspectSandboxPreflight ws
        case result of
          NogitConflict info -> do
            info.kind `shouldEqual` GitSymlink
            String.contains (String.Pattern "git symlink")
              (renderNogitConflictPrompt info)
              `shouldEqual` true
          _ -> fail "Expected a nogit conflict for a git symlink"

    it "A2c: nogit plus a gitfile is reported as a gitfile" do
      withWorkspace \ws -> do
        writeNogit ws
        writeWorkspaceFile ws ".git" "gitdir: /tmp/example.git\n"
        result <- inspectSandboxPreflight ws
        case result of
          NogitConflict info -> do
            info.kind `shouldEqual` GitFile
            String.contains (String.Pattern "gitfile")
              (renderNogitConflictPrompt info)
              `shouldEqual` true
          _ -> fail "Expected a nogit conflict for a gitfile"

    it "A2c: nogit plus a non-git plain file is reported as another git object" do
      withWorkspace \ws -> do
        writeNogit ws
        writeWorkspaceFile ws ".git" "not a gitdir file\n"
        result <- inspectSandboxPreflight ws
        case result of
          NogitConflict info -> do
            info.kind `shouldEqual` OtherGitObject
            String.contains (String.Pattern "other git object")
              (renderNogitConflictPrompt info)
              `shouldEqual` true
          _ -> fail "Expected a nogit conflict for another git object"

  describe "A2d: sandbox preflight conflict resolution" do

    it "A2d: choosing halt keeps nogit and aborts startup" do
      withWorkspace \ws -> do
        writeNogit ws
        createGitDirectory ws
        result <- runSandboxPreflight ws \prompt -> do
          String.contains (String.Pattern "remove .7aigent/state/nogit and proceed")
            prompt `shouldEqual` true
          pure "halt"
        result `shouldEqual` HaltStartup
        nogitExists <- workspaceFileExists ws ".7aigent/state/nogit"
        nogitExists `shouldEqual` true

    it "A2d: choosing proceed removes nogit and continues startup" do
      withWorkspace \ws -> do
        writeNogit ws
        createGitDirectory ws
        result <- runSandboxPreflight ws \prompt -> do
          String.contains (String.Pattern "re-trusts the current .git metadata")
            prompt `shouldEqual` true
          pure "proceed"
        result `shouldEqual` ContinueStartup
        nogitExists <- workspaceFileExists ws ".7aigent/state/nogit"
        nogitExists `shouldEqual` false

writeNogit :: WorkspacePath -> Aff Unit
writeNogit ws =
  writeWorkspaceFile ws ".7aigent/state/nogit" ""

createGitDirectory :: WorkspacePath -> Aff Unit
createGitDirectory ws =
  writeWorkspaceFile ws ".git/HEAD" "ref: refs/heads/main\n"

createGitSymlink :: WorkspacePath -> Aff Unit
createGitSymlink ws@(WorkspacePath root) = do
  writeWorkspaceFile ws ".git-real/HEAD" "ref: refs/heads/main\n"
  liftEffect $ createSymlink ".git-real" (Path.concat [ root, ".git" ])
