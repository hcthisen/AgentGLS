#!/bin/bash
# server-health.sh — Collect server metrics and push to Supabase
# Runs every 10 minutes via cron

set -euo pipefail

CRED_FILE="$HOME/.claude/credentials/supabase.env"
if [[ -f "$CRED_FILE" ]]; then source "$CRED_FILE"; else echo "$(date) ERROR: $CRED_FILE not found" >&2; exit 1; fi

SUPABASE_URL="${SUPABASE_URL:-http://localhost:3001}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Collect Metrics ---

# Uptime
UPTIME=$(uptime -p 2>/dev/null || uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1}')

# CPU
CPU_PERCENT=$(awk '/^cpu /{u=$2+$4; t=$2+$3+$4+$5+$6+$7+$8; if(t>0) printf "%.1f", u*100/t}' /proc/stat 2>/dev/null || echo "0")

# RAM
RAM_INFO=$(free -m 2>/dev/null | awk '/^Mem:/{print $3" "$2}')
RAM_USED=$(echo "$RAM_INFO" | awk '{print $1}')
RAM_TOTAL=$(echo "$RAM_INFO" | awk '{print $2}')

# Disk
DISK_INFO=$(df -BG / 2>/dev/null | awk 'NR==2{gsub("G",""); print $3" "$2}')
DISK_USED=$(echo "$DISK_INFO" | awk '{print $1}')
DISK_TOTAL=$(echo "$DISK_INFO" | awk '{print $2}')

# Load
LOAD_AVG=$(cat /proc/loadavg 2>/dev/null | awk '{print $1", "$2", "$3}' || echo "0, 0, 0")

# Connections
ACTIVE_CONN=$(ss -tun 2>/dev/null | tail -n +2 | wc -l || echo "0")

