#!/bin/bash
# task-runner.sh - Execute a scheduled task through the provider-neutral runtime.
# Called by cron: task-runner.sh <task_id>

set -euo pipefail

export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"

TASK_ID="${1:?Task ID required}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROVIDER_RUN_SCRIPT="$SCRIPT_DIR/provider-run.sh"
CRED_FILE="$HOME/.claude/credentials/supabase.env"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/provider-lib.sh"

if [[ -f "$CRED_FILE" ]]; then
  source "$CRED_FILE"
else
  echo "$(date) ERROR: $CRED_FILE not found" >&2
  exit 1
fi

load_agentgls_env

SUPABASE_URL="${SUPABASE_URL:-http://localhost:3001}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY}"

task_json=$(curl -sf "${SUPABASE_URL}/cc_scheduled_tasks?id=eq.${TASK_ID}&enabled=eq.true&limit=1" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" 2>/dev/null || echo "[]")

history_json=$(curl -sf "${SUPABASE_URL}/cc_task_history?task_id=eq.${TASK_ID}&select=result,created_at&order=created_at.desc&limit=10" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" 2>/dev/null || echo "[]")

export TASK_JSON="$task_json"
export HISTORY_JSON="$history_json"
export TASK_ID SUPABASE_URL SUPABASE_KEY
export SEND_TELEGRAM_SCRIPT="$SCRIPT_DIR/send-telegram.sh"
export PROVIDER_RUN_SCRIPT

python3 <<'PYEOF'
import datetime
import json
import os
import subprocess
import sys
import tempfile

task_json = os.environ.get("TASK_JSON", "[]")
history_json = os.environ.get("HISTORY_JSON", "[]")
task_id = os.environ["TASK_ID"]
supabase_url = os.environ["SUPABASE_URL"]
supabase_key = os.environ["SUPABASE_KEY"]
send_telegram_script = os.environ.get("SEND_TELEGRAM_SCRIPT", "")
provider_run_script = os.environ.get("PROVIDER_RUN_SCRIPT", "")


def api(method, endpoint, data=None):
    command = [
        "curl",
        "-sf",
        "-X",
        method,
        f"{supabase_url}/{endpoint}",
        "-H",
        f"apikey: {supabase_key}",
        "-H",
        f"Authorization: Bearer {supabase_key}",
        "-H",
        "Content-Type: application/json",
    ]
    if data is not None:
        command.extend(["-d", json.dumps(data)])
    return subprocess.run(command, capture_output=True, text=True, timeout=10)


def run_provider(prompt: str) -> str:
    if not provider_run_script:
        return "(Task error: provider-run.sh is not configured)"

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write(prompt)
        prompt_path = handle.name

    try:
        result = subprocess.run(
            ["bash", provider_run_script, "scheduled", prompt_path],
            capture_output=True,
            text=True,
            timeout=10800,
        )
    except subprocess.TimeoutExpired:
        return "(Task error: provider-run.sh timed out after 3 hours)"
    except Exception as exc:
        return f"(Task error: {exc})"
    finally:
        try:
            os.unlink(prompt_path)
        except FileNotFoundError:
            pass

    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"provider-run exited {result.returncode}"
        return f"(Task error: {detail})"

    output = result.stdout.strip()
    return output or "(No output generated)"


data = json.loads(task_json)
if not data:
    print(f"Task {task_id[:8]} not found or disabled")
    sys.exit(0)

task = data[0]
name = task.get("name", "Unnamed task")
prompt = task.get("prompt", "")
chat_id = task.get("chat_id", "")
model = task.get("model", "default")

if not prompt:
    print("Empty prompt, skipping")
    sys.exit(0)

print(f"Running task: {name}")

history = json.loads(history_json)
history_lines = []
for item in history:
    created_at = (item.get("created_at") or "")[:16]
    result_text = (item.get("result") or "").strip()
    if result_text:
        history_lines.append(f"- [{created_at}] {result_text[:200]}")

prompt_parts = [
    "Scheduled task execution for AgentGLS.",
    f"Task ID: {task_id}",
    f"Task name: {name}",
    f"Current UTC time: {datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()}",
    "Return only the task result for the operator. Keep it concise unless the task itself requires depth.",
    "Outbound delivery is handled after this run. Do not mention Telegram delivery mechanics.",
    f"Requested model hint from the task record: {model}. Use it only if your runtime already supports it without extra setup; otherwise ignore the hint.",
    f"Task prompt:\n{prompt}",
]

if history_lines:
    prompt_parts.append(
        "Previous outputs for this recurring task. Do not repeat them unless the task explicitly asks for repetition:\n"
        + "\n".join(history_lines)
    )

output = run_provider("\n\n".join(prompt_parts))
print(f"Output: {output[:200]}...")

if chat_id and send_telegram_script:
    message = f"{name}\n\n{output}"
    try:
        response = subprocess.run(
            ["bash", send_telegram_script, str(chat_id)],
            input=message,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if response.returncode == 0:
            print(f"Sent to Telegram chat {chat_id}")
        else:
            print(f"Telegram send failed: {response.stderr or response.stdout}")
    except Exception as exc:
        print(f"Telegram error: {exc}")

now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

api(
    "POST",
    "cc_task_history",
    {
        "task_id": task_id,
        "task_name": name,
        "result": output[:4000],
        "chat_id": chat_id,
        "created_at": now,
    },
)

api(
    "PATCH",
    f"cc_scheduled_tasks?id=eq.{task_id}",
    {
        "last_run": now,
        "last_result": output[:2000],
        "updated_at": now,
    },
)

old = subprocess.run(
    [
        "curl",
        "-sf",
        f"{supabase_url}/cc_task_history?task_id=eq.{task_id}&select=id&order=created_at.desc&offset=20",
        "-H",
        f"apikey: {supabase_key}",
        "-H",
        f"Authorization: Bearer {supabase_key}",
    ],
    capture_output=True,
    text=True,
    timeout=10,
)

try:
    old_ids = [row["id"] for row in json.loads(old.stdout)]
    for old_id in old_ids:
        api("DELETE", f"cc_task_history?id=eq.{old_id}")
    if old_ids:
        print(f"Pruned {len(old_ids)} old history entries")
except Exception:
    pass

print("Task complete")
PYEOF
