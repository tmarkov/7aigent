import { execSync } from "node:child_process";

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
