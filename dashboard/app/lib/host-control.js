import fs from 'fs'
import ssh2 from 'ssh2'

const { Client } = ssh2

const SSH_HOST = process.env.SSH_HOST || 'host.docker.internal'
const SSH_USER = process.env.SSH_USER || 'agentgls'
const SSH_KEY_PATH = '/ssh-key/id_ed25519'
const HOST_INSTALL_DIR = '/opt/agentgls'
const PROVIDER_LIB_PATH = `${HOST_INSTALL_DIR}/scripts/provider-lib.sh`
const PROVIDER_AUTH_SCRIPT_PATH = `${HOST_INSTALL_DIR}/scripts/provider-auth.py`
const OPERATOR_CHAT_PATH = `${HOST_INSTALL_DIR}/scripts/operator_chat.py`
const TELEGRAM_BRIDGE_PATH = `${HOST_INSTALL_DIR}/scripts/telegram-bridge.py`
const TELEGRAM_LOG_PATH = `${HOST_INSTALL_DIR}/logs/telegram-bridge.log`
const GOALLOOP_SYNC_PATH = `${HOST_INSTALL_DIR}/scripts/goalloop-sync.sh`
const GOALLOOP_HEARTBEAT_PATH = `${HOST_INSTALL_DIR}/scripts/goalloop-heartbeat.sh`

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`
}

function readSshKey() {
  return fs.readFileSync(SSH_KEY_PATH, 'utf8')
}

export function runHostCommand(command, { stdin = '', allowFailure = false } = {}) {
  return new Promise((resolve, reject) => {
    const client = new Client()
    let stdout = ''
    let stderr = ''

    client
      .on('ready', () => {
        client.exec(`bash -lc ${shellQuote(command)}`, (error, stream) => {
          if (error) {
            client.end()
            reject(error)
            return
          }

          stream.on('close', (code) => {
            client.end()
            const result = { code: code ?? 0, stdout: stdout.trim(), stderr: stderr.trim() }
            if (!allowFailure && result.code !== 0) {
              reject(new Error(result.stderr || result.stdout || `Host command failed (${result.code})`))
              return
            }
            resolve(result)
          })

          stream.on('data', (data) => {
            stdout += data.toString()
          })

          stream.stderr.on('data', (data) => {
            stderr += data.toString()
          })

          if (stdin) {
            stream.end(stdin)
          } else {
            stream.end()
          }
        })
      })
      .on('error', (error) => {
        reject(error)
      })
      .connect({
        host: SSH_HOST,
        port: 22,
        username: SSH_USER,
        privateKey: readSshKey(),
      })
  })
}

export function runSetupAction(action, payload = {}) {
  const stdin = JSON.stringify(payload)
  return runHostCommand(`python3 ${HOST_INSTALL_DIR}/scripts/setup-instance.py ${shellQuote(action)}`, { stdin })
}

export function runProviderScript(subcommand, provider) {
  const args = [HOST_INSTALL_DIR + '/scripts/install-provider.sh', subcommand]
  if (provider) args.push(provider)
  const command = args.map(shellQuote).join(' ')
  return runHostCommand(command, { allowFailure: subcommand !== 'install' })
}

export function probeProviderScript(provider) {
  return runProviderScript('probe', provider)
}

async function parseJsonStdout(result, fallbackMessage) {
  try {
    return JSON.parse(result.stdout || '{}')
  } catch {
    throw new Error(fallbackMessage)
  }
}

export async function runProviderAuthAction(action, provider, payload = {}) {
  const stdin = JSON.stringify(payload)
  const result = await runHostCommand(
    `python3 ${shellQuote(PROVIDER_AUTH_SCRIPT_PATH)} ${shellQuote(action)} ${shellQuote(provider)}`,
    { stdin }
  )
  return parseJsonStdout(result, 'Provider auth response was not valid JSON')
}

export function getProviderAuthState(provider) {
  return runProviderAuthAction('status', provider)
}

export function startProviderAuth(provider) {
  return runProviderAuthAction('start', provider)
}

export function cancelProviderAuth(provider) {
  return runProviderAuthAction('cancel', provider)
}

export function submitProviderAuthCode(provider, value) {
  return runProviderAuthAction('submit', provider, { value })
}

export async function getTelegramBridgeState() {
  const result = await runHostCommand(
    `python3 ${shellQuote(TELEGRAM_BRIDGE_PATH)} inspect`,
    { allowFailure: true }
  )

  if (result.code !== 0) {
    throw new Error(result.stderr || result.stdout || 'Telegram bridge inspection failed')
  }

  try {
    return JSON.parse(result.stdout || '{}')
  } catch {
    throw new Error('Telegram bridge inspection returned invalid JSON')
  }
}

export function approveTelegramPair(code) {
  return runHostCommand(
    `python3 ${shellQuote(TELEGRAM_BRIDGE_PATH)} pair ${shellQuote(code)}`,
    { allowFailure: true }
  )
}

export function startTelegramBridge() {
  const script = [
    `source ${shellQuote(PROVIDER_LIB_PATH)}`,
    `bridge_script=${shellQuote(TELEGRAM_BRIDGE_PATH)}`,
    `log_file=${shellQuote(TELEGRAM_LOG_PATH)}`,
    'mkdir -p "$(dirname "$log_file")"',
    'if provider_telegram_bridge_running; then',
    '  pkill -f "python3 ${bridge_script} run" >/dev/null 2>&1 || pkill -f "${bridge_script} run" >/dev/null 2>&1 || true',
    '  sleep 1',
    'fi',
    'nohup python3 "$bridge_script" run >> "$log_file" 2>&1 < /dev/null &',
    'sleep 2',
    'if provider_telegram_bridge_running; then',
    '  echo "telegram bridge running"',
    'else',
    '  echo "telegram bridge failed to start" >&2',
    '  exit 1',
    'fi',
  ].join('\n')

  return runHostCommand(script)
}

export function stopTelegramBridge() {
  const script = [
    `source ${shellQuote(PROVIDER_LIB_PATH)}`,
    `bridge_script=${shellQuote(TELEGRAM_BRIDGE_PATH)}`,
    'if provider_telegram_bridge_running; then',
    '  pkill -f "python3 ${bridge_script} run" >/dev/null 2>&1 || pkill -f "${bridge_script} run" >/dev/null 2>&1 || true',
    '  sleep 1',
    'fi',
    'if provider_telegram_bridge_running; then',
    '  echo "telegram bridge is still running" >&2',
    '  exit 1',
    'fi',
    'echo "telegram bridge stopped"',
  ].join('\n')

  return runHostCommand(script)
}

export function configureCaddy(domain) {
  const caddyfile = [
    '# AGENTGLS MANAGED BEGIN',
    `${domain} {`,
    '\treverse_proxy /ws/terminal localhost:3002',
    '\treverse_proxy localhost:3000',
    '}',
    '# AGENTGLS MANAGED END',
    '',
  ].join('\n')
  const script = [
    'sudo mkdir -p /etc/caddy',
    `sudo python3 - ${shellQuote(domain)} <<'PY'
from pathlib import Path
import sys

host = sys.argv[1].strip()
begin = "# AGENTGLS MANAGED BEGIN"
end = "# AGENTGLS MANAGED END"
block = """${caddyfile}"""
path = Path("/etc/caddy/Caddyfile")
existing = path.read_text(encoding="utf-8") if path.exists() else ""
if begin in existing and end in existing:
    start = existing.index(begin)
    finish = existing.index(end, start) + len(end)
    updated = f"{existing[:start].rstrip()}\\n\\n{block}\\n{existing[finish:].lstrip()}"
elif existing.strip():
    updated = f"{existing.rstrip()}\\n\\n{block}"
else:
    updated = block
path.write_text(updated.rstrip() + "\\n", encoding="utf-8")
PY`,
    'sudo caddy validate --config /etc/caddy/Caddyfile >/dev/null',
    'if ! sudo systemctl enable caddy --now >/dev/null 2>&1; then echo "Failed to start Caddy" >&2; exit 1; fi',
    'if ! sudo systemctl reload caddy >/dev/null 2>&1; then if ! sudo caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1; then echo "Failed to reload Caddy" >&2; exit 1; fi; fi',
  ].join('\n')
  return runHostCommand(script)
}

export function waitForHttpsHost(domain) {
  const script = [
    `host=${shellQuote(domain)}`,
    'for attempt in $(seq 1 24); do',
    '  if curl -fsS --connect-timeout 5 --max-time 10 "https://$host" >/dev/null 2>&1; then',
    '    echo "https ready"',
    '    exit 0',
    '  fi',
    '  sleep 5',
    'done',
    'echo "HTTPS did not become ready in time" >&2',
    'exit 1',
  ].join('\n')

  return runHostCommand(script)
}

export function runGoalSync() {
  return runHostCommand(`bash ${shellQuote(GOALLOOP_SYNC_PATH)}`)
}

export async function getGoalloopRuntimeState() {
  const script = [
    `install_dir=${shellQuote(HOST_INSTALL_DIR)}`,
    `python3 - "$install_dir" <<'PY'
import importlib.util
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(sys.argv[1])
goalmeta_path = root / "scripts" / "goalmeta.py"
heartbeat_log_path = root / "logs" / "goalloop-heartbeat.log"
objective_re = re.compile(r"(?ms)^##\\s+Objective\\s*\\n+(.*?)(?=^\\s*##\\s+|\\Z)")

spec = importlib.util.spec_from_file_location("goalmeta", goalmeta_path)
goalmeta = importlib.util.module_from_spec(spec)
if spec.loader is None:
    raise RuntimeError("goalmeta loader unavailable")
spec.loader.exec_module(goalmeta)

def iso_mtime(path: Path) -> str:
    return datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

def extract_objective(body: str) -> str:
    match = objective_re.search(body)
    return match.group(1).strip() if match else ""

def collect(status_dir: str) -> list[dict]:
    goal_dir = root / "goals" / status_dir
    items = []
    if not goal_dir.exists():
        return items
    for path in sorted(goal_dir.glob("*.md"), key=lambda value: value.stat().st_mtime, reverse=True):
        if not path.is_file() or path.name.startswith("_"):
            continue
        front_matter, body = goalmeta.parse_goal(path)
        items.append(
            {
                "slug": path.stem,
                "title": str(front_matter.get("title") or path.stem),
                "status": status_dir,
                "priority": str(front_matter.get("priority") or "medium"),
                "brief_status": str(front_matter.get("brief_status") or "draft"),
                "run_state": str(front_matter.get("run_state") or "idle"),
                "approval_policy": str(front_matter.get("approval_policy") or "auto"),
                "heartbeat_minutes": int(front_matter.get("heartbeat_minutes") or 60),
                "last_run": front_matter.get("last_run"),
                "next_eligible_at": front_matter.get("next_eligible_at"),
                "deadline_at": front_matter.get("deadline_at"),
                "parent": front_matter.get("parent"),
                "updated_at": iso_mtime(path),
                "objective": extract_objective(body),
            }
        )
    return items

process_result = subprocess.run(
    ["pgrep", "-af", "[g]oalloop-heartbeat.sh"],
    capture_output=True,
    text=True,
    check=False,
)
processes = [line.strip() for line in process_result.stdout.splitlines() if line.strip()]
log_tail = []
if heartbeat_log_path.exists():
    log_tail = heartbeat_log_path.read_text(encoding="utf-8", errors="replace").splitlines()[-20:]

print(
    json.dumps(
        {
            "activeGoals": collect("active"),
            "pausedGoals": collect("paused"),
            "completedGoals": collect("completed"),
            "heartbeat": {
                "running": bool(processes),
                "processes": processes,
                "logTail": log_tail,
            },
        }
    )
)
PY`,
  ].join('\n')

  const result = await runHostCommand(script)
  return parseJsonStdout(result, 'GoalLoop runtime response was not valid JSON')
}

export function triggerGoalloopHeartbeat() {
  const script = [
    `heartbeat_script=${shellQuote(GOALLOOP_HEARTBEAT_PATH)}`,
    `heartbeat_log=${shellQuote(`${HOST_INSTALL_DIR}/logs/goalloop-heartbeat.log`)}`,
    'nohup bash "$heartbeat_script" >> "$heartbeat_log" 2>&1 < /dev/null &',
    'echo "GoalLoop heartbeat triggered"',
  ].join('\n')

  return runHostCommand(script)
}

export async function getDashboardChat(limit = 200) {
  const normalizedLimit = Number.isFinite(limit) ? Math.max(1, Math.min(500, Math.trunc(limit))) : 200
  const result = await runHostCommand(
    `python3 ${shellQuote(OPERATOR_CHAT_PATH)} recent --limit ${normalizedLimit}`
  )
  return parseJsonStdout(result, 'Dashboard chat response was not valid JSON')
}

export async function sendDashboardChatMessage(text, displayName = '') {
  const payload = JSON.stringify({ text, display_name: displayName })
  const result = await runHostCommand(
    `python3 ${shellQuote(OPERATOR_CHAT_PATH)} send-dashboard`,
    { stdin: payload }
  )
  return parseJsonStdout(result, 'Dashboard chat send response was not valid JSON')
}
