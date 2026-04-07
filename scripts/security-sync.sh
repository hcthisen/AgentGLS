#!/bin/bash
# security-sync.sh — Sync fail2ban bans + login history to Supabase
# Runs every 10 minutes via cron

set -euo pipefail

CRED_FILE="$HOME/.claude/credentials/supabase.env"
if [[ -f "$CRED_FILE" ]]; then source "$CRED_FILE"; else echo "$(date) ERROR: $CRED_FILE not found" >&2; exit 1; fi

SUPABASE_URL="${SUPABASE_URL:-http://localhost:3001}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# --- Sync fail2ban bans ---

sync_bans() {
  if ! command -v fail2ban-client &>/dev/null; then
    log "fail2ban not installed, skipping ban sync"
    return
  fi

  local banned_ips
  banned_ips=$(fail2ban-client status sshd 2>/dev/null | grep "Banned IP list" | sed 's/.*Banned IP list:\s*//' | tr ' ' '\n' | grep -v '^$') || true

  if [[ -z "$banned_ips" ]]; then
    log "No banned IPs"
    return
  fi

  local count=0
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue

    # Check if already in DB
    local existing
    existing=$(curl -sf "${SUPABASE_URL}/cc_security_bans?ip=eq.${ip}&select=ip" \
      -H "apikey: ${SUPABASE_KEY}" \
      -H "Authorization: Bearer ${SUPABASE_KEY}" 2>/dev/null || echo "[]")

    if echo "$existing" | grep -q "$ip"; then
      continue
    fi

    # GeoIP lookup (rate limited: 45/min)
    local country="" country_code=""
    local geo
    geo=$(curl -sf "http://ip-api.com/json/${ip}?fields=country,countryCode" 2>/dev/null || echo "{}")
    country=$(echo "$geo" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('country',''))" 2>/dev/null || true)
    country_code=$(echo "$geo" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('countryCode',''))" 2>/dev/null || true)

    # Insert ban
    curl -sf -X POST "${SUPABASE_URL}/cc_security_bans" \
      -H "apikey: ${SUPABASE_KEY}" \
      -H "Authorization: Bearer ${SUPABASE_KEY}" \
      -H "Content-Type: application/json" \
      -H "Prefer: resolution=merge-duplicates" \
      -d "{\"ip\":\"${ip}\",\"jail\":\"sshd\",\"country\":\"${country}\",\"country_code\":\"${country_code}\"}" >/dev/null 2>&1 || true

    count=$((count + 1))
    # Brief pause to respect GeoIP rate limit
    sleep 0.1
  done <<< "$banned_ips"

  log "Synced $count new ban(s)"
}

# --- Sync login history ---

sync_logins() {
  # Delete existing logins and re-insert fresh data
  curl -sf -X DELETE "${SUPABASE_URL}/cc_security_logins?id=neq.00000000-0000-0000-0000-000000000000" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" >/dev/null 2>&1 || true

  # Get recent logins
  local logins
  logins=$(last -n 50 -w 2>/dev/null | head -50) || true

  echo "$logins" | python3 -c "
import json, sys, subprocess, os

supabase_url = os.environ.get('SUPABASE_URL', 'http://localhost:3001')
supabase_key = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')

entries = []
for line in sys.stdin:
    line = line.strip()
    if not line or line.startswith('wtmp') or line.startswith('reboot'):
        continue
    parts = line.split()
    if len(parts) < 4:
        continue
    user = parts[0]
    session_type = parts[1]
    ip = parts[2] if len(parts) > 6 else ''
    # Try to extract login time
    login_at = ' '.join(parts[3:6]) if len(parts) > 5 else ''
    duration = parts[-1] if '(' in parts[-1] else ''

    entries.append({
        'user_name': user,
        'ip': ip,
        'login_at': login_at,
        'session_type': session_type,
        'duration': duration
    })

# Add tmux sessions
import subprocess as sp
try:
    result = sp.run(['tmux', 'list-sessions', '-F', '#{session_name} #{session_created}'],
                    capture_output=True, text=True, timeout=5)
    for line in result.stdout.strip().split('\n'):
        if line:
            parts = line.split(' ', 1)
            entries.append({
                'user_name': 'root',
                'ip': '',
                'login_at': parts[1] if len(parts) > 1 else '',
                'session_type': f'tmux (Claude Code)' if 'claude' in parts[0] else f'tmux ({parts[0]})',
                'duration': 'active'
            })
except:
    pass

# Batch insert
if entries:
    data = json.dumps(entries)
    sp.run([
        'curl', '-sf', '-X', 'POST',
        f'{supabase_url}/cc_security_logins',
        '-H', f'apikey: {supabase_key}',
        '-H', f'Authorization: Bearer {supabase_key}',
        '-H', 'Content-Type: application/json',
        '-d', data
    ], capture_output=True)
    print(f'Inserted {len(entries)} login entries')
" 2>/dev/null || true
}

# --- Sync aggregate stats ---

sync_stats() {
  local total_banned=0 total_failed=0 total_logins=0

  if command -v fail2ban-client &>/dev/null; then
    total_banned=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}') || true
    total_failed=$(fail2ban-client status sshd 2>/dev/null | grep "Total failed" | awk '{print $NF}') || true
  fi
  total_logins=$(last -n 1000 2>/dev/null | grep -c -v "^$\|^wtmp\|^reboot") || true

  curl -sf -X PATCH "${SUPABASE_URL}/cc_security_stats?id=eq.1" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"total_banned\":${total_banned:-0},\"total_failed\":${total_failed:-0},\"total_logins\":${total_logins:-0},\"last_updated\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"}" >/dev/null 2>&1 || true

  log "Stats: banned=${total_banned:-0} failed=${total_failed:-0} logins=${total_logins:-0}"
}

# --- Main ---

log "Starting security sync..."
sync_bans
sync_logins
sync_stats
log "Security sync complete"
