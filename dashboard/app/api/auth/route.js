import { NextResponse } from 'next/server'
import { createHash } from 'crypto'
import { buildSessionToken, getDashboardAuthConfig, sessionCookieOptions } from '../../lib/auth'

export async function POST(request) {
  const { email, password } = await request.json()
  if (!password) {
    return NextResponse.json({ error: 'Password required' }, { status: 400 })
  }

  const config = getDashboardAuthConfig()
  if (!config.passwordHash) {
    return NextResponse.json({ error: 'Admin account is not configured yet' }, { status: 409 })
  }

  if (config.adminEmail && String(email || '').trim().toLowerCase() !== config.adminEmail.toLowerCase()) {
    return NextResponse.json({ error: 'Invalid email or password' }, { status: 401 })
  }

  const hash = createHash('sha256').update(password).digest('hex')
  if (hash !== config.passwordHash) {
    return NextResponse.json({ error: 'Invalid email or password' }, { status: 401 })
  }

  const sessionToken = buildSessionToken()
  if (!sessionToken) {
    return NextResponse.json({ error: 'Dashboard auth secret is missing' }, { status: 500 })
  }

  const response = NextResponse.json({ ok: true })
  response.cookies.set('dashboard_session', sessionToken, sessionCookieOptions(request))

  return response
}
