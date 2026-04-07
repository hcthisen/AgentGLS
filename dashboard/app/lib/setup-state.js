import fs from 'fs'
import path from 'path'
import { GOALS_PATH, readRuntimeEnv, readTextFile } from './runtime-config'
import { getTelegramBridgeState, runProviderScript } from './host-control'

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

function providerApiKeyState(env, provider) {
  if (provider === 'claude') {
    return {
      configured: Boolean(env.ANTHROPIC_API_KEY),
      envVar: 'ANTHROPIC_API_KEY',
      masked: maskToken(env.ANTHROPIC_API_KEY || ''),
      label: 'Anthropic API key',
    }
  }

  if (provider === 'codex') {
    return {
      configured: Boolean(env.OPENAI_API_KEY),
      envVar: 'OPENAI_API_KEY',
      masked: maskToken(env.OPENAI_API_KEY || ''),
      label: 'OpenAI API key',
    }
  }

  return {
    configured: false,
    envVar: '',
    masked: '',
    label: 'API key',
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
      apiKeyConfigured: false,
      maskedApiKey: '',
      authEnvVar: '',
      authInputLabel: '',
    },
    domain: {
      value: env.AGENTGLS_DOMAIN || '',
      configured: Boolean(env.AGENTGLS_DOMAIN),
      skipped: env.AGENTGLS_DOMAIN_SKIPPED === '1',
      done: Boolean(env.AGENTGLS_DOMAIN) || env.AGENTGLS_DOMAIN_SKIPPED === '1',
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
    const apiKeyState = providerApiKeyState(env, state.provider.selected)
    state.provider.apiKeyConfigured = apiKeyState.configured
    state.provider.maskedApiKey = apiKeyState.masked
    state.provider.authEnvVar = apiKeyState.envVar
    state.provider.authInputLabel = apiKeyState.label

    try {
      const installResult = await runProviderScript('status', state.provider.selected)
      state.provider.installed = installResult.code === 0
      state.provider.installStatus = compact(installResult.stdout || installResult.stderr || 'missing')

      if (state.provider.installed) {
        const authResult = await runProviderScript('auth-status', state.provider.selected)
        state.provider.authenticated = authResult.code === 0
        state.provider.authStatus = compact(authResult.stdout || authResult.stderr || 'not authenticated')
      } else {
        state.provider.authStatus = 'provider not installed'
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : 'provider check failed'
      state.provider.installStatus = message
      state.provider.authStatus = message
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
