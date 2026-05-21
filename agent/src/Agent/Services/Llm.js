import * as https from "node:https";
import * as http from "node:http";

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
    case "GitDiff":
      return "git_diff";
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
      name: td.name,
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

function streamChatCompletion(endpoint, apiKey, body, onToken, onError, onComplete) {
  let url;
  try {
    url = new URL(endpoint);
  } catch (e) {
    onError(mkError("Invalid API endpoint: " + e.message, null, false));
    return;
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

  const req = proto.request(options, (res) => {
    let settled = false;
    const fail = (error) => {
      if (settled) return;
      settled = true;
      onError(error);
    };
    const succeed = (result) => {
      if (settled) return;
      settled = true;
      onComplete(result);
    };

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
  });

  req.setTimeout(30000, () => {
    req.destroy(new Error("Network timeout"));
  });

  req.on("error", (err) =>
    onError(mkError(err.message, null, looksLikeTimeout(err))));
  req.write(payload);
  req.end();
}

function stripJsonFences(text) {
  const trimmed = text.trim();
  const fenced = trimmed.match(/^```(?:json)?\s*([\s\S]*?)\s*```$/i);
  return fenced ? fenced[1].trim() : trimmed;
}

function extractJsonValue(text) {
  const stripped = stripJsonFences(text);
  try {
    return JSON.parse(stripped);
  } catch (_) {
    const start = stripped.indexOf("{");
    const end = stripped.lastIndexOf("}");
    if (start >= 0 && end > start) {
      return JSON.parse(stripped.slice(start, end + 1));
    }
    throw new Error("Summary response was not valid JSON");
  }
}

function normalizeSummaryPayload(payload, targetIds) {
  const summaries = [];

  if (Array.isArray(payload?.summaries)) {
    for (const entry of payload.summaries) {
      if (typeof entry?.id !== "string" || typeof entry?.summary !== "string") {
        throw new Error("Summary response contained an invalid entry");
      }
      summaries.push({ id: entry.id, summary: entry.summary });
    }
  } else if (payload && typeof payload === "object") {
    for (const id of Object.keys(payload)) {
      if (targetIds.includes(id) && typeof payload[id] === "string") {
        summaries.push({ id, summary: payload[id] });
      }
    }
  } else {
    throw new Error("Summary response had an unsupported shape");
  }

  const byId = new Map(summaries.map((entry) => [entry.id, entry.summary]));
  for (const id of targetIds) {
    if (!byId.has(id)) {
      throw new Error("Summary response omitted requested id '" + id + "'");
    }
  }

  return { summaries: targetIds.map((id) => ({ id, summary: byId.get(id) })) };
}

export function summarizeEvidence(endpoint, apiKey, model, requestJson, onError, onComplete) {
  let request;
  try {
    request = JSON.parse(requestJson);
  } catch (e) {
    onError("Summary request payload was not valid JSON: " + e.message);
    return;
  }

  const targetIds = Array.isArray(request?.target_ids)
    ? request.target_ids.map((id) => String(id))
    : [];

  const messages = [
    {
      role: "system",
      content:
        "You summarize CodeTree rows from structured evidence. Return strict JSON only. " +
        "Each summary must be 1-3 sentences and grounded only in the supplied evidence.",
    },
    {
      role: "user",
      content:
        "Summarize the requested CodeTree rows.\n\n" +
        "Return exactly this JSON shape:\n" +
        "{\"summaries\":[{\"id\":\"<requested id>\",\"summary\":\"<1-3 sentence summary>\"}]}\n\n" +
        "Include every requested id exactly once, preserve the provided target order, " +
        "and do not include markdown fences or any extra prose.\n\n" +
        "Request JSON:\n" + requestJson,
    },
  ];

  const MAX_ATTEMPTS = 3;

  function attempt(attemptsLeft) {
    streamChatCompletion(
      endpoint,
      apiKey,
      {
        model,
        messages,
        stream: true,
        stream_options: { include_usage: true },
        response_format: { type: "json_object" },
      },
      () => {},
      (error) => onError(error.message),
      (result) => {
        try {
          const payload = extractJsonValue(result.content);
          onComplete(normalizeSummaryPayload(payload, targetIds));
        } catch (e) {
          if (attemptsLeft > 1) {
            attempt(attemptsLeft - 1);
          } else {
            onError(e.message);
          }
        }
      },
    );
  }

  attempt(MAX_ATTEMPTS);
}

// ---------------------------------------------------------------------------
// streamLlmImpl :: String  -- endpoint base URL (no trailing slash)
//   -> String              -- api key
//   -> String              -- model
//   -> Array ApiMsg        -- messages (plain JS objects with { tag, value0 })
//   -> Array ToolDef       -- tool definitions
//   -> (String -> Effect Unit)  -- onToken callback
//   -> (String -> LlmResult -> Effect Unit)  -- completion callback (null err = success)
//   -> Effect Unit
// ---------------------------------------------------------------------------

export const streamLlmImpl =
  (endpoint) => (apiKey) => (model) => (messages) => (tools) =>
  (onToken) => (onError) => (onComplete) => () => {

  const apiMessages = messages.map(encodeMessage);
  const apiTools = tools.map(encodeTool);

  streamChatCompletion(
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
