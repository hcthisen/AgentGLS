import { NextResponse } from 'next/server'
import { createHash } from 'crypto'
import { buildSessionToken, getDashboardAuthConfig } from '../../lib/auth'

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

  const response = NextResponse.json({ ok: true })
  response.cookies.set('dashboard_session', sessionToken, {
    httpOnly: true,
    secure: process.env.NODE_ENV === 'production',
    sameSite: 'strict',
    maxAge: 7 * 24 * 60 * 60, // 7 days
    path: '/',
  })

  return response
}
