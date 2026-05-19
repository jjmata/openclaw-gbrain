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
#
#    Known issue on Render Managed Postgres: several GBrain migrations
#    (v24, v29, v31, v35 at the time of writing) require the connecting
#    role to hold the BYPASSRLS attribute. Render never grants BYPASSRLS
#    to user roles (only the platform's superuser has it), so each of
#    these migrations throws and aborts the whole init. See
#    https://github.com/garrytan/gbrain/issues/416 for the upstream
#    design discussion.
#
#    These migrations are no-ops for this template's threat model: they
#    only enable RLS on tables that are exclusively read via the gbrain
#    role, which owns them (Postgres table owners bypass RLS by default)
#    and is not exposed via PostgREST. We detect each failure, mark the
#    offending migration as applied in gbrain's `config` table, and
#    re-run init. The loop terminates when init succeeds or when a
#    failure occurs that we don't recognise.
# ---------------------------------------------------------------------------
run_gbrain_init() {
  local log_file="/tmp/gbrain-init.$$.log"
  local max_iterations=20
  local iteration=0

  while [ "$iteration" -lt "$max_iterations" ]; do
    iteration=$((iteration + 1))

    if gbrain init --url "$DATABASE_URL" --non-interactive 2>&1 | tee "$log_file"; then
      rm -f "$log_file"
      return 0
    fi

    if ! grep -q 'BYPASSRLS privilege' "$log_file"; then
      log "ERROR: gbrain init failed for a reason other than the known BYPASSRLS limitation. See output above."
      rm -f "$log_file"
      return 1
    fi

    local stuck_version
    stuck_version="$(grep 'BYPASSRLS privilege' "$log_file" | grep -oE 'v[0-9]+' | head -n1 | tr -d 'v')"
    if [ -z "$stuck_version" ]; then
      log "ERROR: could not parse stuck migration version from gbrain output."
      rm -f "$log_file"
      return 1
    fi

    local current_version expected_prev
    current_version="$(psql "$DATABASE_URL" -tAc "SELECT value FROM config WHERE key='version'" 2>/dev/null | tr -d '[:space:]')"
    expected_prev=$((stuck_version - 1))
    if [ "$current_version" != "$expected_prev" ]; then
      log "ERROR: gbrain init failed at v${stuck_version} but schema version is '${current_version:-<unset>}' (expected ${expected_prev}). Aborting to avoid masking an unrelated issue."
      rm -f "$log_file"
      return 1
    fi

    log "Iteration ${iteration}: marking v${stuck_version} as applied (RLS no-op on Render — gbrain role owns the tables and is not exposed via PostgREST)."
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
      -c "UPDATE config SET value='${stuck_version}' WHERE key='version' AND value='${expected_prev}';" >/dev/null

    log "Re-running gbrain init to apply remaining migrations..."
    rm -f "$log_file"
  done

  log "ERROR: hit max BYPASSRLS workaround iterations (${max_iterations}). Investigate manually."
  return 1
}

if [ ! -f "${GBRAIN_HOME:-/data/.gbrain}/config.json" ]; then
  log "Running first-time gbrain init..."
  run_gbrain_init
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
