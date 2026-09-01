#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const mcpEntry = process.env.MCP_ENTRY;
assert(mcpEntry, "Set MCP_ENTRY to firecrawl-mcp/dist/index.js");

const child = spawn(process.execPath, [mcpEntry], {
  env: {
    ...process.env,
    FIRECRAWL_API_URL: process.env.FIRECRAWL_BASE_URL || "http://127.0.0.1:3002",
    FIRECRAWL_SELF_HOSTED_DB_ENABLED: "true",
  },
  stdio: ["pipe", "pipe", "inherit"],
});

let nextId = 1;
let stdoutBuffer = "";
const pending = new Map();
child.stdout.setEncoding("utf8");
child.stdout.on("data", chunk => {
  stdoutBuffer += chunk;
  const lines = stdoutBuffer.split("\n");
  stdoutBuffer = lines.pop() || "";
  for (const line of lines) {
    if (!line.trim()) continue;
    const message = JSON.parse(line);
    const waiter = pending.get(message.id);
    if (waiter) {
      pending.delete(message.id);
      waiter.resolve(message);
    }
  }
});

function rpc(method, params, timeoutMs = 180_000) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`MCP ${method} timed out after ${timeoutMs}ms`));
    }, timeoutMs);
    pending.set(id, {
      resolve: message => {
        clearTimeout(timeout);
        resolve(message);
      },
    });
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
  });
}

