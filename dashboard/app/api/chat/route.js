import { NextResponse } from 'next/server'
import { getDashboardAuthConfig, verifySession } from '../../lib/auth'
import { getDashboardChat, sendDashboardChatMessage } from '../../lib/host-control'

function unauthorized() {
  return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
}

function invalid(message) {
  return NextResponse.json({ error: message }, { status: 400 })
}

function parseLimit(request) {
  const raw = request.nextUrl.searchParams.get('limit')
  const value = Number.parseInt(raw || '200', 10)
  if (!Number.isFinite(value)) return 200
  return Math.max(1, Math.min(500, value))
}

function dashboardDisplayName() {
  const config = getDashboardAuthConfig()
  return config.adminName || config.adminEmail || 'Dashboard operator'
}

export async function GET(request) {
  if (!verifySession(request)) {
    return unauthorized()
  }

  try {
    const payload = await getDashboardChat(parseLimit(request))
    return NextResponse.json(payload)
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Failed to load chat'
    return NextResponse.json({ error: message }, { status: 500 })
  }
}

export async function POST(request) {
  if (!verifySession(request)) {
    return unauthorized()
  }

  const body = await request.json().catch(() => ({}))
  const text = String(body?.text || '').trim()
  if (!text) {
    return invalid('Message text is required')
  }

  try {
    const payload = await sendDashboardChatMessage(text, dashboardDisplayName())
    return NextResponse.json(payload)
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Failed to send chat message'
    return NextResponse.json({ error: message }, { status: 500 })
  }
}
