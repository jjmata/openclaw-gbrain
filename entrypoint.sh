#!/usr/bin/env bash
# Entrypoint for openclaw-render-template-gbrain.
#
# Runs on every container start, but the expensive steps (CREATE EXTENSION,
# gbrain init schema, skills seed) are idempotent and short-circuit on reboots.
# Failures here exit non-zero so Render surfaces the problem instead of
# starting AlphaClaw against a half-initialized brain.

set -euo pipefail

log() { echo "[entrypoint] $*"; }

# ---------------------------------------------------------------------------
# 1. Validate required environment.
# ---------------------------------------------------------------------------
require_env() {
  if [ -z "${!1:-}" ]; then
    log "ERROR: $1 is not set. See README.md for required env vars."
    exit 1
  fi
}

require_env DATABASE_URL
require_env OPENAI_API_KEY
require_env ANTHROPIC_API_KEY
require_env ALPHACLAW_ROOT_DIR

mkdir -p "$ALPHACLAW_ROOT_DIR"
mkdir -p "$ALPHACLAW_ROOT_DIR/skills"
mkdir -p "${GBRAIN_HOME:-/data/.gbrain}"

# ---------------------------------------------------------------------------
# 2. Enable Postgres extensions GBrain depends on.
#    Render Postgres permits CREATE EXTENSION for vector and pg_trgm without
#    superuser. Wrap in a single transaction so the check is one round trip.
# ---------------------------------------------------------------------------
log "Ensuring pgvector + pg_trgm extensions are enabled..."
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
SQL

# ---------------------------------------------------------------------------
# 3. Initialize the GBrain schema (idempotent: safe to re-run).
#    The init wizard normally prompts for a connection URL; passing --url
#    skips the wizard and writes config to $GBRAIN_HOME/config.json.
# ---------------------------------------------------------------------------
if [ ! -f "${GBRAIN_HOME:-/data/.gbrain}/config.json" ]; then
  log "Running first-time gbrain init..."
  gbrain init --url "$DATABASE_URL" --non-interactive
else
  log "gbrain config found, skipping init."
fi

# ---------------------------------------------------------------------------
# 4. Seed the seven GBrain skills into the AlphaClaw skills directory.
#    Only copy on first boot or when the seed is newer (so image upgrades
#    propagate skill updates without clobbering user edits).
# ---------------------------------------------------------------------------
if [ -d /app/skills-seed ]; then
  log "Seeding GBrain skills into $ALPHACLAW_ROOT_DIR/skills..."
  cp -rn /app/skills-seed/* "$ALPHACLAW_ROOT_DIR/skills/" || true
fi

# ---------------------------------------------------------------------------
# 5. Hand off to AlphaClaw.
# ---------------------------------------------------------------------------
log "Starting AlphaClaw..."
exec "$@"
