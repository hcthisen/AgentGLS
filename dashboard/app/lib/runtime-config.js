import fs from 'fs'
import path from 'path'

export const HOST_MOUNT = process.env.AGENTGLS_HOST_MOUNT || '/opt/agentgls-host'
export const ENV_PATH = path.join(HOST_MOUNT, '.env')
export const GOALS_PATH = path.join(HOST_MOUNT, 'goals')

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

export function parseEnvContent(content) {
  const env = {}
  for (const rawLine of content.split(/\r?\n/)) {
    const line = rawLine.trim()
    if (!line || line.startsWith('#')) continue
    const idx = rawLine.indexOf('=')
    if (idx === -1) continue
    const key = rawLine.slice(0, idx)
    const value = rawLine.slice(idx + 1)
    env[key] = decodeEnvValue(value)
  }
  return env
}

export function readRuntimeEnv() {
  try {
    const content = fs.readFileSync(ENV_PATH, 'utf8')
    return parseEnvContent(content)
  } catch {
    return {}
  }
}

export function getRuntimeEnvValue(key, fallback = '') {
  const runtimeEnv = readRuntimeEnv()
  if (runtimeEnv[key] !== undefined) return runtimeEnv[key]
  if (process.env[key] !== undefined) return process.env[key]
  return fallback
}

export function fileExists(targetPath) {
  try {
    return fs.existsSync(targetPath)
  } catch {
    return false
  }
}

export function readTextFile(targetPath) {
  try {
    return fs.readFileSync(targetPath, 'utf8')
  } catch {
    return ''
  }
}
