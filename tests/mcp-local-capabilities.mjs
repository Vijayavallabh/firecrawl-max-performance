#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawn } from "node:child_process";

const mcpEntry = process.env.MCP_ENTRY;
assert(mcpEntry, "Set MCP_ENTRY to firecrawl-mcp/dist/index.js");

async function listTools(databaseEnabled) {
  const env = {
    ...process.env,
    FIRECRAWL_API_URL: "http://127.0.0.1:3002",
  };
  if (databaseEnabled === undefined) {
    delete env.FIRECRAWL_SELF_HOSTED_DB_ENABLED;
  } else {
    env.FIRECRAWL_SELF_HOSTED_DB_ENABLED = String(databaseEnabled);
  }
  const child = spawn(process.execPath, [mcpEntry], {
    env,
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
  ]) child.stdin.write(`${JSON.stringify(message)}\n`);

  const deadline = Date.now() + 5_000;
  while (!output.split("\n").some(line => line.includes('"id":2')) && Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  child.kill("SIGTERM");
  await new Promise(resolve => child.once("exit", resolve));

  const response = output.trim().split("\n").map(line => JSON.parse(line)).find(message => message.id === 2);
  assert(response, `No tools/list response received:\n${output}`);
  return response.result.tools.map(tool => tool.name);
}

const core = [
  "firecrawl_agent", "firecrawl_agent_status", "firecrawl_check_crawl_status",
  "firecrawl_crawl", "firecrawl_developer_search", "firecrawl_map",
  "firecrawl_parse", "firecrawl_research_inspect_paper",
  "firecrawl_research_read_paper", "firecrawl_research_related_papers",
  "firecrawl_research_search_github", "firecrawl_research_search_papers",
  "firecrawl_scrape", "firecrawl_search",
];
const databaseBacked = [
  "firecrawl_feedback", "firecrawl_search_feedback", "firecrawl_interact",
  "firecrawl_interact_stop", "firecrawl_monitor_check",
  "firecrawl_monitor_checks", "firecrawl_monitor_create",
  "firecrawl_monitor_delete", "firecrawl_monitor_get",
  "firecrawl_monitor_list", "firecrawl_monitor_run",
  "firecrawl_monitor_update",
];

const withoutDatabase = await listTools(false);
assert.deepEqual(
  withoutDatabase.filter(name => name.startsWith("firecrawl_")).sort(),
  [...core].sort(),
  "database-disabled MCP surface is inaccurate",
);

const withDatabase = await listTools(true);
for (const required of [...core, ...databaseBacked]) {
  assert(withDatabase.includes(required), `${required} must be advertised when local persistence is enabled`);
}
assert(!withDatabase.includes("firecrawl_extract"), "deprecated extract must stay hidden");

const defaultLocal = await listTools(undefined);
for (const required of [...core, ...databaseBacked]) {
  assert(defaultLocal.includes(required), `${required} must be advertised by this package's persistent local stack`);
}
assert(!defaultLocal.includes("firecrawl_extract"), "deprecated extract must stay hidden by default");

console.log("PASS: MCP capabilities follow local database availability");
