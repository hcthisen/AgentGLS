'use client'
import { useEffect, useState } from 'react'

function compact(value) {
  return String(value || '').replace(/\s+/g, ' ').trim()
}

function formatTimestamp(value) {
  if (!value) return '-'
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return value
  return parsed.toLocaleString()
}

function providerAuthMeta(provider) {
  if (provider === 'claude') {
    return {
      authLabel: 'Claude subscription login',
      connectLabel: 'Connect Claude',
      openLabel: 'Open Claude sign-in',
      statusCommand: 'claude auth status --json',
      intro:
        'Claude Code uses a server-side subscription sign-in session. Open the Claude auth link, then paste the callback URL or code#state value back here.',
    }
  }

  if (provider === 'codex') {
    return {
      authLabel: 'ChatGPT / device auth',
      connectLabel: 'Connect ChatGPT',
      openLabel: 'Open ChatGPT sign-in page',
      statusCommand: 'codex login status',
      intro:
        'Codex uses ChatGPT device auth. AgentGLS starts device auth on the server, then shows the sign-in link and one-time code here.',
    }
  }

  return {
    authLabel: 'Provider login',
    connectLabel: 'Connect provider',
    openLabel: 'Open sign-in',
    statusCommand: '',
    intro: '',
  }
}

function providerAuthStatusLabel(status) {
  switch (status) {
    case 'starting':
      return 'starting'
    case 'waiting':
      return 'waiting for browser sign-in'
    case 'complete':
      return 'connected'
    case 'failed':
      return 'failed'
    case 'canceled':
      return 'canceled'
    default:
      return 'idle'
  }
}

function ProviderProbeResult({ result }) {
  if (!result) return null

  const tone =
    result.status === 'pass' ? 'ok' : result.status === 'warn' ? 'warn' : 'error'

  return (
    <div className={`setup-banner ${tone}`}>
      <div className="setup-check-header">
        <strong>
          {result.status === 'pass'
            ? 'Live check passed'
            : result.status === 'warn'
              ? 'Live check needs attention'
              : 'Live check failed'}
        </strong>
        <span>{formatTimestamp(result.testedAt)}</span>
      </div>
      <div className="setup-check-list">
        {(result.checks || []).map((check, index) => (
          <div key={`${check.code || 'check'}-${index}`} className="setup-check-item">
            <span className={`setup-check-level ${check.level}`}>{check.level}</span>
            <span>{check.message}</span>
            {check.detail && <div className="setup-check-detail">{check.detail}</div>}
            {check.hint && <div className="setup-check-hint">Hint: {check.hint}</div>}
          </div>
        ))}
      </div>
    </div>
  )
}

