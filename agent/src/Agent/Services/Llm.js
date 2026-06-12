import * as https from "node:https";
import * as http from "node:http";
import * as fs from "node:fs";

// ---------------------------------------------------------------------------
// Message encoding for the OpenAI Chat Completions API
// ---------------------------------------------------------------------------

// PureScript data constructors compile to `new ConstructorName2(value0)` instances.
// They do NOT set a `.tag` property; identify them by constructor name instead.
function msgTag(msg) {
  return msg?.constructor?.name?.replace(/\d+$/, "") ?? "";
}

function toolNameTag(name) {
  return name?.constructor?.name?.replace(/\d+$/, "") ?? "";
}

function encodeToolName(name) {
  if (typeof name === "string") return name;

  switch (toolNameTag(name)) {
    case "JuliaRepl":
      return "julia_repl";
    case "GitStage":
      return "git_stage";
    case "GitCommit":
      return "git_commit";
    case "UnknownToolName":
      return typeof name.value0 === "string" ? name.value0 : String(name.value0 ?? "");
    default:
      return typeof name?.value0 === "string" ? name.value0 : String(name);
  }
}

function encodeMessage(msg) {
  switch (msgTag(msg)) {
    case "SystemMessage":
      return { role: "system", content: msg.value0.content };
    case "UserMessage":
      return { role: "user", content: msg.value0.content };
    case "AssistantMessage": {
      const r = { role: "assistant", content: msg.value0.content || null };
      const tcs = msg.value0.toolCalls;
      if (tcs && tcs.length > 0) {
        r.tool_calls = tcs.map((tc) => ({
          id: typeof tc.id === "object" ? tc.id.value0 : tc.id,
          type: "function",
          function: { name: encodeToolName(tc.name), arguments: tc.input },
        }));
      }
      return r;
    }
    case "ToolResultMessage":
      return {
        role: "tool",
        tool_call_id: typeof msg.value0.toolCallId === "object"
          ? msg.value0.toolCallId.value0
          : msg.value0.toolCallId,
        content: msg.value0.output,
      };
    default:
      return { role: "user", content: String(msg) };
  }
}

function encodeTool(td) {
  const properties = {};
  const required = [];
  for (const p of td.parameters) {
    properties[p.name] = { type: "string", description: p.description };
    if (p.required) required.push(p.name);
  }
  return {
    type: "function",
    function: {
      name: encodeToolName(td.name),
      description: td.description,
      parameters: {
        type: "object",
        properties,
        required,
      },
    },
  };
}

function mkError(message, statusCode = null, isTimeout = false) {
  return { message, statusCode, isTimeout };
}

function looksLikeTimeout(err) {
  return err?.code === "ETIMEDOUT" ||
    err?.code === "ESOCKETTIMEDOUT" ||
    /timeout|timed out/i.test(err?.message || "");
}

// Hard wall-clock timeout for LLM requests, regardless of socket activity.
// This catches hung streaming responses that keep the socket "active" indefinitely.
// LLM calls can legitimately take several minutes for long outputs, so this is set
// conservatively. The inactivity timeout (req.setTimeout) handles truly dead connections.
const LLM_WALL_CLOCK_TIMEOUT_MS = 300000; // 5 minutes

let requestLogPath = null;

export function setLlmRequestLogPath(path) {
  return () => {
    requestLogPath = path;
  };
}

function writeRequestLogEntry(jsonLine) {
  if (!requestLogPath) return;
  try {
    fs.appendFileSync(requestLogPath, jsonLine + "\n");
  } catch (_) {}
}

export function writeLlmRequestLogEntry(jsonLine) {
  return () => writeRequestLogEntry(jsonLine);
}

function writeRequestLog(entry) {
  writeRequestLogEntry(JSON.stringify(entry));
}

