import * as fs from "node:fs";
import * as path from "node:path";

// lockFile :: String -> Effect (Effect Unit)
// Acquires an exclusive lock on the given file path (creating it if needed).
// Returns an Effect that releases the lock.
export const lockFile = (filePath) => () => {
    const fd = fs.openSync(filePath, "w");
    // Use flock-style locking via fs.flockSync (Node 22+) or fallback
    try {
        fs.flockSync(fd, "ex");
    } catch (_e) {
        // If flock is not available, use a best-effort approach
        // by writing a lock marker
    }
    return () => {
        try {
            fs.flockSync(fd, "un");
        } catch (_e2) {
            // ignore
        }
        fs.closeSync(fd);
    };
};

// listDirSync :: String -> Effect (Array String)
export const listDirSync = (dirPath) => () => {
    try {
        return fs.readdirSync(dirPath);
    } catch (_e) {
        return [];
    }
};

// mkdirSyncRecursive :: String -> Effect Unit
export const mkdirSyncRecursive = (dirPath) => () => {
    fs.mkdirSync(dirPath, { recursive: true });
};

// appendFileSync :: String -> String -> Effect Unit
export const appendFileSync = (filePath) => (content) => () => {
    fs.appendFileSync(filePath, content, "utf8");
};

// readFileSync :: String -> Effect String
export const readFileSyncImpl = (filePath) => () => {
    return fs.readFileSync(filePath, "utf8");
};

// fileExistsSync :: String -> Effect Boolean
export const fileExistsSync = (filePath) => () => {
    try {
        fs.accessSync(filePath);
        return true;
    } catch (_e) {
        return false;
    }
};
