import fs from 'fs'
import ssh2 from 'ssh2'

const { Client } = ssh2

const SSH_HOST = process.env.SSH_HOST || 'host.docker.internal'
const SSH_USER = process.env.SSH_USER || 'agentgls'
const SSH_KEY_PATH = '/ssh-key/id_ed25519'
const HOST_INSTALL_DIR = '/opt/agentgls'

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

export function configureCaddy(domain) {
  const caddyfile = `dashboard.${domain} {\n\treverse_proxy /ws/terminal localhost:3002\n\treverse_proxy localhost:3000\n}\n`
  const script = [
    'sudo mkdir -p /etc/caddy',
    `cat <<'EOF' | sudo tee /etc/caddy/Caddyfile >/dev/null\n${caddyfile}EOF`,
    'sudo systemctl enable caddy --now >/dev/null 2>&1 || true',
    'sudo systemctl reload caddy >/dev/null 2>&1 || sudo caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true',
  ].join('\n')
  return runHostCommand(script)
}