export default function SettingsTab({ setupState, onSetupUpdate }) {
  const [adminName, setAdminName] = useState(setupState?.adminName || '')
  const [adminEmail, setAdminEmail] = useState(setupState?.adminEmail || '')
  const [adminPassword, setAdminPassword] = useState('')
  const [provider, setProvider] = useState(setupState?.provider?.selected || 'claude')
  const [providerDirty, setProviderDirty] = useState(false)
  const [providerAuthCode, setProviderAuthCode] = useState('')
  const [providerProbe, setProviderProbe] = useState(null)
  const [domain, setDomain] = useState(setupState?.domain?.value || '')
  const [domainResult, setDomainResult] = useState(null)
  const [message, setMessage] = useState('')
  const [error, setError] = useState('')
  const [busyAction, setBusyAction] = useState('')

  useEffect(() => {
    setAdminName(setupState?.adminName || '')
    setAdminEmail(setupState?.adminEmail || '')
    if (!providerDirty) {
      setProvider(setupState?.provider?.selected || 'claude')
    }
    setDomain(setupState?.domain?.value || '')
  }, [providerDirty, setupState])

  useEffect(() => {
    setProviderProbe(null)
    setProviderAuthCode('')
  }, [provider])

  const savedProvider = setupState?.provider?.selected || ''
  const providerSaved = provider === savedProvider
  const currentProviderMeta = providerAuthMeta(provider)
  const providerAuthSession = providerSaved ? setupState?.provider?.authSession || null : null
  const providerAuthSessionStatus = providerSaved
    ? providerAuthSession?.status || (setupState?.provider?.authenticated ? 'complete' : 'idle')
    : 'idle'
  const providerInstallStatus = providerSaved
    ? setupState?.provider?.installStatus || 'pending'
    : savedProvider
      ? `active provider is ${savedProvider}; save to switch`
      : 'save this provider to continue'
  const providerAuthStatus = providerSaved
    ? setupState?.provider?.authStatus || 'pending'
    : 'save this provider to start browser-based authorization'
  const normalizedDomain = compact(domain).toLowerCase()
  const canSaveDomain = Boolean(normalizedDomain) && domainResult?.host === normalizedDomain && domainResult?.matches

  useEffect(() => {
    if (!providerSaved) return undefined
    if (!['starting', 'waiting'].includes(providerAuthSessionStatus)) return undefined

    const interval = window.setInterval(() => {
      void fetch('/api/setup', { cache: 'no-store' })
        .then((res) => res.json().catch(() => ({})).then((data) => ({ ok: res.ok, data })))
        .then(({ ok, data }) => {
          if (ok) {
            onSetupUpdate(data)
          }
        })
        .catch(() => null)
    }, 2000)

    return () => window.clearInterval(interval)
  }, [onSetupUpdate, providerAuthSessionStatus, providerSaved])

  async function executeSetupAction(action, payload = {}, options = {}) {
    setBusyAction(options.busyKey || action)
    setError('')
    setMessage('')

    try {
      const response = await fetch('/api/setup', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action, ...payload }),
      })
      const data = await response.json().catch(() => ({}))
      if (!response.ok) {
        throw new Error(data.error || 'Settings update failed')
      }

      onSetupUpdate(data)
      if (action === 'set_provider') {
        setProviderDirty(false)
      }
      if (options.clearAdminPassword) {
        setAdminPassword('')
      }
      if (options.clearDomainResult) {
        setDomainResult(null)
      }

      setMessage(
        data.syncMessage ||
          data.installOutput ||
          data.caddyMessage ||
          options.successMessage ||
          'Saved'
      )
      return data
    } catch (actionError) {
      setError(actionError instanceof Error ? actionError.message : 'Settings update failed')
      return null
    } finally {
      setBusyAction('')
    }
  }

  async function refreshSetupState() {
    setBusyAction('refresh_setup')
    setError('')
    setMessage('')

    try {
      const response = await fetch('/api/setup', { cache: 'no-store' })
      const data = await response.json().catch(() => ({}))
      if (!response.ok) {
        throw new Error(data.error || 'Failed to refresh settings')
      }
      onSetupUpdate(data)
      setMessage('Settings refreshed')
      return data
    } catch (actionError) {
      setError(actionError instanceof Error ? actionError.message : 'Failed to refresh settings')
      return null
    } finally {
      setBusyAction('')
    }
  }

  async function saveAdminSettings() {
    await executeSetupAction(
      'set_admin',
      {
        name: adminName,
        email: adminEmail,
        password: adminPassword,
      },
      {
        clearAdminPassword: true,
        successMessage: adminPassword ? 'User settings updated' : 'User settings updated; password unchanged',
      }
    )
  }

  async function startProviderAuthSession(providerToStart = provider, authWindow = null) {
    setBusyAction('start_provider_auth')
    setError('')
    setMessage('')

    try {
      const response = await fetch('/api/setup', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'start_provider_auth', provider: providerToStart }),
      })
      const data = await response.json().catch(() => ({}))
      if (!response.ok) {
        throw new Error(data.error || 'Failed to start provider sign-in')
      }

      onSetupUpdate(data)
      const nextSession = data.provider?.authSession

      if (authWindow) {
        if (nextSession?.verificationUrl) {
          authWindow.location.replace(nextSession.verificationUrl)
        } else {
          authWindow.close()
        }
      }

      setMessage(
        data.provider?.authenticated || nextSession?.authDetected || nextSession?.status === 'complete'
          ? 'Provider login is already connected'
          : providerToStart === 'claude'
            ? 'Claude sign-in started. Finish the browser flow, then paste the callback below.'
            : 'ChatGPT sign-in started. Open the sign-in page and enter the one-time code below.'
      )
      return data
    } catch (actionError) {
      if (authWindow) authWindow.close()
      setError(actionError instanceof Error ? actionError.message : 'Failed to start provider sign-in')
      return null
    } finally {
      setBusyAction('')
    }
  }

  async function cancelProviderAuthSession(providerToCancel = provider) {
    await executeSetupAction(
      'cancel_provider_auth',
      { provider: providerToCancel },
      { successMessage: 'Provider sign-in canceled' }
    )
  }

  async function submitProviderAuthCallback() {
    const value = providerAuthCode.trim()
    if (!value) {
      setError('Paste the Claude callback URL or the code#state value')
      return
    }

    const data = await executeSetupAction(
      'submit_provider_auth_code',
      { provider: 'claude', value },
      { successMessage: 'Claude callback submitted' }
    )
    if (data) {
      setProviderAuthCode('')
    }
  }

  async function saveProviderAndStartAuth() {
    const authWindow = typeof window !== 'undefined' ? window.open('', '_blank') : null
    const data = await executeSetupAction(
      'set_provider',
      { provider },
      {
        successMessage: `${provider} saved as the active provider`,
      }
    )

    if (!data) {
      authWindow?.close()
      return
    }

    if (data.provider?.authenticated) {
      authWindow?.close()
      return
    }

    await startProviderAuthSession(provider, authWindow)
  }

  async function runProviderCheck(providerToCheck = provider) {
    setBusyAction('probe_provider')
    setError('')
    setMessage('')

    try {
      const response = await fetch('/api/setup', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'probe_provider', provider: providerToCheck }),
      })
      const data = await response.json().catch(() => ({}))
      if (!response.ok) {
        throw new Error(data.error || 'Provider live check failed')
      }

      onSetupUpdate(data)
      setProviderProbe(data.providerProbe || null)
      setMessage('Provider live check completed')
      return data
    } catch (actionError) {
      setError(actionError instanceof Error ? actionError.message : 'Provider live check failed')
      return null
    } finally {
      setBusyAction('')
    }
  }

  async function checkDomain() {
    setBusyAction('check_domain')
    setError('')
    setMessage('')

    try {
      const response = await fetch('/api/setup', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'check_domain', host: domain }),
      })
      const data = await response.json().catch(() => ({}))
      if (!response.ok) {
        throw new Error(data.error || 'DNS check failed')
      }
      setDomainResult(data)
      setMessage(data.matches ? 'DNS matches this VPS' : 'DNS does not point at this VPS yet')
      return data
    } catch (actionError) {
      setError(actionError instanceof Error ? actionError.message : 'DNS check failed')
      return null
    } finally {
      setBusyAction('')
    }
  }

  async function syncGoals() {
    await executeSetupAction('sync_goals', {}, { successMessage: 'Goal projection synced' })
  }

  return (
    <>
      {(message || error) && (
        <div className={`setup-banner ${error ? 'error' : 'ok'}`}>{error || message}</div>
      )}

      <div className="section">
        <div className="section-header">User Settings</div>
        <div className="section-body">
          <div className="setup-form-grid">
            <input
              type="text"
              placeholder="admin name"
              value={adminName}
              onChange={(event) => setAdminName(event.target.value)}
            />
            <input
              type="email"
              placeholder="admin email"
              value={adminEmail}
              onChange={(event) => setAdminEmail(event.target.value)}
            />
          </div>
          <input
            type="password"
            placeholder="leave blank to keep the current password"
            value={adminPassword}
            onChange={(event) => setAdminPassword(event.target.value)}
          />
          <div className="setup-copy">
            Update the dashboard operator identity. If the password field is blank, the current
            password stays in place.
          </div>
          <div className="form-actions">
            <button
              type="button"
              className="btn-action"
              disabled={busyAction === 'set_admin' || !adminName.trim() || !adminEmail.trim()}
              onClick={() => void saveAdminSettings()}
            >
              {busyAction === 'set_admin' ? 'saving...' : 'save user settings'}
            </button>
          </div>
        </div>
      </div>

      <div className="section">
        <div className="section-header">Runtime Provider</div>
        <div className="section-body">
          <div className="provider-choice">
            <label className={`choice ${provider === 'claude' ? 'selected' : ''}`}>
              <input
                type="radio"
                checked={provider === 'claude'}
                onChange={() => {
                  setProviderDirty(true)
                  setProvider('claude')
                }}
              />
              <span>Claude Code</span>
            </label>
            <label className={`choice ${provider === 'codex' ? 'selected' : ''}`}>
              <input
                type="radio"
                checked={provider === 'codex'}
                onChange={() => {
                  setProviderDirty(true)
                  setProvider('codex')
                }}
              />
              <span>OpenAI Codex</span>
            </label>
          </div>

          <div className="setup-detail">
            <div>
              Chosen provider: <code>{provider}</code>
            </div>
            <div>
              Active provider: <code>{savedProvider || 'not saved yet'}</code>
            </div>
            <div>
              Install status: <code>{providerInstallStatus}</code>
            </div>
            <div>
              Auth status: <code>{providerAuthStatus}</code>
            </div>
            <div>
              Current auth mode:{' '}
              <code>{providerSaved ? setupState?.provider?.authMode || 'unknown' : 'save to inspect'}</code>
            </div>
            <div>
              Expected auth: <code>{currentProviderMeta.authLabel || 'select a provider first'}</code>
            </div>
            <div>
              Sign-in session:{' '}
              <code>{providerSaved ? providerAuthStatusLabel(providerAuthSessionStatus) : 'save to start'}</code>
            </div>
            <div>
              Status check: <code>{currentProviderMeta.statusCommand || '-'}</code>
            </div>
          </div>

          {!providerSaved && (
            <div className="setup-banner warn">
              Save this provider as active first. AgentGLS will then start the browser sign-in flow for it.
            </div>
          )}
          <div className="setup-copy">{currentProviderMeta.intro}</div>
          {providerSaved && setupState?.provider?.authWarning && (
            <div className="setup-banner warn">{setupState.provider.authWarning}</div>
          )}
          {providerSaved && providerAuthSession?.error && (
            <div className="setup-banner error">{providerAuthSession.error}</div>
          )}

          {providerSaved && (
            <div className="setup-subsection">
              <div className="setup-subtitle">Provider sign-in</div>
              {provider === 'claude' && (
                <>
                  <div className="setup-copy">
                    1. Click <strong>{currentProviderMeta.connectLabel}</strong> to start a Claude sign-in session.
                    <br />
                    2. Open the Claude sign-in page.
                    <br />
                    3. Finish the Claude flow and paste the callback URL or code#state value below.
                  </div>
                  {providerAuthSession?.verificationUrl && !setupState?.provider?.authenticated && (
                    <div className="setup-copy">
                      <a
                        href={providerAuthSession.verificationUrl}
                        target="_blank"
                        rel="noreferrer"
                        className="setup-inline-link"
                      >
                        {currentProviderMeta.openLabel}
                      </a>
                    </div>
                  )}
                  {!setupState?.provider?.authenticated && (
                    <textarea
                      rows={4}
                      placeholder="Paste the Claude callback URL or the code#state value here"
                      value={providerAuthCode}
                      onChange={(event) => setProviderAuthCode(event.target.value)}
                    />
                  )}
                  {setupState?.provider?.authenticated && (
                    <div className="setup-banner ok">Claude subscription login is connected on the host.</div>
                  )}
                </>
              )}
              {provider === 'codex' && (
                <>
                  <div className="setup-copy">
                    1. Click <strong>{currentProviderMeta.connectLabel}</strong> to start ChatGPT device auth.
                    <br />
                    2. Open the sign-in page.
                    <br />
                    3. Enter the one-time code shown here and finish the browser flow.
                  </div>
                  {providerAuthSession?.userCode && !setupState?.provider?.authenticated && (
                    <div className="setup-detail">
                      <div>
                        One-time code: <code>{providerAuthSession.userCode}</code>
                      </div>
                    </div>
                  )}
                  {providerAuthSession?.verificationUrl && !setupState?.provider?.authenticated && (
                    <div className="setup-copy">
                      <a
                        href={providerAuthSession.verificationUrl}
                        target="_blank"
                        rel="noreferrer"
                        className="setup-inline-link"
                      >
                        {currentProviderMeta.openLabel}
                      </a>
                    </div>
                  )}
                  {setupState?.provider?.authenticated && (
                    <div className="setup-banner ok">ChatGPT subscription login is connected on the host.</div>
                  )}
                </>
              )}
            </div>
          )}

          <div className="form-actions">
            <button
              type="button"
              className="btn-action"
              disabled={busyAction === 'set_provider' || busyAction === 'start_provider_auth'}
              onClick={() => void saveProviderAndStartAuth()}
            >
              {busyAction === 'set_provider' ? 'saving...' : 'save active provider'}
            </button>
            {providerSaved && !setupState?.provider?.authenticated && (
              <button
                type="button"
                className="btn-sm"
                disabled={busyAction === 'start_provider_auth'}
                onClick={() => {
                  const authWindow = typeof window !== 'undefined' ? window.open('', '_blank') : null
                  void startProviderAuthSession(provider, authWindow)
                }}
              >
                {busyAction === 'start_provider_auth' ? 'starting...' : currentProviderMeta.connectLabel}
              </button>
            )}
            {providerSaved && provider === 'claude' && !setupState?.provider?.authenticated && (
              <button
                type="button"
                className="btn-sm"
                disabled={busyAction === 'submit_provider_auth_code' || !providerAuthCode.trim()}
                onClick={() => void submitProviderAuthCallback()}
              >
                {busyAction === 'submit_provider_auth_code' ? 'submitting...' : 'submit callback'}
              </button>
            )}
            {providerSaved && ['starting', 'waiting'].includes(providerAuthSessionStatus) && (
              <button
                type="button"
                className="btn-cancel"
                disabled={busyAction === 'cancel_provider_auth'}
                onClick={() => void cancelProviderAuthSession(provider)}
              >
                {busyAction === 'cancel_provider_auth' ? 'canceling...' : 'cancel sign-in'}
              </button>
            )}
            <button
              type="button"
              className="btn-sm"
              disabled={busyAction === 'refresh_setup'}
              onClick={() => void refreshSetupState()}
            >
              {busyAction === 'refresh_setup' ? 'refreshing...' : 'refresh auth status'}
            </button>
            <button
              type="button"
              className="btn-sm"
              disabled={busyAction === 'probe_provider' || !providerSaved}
              onClick={() => void runProviderCheck(provider)}
            >
              {busyAction === 'probe_provider' ? 'checking...' : 'run live check'}
            </button>
          </div>

          <ProviderProbeResult result={providerProbe} />
        </div>
      </div>

      <div className="section">
        <div className="section-header">Dashboard Host</div>
        <div className="section-body">
          <input
            type="text"
            placeholder="dashboard.example.com"
            value={domain}
            onChange={(event) => {
              setDomain(event.target.value)
              setDomainResult(null)
            }}
          />
          <div className="setup-copy">
            Enter the exact public hostname for the dashboard. DNS must resolve to this VPS before Caddy is activated and TLS is requested.
          </div>
          {domainResult && (
            <div className={`setup-banner ${domainResult.matches ? 'ok' : 'warn'}`}>
              {domainResult.matches
                ? `${domainResult.host} resolves to ${domainResult.expectedIp}`
                : `${domainResult.host} resolves to ${domainResult.addresses.join(', ') || 'nothing yet'}; expected ${domainResult.expectedIp}`}
            </div>
          )}
          {setupState?.domain?.configured && !domainResult && (
            <div className="setup-detail">
              <div>
                Current host: <code>{setupState.domain.value}</code>
              </div>
              <div>
                Host source: <code>{setupState.domain.source || 'configured'}</code>
              </div>
            </div>
          )}
          <div className="form-actions">
            <button
              type="button"
              className="btn-sm"
              disabled={busyAction === 'check_domain' || !normalizedDomain}
              onClick={() => void checkDomain()}
            >
              {busyAction === 'check_domain' ? 'checking...' : 'check dns'}
            </button>
            <button
              type="button"
              className="btn-action"
              disabled={busyAction === 'set_domain' || !canSaveDomain}
              onClick={() =>
                void executeSetupAction(
                  'set_domain',
                  { host: domain },
                  { clearDomainResult: true, successMessage: 'Dashboard host saved' }
                )
              }
            >
              {busyAction === 'set_domain' ? 'saving...' : 'save host'}
            </button>
            <button
              type="button"
              className="btn-cancel"
              disabled={busyAction === 'set_domain'}
              onClick={() =>
                void executeSetupAction(
                  'set_domain',
                  { skip: true },
                  { clearDomainResult: true, successMessage: 'Using raw IP for now' }
                )
              }
            >
              use raw IP
            </button>
          </div>
        </div>
      </div>

      <div className="section">
        <div className="section-header">Maintenance</div>
        <div className="section-body">
          <div className="setup-copy">
            Refresh runtime state or manually rebuild the goal projection without leaving the dashboard.
          </div>
          <div className="form-actions">
            <button
              type="button"
              className="btn-sm"
              disabled={busyAction === 'refresh_setup'}
              onClick={() => void refreshSetupState()}
            >
              {busyAction === 'refresh_setup' ? 'refreshing...' : 'refresh settings'}
            </button>
            <button
              type="button"
              className="btn-sm"
              disabled={busyAction === 'sync_goals'}
              onClick={() => void syncGoals()}
            >
              {busyAction === 'sync_goals' ? 'syncing...' : 'sync goal projection'}
            </button>
          </div>
        </div>
      </div>
    </>
  )
}
