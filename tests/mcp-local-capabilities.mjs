#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawn } from "node:child_process";

const mcpEntry = process.env.MCP_ENTRY;
assert(mcpEntry, "Set MCP_ENTRY to firecrawl-mcp/dist/index.js");

const child = spawn(process.execPath, [mcpEntry], {
  env: { ...process.env, FIRECRAWL_API_URL: "http://127.0.0.1:3002" },
  stdio: ["pipe", "pipe", "inherit"],
});
let output = "";
child.stdout.setEncoding("utf8");
child.stdout.on("data", chunk => (output += chunk));

for (const message of [
  {
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "mcp-capability-regression", version: "1" },
    },
  },
  { jsonrpc: "2.0", method: "notifications/initialized", params: {} },
  { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} },
]) {
  child.stdin.write(`${JSON.stringify(message)}\n`);
}

const deadline = Date.now() + 5_000;
while (!output.split("\n").some(line => line.includes('"id":2')) && Date.now() < deadline) {
  await new Promise(resolve => setTimeout(resolve, 10));
}
child.kill("SIGTERM");
await new Promise(resolve => child.once("exit", resolve));

const response = output
  .trim()
  .split("\n")
  .map(line => JSON.parse(line))
  .find(message => message.id === 2);
assert(response, `No tools/list response received:\n${output}`);

const names = response.result.tools.map(tool => tool.name);
const unsupported = names.filter(
  name =>
    name.startsWith("firecrawl_monitor_") ||
    [
      "firecrawl_feedback",
      "firecrawl_extract",
      "firecrawl_search_feedback",
      "firecrawl_interact",
      "firecrawl_interact_stop",
    ].includes(name),
);
assert.deepEqual(unsupported, []);
const supported = [
  "firecrawl_agent",
  "firecrawl_agent_status",
  "firecrawl_check_crawl_status",
  "firecrawl_crawl",
  "firecrawl_developer_search",
  "firecrawl_map",
  "firecrawl_parse",
  "firecrawl_research_inspect_paper",
  "firecrawl_research_read_paper",
  "firecrawl_research_related_papers",
  "firecrawl_research_search_github",
  "firecrawl_research_search_papers",
  "firecrawl_scrape",
  "firecrawl_search",
];
for (const required of supported) {
  assert(names.includes(required), `${required} should remain available`);
}
assert.deepEqual(names.filter(name => name.startsWith("firecrawl_")).sort(), supported.sort());
console.log("PASS: local MCP advertises only supported capabilities");
