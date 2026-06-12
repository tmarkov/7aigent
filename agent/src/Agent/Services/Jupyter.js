import * as zmq from "zeromq";
import * as crypto from "node:crypto";
import * as fs from "node:fs";

const SUMMARY_COMM_TARGET = "7aigent.summary";
const SUMMARY_INPUT_PROMPT_PREFIX = "7aigent.summary.reply:";
export const summaryCorrelationTimeoutMilliseconds = 10000;

function summaryCommIdFromPrompt(prompt) {
  const text = String(prompt || "");
  return text.startsWith(SUMMARY_INPUT_PROMPT_PREFIX)
    ? text.slice(SUMMARY_INPUT_PROMPT_PREFIX.length)
    : "";
}

function summaryRequestFromContent(content) {
  if (content?.target_name !== SUMMARY_COMM_TARGET || !content?.comm_id) {
    return null;
  }
  return {
    commId: String(content.comm_id),
    requestJson: JSON.stringify(content.data || {}),
  };
}

export const classifySummaryInputPrompt = summaryCommIdFromPrompt;

export const decodeSummaryCommContent = (contentJson) => {
  try {
    return summaryRequestFromContent(JSON.parse(contentJson))?.requestJson || "";
  } catch (_) {
    return "";
  }
};

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

function buildExecuteRequestContent(code) {
  return {
    code,
    silent: false,
    store_history: true,
    user_expressions: {},
    allow_stdin: true,
    stop_on_error: false,
  };
}

export const executeRequestAllowsStdin = (code) =>
  buildExecuteRequestContent(code).allow_stdin;

