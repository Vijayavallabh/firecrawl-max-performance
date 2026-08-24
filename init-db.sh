#!/usr/bin/env bash
# ======================================================================
# init-db.sh - Creates the local Postgres schema (drizzle tables + the
# monitoring_claim_due_monitors RPC) inside the running nuq-postgres
# container, enabling monitors, search feedback, browser sessions and
# request telemetry in hybrid mode (USE_DB_AUTHENTICATION=false +
# DATABASE_URL pointing at local Postgres).
#
# Idempotent: safe to re-run.
# ======================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$DIR/.env" ]; then
  echo ".env not found — copy env.example and set POSTGRES_PASSWORD first."
  exit 1
fi

DB_USER=$(grep '^POSTGRES_USER=' "$DIR/.env" | cut -d= -f2-)
DB_PASSWORD=$(grep '^POSTGRES_PASSWORD=' "$DIR/.env" | cut -d= -f2-)
DB_NAME=$(grep '^POSTGRES_DB=' "$DIR/.env" | cut -d= -f2-)
[ -n "$DB_USER" ] || { echo "POSTGRES_USER missing from .env"; exit 1; }
[ -n "$DB_PASSWORD" ] || { echo "POSTGRES_PASSWORD missing from .env"; exit 1; }
[ -n "$DB_NAME" ] || { echo "POSTGRES_DB missing from .env"; exit 1; }

urlencode() {
  python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

DBURL="postgres://$(urlencode "$DB_USER"):$(urlencode "$DB_PASSWORD")@nuq-postgres:5432/$(urlencode "$DB_NAME")"

API_CONTAINER=$(docker compose -f "$DIR/docker-compose.yaml" ps -q api)
[ -n "$API_CONTAINER" ] || { echo "Firecrawl api container is not running."; exit 1; }

docker cp "$DIR/db-init.js" "$API_CONTAINER:/tmp/db-init.js"
docker exec -e DATABASE_URL="$DBURL" "$API_CONTAINER" node /tmp/db-init.js

echo ""
echo "Local Postgres schema ready. Monitors, feedback and request telemetry"
echo "will now persist across restarts."