function streamChatCompletion(endpoint, apiKey, body, onToken, onError, onComplete) {
  let url;
  try {
    url = new URL(endpoint);
  } catch (e) {
    onError(mkError("Invalid API endpoint: " + e.message, null, false));
    return () => {};
  }

  const payload = JSON.stringify(body);
  const isHttps = url.protocol === "https:";
  const port = url.port || (isHttps ? 443 : 80);
  const proto = isHttps ? https : http;

  const options = {
    hostname: url.hostname,
    port: Number(port),
    path: url.pathname + (url.search || ""),
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": "Bearer " + apiKey,
      "Content-Length": Buffer.byteLength(payload),
    },
  };

  let settled = false;
  let wallClockTimer;
  const fail = (error) => {
    if (settled) return;
    settled = true;
    clearTimeout(wallClockTimer);
    onError(error);
  };
  const succeed = (result) => {
    if (settled) return;
    settled = true;
    clearTimeout(wallClockTimer);
    onComplete(result);
  };

  const req = proto.request(options, (res) => {
    if (res.statusCode !== 200) {
      let errBody = "";
      res.on("data", (chunk) => errBody += chunk.toString());
      res.on("end", () => {
        fail(mkError("HTTP " + res.statusCode + ": " + errBody, res.statusCode, false));
      });
      return;
    }

    let textContent = "";
    const toolCallsMap = {};
    let inputTokens = 0;
    let cachedInputTokens = 0;
    let outputTokens = 0;
    let buffer = "";

    res.on("data", (chunk) => {
      buffer += chunk.toString();
      const lines = buffer.split("\n");
      buffer = lines.pop();

      for (const line of lines) {
        if (!line.startsWith("data: ")) continue;
        const data = line.slice(6).trim();
        if (data === "[DONE]") continue;
        let parsed;
        try { parsed = JSON.parse(data); } catch (_) { continue; }

        if (parsed.usage) {
          inputTokens = parsed.usage.prompt_tokens || 0;
          cachedInputTokens = parsed.usage.prompt_tokens_details?.cached_tokens || 0;
          outputTokens = parsed.usage.completion_tokens || 0;
        }
        const choice = parsed.choices?.[0];
        if (!choice) continue;
        const delta = choice.delta || {};

        if (delta.content) {
          textContent += delta.content;
          onToken(delta.content);
        }
        if (delta.tool_calls) {
          for (const tc of delta.tool_calls) {
            const idx = tc.index ?? 0;
            if (!toolCallsMap[idx]) toolCallsMap[idx] = { id: "", name: "", arguments: "" };
            if (tc.id) toolCallsMap[idx].id = tc.id;
            if (tc.function?.name) toolCallsMap[idx].name += tc.function.name;
            if (tc.function?.arguments) toolCallsMap[idx].arguments += tc.function.arguments;
          }
        }
      }
    });

    res.on("end", () => {
      const toolCalls = Object.entries(toolCallsMap)
        .sort(([a], [b]) => Number(a) - Number(b))
        .map(([, tc]) => ({ id: tc.id, name: tc.name, input: tc.arguments }));
      succeed({ content: textContent, toolCalls, inputTokens, cachedInputTokens, outputTokens });
    });

    res.on("error", (err) =>
      fail(mkError(err.message, null, looksLikeTimeout(err))));

    // Handles the case where req.destroy() is called after the response has started
    // streaming — Node.js emits 'close' on the response stream, not 'error'.
    res.on("close", () =>
      fail(mkError("Response stream closed before completion", null, false)));
  });

  req.setTimeout(30000, () => {
    req.destroy(new Error("Network timeout"));
  });

  wallClockTimer = setTimeout(() => {
    req.destroy(new Error("LLM request timed out (wall clock)"));
  }, LLM_WALL_CLOCK_TIMEOUT_MS);

  req.on("error", (err) => {
    fail(mkError(err.message, null, looksLikeTimeout(err)));
  });
  writeRequestLog({ timestamp: new Date().toISOString(), endpoint, ...body });
  req.write(payload);
  req.end();

  return () => {
    if (settled) return;
    settled = true;
    clearTimeout(wallClockTimer);
    req.destroy();
  };
}

// ---------------------------------------------------------------------------
// streamLlmImpl :: String  -- endpoint base URL (no trailing slash)
//   -> String              -- api key
//   -> String              -- model
//   -> Array ApiMsg        -- messages (plain JS objects with { tag, value0 })
//   -> Array ToolDef       -- tool definitions
//   -> (String -> Effect Unit)  -- onToken callback
//   -> (String -> LlmResult -> Effect Unit)  -- completion callback (null err = success)
//   -> Effect (Effect Unit)
// ---------------------------------------------------------------------------

export const streamLlmImpl =
  (endpoint) => (apiKey) => (model) => (messages) => (tools) =>
  (onToken) => (onError) => (onComplete) => () => {

  const apiMessages = messages.map(encodeMessage);
  const apiTools = tools.map(encodeTool);

  return streamChatCompletion(
    endpoint,
    apiKey,
    {
      model,
      messages: apiMessages,
      tools: apiTools.length > 0 ? apiTools : undefined,
      stream: true,
      stream_options: { include_usage: true },
    },
    (token) => onToken(token)(),
    (error) => onError(error)(),
    (result) => onComplete(result)(),
  );
};

// callJsonLlmImpl :: String -> String -> String -> Array Message
//   -> (StreamError -> Effect Unit) -> (LlmResult -> Effect Unit)
//   -> Effect (Effect Unit)
//
// Like streamLlmImpl but with no tools and JSON-object response format.
// Tokens are discarded (not streamed to the caller).
export const callJsonLlmImpl =
  (endpoint) => (apiKey) => (model) => (messages) =>
  (onError) => (onComplete) => () => {

  const apiMessages = messages.map(encodeMessage);

  return streamChatCompletion(
    endpoint,
    apiKey,
    {
      model,
      messages: apiMessages,
      stream: true,
      stream_options: { include_usage: true },
      response_format: { type: "json_object" },
    },
    () => {},
    (error) => onError(error)(),
    (result) => onComplete(result)(),
  );
};
