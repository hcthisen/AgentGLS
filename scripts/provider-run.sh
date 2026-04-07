#!/bin/bash
# provider-run.sh — stable provider-neutral runtime entrypoint

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/provider-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  provider-run.sh <channel> <prompt_file>

Channels:
  human | goalloop | scheduled | summary
EOF
}

log_line() {
  local log_file="$1"
  shift
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$log_file"
}

run_provider_mode() {
  local mode="$1"
  local provider="$2"
  local workdir="$3"
  local prompt="$4"
  local stdout_file="$5"
  local stderr_log="$6"
  local -a cmd=()

  case "$mode" in
    first)
      provider_build_first_run_args "$provider" "$prompt" cmd
      ;;
    resume)
      provider_build_resume_args "$provider" "$prompt" cmd
      ;;
    *)
      echo "Unknown provider mode: ${mode:-<empty>}" >&2
      return 1
      ;;
  esac

  log_line "$stderr_log" "mode=$mode cwd=$workdir provider=$provider command=$(shell_join_quoted "${cmd[@]}")"

  (
    cd "$workdir"
    "${cmd[@]}"
  ) >"$stdout_file" 2>>"$stderr_log"
}

main() {
  local channel="${1:-}"
  local prompt_file="${2:-}"
  local provider workdir stderr_log prompt stdout_file
  local status=0

  if [[ $# -ne 2 ]]; then
    usage >&2
    exit 1
  fi

  if [[ -z "$channel" || -z "$prompt_file" ]]; then
    usage >&2
    exit 1
  fi

  load_agentgls_env

  provider="$(resolve_active_provider)"
  workdir="$(ensure_provider_channel_dir "$channel")"
  ensure_provider_state_dir "$channel" >/dev/null
  stderr_log="$(provider_stderr_log_file "$channel" "$provider")"

  if [[ ! -f "$prompt_file" ]]; then
    echo "Prompt file not found: $prompt_file" >&2
    exit 1
  fi

  if [[ ! -r "$prompt_file" ]]; then
    echo "Prompt file is not readable: $prompt_file" >&2
    exit 1
  fi

  if ! provider_binary_available "$provider"; then
    echo "Provider binary not found for $provider" >&2
    log_line "$stderr_log" "provider binary missing for $provider"
    exit 1
  fi

  prompt="$(cat "$prompt_file")"
  stdout_file="$(mktemp)"
  trap 'rm -f "$stdout_file"' EXIT

  if provider_resume_possible "$channel" "$provider"; then
    log_line "$stderr_log" "resume requested for channel=$channel provider=$provider"
    if run_provider_mode resume "$provider" "$workdir" "$prompt" "$stdout_file" "$stderr_log"; then
      provider_mark_resume_ready "$channel" "$provider"
      cat "$stdout_file"
      exit 0
    else
      status=$?
      log_line "$stderr_log" "resume failed for channel=$channel provider=$provider exit=$status; falling back to first run"
    fi
  else
    log_line "$stderr_log" "no resumable session marker for channel=$channel provider=$provider; using first run"
  fi

  : >"$stdout_file"
  if run_provider_mode first "$provider" "$workdir" "$prompt" "$stdout_file" "$stderr_log"; then
    provider_mark_resume_ready "$channel" "$provider"
    cat "$stdout_file"
    exit 0
  else
    status=$?
    log_line "$stderr_log" "first run failed for channel=$channel provider=$provider exit=$status"
    exit "$status"
  fi
}

main "$@"
