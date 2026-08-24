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
  echo ".env not found - run ./setup.sh and set POSTGRES_PASSWORD first."
  exit 1
fi

if ! docker compose -f "$DIR/docker-compose.yaml" config -q; then
  echo "Compose configuration is invalid; fix .env before initializing the database."
  exit 1
fi

# The db-init service receives DATABASE_URL from the same resolved Compose
# environment as the API. This honors custom/remote URLs and avoids parsing
# passwords in shell or process arguments.
docker compose -f "$DIR/docker-compose.yaml" run --rm db-init

echo ""
echo "Local Postgres schema ready. Monitors, feedback and request telemetry"
echo "will now persist across restarts."
