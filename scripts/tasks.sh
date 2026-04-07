#!/bin/bash
# tasks.sh — Manage agent-created scheduled tasks
# Usage: tasks.sh <command> [args]
#
# Tasks are stored in Supabase cc_scheduled_tasks and executed via cron.
# Each task runs a prompt via `claude -p` and optionally sends results to Telegram.

set -euo pipefail

CRED_FILE="$HOME/.claude/credentials/supabase.env"
if [[ -f "$CRED_FILE" ]]; then source "$CRED_FILE"; else echo "ERROR: $CRED_FILE not found" >&2; exit 1; fi

SUPABASE_URL="${SUPABASE_URL:-http://localhost:3001}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="/opt/agentos/logs"
CRON_MARKER="# AGENT_TASK"

# --- Helpers ---

supabase_get() {
  curl -sf "${SUPABASE_URL}/$1" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}"
}

supabase_post() {
  curl -sf -X POST "${SUPABASE_URL}/$1" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=representation" \
    -d "$2"
}

supabase_patch() {
  curl -sf -X PATCH "${SUPABASE_URL}/$1" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=representation" \
    -d "$2"
}

supabase_delete() {
  curl -sf -X DELETE "${SUPABASE_URL}/$1" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}"
}

# Resolve a task ID prefix to a full UUID (UUID columns don't support LIKE)
resolve_task_id() {
  local prefix="$1"
  supabase_get "cc_scheduled_tasks?select=id" | python3 -c "
import json, sys
prefix = '${prefix}'
data = json.load(sys.stdin)
matches = [t['id'] for t in data if t['id'].startswith(prefix)]
if len(matches) == 1:
    print(matches[0])
elif len(matches) == 0:
    sys.exit(1)
else:
    print(f'Ambiguous prefix: {len(matches)} matches', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null
}

# Sync a single task's cron entry (add or remove based on enabled state)
sync_cron_entry() {
  local task_id="$1"
  local cron_expr="$2"
  local enabled="$3"
  local current_cron
  current_cron=$(crontab -l 2>/dev/null || true)

  # Remove existing entry for this task (both comment and job line)
  local filtered
  filtered=$(echo "$current_cron" | grep -v "AGENT_TASK:${task_id}" | grep -v "task-runner.sh ${task_id}" || true)

  if [[ "$enabled" == "true" && -n "$cron_expr" ]]; then
    # Add new entry
    local cron_line="${CRON_MARKER}:${task_id}"
    local job_line="${cron_expr} ${SCRIPT_DIR}/task-runner.sh ${task_id} >> ${LOG_DIR}/tasks.log 2>&1"
    filtered="${filtered}
${cron_line}
${job_line}"
  fi

  # Write back (remove blank lines)
  echo "$filtered" | grep -v '^$' | crontab - 2>/dev/null
}

# --- Commands ---

cmd_list() {
  echo "## Scheduled Tasks"
  supabase_get "cc_scheduled_tasks?select=id,name,cron_expr,chat_id,model,enabled,last_run,last_result&order=created_at.desc" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if not data:
    print('  (no tasks)')
    sys.exit(0)
for t in data:
    status = 'ON' if t.get('enabled') else 'OFF'
    tid = t['id'][:8]
    name = t.get('name', '?')
    cron = t.get('cron_expr', '?')
    model = t.get('model', 'haiku')
    chat = t.get('chat_id', 'none')[:10] if t.get('chat_id') else 'none'
    last_run = (t.get('last_run') or 'never')[:19]
    last_result = (t.get('last_result') or '')[:80]
    print(f'  [{tid}] {status} | {name}')
    print(f'    Schedule: {cron} | Model: {model} | Chat: {chat}')
    print(f'    Last run: {last_run}')
    if last_result:
        print(f'    Last result: {last_result}...')
    print()
print(f'({len(data)} task(s))')
"
}

cmd_add() {
  local data="$1"

  # Insert into Supabase
  local response
  response=$(supabase_post "cc_scheduled_tasks" "$data")

  if [[ -z "$response" ]]; then
    echo "ERROR: Failed to create task" >&2
    exit 1
  fi

  # Extract task ID, cron_expr, enabled
  local task_info
  task_info=$(echo "$response" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if isinstance(data, list): data = data[0]
print(data['id'], data.get('cron_expr',''), data.get('enabled', True))
")
  local task_id cron_expr enabled
  read -r task_id cron_expr enabled <<< "$task_info"

  # Install cron entry
  sync_cron_entry "$task_id" "$cron_expr" "$enabled"

  echo "$response" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if isinstance(data, list): data = data[0]
print(f\"Task created: {data['id'][:8]} — {data.get('name', '?')}\")
print(f\"  Schedule: {data.get('cron_expr', '?')}\")
print(f\"  Prompt: {data.get('prompt', '?')[:100]}...\")
print(f\"  Chat: {data.get('chat_id', 'none')}\")
print(f\"  Model: {data.get('model', 'haiku')}\")
"
}

cmd_remove() {
  local task_id_prefix="$1"

  # Find full task ID
  local full_id
  full_id=$(resolve_task_id "$task_id_prefix") || { echo "Task not found: $task_id_prefix" >&2; exit 1; }

  # Remove cron entry
  sync_cron_entry "$full_id" "" "false"

  # Delete from Supabase
  supabase_delete "cc_scheduled_tasks?id=eq.${full_id}"
  echo "Task removed: ${full_id:0:8}"
}

cmd_pause() {
  local task_id_prefix="$1"

  local full_id
  full_id=$(resolve_task_id "$task_id_prefix") || { echo "Task not found: $task_id_prefix" >&2; exit 1; }

  supabase_patch "cc_scheduled_tasks?id=eq.${full_id}" '{"enabled": false}'
  sync_cron_entry "$full_id" "" "false"
  echo "Task paused: ${full_id:0:8}"
}

cmd_resume() {
  local task_id_prefix="$1"

  local full_id
  full_id=$(resolve_task_id "$task_id_prefix") || { echo "Task not found: $task_id_prefix" >&2; exit 1; }

  local cron_expr
  cron_expr=$(supabase_get "cc_scheduled_tasks?select=cron_expr&id=eq.${full_id}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data[0].get('cron_expr','') if data else '')
" 2>/dev/null)

  supabase_patch "cc_scheduled_tasks?id=eq.${full_id}" '{"enabled": true}'
  sync_cron_entry "$full_id" "$cron_expr" "true"
  echo "Task resumed: ${full_id:0:8} (schedule: $cron_expr)"
}

cmd_run() {
  local task_id_prefix="$1"

  local full_id
  full_id=$(resolve_task_id "$task_id_prefix") || { echo "Task not found: $task_id_prefix" >&2; exit 1; }

  echo "Running task ${full_id:0:8} now..."
  bash "${SCRIPT_DIR}/task-runner.sh" "$full_id"
}

cmd_sync() {
  echo "Syncing all task cron entries..."
  local tasks
  tasks=$(supabase_get "cc_scheduled_tasks?select=id,cron_expr,enabled")

  # First remove all agent task entries from crontab
  local current_cron
  current_cron=$(crontab -l 2>/dev/null || true)
  local filtered
  filtered=$(echo "$current_cron" | grep -v "AGENT_TASK" | grep -v "task-runner.sh" || true)

  # Re-add enabled tasks
  echo "$tasks" | python3 -c "
import json, sys
data = json.load(sys.stdin)
enabled = [t for t in data if t.get('enabled')]
for t in enabled:
    print(t['id'], t.get('cron_expr',''))
print(f'# {len(enabled)} enabled / {len(data)} total', file=sys.stderr)
" 2>&1 1>/dev/null | head -1 >&2

  local additions
  additions=$(echo "$tasks" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data:
    if t.get('enabled') and t.get('cron_expr'):
        tid = t['id']
        cron = t['cron_expr']
        print(f'# AGENT_TASK:{tid}')
        print(f'{cron} /opt/agentos/scripts/task-runner.sh {tid} >> /opt/agentos/logs/tasks.log 2>&1')
")

  if [[ -n "$additions" ]]; then
    filtered="${filtered}
${additions}"
  fi

  echo "$filtered" | grep -v '^$' | crontab - 2>/dev/null
  echo "Cron entries synced."

  # Catch-up: run any enabled tasks whose one-time schedule has passed but never ran
  echo "$tasks" | python3 -c "
import json, sys, datetime, subprocess

data = json.load(sys.stdin)
now = datetime.datetime.now(datetime.timezone.utc)

for t in data:
    if not t.get('enabled') or not t.get('cron_expr'):
        continue
    # Skip recurring tasks (only catch up one-time schedules)
    # One-time cron has specific day-of-month and month fields (not * or */)
    parts = t['cron_expr'].split()
    if len(parts) != 5:
        continue
    minute, hour, dom, month, dow = parts
    # If day-of-month and month are specific numbers, it's a one-time task
    if not (dom.isdigit() and month.isdigit()):
        continue
    # Build the scheduled datetime
    try:
        sched = datetime.datetime(now.year, int(month), int(dom), int(hour), int(minute),
                                  tzinfo=datetime.timezone.utc)
    except ValueError:
        continue
    # If schedule has passed and task never ran, run it now
    if sched <= now and t.get('last_run') is None:
        tid = t['id']
        print(f'Catch-up: running missed task {tid[:8]}')
        subprocess.Popen(
            ['bash', '/opt/agentos/scripts/task-runner.sh', tid],
            stdout=open('/opt/agentos/logs/tasks.log', 'a'),
            stderr=open('/opt/agentos/logs/tasks.log', 'a')
        )
" 2>&1
}

cmd_history() {
  local task_id_prefix="${1:-}"

  if [[ -z "$task_id_prefix" ]]; then
    # Show recent history across all tasks
    echo "## Recent Task Activity (last 20)"
    supabase_get "cc_task_history?select=task_name,result,chat_id,created_at&order=created_at.desc&limit=20" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if not data:
    print('  (no history)')
    sys.exit(0)
for h in data:
    ts = (h.get('created_at') or '')[:19]
    name = h.get('task_name', '?')
    result = (h.get('result') or '')[:120]
    chat = h.get('chat_id', '')
    dest = f' -> chat {chat}' if chat else ''
    print(f'  [{ts}] {name}{dest}')
    print(f'    {result}')
    print()
print(f'({len(data)} entries)')
"
  else
    local full_id
    full_id=$(resolve_task_id "$task_id_prefix") || { echo "Task not found: $task_id_prefix" >&2; exit 1; }

    echo "## History for task ${full_id:0:8}"
    supabase_get "cc_task_history?task_id=eq.${full_id}&select=result,created_at&order=created_at.desc&limit=10" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if not data:
    print('  (no history)')
    sys.exit(0)
for h in data:
    ts = (h.get('created_at') or '')[:19]
    result = (h.get('result') or '')[:200]
    print(f'  [{ts}] {result}')
    print()
print(f'({len(data)} entries)')
"
  fi
}

# --- Main ---

usage() {
  cat << 'EOF'
Usage: tasks.sh <command> [args]

Commands:
  list                      List all scheduled tasks
  add '<json>'              Create a new task
                            Required JSON fields: name, cron_expr, prompt
                            Optional: chat_id, model (default: opus), enabled (default: true)
  remove <id>               Delete a task (use first 8 chars of ID)
  pause <id>                Disable a task without deleting it
  resume <id>               Re-enable a paused task
  run <id>                  Run a task immediately (regardless of schedule)
  history [id]              Show task execution history (all tasks, or specific task)
  sync                      Regenerate all cron entries from database

Examples:
  tasks.sh add '{"name":"Cat jokes","cron_expr":"0 * * * *","prompt":"Tell me a funny cat joke","chat_id":"123456"}'
  tasks.sh list
  tasks.sh history
  tasks.sh history a1b2c3d4
  tasks.sh remove a1b2c3d4
EOF
  exit 1
}

case "${1:-}" in
  list)    cmd_list ;;
  add)     cmd_add "${2:?JSON data required}" ;;
  remove)  cmd_remove "${2:?Task ID required}" ;;
  pause)   cmd_pause "${2:?Task ID required}" ;;
  resume)  cmd_resume "${2:?Task ID required}" ;;
  run)     cmd_run "${2:?Task ID required}" ;;
  history) cmd_history "${2:-}" ;;
  sync)    cmd_sync ;;
  *)       usage ;;
esac
