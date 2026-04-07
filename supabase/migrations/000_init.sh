#!/bin/bash
# Apply all migrations in order, substituting the authenticator password

# 001: Core schema (has password placeholder)
sed "s/AUTHENTICATOR_PASSWORD_PLACEHOLDER/${POSTGRES_PASSWORD}/g" \
  /docker-entrypoint-initdb.d/001_initial_schema.sql | \
  psql -U postgres -d postgres

# 002+: Additional migrations (no substitution needed)
for f in /docker-entrypoint-initdb.d/002_*.sql; do
  [ -f "$f" ] || continue
  echo "Applying $(basename "$f")..."
  psql -U postgres -d postgres < "$f"
done
