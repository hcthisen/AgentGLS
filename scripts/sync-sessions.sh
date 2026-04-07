#!/bin/bash
# sync-sessions.sh — Sync Claude Code JSONL session files to Supabase
# Usage: sync-sessions.sh [--all]

set -euo pipefail

CRED_FILE="$HOME/.claude/credentials/supabase.env"
SESSION_DIR="$HOME/.claude/projects/-root"
SYNC_ALL="${1:-}"

if [[ -f "$CRED_FILE" ]]; then
  source "$CRED_FILE"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Credentials not found at $CRED_FILE" >&2
  exit 1
fi

SUPABASE_URL="${SUPABASE_URL:-http://localhost:3001}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY}"

if [[ ! -d "$SESSION_DIR" ]]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') No session directory found at $SESSION_DIR"
  exit 0
fi

# Find JSONL files to sync
if [[ "$SYNC_ALL" == "--all" ]]; then
  FILES=$(find "$SESSION_DIR" -name "*.jsonl" -type f 2>/dev/null)
else
  # Only the most recently modified file
  FILES=$(find "$SESSION_DIR" -name "*.jsonl" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
fi

if [[ -z "$FILES" ]]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') No JSONL files found"
  exit 0
fi

process_file() {
  local file="$1"
  local filename=$(basename "$file" .jsonl)

  # Extract content using Python
  local content
  content=$(python3 -c "
import json, sys, re

messages = []
try:
    with open('$file', 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
                role = entry.get('role', '')
                if role not in ('human', 'assistant'):
                    continue
                # Get text content
                msg_content = ''
                content_field = entry.get('content', '')
                if isinstance(content_field, str):
                    msg_content = content_field
                elif isinstance(content_field, list):
                    parts = []
                    for block in content_field:
                        if isinstance(block, dict) and block.get('type') == 'text':
                            parts.append(block.get('text', ''))
                    msg_content = ' '.join(parts)
                # Filter system reminders
                msg_content = re.sub(r'<system-reminder>.*?</system-reminder>', '', msg_content, flags=re.DOTALL)
                # Truncate
                if len(msg_content) > 500:
                    msg_content = msg_content[:500] + '...'
                if msg_content.strip():
                    messages.append(f'[{role}] {msg_content.strip()}')
            except json.JSONDecodeError:
                continue
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)

print('\n'.join(messages))
" 2>/dev/null)

  if [[ -z "$content" ]]; then
    return
  fi

  # Escape for JSON
  local json_content
  json_content=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$content")

  # Upsert via PostgREST
  local response
  response=$(curl -sf -X POST "${SUPABASE_URL}/cc_sessions" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: resolution=merge-duplicates,return=minimal" \
    -d "{\"id\":\"${filename}\",\"content\":${json_content},\"project\":\"root\"}" 2>&1) || true

  echo "$(date '+%Y-%m-%d %H:%M:%S') Synced: $filename ($(echo "$content" | wc -c) bytes)"
}

echo "$(date '+%Y-%m-%d %H:%M:%S') Starting session sync..."
count=0
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  process_file "$file"
  count=$((count + 1))
done <<< "$FILES"
echo "$(date '+%Y-%m-%d %H:%M:%S') Sync complete: $count file(s) processed"
