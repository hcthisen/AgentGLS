#!/bin/bash
# memory.sh — Memory CRUD operations for Claude Code via Supabase REST API
# Usage: memory.sh <command> [args]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRED_FILE="$HOME/.claude/credentials/supabase.env"

CUSTOM_FILE="$HOME/.claude/credentials/custom.env"

if [[ -f "$CRED_FILE" ]]; then
  source "$CRED_FILE"
else
  echo "ERROR: Credentials not found at $CRED_FILE" >&2
  exit 1
fi
[[ -f "$CUSTOM_FILE" ]] && source "$CUSTOM_FILE"

SUPABASE_URL="${SUPABASE_URL:-http://localhost:3001}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY}"

# --- Helpers ---

supabase_get() {
  local endpoint="$1"
  curl -sf "${SUPABASE_URL}/${endpoint}" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}"
}

supabase_post() {
  local endpoint="$1"
  local data="$2"
  local prefer="${3:-return=representation}"
  curl -sf -X POST "${SUPABASE_URL}/${endpoint}" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: ${prefer}" \
    -d "$data"
}

supabase_patch() {
  local endpoint="$1"
  local data="$2"
  curl -sf -X PATCH "${SUPABASE_URL}/${endpoint}" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=representation" \
    -d "$data"
}

supabase_delete() {
  local endpoint="$1"
  curl -sf -X DELETE "${SUPABASE_URL}/${endpoint}" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}"
}

format_json() {
  python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if isinstance(data, list):
        for item in data:
            if isinstance(item, dict):
                for k, v in item.items():
                    if v is not None and v != '' and v != []:
                        print(f'  {k}: {v}')
                print('  ---')
    elif isinstance(data, dict):
        for k, v in data.items():
            if v is not None:
                print(f'  {k}: {v}')
    if isinstance(data, list):
        print(f'({len(data)} results)')
except:
    pass
"
}

# --- Commands ---

cmd_load() {
  echo "=== MEMORY LOAD ==="
  echo ""

  echo "## Consolidated Knowledge"
  supabase_get "cc_memory?select=topic,content,tags,updated_at&type=eq.consolidated&order=updated_at.desc&limit=20" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if not data:
        print('  (no consolidated memories yet)')
    for item in data:
        topic = item.get('topic','?')
        content = item.get('content','')
        updated = (item.get('updated_at','') or '')[:10]
        tags = ', '.join(item.get('tags',[]) or [])
        tag_str = f' [{tags}]' if tags else ''
        print(f'  **{topic}** (updated {updated}){tag_str}')
        for line in content.split('. '):
            line = line.strip()
            if line:
                suffix = '' if line.endswith('.') else '.'
                print(f'    {line}{suffix}')
        print()
    print(f'({len(data)} topics)')
except:
    print('  (no data)')
"
  echo ""

  echo "## Recent Sessions (last 10)"
  supabase_get "cc_sessions?select=id,session_date,summary,tags&summary=not.is.null&order=session_date.desc&limit=10" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for item in data:
        sid = item.get('id','?')[:8]
        date = (item.get('session_date','') or '')[:10]
        summary = item.get('summary','(no summary)')
        tags = ', '.join(item.get('tags',[]) or [])
        tag_str = f' (tags: {tags})' if tags else ''
        print(f'  [{sid}] {date} — {summary}{tag_str}')
    print(f'({len(data)} sessions)')
except:
    print('  (no data)')
"
  echo ""

  echo "## User Profile"
  supabase_get "cc_user_profile?select=category,key,value&order=category" | format_json
  echo ""
  echo "=== END MEMORY LOAD ==="
  echo "Use 'memory.sh get <id>' for full detail on any session."
}

cmd_search() {
  local query="$1"
  echo "## Search: '$query'"
  supabase_get "cc_sessions?select=id,session_date,summary,tags&or=(summary.ilike.*${query}*,tags.cs.{${query}})&order=session_date.desc&limit=20" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for item in data:
        sid = item.get('id','?')[:8]
        date = (item.get('session_date','') or '')[:10]
        summary = item.get('summary','(no summary)')
        tags = ', '.join(item.get('tags',[]) or [])
        tag_str = f' (tags: {tags})' if tags else ''
        print(f'  [{sid}] {date} — {summary}{tag_str}')
    print(f'({len(data)} results)')
except:
    print('  (no data)')
"
}

