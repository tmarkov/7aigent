import { execFileSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import * as path from "node:path";

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

const indexContents = (indexPath) =>
  existsSync(indexPath) ? readFileSync(indexPath) : Buffer.alloc(0);

const indexMatches = (leftPath, rightPath) =>
  indexContents(leftPath).equals(indexContents(rightPath));

const stagedSummary = (cwd) => {
  const summary = safeGit(cwd, ["diff", "--cached", "--stat", "--summary"]);
  if (summary.trim() !== "") {
    return summary;
  }

  const names = safeGit(cwd, ["diff", "--cached", "--name-only"]);
  return names.trim() === "" ? "Staged selected changes." : names;
};

// execGitStageAll :: String -> String
export const execGitStageAll = (cwd) => () => {
  try {
    runGit(cwd, ["add", "-A"]);
    return stagedSummary(cwd);
  } catch (error) {
    throw new Error(stderrOrMessage(error));
  }
};

// execGitStagePlan :: String -> Array { path :: String, oldPath :: String } -> String -> String
export const execGitStagePlan = (cwd) => (wholeFiles) => (partialUnstagedPatch) => () => {
  const dir = mkdtempSync(path.join(tmpdir(), "7aigent-stage-"));
  const tempIndex = path.join(dir, "index");
  const indexPath = realIndexPath(cwd);
  const env = { ...process.env, GIT_INDEX_FILE: tempIndex };

  try {
    copyCurrentIndex(indexPath, tempIndex);
    stageWholeFiles(cwd, wholeFiles, env);
    applyCachedPatch(cwd, partialUnstagedPatch, env);

    if (indexMatches(tempIndex, indexPath)) {
      throw new Error("No selected changes to stage");
    }

    copyFileSync(tempIndex, indexPath);
    return stagedSummary(cwd);
  } catch (error) {
    throw new Error(stderrOrMessage(error));
  } finally {
    cleanupTempDir(dir);
  }
};
