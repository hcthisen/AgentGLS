#!/bin/bash
# watchdog.sh — Provider-neutral tmux shell and Telegram bridge watchdog

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/provider-lib.sh"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

legacy_warning_marker() {
  printf '%s/state/watchdog/legacy-claude.warned\n' "$(provider_install_dir)"
}

ensure_shell_session() {
  local session="$1"
  local workdir

  workdir="$(ensure_provider_shell_session_dir "$session")"

  if tmux has-session -t "$session" 2>/dev/null; then
    return 0
  fi

  log "tmux session '$session' not found; creating shell session in $workdir"
  tmux new-session -d -s "$session" -c "$workdir"
}

warn_legacy_claude_session() {
  local marker
  marker="$(legacy_warning_marker)"
  mkdir -p "$(dirname "$marker")"

  if tmux has-session -t claude 2>/dev/null; then
    if [[ ! -f "$marker" ]]; then
      log "legacy tmux session 'claude' detected; 'agent' is now the canonical human shell session"
      : > "$marker"
    fi
    return 0
  fi

  rm -f "$marker"
}

ensure_telegram_bridge() {
  local bridge_script log_file

  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    return 0
  fi

  if provider_telegram_bridge_running; then
    return 0
  fi

  bridge_script="$(provider_telegram_bridge_script)"
  log_file="$(provider_install_dir)/logs/telegram-bridge.log"
  mkdir -p "$(dirname "$log_file")"

  log "telegram bridge not running; starting..."
  nohup python3 "$bridge_script" run >> "$log_file" 2>&1 &
  sleep 2

  if provider_telegram_bridge_running; then
    log "telegram bridge started"
    return 0
  fi

  log "ERROR: telegram bridge failed to start"
  return 1
}

main() {
  load_agentgls_env

  ensure_shell_session "agent"
  ensure_shell_session "goalloop"
  warn_legacy_claude_session
  ensure_telegram_bridge
}

main "$@"
