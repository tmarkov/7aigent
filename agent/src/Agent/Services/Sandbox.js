import { spawn } from "node:child_process";

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
  });

  proc.stdout.on("data", (data) => {
    if (resolved) return;
    outputBuf += data.toString();
    const lines = outputBuf.split("\n");
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed) {
        resolved = true;
        const kill = () => () => {
          try { proc.kill("SIGTERM"); } catch (_) {}
        };
        onSuccess({ kernelJsonPath: trimmed, kill })();
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
