const http = require('http')
const { WebSocketServer } = require('ws')
const { Client } = require('ssh2')
const crypto = require('crypto')
const fs = require('fs')
const path = require('path')

const PORT = 3002
const SSH_HOST = process.env.SSH_HOST || 'host.docker.internal'
const SSH_USER = process.env.SSH_USER || 'agentos'
const SSH_KEY_PATH = '/ssh-key/id_ed25519'
const HOST_MOUNT = process.env.AGENTOS_HOST_MOUNT || '/opt/agentos-host'
const ENV_PATH = path.join(HOST_MOUNT, '.env')
const IDLE_TIMEOUT = 60 * 60 * 1000 // 60 minutes
const PING_INTERVAL = 45 * 1000 // 45 seconds
const MAX_MISSED_PONGS = 3 // tolerate 3 missed pongs (background tabs throttle timers)

function decodeEnvValue(value) {
  const trimmed = value.trim()
  if (
    trimmed.length >= 2 &&
    ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
      (trimmed.startsWith("'") && trimmed.endsWith("'")))
  ) {
    return trimmed.slice(1, -1).replace(/\\"/g, '"').replace(/\\\\/g, '\\')
  }
  return trimmed
}

function readRuntimeEnv() {
  try {
    const content = fs.readFileSync(ENV_PATH, 'utf8')
    const env = {}
    for (const rawLine of content.split(/\r?\n/)) {
      const line = rawLine.trim()
      if (!line || line.startsWith('#')) continue
      const idx = rawLine.indexOf('=')
      if (idx === -1) continue
      env[rawLine.slice(0, idx)] = decodeEnvValue(rawLine.slice(idx + 1))
    }
    return env
  } catch {
    return {}
  }
}

function verifySession(cookieHeader) {
  if (!cookieHeader) return false
  const env = readRuntimeEnv()
  const cookies = Object.fromEntries(
    cookieHeader.split(';').map(c => {
      const [k, ...v] = c.trim().split('=')
      return [k, v.join('=')]
    })
  )
  const sessionToken = cookies['dashboard_session']
  if (!sessionToken) return false
  const expected = crypto.createHash('sha256')
    .update((env.DASHBOARD_PASSWORD_HASH || '') + (env.JWT_SECRET || ''))
    .digest('hex')
  return sessionToken === expected
}

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' })
  res.end('AgentGLS Terminal WebSocket Server')
})

const wss = new WebSocketServer({ server })

wss.on('connection', (ws, req) => {
  // Verify authentication
  if (!verifySession(req.headers.cookie)) {
    ws.close(4001, 'Unauthorized')
    return
  }

  console.log(`[${new Date().toISOString()}] Terminal session opened`)

  let sshStream = null
  let idleTimer = null
  let pingTimer = null
  let missedPongs = 0

  const resetIdleTimer = () => {
    if (idleTimer) clearTimeout(idleTimer)
    idleTimer = setTimeout(() => {
      console.log('Idle timeout — closing session')
      ws.close(4002, 'Idle timeout')
    }, IDLE_TIMEOUT)
  }
  resetIdleTimer()

  // Heartbeat: detect dead connections (e.g., client navigated away without clean close)
  // Tolerate multiple missed pongs since background tabs throttle WebSocket timers
  pingTimer = setInterval(() => {
    missedPongs++
    if (missedPongs > MAX_MISSED_PONGS) {
      console.log(`Client unresponsive (${missedPongs} missed pongs) — terminating session`)
      ws.terminate()
      return
    }
    ws.ping()
  }, PING_INTERVAL)

  ws.on('pong', () => { missedPongs = 0 })

  // Read SSH key
  let privateKey
  try {
    privateKey = fs.readFileSync(SSH_KEY_PATH, 'utf8')
  } catch (err) {
    console.error('Failed to read SSH key:', err.message)
    ws.close(4003, 'SSH key not available')
    return
  }

  // Establish SSH connection
  const ssh = new Client()

  ssh.on('ready', () => {
    ssh.shell({ term: 'xterm-256color', cols: 80, rows: 24 }, (err, stream) => {
      if (err) {
        console.error('SSH shell error:', err.message)
        ws.close(4004, 'SSH shell failed')
        return
      }

      sshStream = stream

      // SSH → WebSocket
      stream.on('data', (data) => {
        resetIdleTimer()
        if (ws.readyState === 1) {
          ws.send(data)
        }
      })

      stream.on('close', () => {
        console.log(`[${new Date().toISOString()}] SSH stream closed`)
        ws.close()
      })

      stream.stderr.on('data', (data) => {
        if (ws.readyState === 1) ws.send(data)
      })
    })
  })

  ssh.on('error', (err) => {
    console.error('SSH error:', err.message)
    ws.close(4005, 'SSH connection failed')
  })

  ssh.connect({
    host: SSH_HOST,
    port: 22,
    username: SSH_USER,
    privateKey,
  })

  // WebSocket → SSH
  ws.on('message', (data) => {
    resetIdleTimer()
    if (!sshStream) return

    const buf = Buffer.from(data)

    // Check for resize command (prefix byte 0x00)
    if (buf.length > 1 && buf[0] === 0) {
      try {
        const dims = JSON.parse(buf.slice(1).toString())
        if (dims.cols && dims.rows) {
          sshStream.setWindow(dims.rows, dims.cols, 0, 0)
        }
      } catch {
        // Not a resize command, treat as regular input
        sshStream.write(buf)
      }
      return
    }

    sshStream.write(buf)
  })

  ws.on('close', () => {
    console.log(`[${new Date().toISOString()}] Terminal session closed`)
    if (idleTimer) clearTimeout(idleTimer)
    if (pingTimer) clearInterval(pingTimer)
    ssh.end()
  })

  ws.on('error', (err) => {
    console.error('WebSocket error:', err.message)
    ssh.end()
  })
})

server.listen(PORT, () => {
  console.log(`Terminal WebSocket server listening on port ${PORT}`)
  console.log(`SSH target: ${SSH_USER}@${SSH_HOST}`)
})
