#!/usr/bin/env node
const fs = require("fs");

const sdkOnly = process.argv[2] === "--sdk";
const mcpPath = sdkOnly ? null : process.argv[2];
const sdkPath = process.argv[3];

if (!sdkOnly && (!mcpPath || !fs.existsSync(mcpPath))) {
  console.error("MCP bundle not found");
  process.exit(1);
}

function patchTool(source, toolName, pattern, replacement, label) {
  const start = source.indexOf(`name: "${toolName}"`);
  if (start < 0) throw new Error(`MCP tool not found: ${toolName}`);
  const end = source.indexOf("server2.addTool", start + 1);
  const finish = end < 0 ? source.length : end;
  const before = source.slice(start, finish);
  const after = before.replace(pattern, replacement);
  if (after === before && !pattern.test(before)) {
    throw new Error(`MCP patch did not match: ${label}`);
  }
  return source.slice(0, start) + after + source.slice(finish);
}

function patchMcpOutputLimit(source) {
  const marker = "firecrawl-mcp-output-cap-v1";
  const helper = `
// ${marker}
var MCP_MAX_OUTPUT_CHARS = Math.max(
  1000,
  Number(process.env.FIRECRAWL_MCP_MAX_OUTPUT_CHARS) || 400000
);
function truncateMcpOutput(value) {
  const text = String(value ?? "");
  if (text.length <= MCP_MAX_OUTPUT_CHARS) return text;
  const notice = \`\\n\\n[Firecrawl output truncated at \${MCP_MAX_OUTPUT_CHARS} characters; narrow the request or paginate for the complete result.]\\n\\n\`;
  const available = Math.max(0, MCP_MAX_OUTPUT_CHARS - notice.length);
  const headLength = Math.ceil(available * 0.8);
  const tailLength = available - headLength;
  return text.slice(0, headLength) + notice + (tailLength > 0 ? text.slice(-tailLength) : "");
}
`;

  if (!source.includes(marker)) {
    const anchors = ["function asText(data)", "function asText2(data)"];
    const anchor = anchors.find(candidate => source.includes(candidate));
    if (!anchor) throw new Error("MCP output serializer not found");
    source = source.replace(anchor, helper + "\n" + anchor);
  }

  const serializers = [
    [
      /function asText\(data\) \{\s*return JSON\.stringify\(data, null, 2\);\s*\}/g,
      "function asText(data) {\n  return truncateMcpOutput(JSON.stringify(data, null, 2));\n}",
    ],
    [
      /function asText2\(data\) \{\s*return JSON\.stringify\(data, null, 2\);\s*\}/g,
      "function asText2(data) {\n  return truncateMcpOutput(JSON.stringify(data, null, 2));\n}",
    ],
  ];
  let serializerFound = false;
  for (const [pattern, replacement] of serializers) {
    if (pattern.test(source)) serializerFound = true;
    source = source.replace(pattern, replacement);
  }
  if (!serializerFound && !source.includes("truncateMcpOutput(JSON.stringify")) {
    throw new Error("MCP output serializer patch did not match");
  }

  source = source.replace(
    "if (text.length <= MCP_MAX_OUTPUT_CHARS) return truncateMcpOutput(text);",
    "if (text.length <= MCP_MAX_OUTPUT_CHARS) return text;",
  );
  source = source.replace(/return responseText;/g, "return truncateMcpOutput(responseText);");
  source = source.replace(
    /(const text = await response\.text\(\);[\s\S]*?if \(!response\.ok\)[\s\S]*?)return text;/g,
    "$1return truncateMcpOutput(text);",
  );
  return source;
}

