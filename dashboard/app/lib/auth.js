import { createHash } from 'crypto'
import { readRuntimeEnv } from './runtime-config'

export function getDashboardAuthConfig() {
  const env = readRuntimeEnv()
  return {
    adminName: env.AGENTGLS_ADMIN_NAME || '',
    adminEmail: env.AGENTGLS_ADMIN_EMAIL || '',
    passwordHash: env.DASHBOARD_PASSWORD_HASH || '',
    jwtSecret: env.JWT_SECRET || process.env.JWT_SECRET || '',
  }
}

export function isAdminConfigured() {
  const config = getDashboardAuthConfig()
  return Boolean(config.passwordHash && config.adminEmail)
}

export function buildSessionToken() {
  const { passwordHash, jwtSecret } = getDashboardAuthConfig()
  if (!passwordHash || !jwtSecret) return ''
  return createHash('sha256').update(passwordHash + jwtSecret).digest('hex')
}

export function verifySession(request) {
  const cookie = request.cookies.get('dashboard_session')
  if (!cookie) return false
  const expected = buildSessionToken()
  return Boolean(expected) && cookie.value === expected
}

export function requireSetupAccess(request) {
  if (!isAdminConfigured()) return true
  return verifySession(request)
}

export async function supabaseGet(endpoint, useServiceRole = false) {
  const key = useServiceRole ? process.env.SUPABASE_SERVICE_ROLE_KEY : process.env.SUPABASE_ANON_KEY
  const url = `${process.env.SUPABASE_URL}/${endpoint}`
  const res = await fetch(url, {
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
    },
    cache: 'no-store',
  })
  if (!res.ok) return null
  return res.json()
}

export async function supabasePost(endpoint, data, useServiceRole = true) {
  const key = useServiceRole ? process.env.SUPABASE_SERVICE_ROLE_KEY : process.env.SUPABASE_ANON_KEY
  const url = `${process.env.SUPABASE_URL}/${endpoint}`
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
      Prefer: 'resolution=merge-duplicates,return=representation',
    },
    body: JSON.stringify(data),
  })
  if (!res.ok) return null
  return res.json()
}

export async function supabaseDelete(endpoint, useServiceRole = true) {
  const key = useServiceRole ? process.env.SUPABASE_SERVICE_ROLE_KEY : process.env.SUPABASE_ANON_KEY
  const url = `${process.env.SUPABASE_URL}/${endpoint}`
  const res = await fetch(url, {
    method: 'DELETE',
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
    },
  })
  return res.ok
}
