import { createHash } from 'crypto'
import dns from 'dns/promises'
import { NextResponse } from 'next/server'
import { buildSessionToken, requireSetupAccess } from '../../lib/auth'
import { configureCaddy, runProviderScript, runSetupAction } from '../../lib/host-control'
import { getSetupState } from '../../lib/setup-state'

function unauthorized() {
  return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
}

function invalid(message) {
  return NextResponse.json({ error: message }, { status: 400 })
}

function normalizeDomain(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .replace(/^https?:\/\//, '')
    .replace(/\/.*$/, '')
}

async function getPublicIp() {
  const response = await fetch('https://api.ipify.org?format=json', { cache: 'no-store' })
  if (!response.ok) {
    throw new Error('Unable to determine public IP')
  }
  const data = await response.json()
  return data.ip
}

async function setupResponse(extra = {}) {
  const state = await getSetupState()
  return NextResponse.json({ ...state, ...extra })
}

export async function GET(request) {
  if (!requireSetupAccess(request)) {
    return unauthorized()
  }

  return setupResponse()
}

export async function POST(request) {
  if (!requireSetupAccess(request)) {
    return unauthorized()
  }

  const body = await request.json()
  const action = body?.action

  try {
    if (action === 'set_admin') {
      const name = String(body.name || '').trim()
      const email = String(body.email || '').trim().toLowerCase()
      const password = String(body.password || '')

      if (!name || !email || !password) {
        return invalid('Name, email, and password are required')
      }

      const passwordHash = createHash('sha256').update(password).digest('hex')
      await runSetupAction('set-admin', { name, email, password_hash: passwordHash })

      const response = await setupResponse()
      response.cookies.set('dashboard_session', buildSessionToken(), {
        httpOnly: true,
        secure: process.env.NODE_ENV === 'production',
        sameSite: 'strict',
        maxAge: 7 * 24 * 60 * 60,
        path: '/',
      })
      return response
    }

    if (action === 'set_provider') {
      const provider = String(body.provider || '').trim()
      if (!['claude', 'codex'].includes(provider)) {
        return invalid('Provider must be claude or codex')
      }

      await runSetupAction('set-provider', { provider })
      const installResult = await runProviderScript('install', provider)
      return setupResponse({
        installOutput: installResult.stdout || installResult.stderr || `${provider} installed`,
      })
    }

    if (action === 'check_domain') {
      const domain = normalizeDomain(body.domain)
      if (!domain) {
        return invalid('Domain is required')
      }

      const [expectedIp, addresses] = await Promise.all([
        getPublicIp(),
        dns.resolve4(domain).catch(() => []),
      ])

      return NextResponse.json({
        ok: true,
        domain,
        expectedIp,
        addresses,
        matches: addresses.includes(expectedIp),
      })
    }

    if (action === 'set_domain') {
      const skip = Boolean(body.skip)
      const domain = normalizeDomain(body.domain)

      if (!skip && !domain) {
        return invalid('Domain is required unless skipped')
      }

      await runSetupAction('set-domain', skip ? { skip: true } : { domain })

      let caddyMessage = ''
      if (!skip && domain) {
        try {
          await configureCaddy(domain)
          caddyMessage = `Caddy configured for dashboard.${domain}`
        } catch (error) {
          caddyMessage = error instanceof Error ? error.message : 'Failed to configure Caddy'
        }
      }

      return setupResponse({ caddyMessage })
    }

    if (action === 'set_telegram') {
      const skip = Boolean(body.skip)
      const token = String(body.token || '').trim()

      if (!skip && !token) {
        return invalid('Telegram bot token is required unless skipped')
      }

      await runSetupAction('set-telegram', skip ? { skip: true } : { token })
      return setupResponse()
    }

    if (action === 'set_context') {
      const text = String(body.text || '').trim()
      if (!text) {
        return invalid('Business context is required')
      }

      await runSetupAction('write-context', { text })
      return setupResponse()
    }

    if (action === 'set_initial_goal') {
      const title = String(body.title || '').trim()
      const summary = String(body.summary || '').trim()
      if (!title || !summary) {
        return invalid('Goal title and summary are required')
      }

      await runSetupAction('create-goal', { title, summary })
      return setupResponse()
    }

    return invalid('Unknown setup action')
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Setup action failed'
    return NextResponse.json({ error: message }, { status: 500 })
  }
}
