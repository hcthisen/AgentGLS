#!/bin/bash
# ============================================================
# telegram-setup.sh — Guided Telegram Bot API setup for AgentGLS
# Run as the agentgls user after bootstrap.
#
# Can also be run with:
#   AGENTGLS_TELEGRAM_TOKEN=123:AAH... bash telegram-setup.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/provider-lib.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }

INSTALL_DIR="$(provider_install_dir)"
BRIDGE_SCRIPT="$INSTALL_DIR/scripts/telegram-bridge.py"
SETUP_HELPER="$INSTALL_DIR/scripts/setup-instance.py"
LOG_FILE="$INSTALL_DIR/logs/telegram-bridge.log"

load_agentgls_env

bridge_running() {
  pgrep -f "python3 ${BRIDGE_SCRIPT} run" >/dev/null 2>&1 || pgrep -f "${BRIDGE_SCRIPT} run" >/dev/null 2>&1
}

start_bridge() {
  mkdir -p "$(dirname "$LOG_FILE")"

  if bridge_running; then
    info "Telegram bridge already running; restarting to pick up the current token."
    pkill -f "python3 ${BRIDGE_SCRIPT} run" >/dev/null 2>&1 || pkill -f "${BRIDGE_SCRIPT} run" >/dev/null 2>&1 || true
    sleep 1
  fi

  nohup python3 "$BRIDGE_SCRIPT" run >> "$LOG_FILE" 2>&1 &
  sleep 2

  if bridge_running; then
    success "Telegram bridge is running"
  else
    error "Telegram bridge failed to start. Check $LOG_FILE"
    exit 1
  fi
}

store_token() {
  local token="$1"
  AGENTGLS_TELEGRAM_SETUP_TOKEN="$token" \
    python3 - <<'PY' | python3 "$SETUP_HELPER" set-telegram
import json
import os

print(json.dumps({"token": os.environ["AGENTGLS_TELEGRAM_SETUP_TOKEN"]}))
PY
}

echo ""
echo -e "${GREEN}${BOLD}AgentGLS — Telegram Setup${NC}"
echo "==========================="
echo ""

if [[ ! -f "$SETUP_HELPER" ]]; then
  error "Missing setup helper: $SETUP_HELPER"
  exit 1
fi

if [[ ! -f "$BRIDGE_SCRIPT" ]]; then
  error "Missing Telegram bridge: $BRIDGE_SCRIPT"
  exit 1
fi

echo -e "${BOLD}Step 1 — Create a Telegram bot${NC}"
echo ""
echo "  1. Open Telegram and search for @BotFather"
echo "  2. Send /newbot"
echo "  3. Choose a display name"
echo "  4. Choose a unique username ending in 'bot'"
echo "  5. Copy the bot token BotFather returns"
echo ""

echo -e "${BOLD}Step 2 — Store the bot token in /opt/agentgls/.env${NC}"
echo ""

TOKEN="${AGENTGLS_TELEGRAM_TOKEN:-}"
NEED_TOKEN=true

if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  info "Existing token found: ${TELEGRAM_BOT_TOKEN:0:10}..."
  if [[ -n "$TOKEN" ]]; then
    info "Overwriting with token from AGENTGLS_TELEGRAM_TOKEN"
  else
    read -rp "  Keep the existing token? (Y/n): " keep
    if [[ "${keep,,}" != "n" ]]; then
      NEED_TOKEN=false
      TOKEN="$TELEGRAM_BOT_TOKEN"
      success "Keeping existing token"
    fi
  fi
fi

if $NEED_TOKEN; then
  if [[ -z "$TOKEN" ]]; then
    read -rp "  Paste your bot token: " TOKEN
  else
    info "Using token from AGENTGLS_TELEGRAM_TOKEN"
  fi

  if [[ -z "$TOKEN" ]]; then
    error "No token provided."
    exit 1
  fi

  if [[ ! "$TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
    warn "Token format looks unusual. Double-check it before continuing."
  fi

  store_token "$TOKEN"
  export TELEGRAM_BOT_TOKEN="$TOKEN"
  success "Token stored in $INSTALL_DIR/.env"
fi
echo ""

echo -e "${BOLD}Step 3 — Start the provider-neutral Telegram bridge${NC}"
echo ""
start_bridge
echo "  Log file: $LOG_FILE"
echo "  Status:   python3 $BRIDGE_SCRIPT status"
echo ""

echo -e "${BOLD}Step 4 — Pair your Telegram chat${NC}"
echo ""
echo "  1. Open your bot in Telegram and send any message"
echo "  2. The bot replies with a 6-character pairing code"
echo "  3. If you need to see pending codes on the server, run:"
echo ""
echo -e "       ${GREEN}python3 $BRIDGE_SCRIPT list-pending${NC}"
echo ""
echo "  4. Approve the code with:"
echo ""
echo -e "       ${GREEN}python3 $BRIDGE_SCRIPT pair <CODE>${NC}"
echo ""

read -rp "  Enter a pairing code now to approve it, or press Enter to skip: " PAIR_CODE
if [[ -n "${PAIR_CODE:-}" ]]; then
  if python3 "$BRIDGE_SCRIPT" pair "$PAIR_CODE"; then
    success "Pairing approved"
  else
    error "Pairing failed. Use 'python3 $BRIDGE_SCRIPT list-pending' and try again."
    exit 1
  fi
fi

echo ""
echo -e "${GREEN}${BOLD}Telegram setup complete!${NC}"
echo ""
echo "  Useful commands:"
echo "    python3 $BRIDGE_SCRIPT status        — bridge status"
echo "    python3 $BRIDGE_SCRIPT list-pending  — pending pair requests"
echo "    python3 $BRIDGE_SCRIPT list-allowed  — allowlisted chats"
echo "    tail -f $LOG_FILE                    — bridge log"
echo ""
