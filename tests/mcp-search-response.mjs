#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";

const mcpEntry = process.env.MCP_ENTRY;
assert(mcpEntry, "Set MCP_ENTRY to firecrawl-mcp/dist/index.js");

const expected = {
  success: true,
  data: {
    web: [
      {
        title: "BUB1B and mosaic variegated aneuploidy",
        url: "https://example.test/bub1b",
        description: "Deterministic fixture",
      },
    ],
  },
  creditsUsed: 1,
  id: "00000000-0000-7000-8000-000000000001",
};

const api = createServer((request, response) => {
  if (request.method !== "POST" || request.url !== "/v2/search") {
    response.writeHead(404).end();
    return;
  }
  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify(expected));
});

await new Promise((resolve) => api.listen(0, "127.0.0.1", resolve));
const address = api.address();
assert(address && typeof address === "object");

const child = spawn(process.execPath, [mcpEntry], {
  env: {
    ...process.env,
    FIRECRAWL_API_URL: `http://127.0.0.1:${address.port}`,
  },
  stdio: ["pipe", "pipe", "inherit"],
});

let output = "";
child.stdout.setEncoding("utf8");
child.stdout.on("data", (chunk) => {
  output += chunk;
});

child.stdin.write(
  `${JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "mcp-search-regression", version: "1" },
    },
  })}\n`,
);
child.stdin.write(
  `${JSON.stringify({
    jsonrpc: "2.0",
    method: "notifications/initialized",
    params: {},
  })}\n`,
);
child.stdin.write(
  `${JSON.stringify({
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: {
      name: "firecrawl_search",
      arguments: { query: "BUB1B mosaic variegated aneuploidy", limit: 1 },
    },
  })}\n`,
);

const deadline = Date.now() + 5_000;
while (!output.split("\n").some((line) => line.includes('"id":2')) && Date.now() < deadline) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}

child.kill("SIGTERM");
await new Promise((resolve) => child.once("exit", resolve));
api.close();

const responseLine = output
  .trim()
  .split("\n")
  .map((line) => JSON.parse(line))
  .find((message) => message.id === 2);
assert(responseLine, `No tools/call response received:\n${output}`);

const payload = JSON.parse(responseLine.result.content[0].text);
assert.deepEqual(payload, expected);
console.log("PASS: MCP preserves grouped Firecrawl search responses");
