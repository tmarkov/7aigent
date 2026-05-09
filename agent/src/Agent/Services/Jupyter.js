import * as zmq from "zeromq";
import * as crypto from "node:crypto";
import * as fs from "node:fs";

function readKernelJson(kernelJsonPath) {
  return JSON.parse(fs.readFileSync(kernelJsonPath, "utf8"));
}

function hmacSha256(key, parts) {
  const h = crypto.createHmac("sha256", key);
  for (const p of parts) h.update(p);
  return h.digest("hex");
}

function buildMsg(key, sessionId, msgType, content, msgId) {
  const header = JSON.stringify({
    msg_id: msgId,
    session: sessionId,
    username: "7aigent",
    date: new Date().toISOString(),
    msg_type: msgType,
    version: "5.3",
  });
  const parentHeader = "{}";
  const metadata = "{}";
  const contentStr = JSON.stringify(content);
  const sig = hmacSha256(key, [header, parentHeader, metadata, contentStr]);
  return [
    Buffer.from("<IDS|MSG>"),
    Buffer.from(sig),
    Buffer.from(header),
    Buffer.from(parentHeader),
    Buffer.from(metadata),
    Buffer.from(contentStr),
  ];
}

function parseMsg(frames) {
  let delimIdx = -1;
  for (let i = 0; i < frames.length; i++) {
    if (frames[i].toString() === "<IDS|MSG>") { delimIdx = i; break; }
  }
  if (delimIdx < 0) return null;
  try {
    const header = JSON.parse(frames[delimIdx + 2].toString());
    const content = JSON.parse(frames[delimIdx + 5].toString());
    const parentHeader = JSON.parse(frames[delimIdx + 3].toString());
    return { header, content, parentHeader };
  } catch (_) { return null; }
}

// connectKernelImpl :: String
//   -> (String -> Effect Unit)  -- onError
//   -> (KernelHandle -> Effect Unit)  -- onSuccess
//   -> Effect Unit
//
// KernelHandle = {
//   execute :: String -> (String -> Effect Unit) -> (String -> Effect Unit) -> Effect Unit,
//   interrupt :: Effect Unit -> Effect Unit,  -- takes onDone
//   close :: Effect Unit
// }
export const connectKernelImpl = (kernelJsonPath) => (onError) => (onSuccess) => () => {
  let config;
  try { config = readKernelJson(kernelJsonPath); }
  catch (e) { onError("Failed to read kernel.json: " + e.message)(); return; }

  const sessionId = crypto.randomUUID();
  const key = config.key;

  // For IPC transport: address is ipc://<ip>-<port> (Jupyter spec separator is hyphen)
  // For TCP transport: address is tcp://<ip>:<port>
  function addr(port) {
    if (config.transport === "tcp") return `tcp://${config.ip}:${port}`;
    return `ipc://${config.ip}-${port}`;
  }

  const shell = new zmq.Dealer();
  const iopub = new zmq.Subscriber();
  const control = new zmq.Dealer();

  // Map from msgId -> { resolve, onToken, output: string[] }
  const pending = new Map();

  async function iopubLoop() {
    for await (const frames of iopub) {
      const parsed = parseMsg(frames.map ? frames : Array.from(frames));
      if (!parsed) continue;
      const parentMsgId = parsed.parentHeader?.msg_id || parsed.header?.parent_header?.msg_id;
      const handler = pending.get(parentMsgId);
      if (!handler) continue;

      switch (parsed.header.msg_type) {
        case "stream":
          handler.onToken(parsed.content.text || "")();
          handler.output.push(parsed.content.text || "");
          break;
        case "execute_result": {
          const text = (parsed.content.data || {})["text/plain"] || "";
          if (text) { handler.onToken(text)(); handler.output.push(text); }
          break;
        }
        case "display_data": {
          const text = (parsed.content.data || {})["text/plain"] || "";
          if (text) handler.output.push(text);
          break;
        }
        case "error": {
          const text = (parsed.content.traceback || []).join("\n");
          handler.onToken(text)();
          handler.output.push(text);
          break;
        }
        case "status":
          if (parsed.content.execution_state === "idle") {
            handler.resolve(handler.output.join(""));
            pending.delete(parentMsgId);
          }
          break;
      }
    }
  }

  Promise.all([
    shell.connect(addr(config.shell_port)),
    iopub.connect(addr(config.iopub_port)),
    control.connect(addr(config.control_port)),
  ]).then(() => {
    iopub.subscribe(Buffer.alloc(0));
    iopubLoop().catch((_) => {/* socket closed on cleanup */});

    const handle = {
      // execute :: String -> (String -> Effect Unit) -> (String -> Effect Unit) -> Effect Unit
      // onToken is called for each partial output; onComplete is called with the full output
      execute: (code) => (onToken) => (onComplete) => () => {
        const msgId = crypto.randomUUID();
        const msg = buildMsg(key, sessionId, "execute_request", {
          code,
          silent: false,
          store_history: true,
          user_expressions: {},
          allow_stdin: false,
          stop_on_error: false,
        }, msgId);

        const p = new Promise((resolve) => {
          pending.set(msgId, { resolve, onToken, output: [] });
        });

        shell.send(msg).then(() => {
          p.then((output) => onComplete(output)());
        }).catch((err) => {
          pending.delete(msgId);
          onComplete("[kernel error: " + err.message + "]")();
        });
      },

      // interrupt :: (Effect Unit) -> Effect Unit  -- takes a no-arg callback
      interrupt: (onDone) => () => {
        const msgId = crypto.randomUUID();
        const msg = buildMsg(key, sessionId, "interrupt_request", {}, msgId);
        control.send(msg).then(() => onDone()).catch(() => onDone());
      },

      // close :: Effect Unit
      close: () => () => {
        try { shell.close(); } catch (_) {}
        try { iopub.close(); } catch (_) {}
        try { control.close(); } catch (_) {}
      },
    };

    onSuccess(handle)();
  }).catch((err) => {
    onError("Failed to connect to kernel: " + err.message)();
  });
};
