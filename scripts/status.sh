#!/bin/bash
# status.sh — post-install verification for the current AgentGLS baseline

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/provider-lib.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  [${GREEN}OK${NC}]   $1"; }
warn() { echo -e "  [${YELLOW}WARN${NC}] $1"; }
fail() { echo -e "  [${RED}FAIL${NC}] $1"; }

check() {
  if eval "$2" >/dev/null 2>&1; then ok "$1"; else fail "$1"; fi
}

run_as_agentgls() {
  local command="$1"

  if [[ "$(id -un)" == "$AGENTGLS_USER" ]]; then
    bash -lc "$command"
  else
    sudo -H -u "$AGENTGLS_USER" bash -lc "$command"
  fi
}

tmux_session_exists() {
  local session="$1"
  local quoted

  quoted="$(printf '%q' "$session")"
  run_as_agentgls "tmux has-session -t ${quoted}"
}

telegram_bridge_running() {
  local quoted

  quoted="$(printf '%q' "$SCRIPT_DIR/provider-lib.sh")"
  run_as_agentgls "source ${quoted}; provider_telegram_bridge_running"
}

count_goal_files() {
  local dir="$1"

  if [[ ! -d "$dir" ]]; then
    echo "0"
    return 0
  fi

  find "$dir" -maxdepth 1 -type f -name '*.md' ! -name '_*' | wc -l | tr -d '[:space:]'
}

INSTALL_DIR="$(provider_install_dir)"
AGENTGLS_USER="${AGENTGLS_USER:-agentgls}"

load_agentgls_env

echo ""
echo "AgentGLS System Status"
echo "======================"
echo ""

check "Docker running" "systemctl is-active docker"
check "PostgreSQL container up" "docker ps | grep -q agentgls-db"
check "PostgREST responding on :3001" "curl -sf http://localhost:3001/ >/dev/null"
check "Dashboard responding on :3000" "curl -sf http://localhost:3000 >/dev/null"
check "Terminal WebSocket listening on :3002" "ss -tln | grep -q ':3002 '"
check "Caddy running" "systemctl is-active caddy"
check "fail2ban running" "systemctl is-active fail2ban"

echo ""
echo "Runtime"
echo "-------"

if [[ -n "${AGENTGLS_PROVIDER:-}" ]]; then
  ok "Active provider: ${AGENTGLS_PROVIDER}"

  if run_as_agentgls "'$INSTALL_DIR/scripts/install-provider.sh' status '$AGENTGLS_PROVIDER'" >/dev/null 2>&1; then
    ok "Provider binary present: ${AGENTGLS_PROVIDER}"
  else
    fail "Provider binary missing: ${AGENTGLS_PROVIDER}"
  fi

  if run_as_agentgls "'$INSTALL_DIR/scripts/install-provider.sh' auth-status '$AGENTGLS_PROVIDER'" >/dev/null 2>&1; then
    ok "Provider authenticated"
  else
    warn "Provider not authenticated yet"
  fi
else
  warn "No active provider selected yet"
fi

if tmux_session_exists "agent" >/dev/null 2>&1; then
  ok "tmux session exists: agent"
else
  fail "tmux session missing: agent"
fi

if tmux_session_exists "goalloop" >/dev/null 2>&1; then
  ok "tmux session exists: goalloop"
else
  fail "tmux session missing: goalloop"
fi

if tmux_session_exists "claude" >/dev/null 2>&1; then
  warn "Legacy tmux session detected: claude (agent is canonical)"
fi

if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  if telegram_bridge_running >/dev/null 2>&1; then
    ok "Telegram bridge running"
  else
    fail "Telegram bridge not running"
  fi
else
  warn "Telegram bridge idle: TELEGRAM_BOT_TOKEN not configured"
fi

for dir in human goalloop scheduled summary; do
  if [[ -d "$INSTALL_DIR/runtime/$dir" ]]; then
    ok "Runtime dir exists: runtime/$dir"
  else
    fail "Runtime dir missing: runtime/$dir"
  fi
done

echo ""
echo "Goals"
echo "-----"

if [[ -d "$INSTALL_DIR/goals" ]]; then
  ok "Active goals: $(count_goal_files "$INSTALL_DIR/goals/active")"
  ok "Paused goals: $(count_goal_files "$INSTALL_DIR/goals/paused")"
  ok "Completed goals: $(count_goal_files "$INSTALL_DIR/goals/completed")"
else
  fail "Goals directory missing: $INSTALL_DIR/goals"
fi

echo ""
echo "Access"
echo "------"

if [[ -n "${AGENTGLS_DOMAIN:-}" ]]; then
  if curl -sfk "https://dashboard.${AGENTGLS_DOMAIN}" >/dev/null 2>&1; then
    ok "Domain routing works: dashboard.${AGENTGLS_DOMAIN}"
  else
    warn "Domain configured but not reachable yet: dashboard.${AGENTGLS_DOMAIN}"
  fi
else
  warn "No domain configured yet; use the onboarding flow on :3000"
fi

ADMIN_EMAIL="${AGENTGLS_ADMIN_EMAIL:-}"
if [[ -n "$ADMIN_EMAIL" && -n "${DASHBOARD_PASSWORD_HASH:-}" ]]; then
  ok "Admin account configured: $ADMIN_EMAIL"
else
  warn "Admin account not configured yet"
fi

if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  ok "Telegram bot token stored"
else
  warn "Telegram bot token not stored yet"
fi

echo ""
