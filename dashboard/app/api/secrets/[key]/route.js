import { NextResponse } from 'next/server'
import { verifySession, supabaseDelete } from '../../../lib/auth'

export async function DELETE(request, { params }) {
  if (!verifySession(request)) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
  }

  const { key } = await params
  if (!key) {
    return NextResponse.json({ error: 'Key is required' }, { status: 400 })
  }

  const ok = await supabaseDelete(`cc_secrets?key=eq.${encodeURIComponent(key)}`, true)
  if (!ok) {
    return NextResponse.json({ error: 'Failed to delete' }, { status: 500 })
  }

  return NextResponse.json({ ok: true })
}
