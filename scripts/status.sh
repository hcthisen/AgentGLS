#!/bin/bash
# status.sh — post-install verification for the current AgentGLS baseline

set -euo pipefail

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

INSTALL_DIR="/opt/agentos"
ENV_FILE="$INSTALL_DIR/.env"
AGENTOS_USER="agentos"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

echo ""
echo "AgentGLS System Status"
echo "======================"
echo ""

check "Docker running" "systemctl is-active docker"
check "PostgreSQL container up" "docker ps | grep -q agentos-db"
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

  if sudo -u "$AGENTOS_USER" bash -lc "'$INSTALL_DIR/scripts/install-provider.sh' status '$AGENTGLS_PROVIDER'" >/tmp/agentgls-provider-status.txt 2>&1; then
    ok "Provider binary present"
  else
    fail "Provider binary missing"
  fi

  if sudo -u "$AGENTOS_USER" bash -lc "'$INSTALL_DIR/scripts/install-provider.sh' auth-status '$AGENTGLS_PROVIDER'" >/tmp/agentgls-provider-auth.txt 2>&1; then
    ok "Provider authenticated"
  else
    warn "Provider not authenticated yet"
  fi
else
  warn "No active provider selected yet"
fi

for dir in human goalloop scheduled summary; do
  if [[ -d "$INSTALL_DIR/runtime/$dir" ]]; then
    ok "Runtime dir exists: runtime/$dir"
  else
    fail "Runtime dir missing: runtime/$dir"
  fi
done

echo ""
echo "Access"
echo "------"

if [[ -n "${AGENTOS_DOMAIN:-}" ]]; then
  if curl -sfk "https://dashboard.${AGENTOS_DOMAIN}" >/dev/null 2>&1; then
    ok "Domain routing works: dashboard.${AGENTOS_DOMAIN}"
  else
    warn "Domain configured but not reachable yet: dashboard.${AGENTOS_DOMAIN}"
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