function decode(response, tool) {
  assert(!response.error, `${tool}: ${JSON.stringify(response.error)}`);
  assert(!response.result?.isError, `${tool}: ${response.result?.content?.[0]?.text}`);
  const text = response.result?.content?.[0]?.text;
  assert.equal(typeof text, "string", `${tool}: missing text result`);
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

async function call(name, args, timeoutMs) {
  const response = await rpc("tools/call", { name, arguments: args }, timeoutMs);
  const result = decode(response, name);
  console.log(`PASS: ${name}`);
  return result;
}

async function sleep(ms) {
  await new Promise(resolve => setTimeout(resolve, ms));
}

let monitorId;
let interactScrapeId;
try {
  await rpc("initialize", {
    protocolVersion: "2025-06-18",
    capabilities: {},
    clientInfo: { name: "firecrawl-live-tool-regression", version: "1" },
  });
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized", params: {} })}\n`);

  const listed = await rpc("tools/list", {});
  const toolNames = listed.result.tools.map(tool => tool.name).filter(name => name.startsWith("firecrawl_"));
  assert.equal(toolNames.length, 26, `expected 26 operational tools, got ${toolNames.length}`);
  assert(!toolNames.includes("firecrawl_extract"), "deprecated extract must not be advertised");

  const search = await call("firecrawl_search", {
    query: '"mosaic variegated aneuploidy" BUB1B',
    categories: ["research"],
    includeDomains: ["pubmed.ncbi.nlm.nih.gov", "pmc.ncbi.nlm.nih.gov", "nature.com"],
    highlights: true,
    limit: 5,
  });
  assert(search.success && search.id && search.data?.web?.length, "search returned no literature");
  assert(search.data.web.every(x => /(?:^|\.)(?:ncbi\.nlm\.nih\.gov|nature\.com)$/.test(new URL(x.url).hostname)));

  const scrape = await call("firecrawl_scrape", {
    url: "https://medlineplus.gov/genetics/gene/bub1b/",
    formats: ["markdown", "links", "summary"],
    onlyMainContent: true,
  });
  assert(/BUB1B/i.test(scrape.markdown || ""), "scrape content is empty or unrelated");
  assert(scrape.metadata?.scrapeId, "scrape did not return scrapeId");

  const map = await call("firecrawl_map", {
    url: "https://medlineplus.gov/genetics/",
    search: "BUB1B",
    limit: 5,
  });
  assert((map.links || map).length > 0, "map returned no links");

  const crawl = await call("firecrawl_crawl", {
    url: "https://medlineplus.gov/genetics/gene/bub1b/",
    sitemap: "skip",
    limit: 1,
    scrapeOptions: { formats: ["markdown"] },
  }, 240_000);
  assert.equal(crawl.status, "completed", JSON.stringify(crawl));
  assert(crawl.id, "crawl did not return an id");
  const crawlStatus = await call("firecrawl_check_crawl_status", { id: crawl.id });
  assert.equal(crawlStatus.status, "completed", JSON.stringify(crawlStatus));

  const parsed = await call("firecrawl_parse", {
    filePath: fileURLToPath(new URL("./fixtures/mva-public.html", import.meta.url)),
    formats: ["markdown", "links"],
  });
  assert(/BUB1B/.test(parsed.markdown || parsed.data?.markdown || ""), "parse lost fixture content");

  const papers = await call("firecrawl_research_search_papers", {
    query: "BUB1B mosaic variegated aneuploidy chromosome segregation",
    k: 5,
  });
  assert.equal(typeof papers, "string");
  assert(!papers.includes("(no results)"), `paper search returned no results: ${papers}`);
  assert(/BUB1B|TRIP13|aneuploid|chromosome missegregation/i.test(papers), "paper search returned unrelated results");
  const inspect = await call("firecrawl_research_inspect_paper", { paperId: "doi:10.1038/ng1449" });
  assert.equal(typeof inspect, "string");
  assert(!inspect.includes("(paper not found)"), `paper inspect returned no metadata: ${inspect}`);
  assert(/BUB1B|mosaic variegated aneuploidy/i.test(inspect), "paper inspect returned unrelated metadata");
  const read = await call("firecrawl_research_read_paper", {
    paperId: "pmid:35804254",
    question: "What does this paper report about BUB1B variants and mosaic variegated aneuploidy?",
    k: 3,
  });
  assert.equal(typeof read, "string");
  assert(!read.includes("(no full-text passages available"), `paper read returned no passages: ${read}`);
  assert(/BUB1B|variant|aneuploid/i.test(read), "paper passages were unrelated");
  const related = await call("firecrawl_research_related_papers", {
    seed_ids: ["doi:10.1038/ng1449"],
    intent: "BUB1B, spindle checkpoint, and mosaic variegated aneuploidy",
    mode: "similar",
    rerank: true,
    k: 5,
  });
  assert.equal(typeof related, "string");
  assert(!related.includes("(no results)"), `related-paper search returned no results: ${related}`);
  assert(!/ZNF699|DEGCAGS/i.test(related), "related papers leaked zero-relevance noise");
  const github = await call("firecrawl_research_search_github", { query: "BUB1B variant prioritization", k: 5 });
  assert.equal(typeof github, "string");
  assert(!github.includes("(no results)"), `GitHub research returned no results: ${github}`);
  const developer = await call("firecrawl_developer_search", { query: "BUB1B variant prioritization VCF", k: 5 });
  assert.equal(typeof developer, "string");
  assert(!developer.includes("(no results)"), `developer search returned no results: ${developer}`);

  const agent = await call("firecrawl_agent", {
    urls: ["https://medlineplus.gov/genetics/gene/bub1b/"],
    prompt: "Return the public gene symbol and associated syndrome name.",
    schema: {
      type: "object",
      properties: { gene: { type: "string" }, syndrome: { type: "string" } },
      required: ["gene", "syndrome"],
      additionalProperties: false,
    },
  });
  assert(agent.id, "agent did not return an id");
  let agentStatus;
  for (let attempt = 0; attempt < 45; attempt += 1) {
    agentStatus = await call("firecrawl_agent_status", { id: agent.id });
    if (["completed", "failed", "cancelled"].includes(agentStatus.status)) break;
    await sleep(2_000);
  }
  assert.equal(agentStatus.status, "completed", JSON.stringify(agentStatus));
  assert.equal(agentStatus.model, "accounts/fireworks/models/deepseek-v4-flash-0731");
  assert.equal(agentStatus.data?.gene, "BUB1B");
  assert(agentStatus.creditsUsed > 0, "agent credits were not recorded");

  await call("firecrawl_search_feedback", {
    searchId: search.id,
    rating: "good",
    valuableSources: [{ url: search.data.web[0].url, reason: "Directly relevant public MVA literature" }],
  });
  await call("firecrawl_feedback", {
    endpoint: "scrape",
    jobId: scrape.metadata.scrapeId,
    rating: "good",
    url: "https://medlineplus.gov/genetics/gene/bub1b/",
    note: "Substantive public BUB1B content",
  });

  const interact = await call("firecrawl_interact", {
    url: "https://medlineplus.gov/genetics/gene/bub1b/",
    code: "agent-browser get title",
    language: "bash",
    timeout: 30,
  }, 120_000);
  interactScrapeId = interact.scrapeId;
  assert(interact.success && /BUB1B/.test(interact.stdout || interact.result || ""), JSON.stringify(interact));
  await call("firecrawl_interact_stop", { scrapeId: interactScrapeId });
  interactScrapeId = undefined;

  const monitor = await call("firecrawl_monitor_create", {
    page: "https://medlineplus.gov/genetics/gene/bub1b/",
    goal: "Track substantive changes to the public BUB1B gene description",
    name: "MVA public BUB1B MCP regression",
    scheduleText: "every day",
    timezone: "UTC",
  });
  monitorId = monitor.data?.id;
  assert(monitor.success && monitorId, JSON.stringify(monitor));
  const monitorList = await call("firecrawl_monitor_list", { limit: 100 });
  assert(monitorList.data?.some?.(x => x.id === monitorId) || monitorList.data?.monitors?.some?.(x => x.id === monitorId), "created monitor absent from list");
  const monitorGet = await call("firecrawl_monitor_get", { id: monitorId });
  assert.equal(monitorGet.data?.id, monitorId);
  const monitorUpdate = await call("firecrawl_monitor_update", {
    id: monitorId,
    body: { name: "MVA public BUB1B MCP regression updated", retentionDays: 2 },
  });
  assert.equal(monitorUpdate.data?.retentionDays, 2);
  const monitorRun = await call("firecrawl_monitor_run", { id: monitorId });
  const checkId = monitorRun.id || monitorRun.data?.id;
  assert(checkId, JSON.stringify(monitorRun));
  let monitorCheck;
  for (let attempt = 0; attempt < 24; attempt += 1) {
    monitorCheck = await call("firecrawl_monitor_check", { id: monitorId, checkId, limit: 10 });
    if (["completed", "partial", "failed"].includes(monitorCheck.data?.status)) break;
    await sleep(5_000);
  }
  assert(["completed", "partial"].includes(monitorCheck.data?.status), JSON.stringify(monitorCheck));
  assert(monitorCheck.data?.pages?.length > 0, "monitor check returned no pages");
  const checks = await call("firecrawl_monitor_checks", { id: monitorId, limit: 10 });
  assert(checks.data?.some?.(x => x.id === checkId) || checks.data?.checks?.some?.(x => x.id === checkId), "monitor check absent from history");
  const deleted = await call("firecrawl_monitor_delete", { id: monitorId });
  assert(deleted.success, JSON.stringify(deleted));
  monitorId = undefined;

  assert.equal(toolNames.length, 26);
  console.log("PASS: all 26 advertised Firecrawl MCP tools completed competition-related live probes");
} finally {
  if (interactScrapeId) {
    await rpc("tools/call", { name: "firecrawl_interact_stop", arguments: { scrapeId: interactScrapeId } }, 30_000).catch(() => {});
  }
  if (monitorId) {
    await rpc("tools/call", { name: "firecrawl_monitor_delete", arguments: { id: monitorId } }, 30_000).catch(() => {});
  }
  child.kill("SIGTERM");
}
