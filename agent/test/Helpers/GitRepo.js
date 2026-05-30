import { execSync as nodeExecSync } from "child_process";

export const execSync = (cmd) => (cwd) => {
    nodeExecSync(cmd, { cwd, stdio: "pipe" });
    return {};
};

export const execOutputSync = (cmd) => (cwd) =>
    nodeExecSync(cmd, { cwd, stdio: "pipe", encoding: "utf8" });
