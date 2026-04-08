#!/bin/bash
# ============================================================
# AgentGLS Bootstrap Installer
# Install the host stack, expose the dashboard, and leave the
# rest of setup to the browser onboarding flow.
# ============================================================

set -euo pipefail

AGENTGLS_USER="agentgls"
INSTALL_DIR="${AGENTGLS_DIR:-/opt/agentgls}"
REPO_URL="https://github.com/hcthisen/AgentGLS.git"
REPO_BRANCH="${AGENTGLS_BRANCH:-main}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }
step()    { echo -e "\n${GREEN}>>>${NC} $*"; }

OVERRIDE_AGENTGLS_DOMAIN="${AGENTGLS_DOMAIN:-}"
OVERRIDE_AGENTGLS_DASHBOARD_HOST="${AGENTGLS_DASHBOARD_HOST:-}"
OVERRIDE_AGENTGLS_PROVIDER="${AGENTGLS_PROVIDER:-}"
OVERRIDE_ADMIN_NAME="${AGENTGLS_ADMIN_NAME:-}"
OVERRIDE_ADMIN_EMAIL="${AGENTGLS_ADMIN_EMAIL:-}"
OVERRIDE_DASHBOARD_PASSWORD="${AGENTGLS_DASHBOARD_PASSWORD:-}"
OVERRIDE_TELEGRAM_TOKEN="${TELEGRAM_BOT_TOKEN:-${AGENTGLS_TELEGRAM_TOKEN:-}}"

derive_dashboard_host_from_domain() {
  local domain="${1:-}"
  if [[ -z "$domain" ]]; then
    return 0
  fi
  printf 'dashboard.%s\n' "$domain"
}

derive_legacy_domain_from_host() {
  local host="${1:-}"
  if [[ "$host" == dashboard.* ]]; then
    printf '%s\n' "${host#dashboard.}"
  fi
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
  fi
}

check_os() {
  if [[ ! -f /etc/os-release ]]; then
    error "Cannot detect OS"
    exit 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    warn "Untested OS: $ID. Proceeding anyway..."
  fi
  info "OS: $PRETTY_NAME"
}

create_user() {
  if id "$AGENTGLS_USER" &>/dev/null; then
    info "User '$AGENTGLS_USER' already exists"
    return
  fi

  step "Creating user '$AGENTGLS_USER'..."
  useradd -m -s /bin/bash "$AGENTGLS_USER"
  echo "$AGENTGLS_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agentgls
  chmod 440 /etc/sudoers.d/agentgls
  success "User '$AGENTGLS_USER' created with passwordless sudo"
}

install_deps() {
  step "Installing system dependencies..."
  export DEBIAN_FRONTEND=noninteractive

  if ! command -v docker &>/dev/null; then
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
    systemctl enable docker --now
    success "Docker installed"
  else
    info "Docker already installed"
  fi

  usermod -aG docker "$AGENTGLS_USER"

  apt-get update -qq
  apt-get install -y -qq \
    tmux \
    fail2ban \
    python3 \
    python3-pip \
    python3-yaml \
    jq \
    curl \
    git \
    unzip \
    openssl \
    ca-certificates >/dev/null 2>&1

  systemctl enable fail2ban --now 2>/dev/null || true
  success "System packages installed"
}

install_nodejs() {
  if command -v node &>/dev/null; then
    info "Node.js already installed: $(node --version)"
    return
  fi

  step "Installing Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs >/dev/null 2>&1
  success "Node.js $(node --version) installed"
}

install_caddy() {
  if command -v caddy &>/dev/null; then
    info "Caddy already installed"
    return
  fi

  step "Installing Caddy..."
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https >/dev/null 2>&1
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null 2>&1
  success "Caddy installed"
}

