import { NextResponse } from 'next/server'
import { verifySession, supabaseGet } from '../../lib/auth'

export async function GET(request) {
  if (!verifySession(request)) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
  }

  const [bans, logins, stats, health] = await Promise.all([
    supabaseGet('cc_security_bans?order=banned_at.desc&limit=100'),
    supabaseGet('cc_security_logins?order=login_at.desc&limit=50'),
    supabaseGet('cc_security_stats?id=eq.1'),
    supabaseGet('cc_server_health?id=eq.1'),
  ])

  return NextResponse.json({
    bans: bans || [],
    logins: logins || [],
    stats: stats?.[0] || {},
    health: health?.[0] || {},
  })
}
