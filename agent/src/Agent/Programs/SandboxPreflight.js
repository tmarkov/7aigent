import fs from "node:fs";
import path from "node:path";

const trimDetail = (text) => text.trim();

const classifyGitObject = (gitPath) => {
  const stat = fs.lstatSync(gitPath);

  if (stat.isSymbolicLink()) {
    return {
      gitExists: true,
      gitKind: "symlink",
      gitDetail: trimDetail(fs.readlinkSync(gitPath)),
    };
  }

  if (stat.isDirectory()) {
    return {
      gitExists: true,
      gitKind: "directory",
      gitDetail: "",
    };
  }

  if (stat.isFile()) {
    const content = fs.readFileSync(gitPath, "utf8");
    const firstLine = content.split(/\r?\n/, 1)[0]?.trim() ?? "";
    if (firstLine.toLowerCase().startsWith("gitdir:")) {
      return {
        gitExists: true,
        gitKind: "gitfile",
        gitDetail: trimDetail(firstLine.slice("gitdir:".length)),
      };
    }

    return {
      gitExists: true,
      gitKind: "other",
      gitDetail: "plain file",
    };
  }

  return {
    gitExists: true,
    gitKind: "other",
    gitDetail: "non-file object",
  };
};

export const inspectSandboxPreflightImpl = (workspacePath) => () => {
  const nogitPath = path.join(workspacePath, ".7aigent", "state", "nogit");
  const gitPath = path.join(workspacePath, ".git");

  const nogitExists = fs.existsSync(nogitPath);
  if (!fs.existsSync(gitPath)) {
    return {
      nogitExists,
      gitExists: false,
      gitKind: "other",
      gitDetail: "",
    };
  }

  return {
    nogitExists,
    ...classifyGitObject(gitPath),
  };
};

export const removeNogitImpl = (nogitPath) => () => {
  fs.rmSync(nogitPath, { force: true });
};