clone_repo() {
  step "Preparing installation directory..."

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Repo exists, pulling latest..."
    git -C "$INSTALL_DIR" fetch --quiet origin "$REPO_BRANCH"
    git -C "$INSTALL_DIR" checkout --quiet "$REPO_BRANCH"
    git -C "$INSTALL_DIR" pull --quiet
  else
    if [[ -d "$INSTALL_DIR" ]] && [[ "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]]; then
      warn "Installation directory exists and is not a git checkout; reusing existing files"
    else
      rm -rf "$INSTALL_DIR"
      git clone --quiet --branch "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR"
    fi
  fi

  mkdir -p "$INSTALL_DIR"/{logs,config,scripts,supabase/migrations}
  chown -R "$AGENTGLS_USER":"$AGENTGLS_USER" "$INSTALL_DIR"
  chmod +x "$INSTALL_DIR"/scripts/*.sh 2>/dev/null || true
  success "Installation directory ready: $INSTALL_DIR"
}

generate_jwt() {
  local role="$1"
  local secret="$2"
  python3 - <<PY
import base64
import hashlib
import hmac
import json
import time

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

header = b64url(json.dumps({'alg':'HS256','typ':'JWT'}).encode())
now = int(time.time())
payload = b64url(json.dumps({
    'role': '$role',
    'iss': 'supabase',
    'iat': now,
    'exp': now + 315360000,
}).encode())
sig = b64url(hmac.new('$secret'.encode(), f'{header}.{payload}'.encode(), hashlib.sha256).digest())
print(f'{header}.{payload}.{sig}')
PY
}

load_existing_env() {
  if [[ -f "$INSTALL_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$INSTALL_DIR/.env"
    set +a
    info "Loaded existing runtime config from .env"
  fi
}

prepare_config() {
  step "Preparing runtime configuration..."

  load_existing_env

  AGENTGLS_DOMAIN="${OVERRIDE_AGENTGLS_DOMAIN:-${AGENTGLS_DOMAIN:-}}"
  AGENTGLS_DASHBOARD_HOST="${OVERRIDE_AGENTGLS_DASHBOARD_HOST:-${AGENTGLS_DASHBOARD_HOST:-}}"
  AGENTGLS_PROVIDER="${OVERRIDE_AGENTGLS_PROVIDER:-${AGENTGLS_PROVIDER:-}}"
  AGENTGLS_ADMIN_NAME="${OVERRIDE_ADMIN_NAME:-${AGENTGLS_ADMIN_NAME:-}}"
  AGENTGLS_ADMIN_EMAIL="${OVERRIDE_ADMIN_EMAIL:-${AGENTGLS_ADMIN_EMAIL:-}}"
  TELEGRAM_BOT_TOKEN="${OVERRIDE_TELEGRAM_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
  AGENTGLS_DOMAIN_SKIPPED="${AGENTGLS_DOMAIN_SKIPPED:-0}"
  AGENTGLS_TELEGRAM_SKIPPED="${AGENTGLS_TELEGRAM_SKIPPED:-0}"

  if [[ -z "${AGENTGLS_DASHBOARD_HOST:-}" && -n "${AGENTGLS_DOMAIN:-}" ]]; then
    AGENTGLS_DASHBOARD_HOST="$(derive_dashboard_host_from_domain "$AGENTGLS_DOMAIN")"
  fi

  AGENTGLS_DOMAIN="$(derive_legacy_domain_from_host "${AGENTGLS_DASHBOARD_HOST:-}")"

  if [[ -n "$OVERRIDE_DASHBOARD_PASSWORD" ]]; then
    DASHBOARD_PASSWORD_HASH="$(echo -n "$OVERRIDE_DASHBOARD_PASSWORD" | sha256sum | awk '{print $1}')"
  else
    DASHBOARD_PASSWORD_HASH="${DASHBOARD_PASSWORD_HASH:-}"
  fi

  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -hex 24)}"
  JWT_SECRET="${JWT_SECRET:-$(openssl rand -base64 32)}"
  SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-$(generate_jwt "anon" "$JWT_SECRET")}"
  SUPABASE_SERVICE_ROLE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-$(generate_jwt "service_role" "$JWT_SECRET")}"

  success "Runtime configuration prepared"
}

write_env() {
  local admin_name_escaped="${AGENTGLS_ADMIN_NAME//\\/\\\\}"
  admin_name_escaped="${admin_name_escaped//\"/\\\"}"

  cat > "$INSTALL_DIR/.env" <<EOF
AGENTGLS_DASHBOARD_HOST=${AGENTGLS_DASHBOARD_HOST}
AGENTGLS_DOMAIN=${AGENTGLS_DOMAIN}
AGENTGLS_PROVIDER=${AGENTGLS_PROVIDER}
AGENTGLS_ADMIN_NAME="${admin_name_escaped}"
AGENTGLS_ADMIN_EMAIL=${AGENTGLS_ADMIN_EMAIL}
AGENTGLS_DOMAIN_SKIPPED=${AGENTGLS_DOMAIN_SKIPPED}
AGENTGLS_TELEGRAM_SKIPPED=${AGENTGLS_TELEGRAM_SKIPPED}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
JWT_SECRET=${JWT_SECRET}
SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY}
SUPABASE_SERVICE_ROLE_KEY=${SUPABASE_SERVICE_ROLE_KEY}
DASHBOARD_PASSWORD_HASH=${DASHBOARD_PASSWORD_HASH}
EOF

  chmod 600 "$INSTALL_DIR/.env"
  chown "$AGENTGLS_USER":"$AGENTGLS_USER" "$INSTALL_DIR/.env"
  success ".env written"
}

prepare_runtime_layout() {
  step "Creating runtime directories..."

  mkdir -p \
    "$INSTALL_DIR/runtime/human" \
    "$INSTALL_DIR/runtime/goalloop" \
    "$INSTALL_DIR/runtime/scheduled" \
    "$INSTALL_DIR/runtime/summary" \
    "$INSTALL_DIR/goals/active" \
    "$INSTALL_DIR/goals/paused" \
    "$INSTALL_DIR/goals/completed" \
    "$INSTALL_DIR/goals/templates" \
    "$INSTALL_DIR/goals/proof" \
    "$INSTALL_DIR/goals/locks"

  touch "$INSTALL_DIR/goals/_context.md" "$INSTALL_DIR/goals/_runbook.md"
  chown -R "$AGENTGLS_USER":"$AGENTGLS_USER" "$INSTALL_DIR/runtime" "$INSTALL_DIR/goals"
  success "Runtime layout ready"
}

install_goalloop_assets() {
  step "Installing GoalLoop runtime assets..."

  local runtime_agents_source="$INSTALL_DIR/config/runtime-agents.md"
  local claude_shim_source="$INSTALL_DIR/config/claude-shim.md"
  local template_source_dir="$INSTALL_DIR/config/goal-templates"
  local template_dest_dir="$INSTALL_DIR/goals/templates"

  if [[ ! -f "$runtime_agents_source" ]]; then
    error "Missing runtime instructions: $runtime_agents_source"
    exit 1
  fi

  if [[ ! -f "$claude_shim_source" ]]; then
    error "Missing Claude shim template: $claude_shim_source"
    exit 1
  fi

  install -m 0644 "$runtime_agents_source" "$INSTALL_DIR/AGENTS.md"
  install -m 0644 "$claude_shim_source" "$INSTALL_DIR/CLAUDE.md"

  if [[ -d "$template_source_dir" ]]; then
    for template in "$template_source_dir"/*.md; do
      [[ -f "$template" ]] || continue
      local dest="$template_dest_dir/$(basename "$template")"
      if [[ ! -f "$dest" ]]; then
        install -m 0644 "$template" "$dest"
      fi
    done
  fi

  chown "$AGENTGLS_USER":"$AGENTGLS_USER" "$INSTALL_DIR/AGENTS.md" "$INSTALL_DIR/CLAUDE.md"
  chown -R "$AGENTGLS_USER":"$AGENTGLS_USER" "$template_dest_dir"
  success "GoalLoop runtime instructions and templates installed"
}

setup_terminal_ssh() {
  step "Setting up SSH keypair for dashboard terminal access..."

  local key_path="$INSTALL_DIR/terminal-ssh-key"
  if [[ ! -f "$key_path" ]]; then
    ssh-keygen -t ed25519 -f "$key_path" -N "" -C "agentgls-terminal" >/dev/null 2>&1
    chown "$AGENTGLS_USER":"$AGENTGLS_USER" "$key_path" "${key_path}.pub"
    chmod 600 "$key_path"
    chmod 644 "${key_path}.pub"
    success "SSH keypair generated"
  else
    info "SSH keypair already exists"
  fi

  local ssh_dir="/home/$AGENTGLS_USER/.ssh"
  local auth_file="$ssh_dir/authorized_keys"
  local pub_key
  pub_key="$(cat "${key_path}.pub")"

  mkdir -p "$ssh_dir"
  touch "$auth_file"
  if ! grep -qF "agentgls-terminal" "$auth_file" 2>/dev/null; then
    echo "from=\"172.16.0.0/12\" $pub_key" >> "$auth_file"
  fi

  chmod 700 "$ssh_dir"
  chmod 600 "$auth_file"
  chown -R "$AGENTGLS_USER":"$AGENTGLS_USER" "$ssh_dir"
  success "Dashboard terminal key installed"
}

write_credentials() {
  step "Writing Supabase credentials for local scripts..."

  local cred_dir="/home/$AGENTGLS_USER/.claude/credentials"
  mkdir -p "$cred_dir"

  cat > "$cred_dir/supabase.env" <<EOF
SUPABASE_URL=http://localhost:3001
SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY}
SUPABASE_SERVICE_ROLE_KEY=${SUPABASE_SERVICE_ROLE_KEY}
EOF

  chmod 700 "$cred_dir"
  chmod 600 "$cred_dir"/*.env
  chown -R "$AGENTGLS_USER":"$AGENTGLS_USER" "/home/$AGENTGLS_USER/.claude"
  success "Local credentials written"
}

start_supabase() {
  step "Starting PostgreSQL and PostgREST..."
  cd "$INSTALL_DIR"

  docker compose up -d supabase-db 2>&1 | grep -v "^$" || true

  info "Waiting for PostgreSQL..."
  for _ in $(seq 1 30); do
    if docker exec agentgls-db pg_isready -U postgres >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if ! docker exec agentgls-db pg_isready -U postgres >/dev/null 2>&1; then
    error "PostgreSQL failed to start"
    exit 1
  fi

  docker compose up -d supabase-rest 2>&1 | grep -v "^$" || true
  sleep 2
  success "Supabase services started"
}

run_database_migrations() {
  step "Applying database migrations..."
  bash "$INSTALL_DIR/scripts/run-migrations.sh"
  success "Database migrations applied"
}

build_dashboard() {
  step "Building dashboard and terminal containers..."
  cd "$INSTALL_DIR"
  docker compose up -d --build dashboard terminal-ws 2>&1 | tail -5 || true
  sleep 3

  if curl -sf http://localhost:3000 >/dev/null 2>&1; then
    success "Dashboard ready on :3000"
  else
    warn "Dashboard may still be building (check: docker logs agentgls-dashboard)"
  fi

  if ss -tlnp | grep -q ':3002 '; then
    success "Terminal WebSocket ready on :3002"
  else
    warn "Terminal WebSocket may still be starting (check: docker logs agentgls-terminal)"
  fi
}

configure_caddy_if_requested() {
  if [[ -z "${AGENTGLS_DASHBOARD_HOST:-}" ]]; then
    info "No dashboard host provided during bootstrap; onboarding will handle domain configuration later"
    return
  fi

  step "Configuring Caddy for ${AGENTGLS_DASHBOARD_HOST}..."
  python3 - "${AGENTGLS_DASHBOARD_HOST}" <<'PY'
from pathlib import Path
import sys

host = sys.argv[1].strip()
begin = "# AGENTGLS MANAGED BEGIN"
end = "# AGENTGLS MANAGED END"
block = (
    f"{begin}\n"
    f"{host} {{\n"
    "\treverse_proxy /ws/terminal localhost:3002\n"
    "\treverse_proxy localhost:3000\n"
    "}\n"
    f"{end}\n"
)

path = Path("/etc/caddy/Caddyfile")
existing = path.read_text(encoding="utf-8") if path.exists() else ""
if begin in existing and end in existing:
    start = existing.index(begin)
    finish = existing.index(end, start) + len(end)
    updated = f"{existing[:start].rstrip()}\n\n{block}\n{existing[finish:].lstrip()}"
elif existing.strip():
    updated = f"{existing.rstrip()}\n\n{block}"
else:
    updated = block
path.write_text(updated.rstrip() + "\n", encoding="utf-8")
PY

  caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1
  if ! systemctl enable caddy --now >/dev/null 2>&1; then
    error "Failed to start Caddy"
    exit 1
  fi
  if ! systemctl reload caddy >/dev/null 2>&1; then
    if ! caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
      error "Failed to reload Caddy"
      exit 1
    fi
  fi
  success "Caddy configured"
}

install_provider_tooling() {
  local provider

  step "Installing provider CLIs..."
  for provider in claude codex; do
    info "Installing provider CLI: ${provider}"
    sudo -u "$AGENTGLS_USER" bash -lc "cd '$INSTALL_DIR' && '$INSTALL_DIR/scripts/install-provider.sh' install '$provider'"
  done
  success "Claude Code and Codex CLI installed"
}

install_crontab() {
  step "Installing base cron jobs..."

  local cron_content="# AgentGLS base maintenance
*/5 * * * * /opt/agentgls/scripts/watchdog.sh >> /opt/agentgls/logs/watchdog.log 2>&1
*/5 * * * * /opt/agentgls/scripts/sync-secrets.sh >> /opt/agentgls/logs/secrets-sync.log 2>&1
*/10 * * * * /opt/agentgls/scripts/security-sync.sh >> /opt/agentgls/logs/security.log 2>&1
*/10 * * * * /opt/agentgls/scripts/server-health.sh >> /opt/agentgls/logs/health.log 2>&1
*/30 * * * * /opt/agentgls/scripts/sync-sessions.sh >> /opt/agentgls/logs/sync.log 2>&1
0 * * * * /opt/agentgls/scripts/goalloop-heartbeat.sh >> /opt/agentgls/logs/goalloop-heartbeat.log 2>&1
*/30 * * * * /opt/agentgls/scripts/goalloop-sync.sh >> /opt/agentgls/logs/goalloop-sync.log 2>&1
0 */2 * * * /opt/agentgls/scripts/daily-summary.sh >> /opt/agentgls/logs/daily-summary.log 2>&1
0 3 * * * /opt/agentgls/scripts/memory-consolidate.sh >> /opt/agentgls/logs/memory-consolidate.log 2>&1"

  echo "$cron_content" | crontab -u "$AGENTGLS_USER" -
  success "Base cron jobs installed"
}

restore_scheduled_task_cron() {
  step "Re-syncing scheduled task cron entries..."

  if sudo -u "$AGENTGLS_USER" bash "$INSTALL_DIR/scripts/tasks.sh" sync >/dev/null 2>&1; then
    success "Scheduled task cron entries synced from database"
  else
    warn "Scheduled task cron re-sync failed; rerun /opt/agentgls/scripts/tasks.sh sync after bootstrap if tasks already exist"
  fi
}

run_initial_sync() {
  step "Running initial health sync..."
  sudo -H -u "$AGENTGLS_USER" bash "$INSTALL_DIR/scripts/watchdog.sh" 2>/dev/null || true
  sudo -u "$AGENTGLS_USER" bash "$INSTALL_DIR/scripts/security-sync.sh" 2>/dev/null || true
  sudo -u "$AGENTGLS_USER" bash "$INSTALL_DIR/scripts/server-health.sh" 2>/dev/null || true
  sudo -u "$AGENTGLS_USER" bash "$INSTALL_DIR/scripts/goalloop-sync.sh" 2>/dev/null || true
  success "Initial sync complete"
}

print_banner() {
  local server_ip
  server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  server_ip="${server_ip:-YOUR_VPS_IP}"

  echo ""
  echo -e "${GREEN}============================================${NC}"
  echo -e "${GREEN}  AgentGLS Bootstrap Complete${NC}"
  echo -e "${GREEN}============================================${NC}"
  echo ""
  echo -e "  Dashboard: ${BLUE}http://${server_ip}:3000${NC}"
  if [[ -n "${AGENTGLS_DASHBOARD_HOST:-}" ]]; then
    echo -e "  Domain:    ${BLUE}https://${AGENTGLS_DASHBOARD_HOST}${NC}"
  fi
  echo ""
  echo -e "  ${YELLOW}Next steps:${NC}"
  echo "  1. Open the dashboard in your browser"
  echo "  2. Create the admin account if it is not already configured"
  echo "  3. Choose and authenticate the active provider"
  echo "  4. Finish domain, Telegram, business context, and first-goal setup"
  echo ""
  if [[ -n "${AGENTGLS_PROVIDER:-}" ]]; then
    echo "  Selected provider from env: ${AGENTGLS_PROVIDER}"
  else
    echo "  No provider was preselected. The onboarding wizard will ask you to choose one."
  fi
  echo ""
  echo "  Manual status check:"
  echo "    bash /opt/agentgls/scripts/status.sh"
  echo ""
}

main() {
  echo ""
  echo -e "${GREEN}AgentGLS Bootstrap Installer${NC}"
  echo "=============================="
  echo ""

  check_root
  check_os
  create_user
  install_deps
  install_nodejs
  install_caddy
  clone_repo
  prepare_config
  write_env
  prepare_runtime_layout
  install_goalloop_assets
  setup_terminal_ssh
  write_credentials
  start_supabase
  run_database_migrations
  build_dashboard
  configure_caddy_if_requested
  install_provider_tooling
  install_crontab
  restore_scheduled_task_cron
  run_initial_sync
  print_banner
}

main "$@"
