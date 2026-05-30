import { execFileSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import * as path from "node:path";

const EMPTY_TREE_SHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

const stderrOrMessage = (error) => error.stderr || error.message || "git command failed";

const runGit = (cwd, args, options = {}) =>
  execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    stdio: ["pipe", "pipe", "pipe"],
    ...options,
  });

const safeGit = (cwd, args, options = {}) => {
  try {
    return runGit(cwd, args, options);
  } catch (error) {
    return error.stdout || "";
  }
};

const realIndexPath = (cwd) =>
  path.resolve(cwd, runGit(cwd, ["rev-parse", "--git-path", "index"]).trim());

const copyCurrentIndex = (indexPath, targetPath) => {
  if (existsSync(indexPath)) {
    copyFileSync(indexPath, targetPath);
  } else {
    writeFileSync(targetPath, "");
  }
};

const cleanupTempDir = (dir) => {
  rmSync(dir, { recursive: true, force: true });
};

const stageWholeFiles = (cwd, wholeFiles, env) => {
  for (const file of wholeFiles) {
    const pathspecs = file.oldPath === ""
      ? [file.path]
      : [file.oldPath, file.path];
    runGit(cwd, ["add", "-A", "--", ...pathspecs], { env });
  }
};

const applyCachedPatch = (cwd, patchText, env) => {
  if (patchText.trim() === "") {
    return;
  }

  runGit(cwd, ["apply", "--cached", "--recount", "-"], {
    env,
    input: patchText,
  });
};

const hasHead = (cwd) => {
  try {
    runGit(cwd, ["rev-parse", "--verify", "HEAD"]);
    return true;
  } catch (_error) {
    return false;
  }
};

const headTreeSha = (cwd) =>
  hasHead(cwd)
    ? runGit(cwd, ["rev-parse", "HEAD^{tree}"]).trim()
    : EMPTY_TREE_SHA;

const commitSummary = (cwd, revision) => {
  const summary = safeGit(cwd, ["show", "--stat", "--format=medium", revision]);
  return summary.trim() === "" ? revision : summary;
};

const commitWithMessage = (cwd, args, message, options = {}) =>
  runGit(cwd, args, { ...options, input: message });

const initializeCommitIndex = (cwd, indexPath) => {
  writeFileSync(indexPath, "");
  const env = { ...process.env, GIT_INDEX_FILE: indexPath };
  if (hasHead(cwd)) {
    runGit(cwd, ["read-tree", "HEAD"], { env });
  } else {
    runGit(cwd, ["read-tree", "--empty"], { env });
  }
  return env;
};

const createSelectedCommit = (cwd, message, wholeFiles, partialAllPatch, commitIndexPath) => {
  const env = initializeCommitIndex(cwd, commitIndexPath);
  stageWholeFiles(cwd, wholeFiles, env);
  applyCachedPatch(cwd, partialAllPatch, env);

  const newTree = runGit(cwd, ["write-tree"], { env }).trim();
  if (newTree === headTreeSha(cwd)) {
    throw new Error("No selected changes to commit");
  }

  const args = hasHead(cwd)
    ? ["commit-tree", newTree, "-p", "HEAD"]
    : ["commit-tree", newTree];
  return commitWithMessage(cwd, args, message, { env }).trim();
};

const prepareUpdatedIndex = (cwd, wholeFiles, partialUnstagedPatch, updatedIndexPath) => {
  const indexPath = realIndexPath(cwd);
  copyCurrentIndex(indexPath, updatedIndexPath);
  const env = { ...process.env, GIT_INDEX_FILE: updatedIndexPath };
  stageWholeFiles(cwd, wholeFiles, env);
  applyCachedPatch(cwd, partialUnstagedPatch, env);
};

const finalizeSelectedCommit = (cwd, commitSha, updatedIndexPath) => {
  const indexPath = realIndexPath(cwd);
  const backupDir = mkdtempSync(path.join(tmpdir(), "7aigent-commit-backup-"));
  const backupIndexPath = path.join(backupDir, "index");
  const originalHead = hasHead(cwd) ? runGit(cwd, ["rev-parse", "HEAD"]).trim() : "";

  try {
    copyCurrentIndex(indexPath, backupIndexPath);
    copyFileSync(updatedIndexPath, indexPath);
    runGit(cwd, ["reset", "--soft", commitSha]);
  } catch (error) {
    try {
      copyFileSync(backupIndexPath, indexPath);
    } catch (_restoreError) {
      // best effort
    }

    if (originalHead !== "") {
      try {
        runGit(cwd, ["reset", "--soft", originalHead]);
      } catch (_headRestoreError) {
        // best effort
      }
    }

    throw error;
  } finally {
    cleanupTempDir(backupDir);
  }
};

// execGitCommitAll :: String -> String -> String
export const execGitCommitAll = (cwd) => (message) => () => {
  try {
    runGit(cwd, ["add", "-A"]);
    commitWithMessage(cwd, ["commit", "--file", "-"], message);
    return commitSummary(cwd, "HEAD");
  } catch (error) {
    throw new Error(stderrOrMessage(error));
  }
};

// execGitCommitStaged :: String -> String -> String
export const execGitCommitStaged = (cwd) => (message) => () => {
  try {
    commitWithMessage(cwd, ["commit", "--file", "-"], message);
    return commitSummary(cwd, "HEAD");
  } catch (error) {
    throw new Error(stderrOrMessage(error));
  }
};

// execGitCommitPlan
//   :: String
//   -> String
//   -> Array { path :: String, oldPath :: String }
//   -> String
//   -> String
//   -> String
export const execGitCommitPlan =
  (cwd) => (message) => (wholeFiles) => (partialAllPatch) => (partialUnstagedPatch) => () => {
    const dir = mkdtempSync(path.join(tmpdir(), "7aigent-commit-"));
    const commitIndexPath = path.join(dir, "commit-index");
    const updatedIndexPath = path.join(dir, "updated-index");

    try {
      const commitSha = createSelectedCommit(
        cwd,
        message,
        wholeFiles,
        partialAllPatch,
        commitIndexPath,
      );
      prepareUpdatedIndex(cwd, wholeFiles, partialUnstagedPatch, updatedIndexPath);
      finalizeSelectedCommit(cwd, commitSha, updatedIndexPath);
      return commitSummary(cwd, commitSha);
    } catch (error) {
      throw new Error(stderrOrMessage(error));
    } finally {
      cleanupTempDir(dir);
    }
  };
