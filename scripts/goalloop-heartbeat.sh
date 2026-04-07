#!/bin/bash
# goalloop-heartbeat.sh - Claim one GoalLoop goal and execute it via provider-run.sh.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/provider-lib.sh"

load_agentgls_env

INSTALL_DIR="$(provider_install_dir)"
GOALS_DIR="$INSTALL_DIR/goals"
ACTIVE_DIR="$GOALS_DIR/active"
PAUSED_DIR="$GOALS_DIR/paused"
COMPLETED_DIR="$GOALS_DIR/completed"
LOG_DIR="$INSTALL_DIR/logs"
STATE_DIR="$INSTALL_DIR/state/goalloop"
HEARTBEAT_LOG="$LOG_DIR/goalloop-heartbeat.log"
HEARTBEAT_LOCK="$GOALS_DIR/locks/_heartbeat.lock"
GOALMETA_SCRIPT="$SCRIPT_DIR/goalmeta.py"
SYNC_SCRIPT="$SCRIPT_DIR/goalloop-sync.sh"
WAIT_TIMEOUT_SECONDS="${AGENTGLS_GOALLOOP_TIMEOUT_SECONDS:-21600}"

mkdir -p "$ACTIVE_DIR" "$PAUSED_DIR" "$COMPLETED_DIR" "$STATE_DIR" "$LOG_DIR" "$(dirname "$HEARTBEAT_LOCK")"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$HEARTBEAT_LOG"
}

json_field() {
  local key="$1"
  python3 -c "import json,sys; value=json.load(sys.stdin).get('$key'); print('' if value is None else value)"
}

goalmeta_get() {
  local file="$1"
  local field="$2"
  local value

  value="$(python3 "$GOALMETA_SCRIPT" get "$file" "$field" 2>/dev/null || true)"
  if [[ "$value" == "null" ]]; then
    value=""
  fi
  printf '%s\n' "$value"
}

ensure_goalloop_session() {
  local workdir

  workdir="$(ensure_provider_shell_session_dir "goalloop")"
  if tmux has-session -t goalloop 2>/dev/null; then
    return 0
  fi

  log "tmux session 'goalloop' missing; creating shell session in $workdir"
  tmux new-session -d -s goalloop -c "$workdir"
}

run_sync() {
  if [[ ! -x "$SYNC_SCRIPT" ]]; then
    return 0
  fi

  if "$SYNC_SCRIPT" >> "$LOG_DIR/goalloop-sync.log" 2>&1; then
    log "Goal projection sync complete"
  else
    log "Goal projection sync failed"
  fi
}

exec 9>"$HEARTBEAT_LOCK"
if ! flock -n 9; then
  log "Heartbeat skipped; another run is still active"
  exit 0
fi

ensure_goalloop_session

selection="$(python3 "$GOALMETA_SCRIPT" claim "$ACTIVE_DIR" 2>/dev/null || true)"
if [[ -z "$selection" || "$selection" == "null" ]]; then
  log "No eligible goals to claim"
  run_sync
  exit 0
fi

goal_slug="$(printf '%s' "$selection" | json_field slug)"
goal_file="$(printf '%s' "$selection" | json_field file)"
run_id="$(printf '%s' "$selection" | json_field run_id)"
goal_rank="$(printf '%s' "$selection" | json_field rank)"
goal_title="$(goalmeta_get "$goal_file" title)"
notify_chat_id="$(goalmeta_get "$goal_file" notify_chat_id)"

prompt_file="$STATE_DIR/${run_id}.prompt.md"
runner_file="$STATE_DIR/${run_id}.runner.sh"
output_file="$STATE_DIR/${run_id}.output.log"
status_file="$STATE_DIR/${run_id}.status"

notify_instruction="No notify_chat_id is configured for this goal. Do not attempt Telegram notifications."
if [[ -n "$notify_chat_id" ]]; then
  notify_instruction="If the goal is blocked or the run cannot complete, notify the operator with: bash $SCRIPT_DIR/send-telegram.sh $notify_chat_id \"Goal blocked: $goal_slug - <reason>\""
fi

cat > "$prompt_file" <<EOF
GoalLoop heartbeat run for AgentGLS.

Current time (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)
Run ID: $run_id
Goal slug: $goal_slug
Goal title: $goal_title
Goal file: $goal_file
Goals root: $GOALS_DIR
Context file: $GOALS_DIR/_context.md
Runbook file: $GOALS_DIR/_runbook.md
Proof directory: $GOALS_DIR/proof/$goal_slug
Locks directory: $GOALS_DIR/locks

You are executing exactly one autonomous GoalLoop turn. Follow the canonical protocol from AGENTS.md.

Requirements:
- Read the goal file, context, and runbook before acting.
- Work only on this goal.
- Capture proof under $GOALS_DIR/proof/$goal_slug when verification requires it.
- Before mutating shared external systems, acquire the relevant flock lock under $GOALS_DIR/locks.
- Keep any human-facing notes concise.

When you finish this turn, you must run exactly one of these commands:
1. python3 $GOALMETA_SCRIPT finalize $goal_file
2. python3 $GOALMETA_SCRIPT complete $goal_file $COMPLETED_DIR
3. python3 $GOALMETA_SCRIPT pause $goal_file $PAUSED_DIR

$notify_instruction

Do not explain how outbound delivery works. Do not leave the goal in run_state=running when you stop.
EOF

provider_cmd="$(build_provider_run_cmd "goalloop" "$prompt_file")"
cat > "$runner_file" <<EOF
#!/bin/bash
set -euo pipefail
set -o pipefail
if $provider_cmd 2>&1 | tee $(printf '%q' "$output_file"); then
  rc=0
else
  rc=\${PIPESTATUS[0]}
fi
printf '%s\n' "\$rc" > $(printf '%q' "$status_file")
exit "\$rc"
EOF
chmod +x "$runner_file"
rm -f "$status_file" "$output_file"

log "Claimed goal '$goal_slug' (run_id=$run_id rank=$goal_rank); injecting provider turn into tmux session"
tmux send-keys -t goalloop "$(shell_join_quoted bash "$runner_file")" C-m

SECONDS=0
while [[ ! -f "$status_file" ]]; do
  if (( SECONDS >= WAIT_TIMEOUT_SECONDS )); then
    log "Heartbeat timed out waiting for provider completion for '$goal_slug' after ${WAIT_TIMEOUT_SECONDS}s"
    run_sync
    exit 1
  fi
  sleep 5
done

status_code="$(tr -d '[:space:]' < "$status_file")"
if [[ "$status_code" == "0" ]]; then
  log "Goal '$goal_slug' finished successfully (run_id=$run_id)"
else
  tail_output="$(tail -n 5 "$output_file" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
  log "Goal '$goal_slug' failed (run_id=$run_id exit=$status_code output_tail=${tail_output:-<empty>})"
fi

rm -f "$prompt_file" "$runner_file" "$status_file"
run_sync

exit "${status_code:-1}"
