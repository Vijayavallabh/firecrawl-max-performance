#!/usr/bin/env bash
# ======================================================================
# setup.sh — One-command setup for self-hosted Firecrawl with max
# performance, research service, and SearXNG search backend.
#
# Prerequisites:
#   - Docker + Docker Compose
#   - git, curl, python3, perl, openssl
#
# Usage:
#   ./setup.sh
# ======================================================================
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

FIRECRAWL_REF="${FIRECRAWL_REF:-7f1ecf3bd2eb92ad3fe560cc441421bf8a12b12e}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Firecrawl Self-Host Setup (Max Performance + Research)     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Check prerequisites ──────────────────────────────────────────────
echo "Checking prerequisites..."
command -v docker >/dev/null 2>&1 || { echo "Error: docker not found. Install Docker first."; exit 1; }
command -v git >/dev/null 2>&1 || { echo "Error: git not found."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "Error: curl not found."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Error: python3 not found."; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "Error: perl not found."; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "Error: openssl not found."; exit 1; }
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
  git -C firecrawl checkout --detach "$FIRECRAWL_REF"
  echo "  Checked out Firecrawl $FIRECRAWL_REF."
  echo "  Cloned."
fi
if [ -d "firecrawl/.git" ] && ! git -C firecrawl diff --quiet; then
  echo "  Warning: Firecrawl contains local changes; the patcher will preserve them where possible."
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

dotenv_value() {
  python3 - "$1" <<'PY'
import shlex
import sys

key = sys.argv[1]
try:
    lines = open('.env', encoding='utf-8')
except OSError:
    raise SystemExit(0)
for raw in lines:
    line = raw.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    name, value = line.split('=', 1)
    if name.strip() != key:
        continue
    value = value.strip()
    try:
        parsed = shlex.split(value, comments=True)
        print(parsed[0] if parsed else '')
    except ValueError:
        print(value.strip('"\''))
    break
PY
}

urlencode() {
  printf '%s' "$1" | python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))'
}

random_secret() {
  openssl rand -hex 32
}

set_env_value() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

ensure_secret() {
  local key="$1"
  local value
  value=$(dotenv_value "$key")
  if [ -z "$value" ] || [[ "$value" == CHANGE_ME* ]] || [ "$value" = "809bf40addb1732e9ddac97ec3b69f29cd79a3eab5c0e0b3" ]; then
    set_env_value "$key" "$(random_secret)"
    echo "Generated a private value for $key."
  fi
}

ensure_secret BULL_AUTH_KEY
ensure_secret SEARXNG_SECRET
ensure_secret BROWSER_SERVICE_API_KEY
chmod 600 .env

sync_local_database_url() {
  local user password database desired existing
  user=$(dotenv_value POSTGRES_USER)
  password=$(dotenv_value POSTGRES_PASSWORD)
  database=$(dotenv_value POSTGRES_DB)
  if [ -z "$user" ] || [ -z "$password" ] || [ -z "$database" ]; then
    echo "Error: POSTGRES_USER, POSTGRES_PASSWORD, and POSTGRES_DB must be set in .env."
    return 1
  fi
  desired="postgres://$(urlencode "$user"):$(urlencode "$password")@nuq-postgres:5432/$(urlencode "$database")"
  existing=$(dotenv_value DATABASE_URL)
  # A URL targeting the bundled service is setup-managed. Preserve explicit
  # remote/custom URLs so local development and hosted Postgres remain usable.
  if [ -z "$existing" ] || [[ "$existing" == *@nuq-postgres:* ]]; then
    set_env_value DATABASE_URL "$desired"
    echo "Synchronized DATABASE_URL with the PostgreSQL credentials."
  fi
}

# Manual `docker compose up` must receive the same in-stack database URL as
# `./setup.sh --start`, otherwise the schema bootstrap cannot connect.
sync_local_database_url

validate_start_env() {
  local key value base ollama
  for key in POSTGRES_PASSWORD SEARXNG_SECRET BULL_AUTH_KEY BROWSER_SERVICE_API_KEY; do
    value=$(dotenv_value "$key")
    if [ -z "$value" ] || [[ "$value" == CHANGE_ME* ]]; then
      echo "Error: set $key in .env before starting the stack."
      return 1
    fi
  done
  base=$(dotenv_value OPENAI_BASE_URL)
  ollama=$(dotenv_value OLLAMA_BASE_URL)
  if [[ "$base" != *"11434"* ]] && [ -z "$ollama" ]; then
    value=$(dotenv_value OPENAI_API_KEY)
    if [ -z "$value" ] || [[ "$value" == CHANGE_ME* ]]; then
      echo "Error: set OPENAI_API_KEY, or configure OLLAMA_BASE_URL for local LLM use."
      return 1
    fi
  fi
}

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
  validate_start_env
  sync_local_database_url
  chmod 600 .env
  echo "Building Docker images (this may take 10-20 minutes)..."
  docker compose build
  echo ""
  echo "Starting all services..."
  docker compose up -d --wait --wait-timeout 300
  echo ""
  echo "Checking service health..."
  API_PORT=$(dotenv_value PORT)
  API_PORT=${API_PORT:-3002}
  for attempt in $(seq 1 30); do
    if curl -fsS --max-time 5 "http://127.0.0.1:${API_PORT}/" >/dev/null; then
      break
    fi
    if [ "$attempt" -eq 30 ]; then
      echo "Error: Firecrawl API did not become healthy."
      docker compose ps
      exit 1
    fi
    sleep 2
  done
  docker compose exec -T api node -e "
    fetch('http://research-service:8000/health')
      .then(r => r.json())
      .then(d => console.log('Research service:', JSON.stringify(d)))
      .catch(e => { console.error('Research service error:', e.message); process.exit(1); })
  "
  echo "  Firecrawl API: healthy"
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
