#!/bin/bash
# install-provider.sh — install or inspect the active AgentGLS provider CLI

set -euo pipefail

INSTALL_DIR="${AGENTOS_DIR:-/opt/agentos}"

load_env() {
  if [[ -f "$INSTALL_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$INSTALL_DIR/.env"
    set +a
  fi
}

ensure_user_bin_path() {
  local shell_file
  mkdir -p "$HOME/.local/bin"

  for shell_file in "$HOME/.bashrc" "$HOME/.profile"; do
    touch "$shell_file"
    if ! grep -q 'export PATH="\$HOME/.local/bin:\$PATH"' "$shell_file" 2>/dev/null; then
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$shell_file"
    fi
  done

  export PATH="$HOME/.local/bin:$PATH"
}

resolve_provider() {
  local provider="${1:-${AGENTGLS_PROVIDER:-}}"
  case "$provider" in
    claude|codex)
      echo "$provider"
      ;;
    *)
      echo "Unknown or unset provider: ${provider:-<empty>}" >&2
      return 1
      ;;
  esac
}

provider_bin() {
  case "$1" in
    claude) echo "claude" ;;
    codex) echo "codex" ;;
    *) return 1 ;;
  esac
}

is_installed() {
  command -v "$(provider_bin "$1")" >/dev/null 2>&1
}

install_claude() {
  ensure_user_bin_path
  curl -fsSL https://claude.ai/install.sh | bash
}

install_codex() {
  ensure_user_bin_path

  if ! command -v npm >/dev/null 2>&1; then
    echo "npm is required to install Codex CLI" >&2
    return 1
  fi

  npm config set prefix "$HOME/.local" >/dev/null 2>&1 || true
  npm install -g @openai/codex
}

print_status() {
  local provider="$1"
  if is_installed "$provider"; then
    echo "installed"
    return 0
  fi

  echo "missing"
  return 1
}

print_auth_status() {
  local provider="$1"

  if ! is_installed "$provider"; then
    echo "missing"
    return 1
  fi

  case "$provider" in
    claude)
      claude auth status
      ;;
    codex)
      codex login status
      ;;
  esac
}

usage() {
  cat <<'EOF'
Usage:
  install-provider.sh install [claude|codex]
  install-provider.sh status [claude|codex]
  install-provider.sh auth-status [claude|codex]

If no provider argument is provided, AGENTGLS_PROVIDER from /opt/agentos/.env is used.
EOF
}

main() {
  local action="${1:-}"
  local provider_arg="${2:-}"

  load_env

  case "$action" in
    install)
      provider_arg="$(resolve_provider "$provider_arg")"
      if is_installed "$provider_arg"; then
        echo "$provider_arg already installed"
        exit 0
      fi
      case "$provider_arg" in
        claude) install_claude ;;
        codex) install_codex ;;
      esac
      ;;
    status)
      provider_arg="$(resolve_provider "$provider_arg")"
      print_status "$provider_arg"
      ;;
    auth-status)
      provider_arg="$(resolve_provider "$provider_arg")"
      print_auth_status "$provider_arg"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
