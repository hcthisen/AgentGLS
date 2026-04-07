#!/bin/bash
# provider-lib.sh — shared provider helpers for AgentGLS runtime automation

provider_install_dir() {
  printf '%s\n' "${AGENTOS_DIR:-/opt/agentos}"
}

provider_env_file() {
  printf '%s/.env\n' "$(provider_install_dir)"
}

load_agentgls_env() {
  local env_file
  env_file="$(provider_env_file)"

  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
}

resolve_active_provider() {
  local provider="${1:-${AGENTGLS_PROVIDER:-}}"

  case "$provider" in
    claude|codex)
      printf '%s\n' "$provider"
      ;;
    *)
      echo "Unknown or unset provider: ${provider:-<empty>}" >&2
      return 1
      ;;
  esac
}

provider_channel_dir() {
  local channel="$1"

  case "$channel" in
    human|goalloop|scheduled|summary)
      printf '%s/runtime/%s\n' "$(provider_install_dir)" "$channel"
      ;;
    *)
      echo "Unknown provider channel: ${channel:-<empty>}" >&2
      return 1
      ;;
  esac
}

ensure_provider_channel_dir() {
  local dir
  dir="$(provider_channel_dir "$1")"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

provider_shell_session_dir() {
  local session="$1"

  case "$session" in
    agent)
      provider_channel_dir "human"
      ;;
    goalloop)
      provider_channel_dir "goalloop"
      ;;
    *)
      echo "Unknown tmux shell session: ${session:-<empty>}" >&2
      return 1
      ;;
  esac
}

ensure_provider_shell_session_dir() {
  local dir
  dir="$(provider_shell_session_dir "$1")"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

provider_state_dir() {
  printf '%s/.agentgls\n' "$(provider_channel_dir "$1")"
}

ensure_provider_state_dir() {
  local dir
  dir="$(provider_state_dir "$1")"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

provider_resume_marker_file() {
  printf '%s/provider-resume\n' "$(provider_state_dir "$1")"
}

provider_resume_possible() {
  local channel="$1"
  local provider="${2:-$(resolve_active_provider)}"
  local marker

  marker="$(provider_resume_marker_file "$channel")"
  [[ -f "$marker" ]] || return 1
  [[ "$(tr -d '[:space:]' < "$marker")" == "$provider" ]]
}

provider_mark_resume_ready() {
  local channel="$1"
  local provider="${2:-$(resolve_active_provider)}"
  local marker

  ensure_provider_state_dir "$channel" >/dev/null
  marker="$(provider_resume_marker_file "$channel")"
  printf '%s\n' "$provider" > "$marker"
}

provider_log_dir() {
  printf '%s/logs/providers\n' "$(provider_install_dir)"
}

ensure_provider_log_dir() {
  local dir
  dir="$(provider_log_dir)"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

provider_stderr_log_file() {
  local channel="$1"
  local provider="${2:-$(resolve_active_provider)}"

  printf '%s/%s-%s.stderr.log\n' "$(ensure_provider_log_dir)" "$provider" "$channel"
}

provider_telegram_bridge_script() {
  printf '%s/scripts/telegram-bridge.py\n' "$(provider_install_dir)"
}

provider_telegram_bridge_running() {
  local bridge_script
  bridge_script="$(provider_telegram_bridge_script)"

  pgrep -f "python3 ${bridge_script} run" >/dev/null 2>&1 ||
    pgrep -f "${bridge_script} run" >/dev/null 2>&1
}

provider_binary() {
  case "$1" in
    claude) printf '%s\n' "claude" ;;
    codex) printf '%s\n' "codex" ;;
    *)
      echo "Unknown provider: ${1:-<empty>}" >&2
      return 1
      ;;
  esac
}

provider_binary_available() {
  local provider="${1:-$(resolve_active_provider)}"
  command -v "$(provider_binary "$provider")" >/dev/null 2>&1
}

provider_codex_bypass_enabled() {
  [[ "${AGENTGLS_PROVIDER_BYPASS_APPROVALS:-0}" == "1" ]]
}

provider_build_first_run_args() {
  local provider="$1"
  local prompt="$2"
  local outvar="$3"
  local -n cmd_ref="$outvar"

  cmd_ref=()

  case "$provider" in
    claude)
      cmd_ref=(claude -p "$prompt")
      ;;
    codex)
      cmd_ref=(codex exec)
      if provider_codex_bypass_enabled; then
        cmd_ref+=(--dangerously-bypass-approvals-and-sandbox)
      fi
      cmd_ref+=("$prompt")
      ;;
    *)
      echo "Unknown provider: ${provider:-<empty>}" >&2
      return 1
      ;;
  esac
}

provider_build_resume_args() {
  local provider="$1"
  local prompt="$2"
  local outvar="$3"
  local -n cmd_ref="$outvar"

  cmd_ref=()

  case "$provider" in
    claude)
      cmd_ref=(claude -c -p "$prompt")
      ;;
    codex)
      cmd_ref=(codex exec resume --last)
      if provider_codex_bypass_enabled; then
        cmd_ref+=(--dangerously-bypass-approvals-and-sandbox)
      fi
      cmd_ref+=("$prompt")
      ;;
    *)
      echo "Unknown provider: ${provider:-<empty>}" >&2
      return 1
      ;;
  esac
}

shell_join_quoted() {
  local quoted=()
  local arg

  for arg in "$@"; do
    quoted+=("$(printf '%q' "$arg")")
  done

  local old_ifs="$IFS"
  IFS=' '
  printf '%s\n' "${quoted[*]}"
  IFS="$old_ifs"
}

build_provider_run_cmd() {
  local channel="$1"
  local prompt_file="$2"
  shell_join_quoted "$(provider_install_dir)/scripts/provider-run.sh" "$channel" "$prompt_file"
}
