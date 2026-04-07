#!/bin/bash
# run-migrations.sh — Apply database migrations to a running PostgreSQL
# Usage: run-migrations.sh [migration_file]
# If no file specified, applies all migrations in order

set -euo pipefail

MIGRATIONS_DIR="/opt/agentos/supabase/migrations"
DB_CONTAINER="agentos-db"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

if ! docker ps --format '{{.Names}}' | grep -q "^${DB_CONTAINER}$"; then
  echo "ERROR: Container $DB_CONTAINER is not running" >&2
  exit 1
fi

apply_migration() {
  local file="$1"
  local name=$(basename "$file")
  log "Applying migration: $name"
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres < "$file" 2>&1
  log "Migration applied: $name"
}

if [[ -n "${1:-}" ]]; then
  # Apply specific migration
  apply_migration "$1"
else
  # Apply all SQL migrations in order
  for f in "$MIGRATIONS_DIR"/*.sql; do
    [[ -f "$f" ]] || continue
    apply_migration "$f"
  done
fi

log "All migrations complete"
