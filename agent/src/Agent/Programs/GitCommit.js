import { execFileSync, execSync } from "node:child_process";

// execGitCommitSync :: String -> String -> String
export const execGitCommitSync = (cwd) => (args) => () => {
    try {
        return execSync("git " + args, {
            cwd: cwd,
            encoding: "utf8",
            stdio: ["pipe", "pipe", "pipe"],
        });
    } catch (e) {
        throw new Error(e.stderr || e.message || "git command failed");
    }
};

// execGitCommitSafe :: String -> String -> String
export const execGitCommitSafe = (cwd) => (args) => () => {
    try {
        return execSync("git " + args, {
            cwd: cwd,
            encoding: "utf8",
            stdio: ["pipe", "pipe", "pipe"],
        });
    } catch (e) {
        return e.stdout || "";
    }
};

const runGit = (cwd, args, options = {}) =>
    execFileSync("git", args, {
        cwd,
        encoding: "utf8",
        stdio: ["pipe", "pipe", "pipe"],
        ...options,
    });

const hasStagedChanges = (cwd) => {
    try {
        runGit(cwd, ["diff", "--cached", "--quiet"]);
        return false;
    } catch (_e) {
        return true;
    }
};

const applyCachedPatch = (cwd, patch) => {
    if (patch.trim() === "") {
        return;
    }

    runGit(cwd, ["apply", "--cached", "--recount", "-"], { input: patch });
};

const restorePriorStage = (cwd, restorePatch) => {
    if (restorePatch.trim() === "") {
        return "";
    }

    try {
        applyCachedPatch(cwd, restorePatch);
        return "";
    } catch (e) {
        return e.stderr || e.message || "failed to restore staged changes";
    }
};

// execSelectiveGitCommit :: String -> String -> String -> Array String -> String -> String
export const execSelectiveGitCommit =
    (cwd) => (selectedPatch) => (restorePatch) => (selectedFiles) => (message) => () => {
        try {
            runGit(cwd, ["reset", "--mixed", "HEAD", "--", "."]);
            applyCachedPatch(cwd, selectedPatch);
            if (selectedFiles.length > 0) {
                runGit(cwd, ["add", "--", ...selectedFiles]);
            }

            if (!hasStagedChanges(cwd)) {
                throw new Error("No selected changes to commit");
            }

            runGit(cwd, ["commit", "-m", message]);
            const summary = runGit(cwd, ["log", "-1", "--stat"]);
            const restoreWarning = restorePriorStage(cwd, restorePatch);
            return restoreWarning === ""
                ? summary
                : summary + "\n\nWarning: " + restoreWarning;
        } catch (e) {
            try {
                runGit(cwd, ["reset", "--mixed", "HEAD", "--", "."]);
            } catch (_resetError) {
                // best effort
            }
            const restoreError = restorePriorStage(cwd, restorePatch);
            const baseError = e.stderr || e.message || "git command failed";
            if (restoreError !== "") {
                throw new Error(baseError + "\nrestore failed: " + restoreError);
            }
            throw new Error(baseError);
        }
    };
