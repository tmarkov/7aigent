import { execSync } from "node:child_process";

// execGitSync :: String -> String -> String
// Runs a git command in the given directory and returns stdout.
// On error, returns empty string.
export const execGitSync = (cwd) => (args) => () => {
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
