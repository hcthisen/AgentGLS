import { NextResponse } from 'next/server'
import { getDashboardAuthConfig, isAdminConfigured, verifySession } from '../../../lib/auth'

export async function GET(request) {
  const authenticated = verifySession(request)
  const config = getDashboardAuthConfig()
  return NextResponse.json({
    authenticated,
    adminConfigured: isAdminConfigured(),
    adminEmail: config.adminEmail,
  })
}
