#!/usr/bin/env bash
set -euo pipefail

mapfile -t entries < <(find "$HOME/.npm" -path "*/firecrawl-mcp/dist/index.js" -type f 2>/dev/null | sort)
if [ "${#entries[@]}" -eq 0 ]; then
  echo "No cached firecrawl-mcp installation found; run npx -y firecrawl-mcp first." >&2
  exit 1
fi

for entry in "${entries[@]}"; do
  echo "Testing $entry"
  MCP_ENTRY="$entry" node "$(dirname "$0")/mcp-local-capabilities.mjs"
  MCP_ENTRY="$entry" node "$(dirname "$0")/mcp-search-response.mjs"
done