if (!sdkOnly) {
  let source = fs.readFileSync(mcpPath, "utf8");
  const z = "(z\\d+)";
  const zVar = source.match(/\b(z\d+)\.object\(/)?.[1] || "z3";
  const limitPattern = new RegExp(`(k: ${z}\\.number\\(\\)\\.int\\(\\)\\.min\\(1\\)\\.max\\()\\d+`);
  const setLimit = (tool, limit, label) => {
    source = patchTool(
      source,
      tool,
      limitPattern,
      (_, prefix) => `${prefix}${limit}`,
      label,
    );
  };
  setLimit("firecrawl_research_search_papers", 10000, "paper result limit");
  source = patchTool(
    source,
    "firecrawl_research_related_papers",
    new RegExp(`(seed_ids: ${z}\\.array\\(${z}\\.string\\(\\)\\)\\.min\\(1\\)\\.max\\()\\d+`),
    (_, prefix) => `${prefix}20`,
    "related seed limit",
  );
  setLimit("firecrawl_research_related_papers", 500, "related result limit");
  setLimit("firecrawl_research_read_paper", 500, "paper passage limit");
  setLimit("firecrawl_research_search_github", 1000, "GitHub result limit");

  source = source
    .replace(/var MAX_AUTHORS = (15|500);/g, "var MAX_AUTHORS = 200;")
    .replace(/var MAX_ABSTRACT_CHARS = (600|200000);/g, "var MAX_ABSTRACT_CHARS = 50000;")
    .replace(/var MAX_AFFIL_CHARS = (60|4000);/g, "var MAX_AFFIL_CHARS = 1000;")
    .replace(/var MAX_AUTHORS_LINE_CHARS = (400|40000);/g, "var MAX_AUTHORS_LINE_CHARS = 20000;")
    .replace(/var MAX_GITHUB_CONTENT_CHARS = (1200|500000);/g, "var MAX_GITHUB_CONTENT_CHARS = 300000;");

  source = source.replace(
    'lines.push((paper.abstract || "(no abstract)").replace(/\\s+/g, " "));',
    'lines.push((paper.abstract || "(no abstract)").replace(/\\s+/g, " ").slice(0, MAX_ABSTRACT_CHARS));',
  );
  source = patchMcpOutputLimit(source);

  const marker = "function registerLocalDeveloperSearch";
  if (!source.includes(marker)) {
  const registration = `
function registerLocalDeveloperSearch(server2) {
  server2.addTool({
    name: "firecrawl_developer_search",
    description: "Search developer documentation and GitHub code, issues, pull requests, and READMEs.",
    parameters: z3.object({
      query: z3.string().min(1),
      k: z3.number().int().min(1).max(1000).optional(),
      passages: z3.number().int().min(1).max(5).optional(),
      types: z3.array(z3.enum(["doc", "docs", "readme", "repo", "repos", "repo_readme", "issue", "issues", "pull_request", "pr", "prs", "pull_requests", "code"])).optional(),
      repos: z3.array(z3.string()).optional(),
      sources: z3.array(z3.string()).optional(),
      language: z3.string().optional(),
      topic: z3.array(z3.string()).optional(),
      license: z3.string().optional(),
      min_stars: z3.number().int().min(0).optional(),
      max_stars: z3.number().int().min(0).optional(),
      archived: z3.boolean().optional(),
      fork: z3.boolean().optional(),
      skills: z3.enum(["only"]).optional()
    }),
    execute: async (args2, { session }) => {
      const base = (process.env.FIRECRAWL_API_URL || "").replace(/\\/+$/, "");
      if (!base) throw new Error("FIRECRAWL_API_URL is required for developer search");
      const credential = session && session.firecrawlApiKey || process.env.FIRECRAWL_API_KEY;
      const headers = { "Content-Type": "application/json", "X-Origin": "mcp-developer-search", ...(credential ? { Authorization: \`Bearer \${credential}\` } : {}) };
      const aliases = { docs: "doc", repo: "readme", repos: "readme", repo_readme: "readme", issues: "issue", pr: "pull_request", prs: "pull_request", pull_requests: "pull_request" };
      const normalized = { ...args2, types: args2.types?.map(type => aliases[type] || type) };
      const response = await fetch(base + "/v2/search/developer", { method: "POST", headers, body: JSON.stringify(normalized) });
      const text = await response.text();
      if (!response.ok) throw new Error(\`Developer search failed (\${response.status}): \${text}\`);
      return truncateMcpOutput(text);
    }
  });
}
`;
  const anchor = "var PORT =";
  if (!source.includes(anchor)) throw new Error("MCP registration anchor not found");
  source = source.replace(anchor, registration.replaceAll("z3.", `${zVar}.`) + "\n" + anchor);
  source = source.replace(
    "registerResearchTools(server, getClient);",
    "registerResearchTools(server, getClient);\nregisterLocalDeveloperSearch(server);",
  );
}

  fs.writeFileSync(mcpPath, source);
}

if (sdkPath && fs.existsSync(sdkPath)) {
  let sdk = fs.readFileSync(sdkPath, "utf8");
  const next = sdk.replace(/timeout: options\.timeoutMs \?\? 3e5/g, "timeout: options.timeoutMs ?? 6e5");
  if (next === sdk && !sdk.includes("timeout: options.timeoutMs ?? 6e5")) {
    throw new Error("JS SDK timeout patch did not match");
  }
  fs.writeFileSync(sdkPath, next);
}

console.log(`Patched ${sdkOnly ? "JS SDK" : "MCP bundle"}: ${sdkOnly ? sdkPath : mcpPath}`);
