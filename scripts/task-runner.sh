#!/bin/bash
# task-runner.sh — Execute a scheduled task: run prompt via claude -p, send result to Telegram
# Called by cron: task-runner.sh <task_id>
#
# Features:
# - Loads past results to avoid repetition (task memory)
# - Stores each result in cc_task_history (thread awareness for main session)
# - Sends result to Telegram via send-telegram.sh

set -euo pipefail

# Ensure claude is in PATH (cron doesn't load .profile/.bashrc)
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"

TASK_ID="${1:?Task ID required}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CRED_FILE="$HOME/.claude/credentials/supabase.env"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/provider-lib.sh"

if [[ -f "$CRED_FILE" ]]; then source "$CRED_FILE"; else echo "$(date) ERROR: $CRED_FILE not found" >&2; exit 1; fi
load_agentgls_env

SUPABASE_URL="${SUPABASE_URL:-http://localhost:3001}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [task:${TASK_ID:0:8}] $*"; }

# Fetch task from Supabase
task_json=$(curl -sf "${SUPABASE_URL}/cc_scheduled_tasks?id=eq.${TASK_ID}&enabled=eq.true&limit=1" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" 2>/dev/null || echo "[]")

# Fetch last 10 results for this task (task memory)
history_json=$(curl -sf "${SUPABASE_URL}/cc_task_history?task_id=eq.${TASK_ID}&select=result,created_at&order=created_at.desc&limit=10" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" 2>/dev/null || echo "[]")

# Parse and execute via Python (avoids shell quoting nightmares with prompts/results)
export TASK_JSON="$task_json"
export HISTORY_JSON="$history_json"
export TASK_ID SUPABASE_URL SUPABASE_KEY
export SEND_TELEGRAM_SCRIPT="$SCRIPT_DIR/send-telegram.sh"

python3 << 'PYEOF'
import json, os, subprocess, datetime, sys

task_json = os.environ.get("TASK_JSON", "[]")
history_json = os.environ.get("HISTORY_JSON", "[]")
task_id = os.environ["TASK_ID"]
supabase_url = os.environ["SUPABASE_URL"]
supabase_key = os.environ["SUPABASE_KEY"]
send_telegram_script = os.environ.get("SEND_TELEGRAM_SCRIPT", "")

def api(method, endpoint, data=None):
    """Helper for Supabase REST calls."""
    cmd = ["curl", "-sf", "-X", method, f"{supabase_url}/{endpoint}",
           "-H", f"apikey: {supabase_key}",
           "-H", f"Authorization: Bearer {supabase_key}",
           "-H", "Content-Type: application/json"]
    if data:
        cmd.extend(["-d", json.dumps(data)])
    return subprocess.run(cmd, capture_output=True, text=True, timeout=10)

data = json.loads(task_json)
if not data:
    print(f"Task {task_id[:8]} not found or disabled")
    sys.exit(0)

task = data[0]
name = task.get("name", "Unnamed task")
prompt = task.get("prompt", "")
chat_id = task.get("chat_id", "")
model = task.get("model", "opus")

if not prompt:
    print("Empty prompt, skipping")
    sys.exit(0)

print(f"Running task: {name}")

# Build context-aware prompt with history
history = json.loads(history_json)
if history:
    past_results = "\n".join(
        f"- [{h.get('created_at','')[:16]}] {h.get('result','')[:200]}"
        for h in history
    )
    full_prompt = (
        f"{prompt}\n\n"
        f"IMPORTANT: Here are your previous outputs for this recurring task. "
        f"Do NOT repeat any of these. Be fresh and original each time.\n\n"
        f"Previous outputs:\n{past_results}"
    )
else:
    full_prompt = prompt

# Run the prompt via claude -p (no timeout — tasks can run up to 3 hours)
try:
    result = subprocess.run(
        ["claude", "-p", "--model", model, full_prompt],
        capture_output=True, text=True
    )
    output = result.stdout.strip()
    if not output:
        output = "(No output generated)"
except Exception as e:
    output = f"(Task error: {e})"

print(f"Output: {output[:200]}...")

# Send to Telegram
if chat_id and send_telegram_script:
    message = f"{name}\n\n{output}"

    try:
        r = subprocess.run([
            "bash",
            send_telegram_script,
            str(chat_id)
        ], input=message, capture_output=True, text=True, timeout=120)
        if r.returncode == 0:
            print(f"Sent to Telegram chat {chat_id}")
        else:
            print(f"Telegram send failed: {r.stderr or r.stdout}")
    except Exception as e:
        print(f"Telegram error: {e}")

now = datetime.datetime.now(datetime.timezone.utc).isoformat()

# Store in task history (thread awareness + memory for future runs)
api("POST", "cc_task_history", {
    "task_id": task_id,
    "task_name": name,
    "result": output[:4000],
    "chat_id": chat_id,
    "created_at": now
})

# Update last_run and last_result on the task itself
api("PATCH", f"cc_scheduled_tasks?id=eq.{task_id}", {
    "last_run": now,
    "last_result": output[:2000],
    "updated_at": now
})

# Prune old history (keep last 20 per task)
old = subprocess.run([
    "curl", "-sf",
    f"{supabase_url}/cc_task_history?task_id=eq.{task_id}&select=id&order=created_at.desc&offset=20",
    "-H", f"apikey: {supabase_key}",
    "-H", f"Authorization: Bearer {supabase_key}"
], capture_output=True, text=True, timeout=10)

try:
    old_ids = [r["id"] for r in json.loads(old.stdout)]
    for old_id in old_ids:
        api("DELETE", f"cc_task_history?id=eq.{old_id}")
    if old_ids:
        print(f"Pruned {len(old_ids)} old history entries")
except:
    pass

print("Task complete")
PYEOF
