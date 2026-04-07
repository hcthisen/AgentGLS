import { NextResponse } from 'next/server'
import { verifySession, supabaseGet, supabasePost } from '../../lib/auth'

export async function GET(request) {
  if (!verifySession(request)) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
  }

  const { searchParams } = new URL(request.url)
  const reveal = searchParams.get('reveal') === 'true'

  const select = reveal
    ? 'key,value,description,updated_at'
    : 'key,description,updated_at'

  const secrets = await supabaseGet(`cc_secrets?select=${select}&order=key`, true)
  return NextResponse.json(secrets || [])
}

export async function POST(request) {
  if (!verifySession(request)) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
  }

  const body = await request.json()
  const { key, value, description } = body

  if (!key || !value) {
    return NextResponse.json({ error: 'Key and value are required' }, { status: 400 })
  }

  // Validate key format: uppercase, underscores, alphanumeric
  if (!/^[A-Z][A-Z0-9_]*$/.test(key)) {
    return NextResponse.json({ error: 'Key must be UPPERCASE_WITH_UNDERSCORES' }, { status: 400 })
  }

  const result = await supabasePost('cc_secrets', {
    key,
    value,
    description: description || '',
    updated_at: new Date().toISOString(),
  }, true)

  if (!result) {
    return NextResponse.json({ error: 'Failed to save secret' }, { status: 500 })
  }

  return NextResponse.json(result)
}
