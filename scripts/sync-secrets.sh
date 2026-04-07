#!/bin/bash
# sync-secrets.sh — Sync secrets from Supabase to local .env file
# Runs every 5 minutes via cron

set -euo pipefail

CRED_FILE="$HOME/.claude/credentials/supabase.env"
OUTPUT_FILE="$HOME/.claude/credentials/custom.env"

if [[ -f "$CRED_FILE" ]]; then source "$CRED_FILE"; else exit 0; fi

SUPABASE_URL="${SUPABASE_URL:-http://localhost:3001}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY}"

# Fetch all secrets
SECRETS=$(curl -sf "${SUPABASE_URL}/cc_secrets?select=key,value&order=key" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" 2>/dev/null || echo "[]")

# Convert to KEY=value format
NEW_CONTENT=$(echo "$SECRETS" | python3 -c "
import json, sys
try:
    secrets = json.load(sys.stdin)
    for s in secrets:
        key = s.get('key', '')
        value = s.get('value', '')
        # Escape single quotes in value
        value = value.replace(\"'\", \"'\\\"'\\\"'\")
        print(f\"{key}='{value}'\")
except:
    pass
" 2>/dev/null)

# Only write if content changed
EXISTING=""
if [[ -f "$OUTPUT_FILE" ]]; then
  EXISTING=$(cat "$OUTPUT_FILE")
fi

if [[ "$NEW_CONTENT" != "$EXISTING" ]]; then
  echo "$NEW_CONTENT" > "$OUTPUT_FILE"
  chmod 600 "$OUTPUT_FILE"
  echo "$(date '+%Y-%m-%d %H:%M:%S') Secrets synced ($(echo "$NEW_CONTENT" | grep -c '=' || echo 0) keys)"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') Secrets unchanged"
fi