cmd_get() {
  local session_id="$1"
  echo "## Session Detail: $session_id"
  # Match by prefix (first 8 chars) or full UUID
  supabase_get "cc_sessions?select=id,session_date,project,summary,detail_summary,tags&id=like.${session_id}*&limit=1" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if not data:
        print('  Session not found')
    else:
        item = data[0]
        print(f\"  ID: {item.get('id','?')}\")
        print(f\"  Date: {item.get('session_date','?')}\")
        print(f\"  Project: {item.get('project','?')}\")
        print(f\"  Tags: {', '.join(item.get('tags',[]) or [])}\")
        print(f\"  Summary: {item.get('summary','(none)')}\")
        print()
        print('  Detail:')
        detail = item.get('detail_summary','(no detail summary)')
        for line in detail.split('\n'):
            print(f'    {line}')
except:
    print('  (error)')
"
}

cmd_deep_search() {
  local query="$1"
  echo "## Deep Search: '$query' (detail summaries)"
  supabase_get "cc_sessions?select=session_date,project,detail_summary,tags&or=(detail_summary.ilike.*${query}*,summary.ilike.*${query}*,tags.cs.{${query}})&order=session_date.desc&limit=20" | format_json
}

cmd_full_search() {
  local query="$1"
  echo "## Full Search: '$query' (raw content — slow)"
  supabase_get "cc_sessions?select=session_date,project,summary,content&content=ilike.*${query}*&order=session_date.desc&limit=10" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for item in data:
        print(f\"  Date: {item.get('session_date','?')}\")
        print(f\"  Project: {item.get('project','?')}\")
        print(f\"  Summary: {item.get('summary','(none)')}\")
        content = item.get('content','')
        # Show snippet around the match
        if content:
            lower = content.lower()
            idx = lower.find('$query'.lower())
            if idx >= 0:
                start = max(0, idx - 100)
                end = min(len(content), idx + 200)
                print(f'  Snippet: ...{content[start:end]}...')
        print('  ---')
    print(f'({len(data)} results)')
except:
    pass
"
}

cmd_add_memory() {
  local data="$1"
  echo "Adding memory..."
  supabase_post "cc_memory" "$data" | format_json
  echo "Memory added."
}

cmd_add_project() {
  local data="$1"
  echo "Adding/updating project..."
  supabase_post "cc_projects" "$data" "return=representation,resolution=merge-duplicates" | format_json
  echo "Project saved."
}

cmd_add_profile() {
  local data="$1"
  echo "Adding/updating profile..."
  supabase_post "cc_user_profile" "$data" "return=representation,resolution=merge-duplicates" | format_json
  echo "Profile saved."
}

cmd_save_session() {
  local data="$1"
  echo "Saving session..."
  supabase_post "cc_sessions" "$data" "return=representation,resolution=merge-duplicates" | format_json
  echo "Session saved."
}

# --- Main ---

usage() {
  echo "Usage: memory.sh <command> [args]"
  echo ""
  echo "Commands:"
  echo "  load                    Load recent session summaries + user profile"
  echo "  get <id>                Get full detail for a session (use first 8 chars of ID)"
  echo "  search <query>          Search session summaries by keyword"
  echo "  deep-search <query>     Search detail summaries"
  echo "  full-search <query>     Search raw session content (slow)"
  echo "  add-memory <json>       Add a memory entry"
  echo "  add-project <json>      Add/update a project"
  echo "  add-profile <json>      Add/update a user profile entry"
  echo "  save-session <json>     Manually save a session"
  exit 1
}

case "${1:-}" in
  load)         cmd_load ;;
  get)          cmd_get "${2:?Session ID required}" ;;
  search)       cmd_search "${2:?Query required}" ;;
  deep-search)  cmd_deep_search "${2:?Query required}" ;;
  full-search)  cmd_full_search "${2:?Query required}" ;;
  add-memory)   cmd_add_memory "${2:?JSON data required}" ;;
  add-project)  cmd_add_project "${2:?JSON data required}" ;;
  add-profile)  cmd_add_profile "${2:?JSON data required}" ;;
  save-session) cmd_save_session "${2:?JSON data required}" ;;
  *)            usage ;;
esac
