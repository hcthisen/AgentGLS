import fs from 'fs'
import path from 'path'
import { GOALS_PATH, readRuntimeEnv, readTextFile } from './runtime-config'
import { getProviderAuthState, getTelegramBridgeState, runProviderScript } from './host-control'

function firstGoalPath() {
  try {
    const activeDir = path.join(GOALS_PATH, 'active')
    const goals = fs
      .readdirSync(activeDir)
      .filter((name) => name.endsWith('.md') && !name.startsWith('_'))
      .sort()
    return goals.length ? path.join(activeDir, goals[0]) : null
  } catch {
    return null
  }
}

function maskToken(token) {
  if (!token) return ''
  if (token.length <= 8) return 'configured'
  return `${token.slice(0, 4)}...${token.slice(-4)}`
}

function compact(value) {
  return String(value || '').replace(/\s+/g, ' ').trim()
}

function configuredDashboardHost(env) {
  if (env.AGENTGLS_DASHBOARD_HOST) return env.AGENTGLS_DASHBOARD_HOST
  if (env.AGENTGLS_DOMAIN) return `dashboard.${env.AGENTGLS_DOMAIN}`
  return ''
}

function parseProviderAuthState(result) {
  let payload = null

  try {
    payload = JSON.parse(String(result?.stdout || '').trim())
  } catch {
    payload = null
  }

  const message = compact(
    payload?.message || result?.stdout || result?.stderr || 'Provider authentication is not ready'
  )
  const mode = payload?.mode || 'unknown'
  const status = payload?.status || 'missing'
  const authenticated = (result?.code ?? 1) === 0 && status === 'authenticated' && mode === 'subscription'
  const warning = (result?.code ?? 1) === 2 || status === 'warning' ? message : ''

  return {
    authenticated,
    authMode: mode,
    authStatus: message,
    authWarning: warning,
  }
}

export async function getSetupState() {
  const env = readRuntimeEnv()
  const goalPath = firstGoalPath()
  const contextText = readTextFile(path.join(GOALS_PATH, '_context.md')).trim()

  const state = {
    adminConfigured: Boolean(env.AGENTGLS_ADMIN_EMAIL && env.DASHBOARD_PASSWORD_HASH),
    adminName: env.AGENTGLS_ADMIN_NAME || '',
    adminEmail: env.AGENTGLS_ADMIN_EMAIL || '',
    provider: {
      selected: env.AGENTGLS_PROVIDER || '',
      installed: false,
      authenticated: false,
      installStatus: 'pending',
      authStatus: 'pending',
      authMode: 'unknown',
      authWarning: '',
      authSession: null,
    },
    domain: {
      value: configuredDashboardHost(env),
      configured: Boolean(configuredDashboardHost(env)),
      skipped: env.AGENTGLS_DOMAIN_SKIPPED === '1',
      done: Boolean(configuredDashboardHost(env)) || env.AGENTGLS_DOMAIN_SKIPPED === '1',
      source: env.AGENTGLS_DASHBOARD_HOST ? 'host' : env.AGENTGLS_DOMAIN ? 'legacy-domain' : '',
    },
    telegram: {
      configured: Boolean(env.TELEGRAM_BOT_TOKEN),
      skipped: env.AGENTGLS_TELEGRAM_SKIPPED === '1',
      maskedToken: maskToken(env.TELEGRAM_BOT_TOKEN || ''),
      bridgeRunning: false,
      operational: false,
      pendingPairs: 0,
      allowlistedChats: 0,
      envAllowlistedChats: 0,
      logFile: '',
      pendingRequests: [],
      allowedChats: [],
      statusError: '',
    },
    context: {
      configured: Boolean(contextText),
      text: contextText,
    },
    initialGoal: {
      configured: Boolean(goalPath),
      path: goalPath || '',
    },
  }

  state.telegram.done = state.telegram.configured || state.telegram.skipped
  state.telegram.operational = state.telegram.skipped

  if (state.provider.selected) {
    try {
      const installResult = await runProviderScript('status', state.provider.selected)
      state.provider.installed = installResult.code === 0
      state.provider.installStatus = compact(installResult.stdout || installResult.stderr || 'missing')

      if (state.provider.installed) {
        const authResult = await runProviderScript('auth-status', state.provider.selected)
        Object.assign(state.provider, parseProviderAuthState(authResult))
      } else {
        state.provider.authStatus = 'provider not installed'
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : 'provider check failed'
      state.provider.installStatus = message
      state.provider.authStatus = message
    }

    try {
      state.provider.authSession = await getProviderAuthState(state.provider.selected)
    } catch (error) {
      state.provider.authSession = {
        status: 'failed',
        error: error instanceof Error ? error.message : 'provider auth state unavailable',
      }
    }
  }

  if (state.telegram.configured) {
    try {
      const telegramState = await getTelegramBridgeState()
      state.telegram.bridgeRunning = Boolean(telegramState.bridge_running)
      state.telegram.operational = state.telegram.bridgeRunning
      state.telegram.pendingPairs = Number(telegramState.pending_pairs || 0)
      state.telegram.allowlistedChats = Number(telegramState.allowlisted_chats || 0)
      state.telegram.envAllowlistedChats = Number(telegramState.env_allowlisted_chats || 0)
      state.telegram.logFile = telegramState.log_file || ''
      state.telegram.pendingRequests = Array.isArray(telegramState.pending) ? telegramState.pending : []
      state.telegram.allowedChats = Array.isArray(telegramState.allowlisted) ? telegramState.allowlisted : []
    } catch (error) {
      state.telegram.statusError = error instanceof Error ? error.message : 'telegram status unavailable'
    }
  }

  state.completed =
    state.adminConfigured &&
    Boolean(state.provider.selected) &&
    state.provider.installed &&
    state.provider.authenticated &&
    state.domain.done &&
    state.telegram.operational &&
    state.context.configured &&
    state.initialGoal.configured

  return state
}
