#!/usr/bin/env bash
# ======================================================================
# patch-mcp.sh - Patch the installed firecrawl-mcp bundle and SDK.
#
# The bundle is generated code and has changed its zod variable name across
# releases. patch-mcp.js validates each replacement and adds the developer
# search tool when the published MCP package does not expose it yet.
# ======================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v node >/dev/null 2>&1 || {
  echo "Error: node is required to patch firecrawl-mcp."
  exit 1
}

mapfile -t MCP_BUNDLES < <(
  for cache_root in "${HOME:-/home}/.npm" "${HOME:-/home}/.cache" "${HOME:-/home}/.local" /usr/local/lib/node_modules; do
    [ -d "$cache_root" ] && find "$cache_root" -path "*/firecrawl-mcp/dist/index.js" -print 2>/dev/null
  done | sort -u
)

if [ "${#MCP_BUNDLES[@]}" -eq 0 ]; then
  echo "firecrawl-mcp not found in the npm cache."
  echo "Install it first with: npx -y firecrawl-mcp@3.22.2"
  exit 1
fi

for MCP_JS in "${MCP_BUNDLES[@]}"; do
  NODE_MODULES_DIR=$(dirname "$(dirname "$(dirname "$MCP_JS")")")
  SDK_JS="$NODE_MODULES_DIR/@mendable/firecrawl-js/dist/index.js"
  [ -f "$SDK_JS" ] || SDK_JS=""
  node "$SCRIPT_DIR/patch-mcp.js" "$MCP_JS" "$SDK_JS"
  node "$SCRIPT_DIR/scripts/patch-mcp-reliability.mjs" "$MCP_JS"
done
echo "Restart opencode for the patched tool schemas to take effect."
