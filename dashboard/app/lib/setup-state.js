import fs from 'fs'
import path from 'path'
import { GOALS_PATH, readRuntimeEnv, readTextFile } from './runtime-config'
import { runProviderScript } from './host-control'

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

function authCommandFor(provider, adminEmail = '') {
  if (provider === 'claude') {
    const emailFlag = adminEmail ? ` --email ${adminEmail}` : ''
    return `claude auth login --claudeai${emailFlag}`
  }
  if (provider === 'codex') {
    return 'codex login --device-auth'
  }
  return ''
}

export async function getSetupState() {
  const env = readRuntimeEnv()
  const goalPath = firstGoalPath()

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
      authCommand: '',
      manualInstallCommand: '',
    },
    domain: {
      value: env.AGENTOS_DOMAIN || '',
      configured: Boolean(env.AGENTOS_DOMAIN),
      skipped: env.AGENTGLS_DOMAIN_SKIPPED === '1',
      done: Boolean(env.AGENTOS_DOMAIN) || env.AGENTGLS_DOMAIN_SKIPPED === '1',
    },
    telegram: {
      configured: Boolean(env.TELEGRAM_BOT_TOKEN),
      skipped: env.AGENTGLS_TELEGRAM_SKIPPED === '1',
      maskedToken: maskToken(env.TELEGRAM_BOT_TOKEN || ''),
    },
    context: {
      configured: Boolean(readTextFile(path.join(GOALS_PATH, '_context.md')).trim()),
    },
    initialGoal: {
      configured: Boolean(goalPath),
      path: goalPath || '',
    },
  }

  state.telegram.done = state.telegram.configured || state.telegram.skipped

  if (state.provider.selected) {
    state.provider.authCommand = authCommandFor(state.provider.selected, state.adminEmail)
    state.provider.manualInstallCommand =
      state.provider.selected === 'claude'
        ? 'curl -fsSL https://claude.ai/install.sh | bash'
        : 'npm install -g @openai/codex'

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

  state.completed =
    state.adminConfigured &&
    Boolean(state.provider.selected) &&
    state.provider.installed &&
    state.provider.authenticated &&
    state.domain.done &&
    state.telegram.done &&
    state.context.configured &&
    state.initialGoal.configured

  return state
}
