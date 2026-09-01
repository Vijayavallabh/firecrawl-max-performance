#!/usr/bin/env node

import fs from "node:fs";

const target = process.argv[2];
if (!target) throw new Error("Usage: patch-mcp-reliability.mjs <dist/index.js>");

let source = fs.readFileSync(target, "utf8");
source = source
  .replaceAll("LOCAL_DATABASE_TOOL_NAMES", "LOCAL_UNSUPPORTED_TOOL_NAMES")
  .replaceAll("localDatabaseToolUnavailable", "localToolUnavailable");
source = source.replace(
  /\n\+var LOCAL_UNSUPPORTED_TOOL_NAMES([\s\S]*?)\n\+}\nfunction isHostedKeylessSession/,
  (_match, body) =>
    `\nvar LOCAL_UNSUPPORTED_TOOL_NAMES${body.replaceAll("\n+", "\n")}\n}\nfunction isHostedKeylessSession`,
);
source = source.replace(
  `var LOCAL_UNSUPPORTED_TOOL_NAMES = /* @__PURE__ */ new Set([\n  "firecrawl_feedback",`,
  `var LOCAL_UNSUPPORTED_TOOL_NAMES = /* @__PURE__ */ new Set([\n  "firecrawl_extract",\n  "firecrawl_feedback",`,
);
source = source.replace(
  `function localToolUnavailable(toolName) {\n  if (!process.env.FIRECRAWL_API_URL) return false;\n  if ((process.env.FIRECRAWL_SELF_HOSTED_DB_ENABLED || "").toLowerCase() === "true") return false;`,
  `function localToolUnavailable(toolName) {\n  if (!process.env.FIRECRAWL_API_URL) return false;\n  if (toolName === "firecrawl_extract") return true;\n  if ((process.env.FIRECRAWL_SELF_HOSTED_DB_ENABLED || "").toLowerCase() !== "false") return false;`,
);

// Older patch revisions could leave more than one capability declaration.
// Remove every generated copy before inserting the single canonical block.
source = source.replace(
  /\nvar LOCAL_UNSUPPORTED_TOOL_NAMES = \/\* @__PURE__ \*\/ new Set\(\[[\s\S]*?\n\]\);\nfunction localToolUnavailable\(toolName\) \{[\s\S]*?\n\}/g,
  "",
);

function replaceOnce(oldText, newText, label) {
  if (source.includes(newText)) return;
  const first = source.indexOf(oldText);
  if (first < 0 || source.indexOf(oldText, first + 1) >= 0) {
    throw new Error(`Cannot apply ${label}: expected one matching block`);
  }
  source = source.replace(oldText, newText);
}

replaceOnce(
  `var KEYLESS_TOOL_NAMES = /* @__PURE__ */ new Set([\n  "firecrawl_scrape",\n  "firecrawl_search",\n  "firecrawl_parse"\n]);`,
  `var KEYLESS_TOOL_NAMES = /* @__PURE__ */ new Set([\n  "firecrawl_scrape",\n  "firecrawl_search",\n  "firecrawl_parse"\n]);\nvar LOCAL_UNSUPPORTED_TOOL_NAMES = /* @__PURE__ */ new Set([\n  "firecrawl_extract",\n  "firecrawl_feedback",\n  "firecrawl_search_feedback",\n  "firecrawl_interact",\n  "firecrawl_interact_stop"\n]);\nfunction localToolUnavailable(toolName) {\n  if (!process.env.FIRECRAWL_API_URL) return false;\n  if (toolName === "firecrawl_extract") return true;\n  if ((process.env.FIRECRAWL_SELF_HOSTED_DB_ENABLED || "").toLowerCase() !== "false") return false;\n  return LOCAL_UNSUPPORTED_TOOL_NAMES.has(toolName) || toolName.startsWith("firecrawl_monitor_");\n}`,
  "local database capability declaration",
);

replaceOnce(
  `(session?.credentialError || isHostedKeylessSession(session) ? keylessTool : true) && (canList?.(session) ?? true)`,
  `!localToolUnavailable(tool.name) && (session?.credentialError || isHostedKeylessSession(session) ? keylessTool : true) && (canList?.(session) ?? true)`,
  "local database capability filter",
);

replaceOnce(
  `server.addTool = ((tool) => {\n  if (primaryProfile.toolAllowlist && !primaryProfile.toolAllowlist.has(tool.name)) {`,
  `server.addTool = ((tool) => {\n  if (localToolUnavailable(tool.name)) {\n    return;\n  }\n  if (primaryProfile.toolAllowlist && !primaryProfile.toolAllowlist.has(tool.name)) {`,
  "local database registration filter",
);

fs.writeFileSync(target, source);
console.log("Patched MCP local capability negotiation");
