import * as zmq from "zeromq";
import * as crypto from "node:crypto";
import * as fs from "node:fs";
import { summarizeEvidence } from "../Agent.Services.Llm/foreign.js";

const SUMMARY_COMM_TARGET = "7aigent.summary";
const SUMMARY_INPUT_PROMPT_PREFIX = "7aigent.summary.reply:";

function readKernelJson(kernelJsonPath) {
  return JSON.parse(fs.readFileSync(kernelJsonPath, "utf8"));
}

function hmacSha256(key, parts) {
  const h = crypto.createHmac("sha256", key);
  for (const p of parts) h.update(p);
  return h.digest("hex");
}

function buildMsg(key, sessionId, msgType, content, msgId, parentHeader = {}) {
  const header = JSON.stringify({
    msg_id: msgId,
    session: sessionId,
    username: "7aigent",
    date: new Date().toISOString(),
    msg_type: msgType,
    version: "5.3",
  });
  const parentHeaderStr = JSON.stringify(parentHeader);
  const metadata = "{}";
  const contentStr = JSON.stringify(content);
  const sig = hmacSha256(key, [header, parentHeaderStr, metadata, contentStr]);
  return [
    Buffer.from("<IDS|MSG>"),
    Buffer.from(sig),
    Buffer.from(header),
    Buffer.from(parentHeaderStr),
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
//   -> { apiEndpoint :: String, apiKey :: String, model :: String }
//   -> (String -> String -> Effect Unit)  -- onLlmQuery
//   -> (String -> Effect Unit)  -- onError
//   -> (KernelHandle -> Effect Unit)  -- onSuccess
//   -> Effect Unit
//
// KernelHandle = {
//   execute :: String -> (String -> Effect Unit) -> (String -> Effect Unit) -> Effect Unit,
//   interrupt :: Effect Unit -> Effect Unit,  -- takes onDone
//   close :: Effect Unit
// }
export const connectKernelImpl = (kernelJsonPath) => (summaryServiceConfig) => (onLlmQuery) => (onError) => (onSuccess) => () => {
  let config;
  try { config = readKernelJson(kernelJsonPath); }
  catch (e) { onError("Failed to read kernel.json: " + e.message)(); return; }

  const sessionId = crypto.randomUUID();
  const routingId = crypto.randomUUID();
  const key = config.key;

  // For IPC transport: address is ipc://<ip>-<port> (Jupyter spec separator is hyphen)
  // For TCP transport: address is tcp://<ip>:<port>
  function addr(port) {
    if (config.transport === "tcp") return `tcp://${config.ip}:${port}`;
    return `ipc://${config.ip}-${port}`;
  }

  const shell = new zmq.Dealer({ routingId });
  const iopub = new zmq.Subscriber();
  const stdin = new zmq.Dealer({ routingId });
  const control = new zmq.Dealer();

  // Map from msgId -> { resolve, onToken, output: string[], hadError: boolean }
  const pending = new Map();
  const pendingSummaryReplies = new Map();

  function sendShellMessage(msgType, content) {
    const msgId = crypto.randomUUID();
    return shell.send(buildMsg(key, sessionId, msgType, content, msgId));
  }

  function sendStdinReply(content, parentHeader) {
    const msgId = crypto.randomUUID();
    return stdin.send(buildMsg(key, sessionId, "input_reply", content, msgId, parentHeader));
  }

  function handleSummaryComm(parsed) {
    if (parsed.header?.msg_type !== "comm_open") return false;
    const content = parsed.content || {};
    if (content.target_name !== SUMMARY_COMM_TARGET) return false;

    const commId = content.comm_id;
    if (!commId) return true;

    let requestJson = "";
    try {
      requestJson = JSON.stringify(content.data || {});
    } catch (err) {
      _resolvePendingSummary(commId, Promise.resolve({ error: "Summary request payload was not serializable: " + err.message }));
      return true;
    }

    onLlmQuery("summary")(requestJson)();

    if (!summaryServiceConfig?.apiEndpoint || !summaryServiceConfig?.apiKey || !summaryServiceConfig?.model) {
      _resolvePendingSummary(commId, Promise.resolve({ error: "Summary service is not configured." }));
      return true;
    }

    _resolvePendingSummary(
      commId,
      new Promise((resolve) => {
        summarizeEvidence(
          summaryServiceConfig.apiEndpoint,
          summaryServiceConfig.apiKey,
          summaryServiceConfig.model,
          requestJson,
          (errorMessage) => resolve({ error: String(errorMessage) }),
          (responseData) => resolve({ data: responseData }),
        );
      }),
    );
    return true;
  }

  // Resolve the deferred entry for commId with a settled promise.
  // If handleInputRequest registered a deferred resolver first (race: stdin
  // before iopub), call it.  Otherwise write the settled promise directly so
  // handleInputRequest can pick it up with a simple Map lookup.
  function _resolvePendingSummary(commId, settledPromise) {
    const existing = pendingSummaryReplies.get(commId);
    if (existing?._deferred) {
      existing._deferred(settledPromise);
    } else {
      pendingSummaryReplies.set(commId, settledPromise);
    }
  }

  function encodeSummaryReplyValue(result) {
    if (result?.error != null) {
      return "error\t" + Buffer.from(String(result.error), "utf8").toString("base64");
    }

    const lines = ["ok"];
    for (const entry of result?.data?.summaries || []) {
      const encodedSummary = Buffer.from(String(entry.summary), "utf8").toString("base64");
      lines.push(String(entry.id) + "\t" + encodedSummary);
    }
    return lines.join("\n");
  }

  // Return a Promise that resolves to the pending summary reply for commId.
  // If comm_open has already been processed, the map holds a settled Promise
  // and we return it directly.  If comm_open has not yet arrived (stdin raced
  // ahead of iopub), we register a deferred placeholder so _resolvePendingSummary
  // can call our resolver when it does arrive.
  function _awaitPendingSummary(commId) {
    const existing = pendingSummaryReplies.get(commId);
    if (existing && !existing._deferred) return existing;

    // Not yet present (or only a deferred shell): create a deferred promise.
    return new Promise((resolveOuter) => {
      const placeholder = { _deferred: (settledPromise) => resolveOuter(settledPromise) };
      pendingSummaryReplies.set(commId, placeholder);
    });
  }

  async function handleInputRequest(parsed) {
    if (parsed.header?.msg_type !== "input_request") return false;

    const prompt = String(parsed.content?.prompt || "");
    let value = "7aigent does not support arbitrary interactive stdin.";

    if (prompt.startsWith(SUMMARY_INPUT_PROMPT_PREFIX)) {
      const commId = prompt.slice(SUMMARY_INPUT_PROMPT_PREFIX.length);
      // Must exceed LLM_WALL_CLOCK_TIMEOUT_MS × MAX_ATTEMPTS so the LLM has a full
      // chance to respond (or exhaust retries) before we give up on the Julia side.
      const timeoutMs = 330000; // 5.5 minutes — just above the 5-minute LLM wall-clock
      let timeoutHandle;
      const timeoutPromise = new Promise((_, reject) => {
        timeoutHandle = setTimeout(() => reject(new Error("Summary LLM call timed out after 330s")), timeoutMs);
      });
      try {
        const pendingReply = await Promise.race([_awaitPendingSummary(commId), timeoutPromise]);
        value = encodeSummaryReplyValue(await Promise.race([pendingReply, timeoutPromise]));
      } catch (err) {
        value = encodeSummaryReplyValue({ error: String(err.message || err) });
      } finally {
        clearTimeout(timeoutHandle);
        pendingSummaryReplies.delete(commId);
      }
    }

    await sendStdinReply({ value }, parsed.header);
    return true;
  }

  async function iopubLoop() {
    for await (const frames of iopub) {
      const parsed = parseMsg(frames.map ? frames : Array.from(frames));
      if (!parsed) continue;
      if (handleSummaryComm(parsed)) continue;
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
          const rawText = (parsed.content.traceback || []).join("\n");
          // Strip ANSI escape codes for the stored output (sent to the LLM);
          // keep them for the terminal display via onToken.
          const plainText = rawText.replace(/\x1b\[[0-9;]*[mGKJH]/g, "");
          handler.hadError = true;
          handler.onToken(rawText)();
          handler.output.push(plainText);
          break;
        }
        case "status":
          if (parsed.content.execution_state === "idle") {
            handler.resolve({
              output: handler.output.join(""),
              hadError: handler.hadError,
            });
            pending.delete(parentMsgId);
          }
          break;
      }
    }
  }

  async function stdinLoop() {
    for await (const frames of stdin) {
      const parsed = parseMsg(frames.map ? frames : Array.from(frames));
      if (!parsed) continue;
      try {
        await handleInputRequest(parsed);
      } catch (_) {
        // Ignore failed stdin replies; the Julia side timeout will surface the error.
      }
    }
  }

  Promise.all([
    shell.connect(addr(config.shell_port)),
    iopub.connect(addr(config.iopub_port)),
    stdin.connect(addr(config.stdin_port)),
    control.connect(addr(config.control_port)),
  ]).then(() => {
    iopub.subscribe(Buffer.alloc(0));
    iopubLoop().catch((_) => {/* socket closed on cleanup */});
    stdinLoop().catch((_) => {/* socket closed on cleanup */});

    const handle = {
      // execute :: String -> (String -> Effect Unit) -> (ExecutionResult -> Effect Unit) -> Effect Unit
      // onToken is called for each partial output; onComplete is called with the full execution result
      execute: (code) => (onToken) => (onComplete) => () => {
        const msgId = crypto.randomUUID();
        const msg = buildMsg(key, sessionId, "execute_request", {
          code,
          silent: false,
          store_history: true,
          user_expressions: {},
          allow_stdin: /\bsummarize!\s*\(/.test(code),
          stop_on_error: false,
        }, msgId);

        const p = new Promise((resolve) => {
          pending.set(msgId, { resolve, onToken, output: [], hadError: false });
        });

        shell.send(msg).then(() => {
          p.then((result) => onComplete(result)());
        }).catch((err) => {
          pending.delete(msgId);
          onComplete({
            output: "[kernel error: " + err.message + "]",
            hadError: true,
          })();
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
        try { stdin.close(); } catch (_) {}
        try { control.close(); } catch (_) {}
      },
    };

    onSuccess(handle)();
  }).catch((err) => {
    onError("Failed to connect to kernel: " + err.message)();
  });
};
