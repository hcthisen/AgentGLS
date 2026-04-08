import fs from 'fs'
import ssh2 from 'ssh2'

const { Client } = ssh2

const SSH_HOST = process.env.SSH_HOST || 'host.docker.internal'
const SSH_USER = process.env.SSH_USER || 'agentgls'
const SSH_KEY_PATH = '/ssh-key/id_ed25519'
const HOST_INSTALL_DIR = '/opt/agentgls'
const PROVIDER_LIB_PATH = `${HOST_INSTALL_DIR}/scripts/provider-lib.sh`
const PROVIDER_AUTH_SCRIPT_PATH = `${HOST_INSTALL_DIR}/scripts/provider-auth.py`
const TELEGRAM_BRIDGE_PATH = `${HOST_INSTALL_DIR}/scripts/telegram-bridge.py`
const TELEGRAM_LOG_PATH = `${HOST_INSTALL_DIR}/logs/telegram-bridge.log`

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
