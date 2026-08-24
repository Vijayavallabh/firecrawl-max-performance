#!/usr/bin/env bash
# ======================================================================
# setup.sh — One-command setup for self-hosted Firecrawl with max
# performance, research service, and SearXNG search backend.
#
# Prerequisites:
#   - Docker + Docker Compose
#   - git
#   - curl
#
# Usage:
#   ./setup.sh
# ======================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Firecrawl Self-Host Setup (Max Performance + Research)     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Check prerequisites ──────────────────────────────────────────────
echo "Checking prerequisites..."
command -v docker >/dev/null 2>&1 || { echo "Error: docker not found. Install Docker first."; exit 1; }
command -v git >/dev/null 2>&1 || { echo "Error: git not found."; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "Error: docker compose not found."; exit 1; }
echo "  All prerequisites present."
echo ""

# ── Clone Firecrawl ──────────────────────────────────────────────────
if [ -d "firecrawl" ]; then
  echo "Firecrawl directory already exists. Using existing clone."
  echo "  (To re-clone, delete the firecrawl/ directory and re-run.)"
else
  echo "Cloning Firecrawl repository..."
  git clone https://github.com/firecrawl/firecrawl.git firecrawl
  echo "  Cloned."
fi
echo ""

# ── Apply patches ────────────────────────────────────────────────────
echo "Applying performance patches to Firecrawl source..."
bash "$SCRIPT_DIR/patch-firecrawl.sh" "$SCRIPT_DIR/firecrawl"
echo ""

# ── Create .env ──────────────────────────────────────────────────────
if [ -f ".env" ]; then
  echo ".env already exists. Skipping creation."
  echo "  (To recreate, delete .env and re-run.)"
else
  echo "Creating .env from template..."
  cp .env.example .env
  echo "  Created .env — EDIT IT to fill in your API keys!"
  echo ""
  echo "  Required values to set in .env:"
  echo "    OPENAI_API_KEY     — Your Fireworks AI or OpenAI API key"
  echo "    SEARXNG_SECRET     — A random string for SearXNG"
  echo "    POSTGRES_PASSWORD  — A random password for PostgreSQL"
  echo ""
  echo "  Optional but recommended:"
  echo "    GITHUB_TOKEN       — GitHub token for higher API rate limits"
  echo "    MAILTO             — Your email for OpenAlex polite-pool"
fi
echo ""

# Hybrid local-Postgres persistence is enabled whenever DATABASE_URL is set.
# Derive it from the same credentials used by nuq-postgres unless the user
# already supplied a custom URL.
if ! grep -q '^DATABASE_URL=' .env; then
  DB_USER=$(grep '^POSTGRES_USER=' .env | cut -d= -f2-)
  DB_PASSWORD=$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)
  DB_NAME=$(grep '^POSTGRES_DB=' .env | cut -d= -f2-)
  DB_USER_URL=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$DB_USER")
  DB_PASSWORD_URL=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$DB_PASSWORD")
  DB_NAME_URL=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$DB_NAME")
  printf '\nDATABASE_URL=postgres://%s:%s@nuq-postgres:5432/%s\n' \
    "$DB_USER_URL" "$DB_PASSWORD_URL" "$DB_NAME_URL" >> .env
  echo "Configured DATABASE_URL for local Postgres persistence."
fi

# ── Build and start ──────────────────────────────────────────────────
echo "Ready to build and start?"
echo "  1. Edit .env with your API keys"
echo "  2. Run: docker compose build"
echo "  3. Run: docker compose up -d"
echo "  4. Run: ./patch-mcp.sh  (after configuring opencode MCP)"
echo ""
echo "  Or run this script with --start to build and start automatically"
echo "  after you've edited .env:"
echo "    ./setup.sh --start"

if [ "${1:-}" = "--start" ]; then
  echo ""
  echo "Building Docker images (this may take 10-20 minutes)..."
  docker compose build
  echo ""
  echo "Starting all services..."
  docker compose up -d
  echo ""
  echo "Waiting for services to start..."
  sleep 15
  echo ""
  echo "Initializing local Postgres schema (monitors/feedback/sessions)..."
  bash "$SCRIPT_DIR/init-db.sh" || echo "  (DB init skipped — run init-db.sh later)"
  echo ""
  echo "Checking service health..."
  curl -s http://localhost:3002/ | head -c 100
  echo ""
  docker exec firecrawl-api-1 node -e "
    fetch('http://research-service:8000/health')
      .then(r => r.json())
      .then(d => console.log('Research service:', JSON.stringify(d)))
      .catch(e => console.error('Research service error:', e.message))
  " 2>/dev/null || echo "  (Research service check skipped — container may still be starting)"
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  Setup complete!                                            ║"
  echo "║                                                              ║"
  echo "║  Firecrawl API:  http://localhost:3002                       ║"
  echo "║  SearXNG:        http://localhost:8080 (internal only)        ║"
  echo "║                                                              ║"
  echo "║  Next: Configure opencode MCP to use this Firecrawl:         ║"
  echo "║    See README.md → 'Configuring opencode' section            ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
fi
