import fs from "node:fs";

export const createSymlink = (target) => (path) => () => {
  fs.symlinkSync(target, path);
};

export const removePath = (path) => () => {
  fs.rmSync(path, { recursive: true, force: true });
};