# Docker containers
DOCKER_CONTAINERS=$(docker ps --format '{"name":"{{.Names}}","status":"{{.Status}}","image":"{{.Image}}"}' 2>/dev/null | python3 -c "
import json, sys
containers = []
for line in sys.stdin:
    line = line.strip()
    if line:
        containers.append(json.loads(line))
print(json.dumps(containers))
" 2>/dev/null || echo "[]")

# Services
svc_caddy=$(systemctl is-active caddy 2>/dev/null | head -1 || echo "inactive")
svc_fail2ban=$(systemctl is-active fail2ban 2>/dev/null | head -1 || echo "inactive")
svc_docker=$(systemctl is-active docker 2>/dev/null | head -1 || echo "inactive")
svc_ssh=$(systemctl is-active ssh 2>/dev/null | head -1 || echo "inactive")
svc_supabase=$(curl -sf http://localhost:3001/ >/dev/null 2>&1 && echo "reachable" || echo "unreachable")

SERVICES=$(python3 -c "import json; print(json.dumps({'caddy':'${svc_caddy}','fail2ban':'${svc_fail2ban}','docker':'${svc_docker}','ssh':'${svc_ssh}','supabase':'${svc_supabase}'}))" 2>/dev/null || echo '{}')

# Claude Code status
CLAUDE_STATUS=$(python3 -c "
import json, subprocess, os, glob

status = {'running': False, 'telegram': False, 'tmux_session': False, 'total_sessions': 0}

# Check tmux
try:
    r = subprocess.run(['tmux', 'has-session', '-t', 'claude'], capture_output=True, timeout=5)
    status['tmux_session'] = r.returncode == 0
except:
    pass

# Check claude process
try:
    r = subprocess.run(['pgrep', '-f', 'claude.*--continue'], capture_output=True, text=True, timeout=5)
    status['running'] = r.returncode == 0
    if status['running']:
        r2 = subprocess.run(['pgrep', '-f', 'telegram'], capture_output=True, text=True, timeout=5)
        status['telegram'] = r2.returncode == 0
except:
    pass

# Count sessions
home = os.path.expanduser('~')
session_dir = os.path.join(home, '.claude', 'projects', '-root')
try:
    status['total_sessions'] = len(glob.glob(os.path.join(session_dir, '*.jsonl')))
except:
    pass

print(json.dumps(status))
" 2>/dev/null || echo '{}')

# Open ports
OPEN_PORTS=$(ss -tlnp 2>/dev/null | awk 'NR>1{print "{\"port\":\""$4"\",\"process\":\""$7"\"}"}' | python3 -c "
import json, sys
ports = []
for line in sys.stdin:
    line = line.strip()
    if line:
        try: ports.append(json.loads(line))
        except: pass
print(json.dumps(ports))
" 2>/dev/null || echo "[]")

# Top attackers (from fail2ban log)
TOP_ATTACKERS=$(python3 -c "
import json, re, collections
attackers = collections.Counter()
try:
    with open('/var/log/fail2ban.log', 'r') as f:
        for line in f:
            m = re.search(r'Ban (\d+\.\d+\.\d+\.\d+)', line)
            if m:
                attackers[m.group(1)] += 1
    top = [{'ip': ip, 'count': count} for ip, count in attackers.most_common(10)]
    print(json.dumps(top))
except:
    print('[]')
" 2>/dev/null || echo "[]")

# Failed logins per day (last 7 days)
FAILED_PER_DAY=$(python3 -c "
import json, subprocess, re, collections
from datetime import datetime, timedelta
daily = collections.OrderedDict()
for i in range(7):
    d = (datetime.now() - timedelta(days=i)).strftime('%Y-%m-%d')
    daily[d] = 0
try:
    with open('/var/log/auth.log', 'r') as f:
        for line in f:
            if 'Failed password' in line or 'authentication failure' in line:
                # Extract date
                parts = line.split()
                if len(parts) >= 3:
                    month_day = f'{parts[0]} {parts[1]}'
                    try:
                        d = datetime.strptime(f'{datetime.now().year} {month_day}', '%Y %b %d').strftime('%Y-%m-%d')
                        if d in daily:
                            daily[d] += 1
                    except:
                        pass
except:
    pass
print(json.dumps([{'date': k, 'count': v} for k, v in daily.items()]))
" 2>/dev/null || echo "[]")

# System overview (call system-overview.sh)
SYSTEM_OVERVIEW="{}"
if [[ -x "$SCRIPT_DIR/system-overview.sh" ]]; then
  SYSTEM_OVERVIEW=$("$SCRIPT_DIR/system-overview.sh" 2>/dev/null || echo "{}")
fi

# --- Push to Supabase ---

PAYLOAD=$(
  H_UPTIME="$UPTIME" \
  H_CPU="${CPU_PERCENT:-0}" \
  H_RAM_USED="${RAM_USED:-0}" \
  H_RAM_TOTAL="${RAM_TOTAL:-0}" \
  H_DISK_USED="${DISK_USED:-0}" \
  H_DISK_TOTAL="${DISK_TOTAL:-0}" \
  H_LOAD="$LOAD_AVG" \
  H_CONN="${ACTIVE_CONN:-0}" \
  H_DOCKER="$DOCKER_CONTAINERS" \
  H_SERVICES="$SERVICES" \
  H_CLAUDE="$CLAUDE_STATUS" \
  H_PORTS="$OPEN_PORTS" \
  H_ATTACKERS="$TOP_ATTACKERS" \
  H_FAILED="$FAILED_PER_DAY" \
  H_OVERVIEW="$SYSTEM_OVERVIEW" \
  python3 -c "
import json, os
from datetime import datetime, timezone
data = {
    'id': 1,
    'uptime': os.environ.get('H_UPTIME', ''),
    'cpu_percent': float(os.environ.get('H_CPU', '0')),
    'ram_used_mb': int(os.environ.get('H_RAM_USED', '0')),
    'ram_total_mb': int(os.environ.get('H_RAM_TOTAL', '0')),
    'disk_used_gb': float(os.environ.get('H_DISK_USED', '0')),
    'disk_total_gb': float(os.environ.get('H_DISK_TOTAL', '0')),
    'load_avg': os.environ.get('H_LOAD', '0, 0, 0'),
    'active_connections': int(os.environ.get('H_CONN', '0')),
    'docker_containers': json.loads(os.environ.get('H_DOCKER', '[]')),
    'services': json.loads(os.environ.get('H_SERVICES', '{}')),
    'claude_status': json.loads(os.environ.get('H_CLAUDE', '{}')),
    'open_ports': json.loads(os.environ.get('H_PORTS', '[]')),
    'top_attackers': json.loads(os.environ.get('H_ATTACKERS', '[]')),
    'failed_per_day': json.loads(os.environ.get('H_FAILED', '[]')),
    'system_overview': json.loads(os.environ.get('H_OVERVIEW', '{}')),
    'last_updated': datetime.now(timezone.utc).isoformat()
}
print(json.dumps(data))
" 2>/dev/null)

curl -sf -X PATCH "${SUPABASE_URL}/cc_server_health?id=eq.1" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" >/dev/null 2>&1

echo "$(date '+%Y-%m-%d %H:%M:%S') Health metrics updated"
