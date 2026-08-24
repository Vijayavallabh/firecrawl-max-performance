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

MCP_JS=""
for cache_root in "${HOME:-/home}/.npm" "${HOME:-/home}/.cache" "${HOME:-/home}/.local" /usr/local/lib/node_modules; do
  if [ -d "$cache_root" ]; then
    MCP_JS=$(find "$cache_root" -path "*/firecrawl-mcp/dist/index.js" -print -quit 2>/dev/null || true)
  fi
  [ -n "$MCP_JS" ] && break
done

if [ -z "$MCP_JS" ]; then
  echo "firecrawl-mcp not found in the npm cache."
  echo "Install it first with: npx -y firecrawl-mcp@3.22.2"
  exit 1
fi

SDK_JS=""
for cache_root in "${HOME:-/home}/.npm" "${HOME:-/home}/.cache" "${HOME:-/home}/.local" /usr/local/lib/node_modules; do
  if [ -d "$cache_root" ]; then
    SDK_JS=$(find "$cache_root" -path "*/@mendable/firecrawl-js/dist/index.js" -print -quit 2>/dev/null || true)
  fi
  [ -n "$SDK_JS" ] && break
done

node "$SCRIPT_DIR/patch-mcp.js" "$MCP_JS" "$SDK_JS"
echo "Restart opencode for the patched tool schemas to take effect."
