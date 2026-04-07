#!/bin/bash
# ============================================================
# AgentGLS Bootstrap Installer
# Install the host stack, expose the dashboard, and leave the
# rest of setup to the browser onboarding flow.
# ============================================================

set -euo pipefail

AGENTOS_USER="agentos"
INSTALL_DIR="${AGENTOS_DIR:-/opt/agentos}"
REPO_URL="https://github.com/hcthisen/AgentGLS.git"
REPO_BRANCH="${AGENTOS_BRANCH:-main}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }
step()    { echo -e "\n${GREEN}>>>${NC} $*"; }

OVERRIDE_AGENTOS_DOMAIN="${AGENTOS_DOMAIN:-}"
OVERRIDE_AGENTGLS_PROVIDER="${AGENTGLS_PROVIDER:-}"
OVERRIDE_ADMIN_NAME="${AGENTGLS_ADMIN_NAME:-}"
OVERRIDE_ADMIN_EMAIL="${AGENTGLS_ADMIN_EMAIL:-}"
OVERRIDE_DASHBOARD_PASSWORD="${AGENTOS_DASHBOARD_PASSWORD:-}"
OVERRIDE_TELEGRAM_TOKEN="${TELEGRAM_BOT_TOKEN:-${AGENTOS_TELEGRAM_TOKEN:-}}"

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
  if id "$AGENTOS_USER" &>/dev/null; then
    info "User '$AGENTOS_USER' already exists"
    return
  fi

  step "Creating user '$AGENTOS_USER'..."
  useradd -m -s /bin/bash "$AGENTOS_USER"
  echo "$AGENTOS_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agentos
  chmod 440 /etc/sudoers.d/agentos
  success "User '$AGENTOS_USER' created with passwordless sudo"
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

  usermod -aG docker "$AGENTOS_USER"

  apt-get update -qq
  apt-get install -y -qq \
    tmux \
    fail2ban \
    python3 \
    python3-pip \
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
  chown -R "$AGENTOS_USER":"$AGENTOS_USER" "$INSTALL_DIR"
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

  AGENTOS_DOMAIN="${OVERRIDE_AGENTOS_DOMAIN:-${AGENTOS_DOMAIN:-}}"
  AGENTGLS_PROVIDER="${OVERRIDE_AGENTGLS_PROVIDER:-${AGENTGLS_PROVIDER:-}}"
  AGENTGLS_ADMIN_NAME="${OVERRIDE_ADMIN_NAME:-${AGENTGLS_ADMIN_NAME:-}}"
  AGENTGLS_ADMIN_EMAIL="${OVERRIDE_ADMIN_EMAIL:-${AGENTGLS_ADMIN_EMAIL:-}}"
  TELEGRAM_BOT_TOKEN="${OVERRIDE_TELEGRAM_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
  AGENTGLS_DOMAIN_SKIPPED="${AGENTGLS_DOMAIN_SKIPPED:-0}"
  AGENTGLS_TELEGRAM_SKIPPED="${AGENTGLS_TELEGRAM_SKIPPED:-0}"

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
AGENTOS_DOMAIN=${AGENTOS_DOMAIN}
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
  chown "$AGENTOS_USER":"$AGENTOS_USER" "$INSTALL_DIR/.env"
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
  chown -R "$AGENTOS_USER":"$AGENTOS_USER" "$INSTALL_DIR/runtime" "$INSTALL_DIR/goals"
  success "Runtime layout ready"
}

setup_terminal_ssh() {
  step "Setting up SSH keypair for dashboard terminal access..."

  local key_path="$INSTALL_DIR/terminal-ssh-key"
  if [[ ! -f "$key_path" ]]; then
    ssh-keygen -t ed25519 -f "$key_path" -N "" -C "agentos-terminal" >/dev/null 2>&1
    chown "$AGENTOS_USER":"$AGENTOS_USER" "$key_path" "${key_path}.pub"
    chmod 600 "$key_path"
    chmod 644 "${key_path}.pub"
    success "SSH keypair generated"
  else
    info "SSH keypair already exists"
  fi

  local ssh_dir="/home/$AGENTOS_USER/.ssh"
  local auth_file="$ssh_dir/authorized_keys"
  local pub_key
  pub_key="$(cat "${key_path}.pub")"

  mkdir -p "$ssh_dir"
  touch "$auth_file"
  if ! grep -qF "agentos-terminal" "$auth_file" 2>/dev/null; then
    echo "from=\"172.16.0.0/12\" $pub_key" >> "$auth_file"
  fi

  chmod 700 "$ssh_dir"
  chmod 600 "$auth_file"
  chown -R "$AGENTOS_USER":"$AGENTOS_USER" "$ssh_dir"
  success "Dashboard terminal key installed"
}

