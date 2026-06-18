import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

const STDIN_MAX_BYTES = 4096;
const STDIN_WRITE_DEADLINE_MS = 250;
const STDIN_WRITE_RETRY_MS = 10;

function isWouldBlock(err) {
  return err?.code === "EAGAIN" ||
    err?.code === "EWOULDBLOCK" ||
    err?.code === "ENXIO";
}

function closeFd(fd) {
  try {
    fs.close(fd, () => {});
  } catch (_) {}
}

export function sendInputToFifoPath(fifoPath, value, onError, onSuccess) {
  const buffer = Buffer.from(value, "utf8");
  if (buffer.length > STDIN_MAX_BYTES) {
    onError(`timeout input exceeds ${STDIN_MAX_BYTES} byte limit`);
    return;
  }

  const deadline = Date.now() + STDIN_WRITE_DEADLINE_MS;
  const flags = fs.constants.O_WRONLY | fs.constants.O_NONBLOCK;

  const retry = (fn, onTimeout = null) => {
    if (Date.now() >= deadline) {
      if (onTimeout) onTimeout();
      onError("timeout input sink would block");
      return;
    }
    setTimeout(fn, STDIN_WRITE_RETRY_MS);
  };

  const openAndWrite = () => {
    fs.open(fifoPath, flags, (openErr, fd) => {
      if (openErr) {
        if (isWouldBlock(openErr)) {
          retry(openAndWrite);
        } else {
          onError(String(openErr?.message || openErr));
        }
        return;
      }

      const writeOnce = () => {
        fs.write(fd, buffer, 0, buffer.length, null, (writeErr, written) => {
          if (writeErr) {
            if (isWouldBlock(writeErr)) {
              retry(writeOnce, () => closeFd(fd));
            } else {
              closeFd(fd);
              onError(String(writeErr?.message || writeErr));
            }
            return;
          }

          if (written !== buffer.length) {
            closeFd(fd);
            onError("timeout input write was partial");
            return;
          }

          fs.close(fd, (closeErr) => {
            if (closeErr) {
              onError(String(closeErr?.message || closeErr));
            } else {
              onSuccess();
            }
          });
        });
      };

      writeOnce();
    });
  };

  openAndWrite();
}

// spawnSandboxImpl :: String
//   -> (String -> Effect Unit)   -- onError
//   -> ({ kernelJsonPath :: String, kill :: Effect Unit } -> Effect Unit)  -- onSuccess
//   -> Effect Unit
export const spawnSandboxImpl = (workspacePath) => (onError) => (onSuccess) => () => {
  let resolved = false;
  let outputBuf = "";
  let stderrBuf = "";

  const proc = spawn("7aigent-sandbox", [workspacePath], {
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  });

  const signalSandbox = (signal) => {
    try {
      process.kill(-proc.pid, signal);
      return;
    } catch (_) {}
    try {
      proc.kill(signal);
    } catch (_) {}
  };

  proc.stdout.on("data", (data) => {
    if (resolved) return;
    outputBuf += data.toString();
    const lines = outputBuf.split("\n");
    for (const line of lines) {
        const trimmed = line.trim();
        if (trimmed) {
          resolved = true;
          const kill = (onDone) => () => {
            if (proc.exitCode !== null || proc.signalCode !== null) {
              onDone()();
              return;
            }

            let finished = false;
            const done = () => {
              if (finished) return;
              finished = true;
              clearTimeout(timeout);
              proc.off("exit", handleExit);
              onDone()();
            };
            const handleExit = () => done();
            const timeout = setTimeout(() => {
              signalSandbox("SIGKILL");
              done();
            }, 5000);

            proc.once("exit", handleExit);
            try {
              signalSandbox("SIGTERM");
            } catch (_) {
              done();
            }
          };
          // S18: send SIGUSR1 to the sandbox launcher, which forwards
          // SIGINT to the runner process to interrupt Julia execution.
          const interrupt = () => {
            try {
              proc.kill("SIGUSR1");
            } catch (_) {}
          };
          const stdinPath = path.join(path.dirname(trimmed), "stdin");
          const sendInput = (value) => (onError) => (onSuccess) => () => {
            sendInputToFifoPath(
              stdinPath,
              value,
              (err) => onError(err)(),
              () => onSuccess(),
            );
          };
          onSuccess({ kernelJsonPath: trimmed, kill, interrupt, sendInput })();
          return;
        }
    }
  });

  proc.stderr.on("data", (data) => {
    if (resolved) return;
    stderrBuf += data.toString();
  });

  proc.on("error", (err) => {
    if (!resolved) {
      resolved = true;
      onError("Failed to spawn sandbox: " + err.message)();
    }
  });

  proc.on("exit", (code) => {
    if (!resolved) {
      resolved = true;
      const stderr = stderrBuf.trim();
      const detail = stderr
        ? ": " + stderr.split("\n").slice(-5).join(" | ")
        : "";
      onError("Sandbox exited (code " + code + ") before printing kernel.json path" + detail)();
    }
  });
};