// connectKernelImpl :: String
//   -> (String -> Effect Unit)  -- onError
//   -> (KernelHandle -> Effect Unit)  -- onSuccess
//   -> Effect Unit
//
// KernelHandle = {
//   execute :: String -> (String -> Effect Unit) -> (String -> Effect Unit) -> Effect Unit,
//   interrupt :: (String -> Effect Unit) -> Effect Unit -> Effect Unit,
//   close :: Effect Unit
// }
export const connectKernelImpl = (kernelJsonPath) => (onError) => (onSuccess) => () => {
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
  const expiredSummaryRequests = new Set();

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
    let request;
    try {
      request = summaryRequestFromContent(parsed.content || {});
    } catch (err) {
      return true;
    }
    if (!request) return false;

    _resolvePendingSummary(request.commId, Promise.resolve(request.requestJson));
    return true;
  }

  // Resolve the deferred entry for commId with a settled promise.
  // If handleInputRequest registered a deferred resolver first (race: stdin
  // before iopub), call it.  Otherwise write the settled promise directly so
  // handleInputRequest can pick it up with a simple Map lookup.
  function _resolvePendingSummary(commId, settledPromise) {
    if (expiredSummaryRequests.delete(commId)) return;
    const existing = pendingSummaryReplies.get(commId);
    if (existing?._deferred) {
      existing._deferred(settledPromise);
    } else {
      pendingSummaryReplies.set(commId, settledPromise);
    }
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
    const isSummaryPrompt = prompt.startsWith(SUMMARY_INPUT_PROMPT_PREFIX);
    const commId = summaryCommIdFromPrompt(prompt);
    if (isSummaryPrompt) {
      if (!commId) {
        await sendStdinReply(
          { value: "error\t" + Buffer.from(
            "Summary input request omitted its correlation id.",
            "utf8",
          ).toString("base64") },
          parsed.header,
        );
        return true;
      }
      const parentMsgId =
        parsed.parentHeader?.msg_id || parsed.header?.parent_header?.msg_id;
      const handler = pending.get(parentMsgId);
      if (!handler) {
        await sendStdinReply(
          { value: "error\t" + Buffer.from(
            "7aigent has no pending execution for this summary request.",
            "utf8",
          ).toString("base64") },
          parsed.header,
        );
        return true;
      }
      const loadSummaryRequest = (onError) => (onSuccess) => () => {
        let settled = false;
        const timeoutHandle = setTimeout(() => {
          if (settled) return;
          settled = true;
          pendingSummaryReplies.delete(commId);
          expiredSummaryRequests.add(commId);
          onError(
            `Summary request '${commId}' did not receive a matching comm_open ` +
            `within ${summaryCorrelationTimeoutMilliseconds} ms`,
          )();
        }, summaryCorrelationTimeoutMilliseconds);
        _awaitPendingSummary(commId).then((requestJson) => {
          if (settled) return;
          settled = true;
          clearTimeout(timeoutHandle);
          onSuccess(requestJson)();
        }).catch((err) => {
          if (settled) return;
          settled = true;
          clearTimeout(timeoutHandle);
          onError(String(err?.message || err))();
        }).finally(() => {
          pendingSummaryReplies.delete(commId);
        });
        return () => {
          if (settled) return;
          settled = true;
          clearTimeout(timeoutHandle);
          pendingSummaryReplies.delete(commId);
        };
      };
      await deliverInputRequest(handler, parsed, prompt, loadSummaryRequest);
      return true;
    }

    const parentMsgId =
      parsed.parentHeader?.msg_id || parsed.header?.parent_header?.msg_id;
    const handler = pending.get(parentMsgId);
    if (!handler) {
      await sendStdinReply(
        { value: "7aigent has no pending execution for this input request." },
        parsed.header,
      );
      return true;
    }

    await deliverInputRequest(handler, parsed, prompt, null);
    return true;
  }

  async function deliverInputRequest(
    handler,
    parsed,
    prompt,
    summaryRequest,
  ) {
    await new Promise((resolve) => {
      let settled = false;
      const finish = () => {
        if (settled) return false;
        settled = true;
        resolve();
        return true;
      };
      const reply = (value) => (annotation) => (onError) => (onSuccess) => () => {
        if (settled) return;
        sendStdinReply({ value }, parsed.header).then(() => {
          if (annotation) {
            handler.onToken(annotation)();
            handler.output.push(annotation);
          }
          onSuccess();
          finish();
        }).catch((err) => {
          onError(String(err?.message || err))();
          finish();
        });
      };
      handler.onInput({
        prompt,
        summaryRequest,
        reply,
        cancel: () => () => {
          finish();
        },
      })();
    });
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
          if (text) {
            handler.onToken(text)();
            handler.output.push(text);
          }
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
        // A failed stdin socket cannot service this request; keep the receive
        // loop alive so a recoverable handler failure does not block later input.
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
      // execute :: String -> onToken -> onInput -> onComplete -> Effect Unit
      // onToken is called for each partial output; onComplete is called with the full execution result
      execute: (code) => (onToken) => (onInput) => (onComplete) => () => {
        const msgId = crypto.randomUUID();
        const msg = buildMsg(
          key,
          sessionId,
          "execute_request",
          buildExecuteRequestContent(code),
          msgId,
        );

        const p = new Promise((resolve) => {
          pending.set(msgId, {
            resolve,
            completion: null,
            onToken,
            onInput,
            output: [],
            hadError: false,
          });
        });
        pending.get(msgId).completion = p;
        p.then((result) => onComplete(result)());

        shell.send(msg).catch((err) => {
          const handler = pending.get(msgId);
          if (!handler) return;
          pending.delete(msgId);
          handler.resolve({
            output: "[kernel error: " + err.message + "]",
            hadError: true,
          });
        });
      },

      // Interrupt completion means that every execution active when the request
      // was made has subsequently reported idle on IOPub.
      interrupt: (onError) => (onDone) => () => {
        const activeExecutions =
          Array.from(pending.values(), (handler) => handler.completion);
        const msgId = crypto.randomUUID();
        const msg = buildMsg(key, sessionId, "interrupt_request", {}, msgId);
        control.send(msg)
          .then(() => Promise.all(activeExecutions))
          .then(() => onDone())
          .catch((err) => onError(String(err?.message || err))());
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
