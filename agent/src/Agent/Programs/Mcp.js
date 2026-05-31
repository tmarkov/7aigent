// MCP HTTP server FFI.
// Uses the @modelcontextprotocol/sdk streamable-HTTP transport.
//
// startMcpServerImpl :: Int -> Int
//   -> (String -> ({ isError, content } -> Effect Unit) -> Effect Unit)
//   -> Effect Unit
//
// The `onToolCall(message)(done)()` callback runs the agent session.
// JS calls `done(result)()` when the session completes.
// While the session is running, JS sends progress notifications at the
// configured interval (progressIntervalMs, second argument).

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { createMcpExpressApp } from "@modelcontextprotocol/sdk/server/express.js";
import { z } from "zod";

export const startMcpServerImpl = (port) => (progressIntervalMs) => (onToolCall) => () => {
  const app = createMcpExpressApp();

  const makeServer = () => {
    const server = new McpServer({ name: "7aigent", version: "1.0.0" });

    server.registerTool(
      "run",
      {
        description:
          "Run an agent task against the workspace and return the final answer.",
        inputSchema: {
          message: z.string().describe("The task or question for the agent."),
        },
      },
      async ({ message }, extra) => {
        // Send progress notifications at the configured interval.
        let elapsed = 0;
        const intervalSec = Math.max(1, Math.round(progressIntervalMs / 1000));
        const progressToken = extra._meta?.progressToken;
        const timer = setInterval(async () => {
          elapsed += intervalSec;
          try {
            if (progressToken !== undefined) {
              await extra.sendNotification({
                method: "notifications/progress",
                params: {
                  progressToken,
                  progress: elapsed,
                  message: `Agent running (${elapsed}s elapsed)...`,
                },
              });
            }
          } catch (_) {
            // Ignore notification errors — the client may have disconnected.
          }
        }, progressIntervalMs);

        try {
          const result = await new Promise((resolve, reject) => {
            const done = (r) => () => resolve(r);
            try {
              onToolCall(message)(done)();
            } catch (err) {
              reject(err);
            }
          });

          clearInterval(timer);
          return {
            content: [{ type: "text", text: result.content }],
            isError: result.isError,
          };
        } catch (err) {
          clearInterval(timer);
          return {
            content: [{ type: "text", text: String(err) }],
            isError: true,
          };
        }
      }
    );

    return server;
  };

  // Stateless: create a fresh server+transport for each request.
  app.post("/mcp", async (req, res) => {
    const server = makeServer();
    try {
      const transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: undefined,
      });
      await server.connect(transport);
      await transport.handleRequest(req, res, req.body);
      res.on("close", () => {
        transport.close();
        server.close();
      });
    } catch (err) {
      if (!res.headersSent) {
        res.status(500).json({
          jsonrpc: "2.0",
          error: { code: -32603, message: "Internal server error" },
          id: null,
        });
      }
    }
  });

  app.get("/mcp", (_req, res) => {
    res.status(405).json({
      jsonrpc: "2.0",
      error: { code: -32000, message: "Method not allowed." },
      id: null,
    });
  });

  app.delete("/mcp", (_req, res) => {
    res.status(405).json({
      jsonrpc: "2.0",
      error: { code: -32000, message: "Method not allowed." },
      id: null,
    });
  });

  app.listen(port, (err) => {
    if (err) {
      console.error("Failed to start MCP server:", err);
      process.exit(1);
    }
    console.error(`MCP server listening on port ${port}`);
  });
};