write_credentials() {
  step "Writing Supabase credentials for local scripts..."

  local cred_dir="/home/$AGENTOS_USER/.claude/credentials"
  mkdir -p "$cred_dir"

  cat > "$cred_dir/supabase.env" <<EOF
SUPABASE_URL=http://localhost:3001
SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY}
SUPABASE_SERVICE_ROLE_KEY=${SUPABASE_SERVICE_ROLE_KEY}
EOF

  chmod 700 "$cred_dir"
  chmod 600 "$cred_dir"/*.env
  chown -R "$AGENTOS_USER":"$AGENTOS_USER" "/home/$AGENTOS_USER/.claude"
  success "Local credentials written"
}

start_supabase() {
  step "Starting PostgreSQL and PostgREST..."
  cd "$INSTALL_DIR"

  docker compose up -d supabase-db 2>&1 | grep -v "^$" || true

  info "Waiting for PostgreSQL..."
  for _ in $(seq 1 30); do
    if docker exec agentos-db pg_isready -U postgres >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if ! docker exec agentos-db pg_isready -U postgres >/dev/null 2>&1; then
    error "PostgreSQL failed to start"
    exit 1
  fi

  docker compose up -d supabase-rest 2>&1 | grep -v "^$" || true
  sleep 2
  success "Supabase services started"
}

build_dashboard() {
  step "Building dashboard and terminal containers..."
  cd "$INSTALL_DIR"
  docker compose up -d --build dashboard terminal-ws 2>&1 | tail -5 || true
  sleep 3

  if curl -sf http://localhost:3000 >/dev/null 2>&1; then
    success "Dashboard ready on :3000"
  else
    warn "Dashboard may still be building (check: docker logs agentos-dashboard)"
  fi

  if ss -tlnp | grep -q ':3002 '; then
    success "Terminal WebSocket ready on :3002"
  else
    warn "Terminal WebSocket may still be starting (check: docker logs agentos-terminal)"
  fi
}

configure_caddy_if_requested() {
  if [[ -z "${AGENTOS_DOMAIN:-}" ]]; then
    info "No domain provided during bootstrap; onboarding will handle domain configuration later"
    return
  fi

  step "Configuring Caddy for dashboard.${AGENTOS_DOMAIN}..."
  cat > /etc/caddy/Caddyfile <<EOF
dashboard.${AGENTOS_DOMAIN} {
	reverse_proxy /ws/terminal localhost:3002
	reverse_proxy localhost:3000
}
EOF

  systemctl enable caddy --now 2>/dev/null || true
  systemctl reload caddy 2>/dev/null || caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true
  success "Caddy configured"
}

install_provider_if_selected() {
  if [[ -z "${AGENTGLS_PROVIDER:-}" ]]; then
    info "No provider selected during bootstrap; onboarding will install the chosen provider later"
    return
  fi

  step "Installing selected provider: ${AGENTGLS_PROVIDER}"
  sudo -u "$AGENTOS_USER" bash -lc "cd '$INSTALL_DIR' && '$INSTALL_DIR/scripts/install-provider.sh' install '$AGENTGLS_PROVIDER'"
  success "Provider installation finished"
}

install_crontab() {
  step "Installing base cron jobs..."

  local cron_content="# AgentGLS base maintenance
*/5 * * * * /opt/agentos/scripts/sync-secrets.sh >> /opt/agentos/logs/secrets-sync.log 2>&1
*/10 * * * * /opt/agentos/scripts/security-sync.sh >> /opt/agentos/logs/security.log 2>&1
*/10 * * * * /opt/agentos/scripts/server-health.sh >> /opt/agentos/logs/health.log 2>&1
*/30 * * * * /opt/agentos/scripts/sync-sessions.sh >> /opt/agentos/logs/sync.log 2>&1"

  echo "$cron_content" | crontab -u "$AGENTOS_USER" -
  success "Base cron jobs installed"
}

run_initial_sync() {
  step "Running initial health sync..."
  sudo -u "$AGENTOS_USER" bash "$INSTALL_DIR/scripts/security-sync.sh" 2>/dev/null || true
  sudo -u "$AGENTOS_USER" bash "$INSTALL_DIR/scripts/server-health.sh" 2>/dev/null || true
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
  if [[ -n "${AGENTOS_DOMAIN:-}" ]]; then
    echo -e "  Domain:    ${BLUE}https://dashboard.${AGENTOS_DOMAIN}${NC}"
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
  echo "    bash /opt/agentos/scripts/status.sh"
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
  setup_terminal_ssh
  write_credentials
  start_supabase
  build_dashboard
  configure_caddy_if_requested
  install_provider_if_selected
  install_crontab
  run_initial_sync
  print_banner
}

main "$@"
