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
        // ToolCallId is a newtype erased to a plain string at runtime.
        r.tool_calls = tcs.map((tc) => ({
          id: typeof tc.id === "object" ? tc.id.value0 : tc.id,
          type: "function",
          function: { name: tc.name, arguments: tc.input },
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

  const body = JSON.stringify({
    model,
    messages: apiMessages,
    tools: apiTools.length > 0 ? apiTools : undefined,
    stream: true,
    stream_options: { include_usage: true },
  });

  let url;
  try {
    url = new URL(endpoint);
  } catch (e) {
    onError("Invalid API endpoint: " + e.message)();
    return;
  }

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
      "Content-Length": Buffer.byteLength(body),
    },
  };

  const req = proto.request(options, (res) => {
    if (res.statusCode !== 200) {
      let errBody = "";
      res.on("data", (c) => errBody += c.toString());
      res.on("end", () => {
        onError("HTTP " + res.statusCode + ": " + errBody)();
      });
      return;
    }

    let textContent = "";
    const toolCallsMap = {}; // index -> { id, name, arguments }
    let inputTokens = 0;
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
        }
        const choice = parsed.choices?.[0];
        if (!choice) continue;
        const delta = choice.delta || {};

        if (delta.content) {
          textContent += delta.content;
          onToken(delta.content)();
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
      onComplete({ content: textContent, toolCalls, inputTokens })();
    });

    res.on("error", (err) => onError(err.message)());
  });

  req.on("error", (err) => onError(err.message)());
  req.write(body);
  req.end();
};
