#!/usr/bin/env bash
# ======================================================================
# patch-mcp.sh — Patches the firecrawl-mcp npm package to remove
# parameter limits (k.max) and increase HTTP timeout.
#
# Run this AFTER installing firecrawl-mcp (e.g. via opencode or npx).
# ======================================================================
set -euo pipefail

echo "Finding firecrawl-mcp installation..."
MCP_JS=$(find "$HOME/.npm" -path "*/firecrawl-mcp/dist/index.js" 2>/dev/null | head -1 || true)

if [ -z "$MCP_JS" ]; then
  echo "firecrawl-mcp not found in ~/.npm."
  echo "Install it first with: npx -y firecrawl-mcp"
  echo "Or restart opencode (it auto-installs MCP servers)."
  exit 1
fi

echo "Found: $MCP_JS"
echo "Patching..."

# search_papers k.max: 500 -> 10000
sed -i 's/k: z2.number().int().min(1).max(500).optional().describe("Number of ranked papers to return (default 40).")/k: z2.number().int().min(1).max(10000).optional().describe("Number of ranked papers to return (default 40).")/' "$MCP_JS"

# related_papers seed_ids.max: 10 -> 20
sed -i 's/seed_ids: z2.array(z2.string()).min(1).max(10)/seed_ids: z2.array(z2.string()).min(1).max(20)/' "$MCP_JS"

# read_paper k.max: 50 -> 500
sed -i 's/k: z2.number().int().min(1).max(50).optional().describe("Number of passages to return (default 4).")/k: z2.number().int().min(1).max(500).optional().describe("Number of passages to return (default 4).")/' "$MCP_JS"

# search_github k.max: 100 -> 1000
sed -i 's/k: z2.number().int().min(1).max(100).optional()/k: z2.number().int().min(1).max(1000).optional()/' "$MCP_JS"

# JS SDK HTTP timeout: 300s -> 600s
SDK_JS=$(dirname "$(dirname "$MCP_JS")")/@mendable/firecrawl-js/dist/index.js 2>/dev/null || true
if [ -f "$SDK_JS" ]; then
  sed -i 's/timeout: options.timeoutMs ?? 3e5/timeout: options.timeoutMs ?? 6e5/' "$SDK_JS"
  echo "Patched JS SDK timeout: $SDK_JS"
fi

echo ""
echo "Done! MCP server patched with:"
echo "  - search_papers k.max: 500 -> 10000"
echo "  - related_papers seed_ids.max: 10 -> 20"
echo "  - read_paper k.max: 50 -> 500"
echo "  - search_github k.max: 100 -> 1000"
echo "  - HTTP timeout: 300s -> 600s"
echo ""
echo "Restart opencode for changes to take effect."
