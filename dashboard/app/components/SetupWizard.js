'use client'
import { useEffect, useState } from 'react'
import TerminalPane from './TerminalPane'

const STEP_ORDER = ['admin', 'provider', 'domain', 'telegram', 'context', 'launch']

const STEP_META = {
  admin: {
    label: 'Access',
    title: 'Create the dashboard admin',
    blurb: 'Protect the dashboard first so the rest of onboarding can happen from the web UI.',
  },
  provider: {
    label: 'Runtime',
    title: 'Choose and authorize the active provider',
    blurb: 'Bootstrap installs both CLIs. Choose the active runtime, sign in through the embedded terminal, and verify it with a live check.',
  },
  domain: {
    label: 'Domain',
    title: 'Attach the public dashboard host or keep the raw IP',
    blurb: 'Use the exact hostname you want operators to open, then let AgentGLS validate DNS and wire Caddy for TLS.',
  },
  telegram: {
    label: 'Telegram',
    title: 'Bring the operator chat online',
    blurb: 'Store the bot token, start the bridge, and approve a pairing code from the UI.',
  },
  context: {
    label: 'Context',
    title: 'Write the standing business context',
    blurb: 'This becomes the durable context file the runtime will read before future goal work.',
  },
  launch: {
    label: 'Launch',
    title: 'Create the first goal and finish onboarding',
    blurb: 'Seed the first goal file so the dashboard can switch from setup mode into operations.',
  },
}

function stepIsSatisfied(stepId, setupState) {
  if (!setupState) return false

  switch (stepId) {
    case 'admin':
      return Boolean(setupState.adminConfigured)
    case 'provider':
      return Boolean(setupState.provider?.selected && setupState.provider?.installed && setupState.provider?.authenticated)
    case 'domain':
      return Boolean(setupState.domain?.done)
    case 'telegram':
      return Boolean(setupState.telegram?.operational)
    case 'context':
      return Boolean(setupState.context?.configured)
    case 'launch':
      return Boolean(setupState.initialGoal?.configured)
    default:
      return false
  }
}

function deriveCurrentStep(setupState) {
  if (!setupState?.adminConfigured) return 'admin'
  if (!(setupState.provider?.selected && setupState.provider?.installed && setupState.provider?.authenticated)) return 'provider'
  if (!setupState.domain?.done) return 'domain'
  if (!setupState.telegram?.operational) return 'telegram'
  if (!setupState.context?.configured) return 'context'
  if (!setupState.initialGoal?.configured) return 'launch'
  return 'launch'
}

function buildSteps(setupState) {
  return STEP_ORDER.map((id) => {
    const meta = STEP_META[id]
    const complete = stepIsSatisfied(id, setupState)
    let tone = 'pending'
    let status = 'pending'

    if (complete) {
      tone = id === 'telegram' && setupState?.telegram?.skipped ? 'skipped' : 'done'
      status = tone === 'skipped' ? 'skipped' : 'done'
    } else if (id === 'provider' && setupState?.provider?.selected) {
      tone = 'active'
      status = setupState?.provider?.authenticated ? 'ready' : 'auth needed'
    } else if (id === 'telegram' && setupState?.telegram?.configured) {
      tone = 'active'
      status = setupState.telegram.bridgeRunning ? 'running' : 'start bridge'
    } else if (id === 'domain' && setupState?.domain?.configured) {
      tone = 'active'
      status = 'saved'
    }

    return {
      id,
      ...meta,
      complete,
      tone,
      status,
    }
  })
}

function formatTimestamp(value) {
  if (!value) return '-'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleString()
}

function providerAuthMeta(provider) {
  if (provider === 'claude') {
    return {
      authLabel: 'Claude subscription login',
      command: 'claude auth login --claudeai',
      statusCommand: 'claude auth status --json',
      intro: 'Claude Code should use the Claude subscription flow. It opens a browser-based login from the VPS terminal session.',
    }
  }

  if (provider === 'codex') {
    return {
      authLabel: 'ChatGPT / device auth',
      command: 'codex login --device-auth',
      statusCommand: 'codex login status',
      intro: 'Codex should use ChatGPT subscription access. Device auth is the recommended path for remote or headless VPS installs.',
    }
  }

  return {
    authLabel: 'Provider login',
    command: '',
    statusCommand: '',
    intro: '',
  }
}

function StepRail({ steps, currentStep, unlockedIndex, onSelect }) {
  return (
    <div className="setup-rail">
      {steps.map((step, index) => {
        const isActive = step.id === currentStep
        const isUnlocked = index <= unlockedIndex || step.complete
        return (
          <button
            key={step.id}
            type="button"
            className={`setup-rail-item ${isActive ? 'active' : ''} ${step.tone}`}
            onClick={() => isUnlocked && onSelect(step.id)}
            disabled={!isUnlocked}
          >
            <span className="setup-rail-index">{String(index + 1).padStart(2, '0')}</span>
            <span className="setup-rail-copy">
              <span className="setup-rail-label">{step.label}</span>
              <span className="setup-rail-title">{step.title}</span>
            </span>
            <span className={`setup-step-status ${step.tone}`}>{step.status}</span>
          </button>
        )
      })}
    </div>
  )
}

function SnapshotItem({ label, value, tone }) {
  return (
    <div className="setup-snapshot-item">
      <span>{label}</span>
      <strong className={tone || ''}>{value}</strong>
    </div>
  )
}

function PendingPairList({ entries, busyAction, onApprove }) {
  if (!entries.length) {
    return (
      <div className="setup-empty-state">
        No pending chat pair requests yet. Send any message to the bot, then refresh this step.
      </div>
    )
  }

  return (
    <div className="setup-list">
      {entries.map((entry) => (
        <div className="setup-list-row" key={`${entry.chat_id}-${entry.code}`}>
          <div>
            <div className="setup-list-title">
              {entry.display_name || entry.username || entry.chat_id}
            </div>
            <div className="setup-list-copy">
              code <code>{entry.code}</code> | last seen {formatTimestamp(entry.last_seen_at)}
            </div>
          </div>
          <button
            type="button"
            className="btn-sm"
            disabled={busyAction === `pair_${entry.code}`}
            onClick={() => onApprove(entry.code, `pair_${entry.code}`)}
          >
            {busyAction === `pair_${entry.code}` ? 'approving...' : 'approve'}
          </button>
        </div>
      ))}
    </div>
  )
}

function AllowlistList({ entries }) {
  if (!entries.length) {
    return null
  }

  return (
    <div className="setup-list">
      {entries.map((entry) => (
        <div className="setup-list-row" key={`${entry.source}-${entry.chat_id}`}>
          <div>
            <div className="setup-list-title">
              {entry.display_name || entry.username || entry.chat_id}
            </div>
            <div className="setup-list-copy">
              {entry.source} | paired {formatTimestamp(entry.paired_at || entry.updated_at)}
            </div>
          </div>
          <span className="setup-step-status done">{entry.chat_id}</span>
        </div>
      ))}
    </div>
  )
}

function ProviderProbeResult({ result }) {
  if (!result) return null

  const statusClass =
    result.status === 'pass'
      ? 'ok'
      : result.status === 'warn'
        ? 'warn'
        : 'error'

  return (
    <div className={`setup-banner ${statusClass}`}>
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

export default function SetupWizard({
  setupState,
  authenticated,
  onSetupUpdate,
  onAuthenticated,
}) {
  const [adminName, setAdminName] = useState(setupState?.adminName || '')
  const [adminEmail, setAdminEmail] = useState(setupState?.adminEmail || '')
  const [adminPassword, setAdminPassword] = useState('')
  const [provider, setProvider] = useState(setupState?.provider?.selected || 'claude')
  const [providerDirty, setProviderDirty] = useState(false)
  const [providerProbe, setProviderProbe] = useState(null)
  const [domain, setDomain] = useState(setupState?.domain?.value || '')
  const [domainResult, setDomainResult] = useState(null)
  const [telegramToken, setTelegramToken] = useState('')
  const [businessContext, setBusinessContext] = useState(setupState?.context?.text || '')
  const [goalTitle, setGoalTitle] = useState('Define the first operational goal')
  const [goalSummary, setGoalSummary] = useState('')
  const [pairCode, setPairCode] = useState('')
  const [message, setMessage] = useState('')
  const [error, setError] = useState('')
  const [busyAction, setBusyAction] = useState('')
  const [currentStep, setCurrentStep] = useState(() => deriveCurrentStep(setupState))

  useEffect(() => {
    setAdminName(setupState?.adminName || '')
    setAdminEmail(setupState?.adminEmail || '')
    if (!providerDirty) {
      setProvider(setupState?.provider?.selected || 'claude')
    }
    setDomain(setupState?.domain?.value || '')
    setBusinessContext(setupState?.context?.text || '')
  }, [providerDirty, setupState])

  useEffect(() => {
    setProviderProbe(null)
  }, [provider])

  const steps = buildSteps(setupState)
  const completedCount = steps.filter((step) => step.complete).length
  const currentIndex = Math.max(STEP_ORDER.indexOf(currentStep), 0)
  const unlockedIndex = Math.max(STEP_ORDER.indexOf(deriveCurrentStep(setupState)), 0)
  const currentMeta = STEP_META[currentStep]
  const savedProvider = setupState?.provider?.selected || ''
  const providerSaved = provider === savedProvider
  const currentProviderMeta = providerAuthMeta(provider)
  const providerInstallStatus = providerSaved
    ? setupState?.provider?.installStatus || 'pending'
    : savedProvider
      ? `active provider is ${savedProvider}; save to switch`
      : 'save this provider to continue'
  const providerAuthStatus = providerSaved
    ? setupState?.provider?.authStatus || 'pending'
    : 'save this provider to unlock terminal-based authorization'

  async function refreshSetupState(notify = false) {
    setBusyAction('refresh_setup')
    setError('')
    if (notify) setMessage('')

    try {
      const res = await fetch('/api/setup', { cache: 'no-store' })
      const data = await res.json().catch(() => ({}))
      if (!res.ok) {
        throw new Error(data.error || 'Failed to refresh setup state')
      }
      onSetupUpdate(data)
      if (notify) {
        setMessage('Runtime status refreshed')
      }
      return data
    } catch (actionError) {
      setError(actionError instanceof Error ? actionError.message : 'Failed to refresh setup state')
      return null
    } finally {
      setBusyAction('')
    }
  }

  async function executeSetupAction(action, payload = {}, options = {}) {
    setBusyAction(options.busyKey || action)
    setError('')
    setMessage('')

    try {
      const res = await fetch('/api/setup', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action, ...payload }),
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok) {
        throw new Error(data.error || 'Setup action failed')
      }

      onSetupUpdate(data)
      if (action === 'set_admin') {
        onAuthenticated(true)
      }
      if (action === 'set_provider') {
        setProviderDirty(false)
      }

      if (options.clearDomainResult) {
        setDomainResult(null)
      }
      if (options.clearAdminPassword) {
        setAdminPassword('')
      }
      if (options.clearTelegramToken) {
        setTelegramToken('')
      }
      if (options.clearPairCode) {
        setPairCode('')
      }

      setMessage(
        data.telegramMessage ||
          data.installOutput ||
          data.caddyMessage ||
          options.successMessage ||
          'Saved'
      )
      return data
    } catch (actionError) {
      setError(actionError instanceof Error ? actionError.message : 'Setup action failed')
      return null
    } finally {
      setBusyAction('')
    }
  }

  async function runProviderCheck(providerToCheck = provider) {
    setBusyAction('probe_provider')
    setError('')
    setMessage('')

    try {
      const res = await fetch('/api/setup', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'probe_provider', provider: providerToCheck }),
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok) {
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
      const res = await fetch('/api/setup', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'check_domain', host: domain }),
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok) {
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

  function goBack() {
    if (currentIndex > 0) {
      setCurrentStep(STEP_ORDER[currentIndex - 1])
    }
  }

  function goForward() {
    if (currentIndex < STEP_ORDER.length - 1) {
      setCurrentStep(STEP_ORDER[currentIndex + 1])
    }
  }

  async function approvePair(code, busyKey = 'pair_telegram') {
    const data = await executeSetupAction(
      'pair_telegram',
      { code },
      {
        busyKey,
        clearPairCode: true,
        successMessage: `Approved Telegram code ${code}`,
      }
    )
    if (data) {
      setPairCode('')
    }
  }

  const previousStepsComplete =
    stepIsSatisfied('admin', setupState) &&
    stepIsSatisfied('provider', setupState) &&
    stepIsSatisfied('domain', setupState) &&
    stepIsSatisfied('telegram', setupState) &&
    stepIsSatisfied('context', setupState)

  return (
    <div className="dashboard">
      <div className="header">
        <div>
          <h1>AgentGLS // onboarding</h1>
          <div className="refresh">Bootstrap is done. Finish the runtime setup one step at a time.</div>
        </div>
        {authenticated && (
          <button className="logout-btn" onClick={() => onAuthenticated(false)}>
            lock
          </button>
        )}
      </div>

      {(message || error) && (
        <div className={`setup-banner ${error ? 'error' : 'ok'}`}>{error || message}</div>
      )}

      <div className="setup-shell">
        <aside className="section setup-sidebar">
          <div className="section-header">Setup Flow</div>
          <div className="section-body">
            <div className="setup-progress-copy">
              <div>{completedCount}/{STEP_ORDER.length} steps complete</div>
              <div>{setupState?.completed ? 'Runtime ready' : 'Continue until the dashboard unlocks'}</div>
            </div>
            <StepRail
              steps={steps}
              currentStep={currentStep}
              unlockedIndex={unlockedIndex}
              onSelect={setCurrentStep}
            />

            <div className="setup-snapshot">
              <div className="setup-snapshot-title">Runtime Snapshot</div>
              <SnapshotItem
                label="Provider"
                value={setupState?.provider?.selected || 'unset'}
                tone={setupState?.provider?.authenticated ? 'ok' : ''}
              />
              <SnapshotItem
                label="Domain"
                value={
                  setupState?.domain?.configured
                    ? setupState.domain.value
                    : setupState?.domain?.skipped
                      ? 'skipped'
                      : 'raw IP'
                }
                tone={setupState?.domain?.done ? 'ok' : ''}
              />
              <SnapshotItem
                label="Telegram"
                value={
                  setupState?.telegram?.skipped
                    ? 'skipped'
                    : setupState?.telegram?.bridgeRunning
                      ? 'bridge live'
                      : setupState?.telegram?.configured
                        ? 'token stored'
                        : 'pending'
                }
                tone={setupState?.telegram?.operational ? 'ok' : ''}
              />
              <SnapshotItem
                label="Context"
                value={setupState?.context?.configured ? 'written' : 'pending'}
                tone={setupState?.context?.configured ? 'ok' : ''}
              />
            </div>
          </div>
        </aside>

        <section className="section setup-stage">
          <div className="section-header">
            {String(currentIndex + 1).padStart(2, '0')} / {STEP_ORDER.length} {currentMeta.label}
          </div>
          <div className="section-body setup-stage-body">
            <div className="setup-stage-intro">
              <div className="setup-step-title">{currentMeta.title}</div>
              <div className="setup-copy">{currentMeta.blurb}</div>
            </div>

            {currentStep === 'admin' && (
              <>
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
                  placeholder={
                    setupState?.adminConfigured
                      ? 'enter a new password to rotate it'
                      : 'dashboard password'
                  }
                  value={adminPassword}
                  onChange={(event) => setAdminPassword(event.target.value)}
                />
                <div className="setup-copy">
                  The dashboard login and terminal access both use this admin identity.
                </div>
                <div className="form-actions">
                  <button
                    type="button"
                    className="btn-action"
                    disabled={
                      busyAction === 'set_admin' ||
                      !adminName.trim() ||
                      !adminEmail.trim() ||
                      !adminPassword
                    }
                    onClick={() =>
                      executeSetupAction(
                        'set_admin',
                        {
                          name: adminName,
                          email: adminEmail,
                          password: adminPassword,
                        },
                        {
                          clearAdminPassword: true,
                          successMessage: 'Admin account saved',
                        }
                      )
                    }
                  >
                    {busyAction === 'set_admin'
                      ? 'saving...'
                      : setupState?.adminConfigured
                        ? 'save admin changes'
                        : 'create admin'}
                  </button>
                </div>
              </>
            )}

            {currentStep === 'provider' && (
              <>
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
                    Status check: <code>{currentProviderMeta.statusCommand || '-'}</code>
                  </div>
                </div>
                {!providerSaved && (
                  <div className="setup-banner warn">
                    Save this provider as active first. Then the embedded terminal and live check will target it.
                  </div>
                )}
                <div className="setup-copy">
                  {currentProviderMeta.intro}
                </div>
                <div className="setup-copy">
                  Save the provider, run the login command below in the terminal, then refresh the runtime status and rerun the live hello probe.
                </div>
                <div className="setup-detail">
                  <div>
                    Login command: <code>{currentProviderMeta.command || 'save a provider first'}</code>
                  </div>
                </div>
                {providerSaved && setupState?.provider?.authWarning && (
                  <div className="setup-banner warn">{setupState.provider.authWarning}</div>
                )}
                <div className="form-actions">
                  <button
                    type="button"
                    className="btn-action"
                    disabled={busyAction === 'set_provider'}
                    onClick={() =>
                      executeSetupAction(
                        'set_provider',
                        { provider },
                        { successMessage: `${provider} saved as the active provider` }
                      )
                    }
                  >
                    {busyAction === 'set_provider' ? 'saving...' : 'save active provider'}
                  </button>
                  <button
                    type="button"
                    className="btn-sm"
                    disabled={busyAction === 'refresh_setup'}
                    onClick={() => refreshSetupState(true)}
                  >
                    {busyAction === 'refresh_setup' ? 'refreshing...' : 'refresh auth status'}
                  </button>
                  <button
                    type="button"
                    className="btn-sm"
                    disabled={busyAction === 'probe_provider' || !providerSaved}
                    onClick={() => runProviderCheck(provider)}
                  >
                    {busyAction === 'probe_provider' ? 'checking...' : 'run live check'}
                  </button>
                </div>
                {providerSaved && (
                  <div className="embedded-terminal">
                    <div className="setup-subtitle">Embedded terminal</div>
                    <div className="setup-copy">
                      Run <code>{currentProviderMeta.command}</code> here. When the login finishes, use
                      refresh auth status above to reload the provider state.
                    </div>
                    <pre className="setup-command"><code>{currentProviderMeta.command}</code></pre>
                    <TerminalPane />
                  </div>
                )}
                <ProviderProbeResult result={providerProbe} />
              </>
            )}

            {currentStep === 'domain' && (
              <>
                <input
                  type="text"
                  placeholder="dashboard.example.com"
                  value={domain}
                  onChange={(event) => setDomain(event.target.value)}
                />
                <div className="setup-copy">
                  Save the exact public hostname you want to use for the dashboard and terminal
                  websocket. Skip this if you want to keep using the raw IP during bring-up.
                </div>
                {domainResult && (
                  <div className={`setup-banner ${domainResult.matches ? 'ok' : 'warn'}`}>
                    {domainResult.matches
                      ? `${domainResult.host} resolves to ${domainResult.expectedIp}`
                      : `${domainResult.host} resolves to ${domainResult.addresses.join(', ') || 'nothing yet'}; expected ${domainResult.expectedIp}`}
                  </div>
                )}
                <div className="form-actions">
                  <button
                    type="button"
                    className="btn-sm"
                    disabled={busyAction === 'check_domain' || !domain.trim()}
                    onClick={checkDomain}
                  >
                    {busyAction === 'check_domain' ? 'checking...' : 'check dns'}
                  </button>
                  <button
                    type="button"
                    className="btn-action"
                    disabled={busyAction === 'set_domain' || !domain.trim()}
                    onClick={() =>
                      executeSetupAction(
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
                      executeSetupAction(
                        'set_domain',
                        { skip: true },
                        { clearDomainResult: true, successMessage: 'Domain skipped for now' }
                      )
                    }
                  >
                    skip for now
                  </button>
                </div>
              </>
            )}

            {currentStep === 'telegram' && (
              <>
                <input
                  type="password"
                  placeholder={
                    setupState?.telegram?.configured
                      ? `configured: ${setupState.telegram.maskedToken}`
                      : 'telegram bot token'
                  }
                  value={telegramToken}
                  onChange={(event) => setTelegramToken(event.target.value)}
                />
                <div className="setup-detail">
                  <div>
                    Bridge status:{' '}
                    <code>
                      {setupState?.telegram?.skipped
                        ? 'skipped'
                        : setupState?.telegram?.bridgeRunning
                          ? 'running'
                          : setupState?.telegram?.configured
                            ? 'stopped'
                            : 'not configured'}
                    </code>
                  </div>
                  <div>
                    Pending pairs: <code>{setupState?.telegram?.pendingPairs || 0}</code>
                  </div>
                  <div>
                    Allowlisted chats:{' '}
                    <code>
                      {(setupState?.telegram?.allowlistedChats || 0) +
                        (setupState?.telegram?.envAllowlistedChats || 0)}
                    </code>
                  </div>
                  <div>
                    Log file:{' '}
                    <code>{setupState?.telegram?.logFile || '/opt/agentgls/logs/telegram-bridge.log'}</code>
                  </div>
                </div>
                {setupState?.telegram?.statusError && (
                  <div className="setup-banner warn">{setupState.telegram.statusError}</div>
                )}
                <div className="form-actions">
                  <button
                    type="button"
                    className="btn-action"
                    disabled={busyAction === 'set_telegram' || !telegramToken.trim()}
                    onClick={() =>
                      executeSetupAction(
                        'set_telegram',
                        { token: telegramToken },
                        {
                          clearTelegramToken: true,
                          successMessage: 'Telegram token saved and bridge started',
                        }
                      )
                    }
                  >
                    {busyAction === 'set_telegram' ? 'starting...' : 'save token + start bridge'}
                  </button>
                  <button
                    type="button"
                    className="btn-sm"
                    disabled={busyAction === 'restart_telegram' || !setupState?.telegram?.configured}
                    onClick={() =>
                      executeSetupAction(
                        'restart_telegram',
                        {},
                        { successMessage: 'Telegram bridge restarted' }
                      )
                    }
                  >
                    {busyAction === 'restart_telegram' ? 'restarting...' : 'restart bridge'}
                  </button>
                  <button
                    type="button"
                    className="btn-sm"
                    disabled={busyAction === 'refresh_setup'}
                    onClick={() => refreshSetupState(true)}
                  >
                    {busyAction === 'refresh_setup' ? 'refreshing...' : 'refresh'}
                  </button>
                  <button
                    type="button"
                    className="btn-cancel"
                    disabled={busyAction === 'set_telegram'}
                    onClick={() =>
                      executeSetupAction(
                        'set_telegram',
                        { skip: true },
                        { clearTelegramToken: true, successMessage: 'Telegram skipped for now' }
                      )
                    }
                  >
                    skip for now
                  </button>
                </div>

                <div className="setup-subsection">
                  <div className="setup-subtitle">Pair the operator chat</div>
                  <div className="setup-copy">
                    1. Open the bot in Telegram and send any message.
                    <br />
                    2. Refresh this step to load the pending six-character code.
                    <br />
                    3. Approve it here and the chat becomes allowlisted immediately.
                  </div>
                  <div className="form-row">
                    <input
                      type="text"
                      placeholder="pairing code"
                      value={pairCode}
                      onChange={(event) => setPairCode(event.target.value.toUpperCase())}
                    />
                    <button
                      type="button"
                      className="btn-action"
                      disabled={busyAction === 'pair_telegram' || !pairCode.trim()}
                      onClick={() => approvePair(pairCode.trim(), 'pair_telegram')}
                    >
                      {busyAction === 'pair_telegram' ? 'approving...' : 'approve code'}
                    </button>
                  </div>
                </div>

                <div className="setup-subsection">
                  <div className="setup-subtitle">Pending requests</div>
                  <PendingPairList
                    entries={setupState?.telegram?.pendingRequests || []}
                    busyAction={busyAction}
                    onApprove={approvePair}
                  />
                </div>

                <div className="setup-subsection">
                  <div className="setup-subtitle">Allowlisted chats</div>
                  <AllowlistList entries={setupState?.telegram?.allowedChats || []} />
                  {!(setupState?.telegram?.allowedChats || []).length && (
                    <div className="setup-empty-state">No chats have been approved yet.</div>
                  )}
                </div>
              </>
            )}

            {currentStep === 'context' && (
              <>
                <textarea
                  rows={14}
                  placeholder="What the business does, the current operating context, constraints, resources, and what matters right now."
                  value={businessContext}
                  onChange={(event) => setBusinessContext(event.target.value)}
                />
                <div className="setup-copy">
                  This writes <code>/opt/agentgls/goals/_context.md</code> and becomes the
                  baseline context for future GoalLoop work.
                </div>
                <div className="form-actions">
                  <button
                    type="button"
                    className="btn-action"
                    disabled={busyAction === 'set_context' || !businessContext.trim()}
                    onClick={() =>
                      executeSetupAction(
                        'set_context',
                        { text: businessContext },
                        { successMessage: 'Business context saved' }
                      )
                    }
                  >
                    {busyAction === 'set_context' ? 'saving...' : 'save context'}
                  </button>
                </div>
              </>
            )}

            {currentStep === 'launch' && (
              <>
                <div className="setup-summary-grid">
                  <SnapshotItem label="Admin" value={setupState?.adminEmail || 'pending'} tone="ok" />
                  <SnapshotItem
                    label="Provider"
                    value={setupState?.provider?.selected || 'pending'}
                    tone={setupState?.provider?.authenticated ? 'ok' : ''}
                  />
                  <SnapshotItem
                    label="Domain"
                    value={
                      setupState?.domain?.configured
                        ? setupState.domain.value
                        : setupState?.domain?.skipped
                          ? 'skipped'
                          : 'pending'
                    }
                    tone={setupState?.domain?.done ? 'ok' : ''}
                  />
                  <SnapshotItem
                    label="Telegram"
                    value={
                      setupState?.telegram?.skipped
                        ? 'skipped'
                        : setupState?.telegram?.bridgeRunning
                          ? 'ready'
                          : 'pending'
                    }
                    tone={setupState?.telegram?.operational ? 'ok' : ''}
                  />
                  <SnapshotItem
                    label="Context"
                    value={setupState?.context?.configured ? 'written' : 'pending'}
                    tone={setupState?.context?.configured ? 'ok' : ''}
                  />
                  <SnapshotItem
                    label="Goal file"
                    value={setupState?.initialGoal?.path || 'not created'}
                    tone={setupState?.initialGoal?.configured ? 'ok' : ''}
                  />
                </div>

                <input
                  type="text"
                  placeholder="first goal title"
                  value={goalTitle}
                  onChange={(event) => setGoalTitle(event.target.value)}
                />
                <textarea
                  rows={8}
                  placeholder="Describe the first goal clearly enough that the runtime can refine and work it later."
                  value={goalSummary}
                  onChange={(event) => setGoalSummary(event.target.value)}
                />
                <div className="setup-copy">
                  The first goal file is created in <code>/opt/agentgls/goals/active/</code> with{' '}
                  <code>brief_status: draft</code>. After this saves, the setup flow will hand over to
                  the main dashboard.
                </div>
                <div className="form-actions">
                  <button
                    type="button"
                    className="btn-action"
                    disabled={
                      busyAction === 'set_initial_goal' ||
                      !previousStepsComplete ||
                      !goalTitle.trim() ||
                      !goalSummary.trim()
                    }
                    onClick={() =>
                      executeSetupAction(
                        'set_initial_goal',
                        { title: goalTitle, summary: goalSummary },
                        { successMessage: 'First goal created' }
                      )
                    }
                  >
                    {busyAction === 'set_initial_goal'
                      ? 'creating...'
                      : 'create first goal + finish'}
                  </button>
                </div>
              </>
            )}

            <div className="setup-stage-footer">
              <div className="form-actions">
                {currentIndex > 0 && (
                  <button type="button" className="btn-cancel" onClick={goBack}>
                    back
                  </button>
                )}
                {currentStep !== 'launch' && stepIsSatisfied(currentStep, setupState) && (
                  <button type="button" className="btn-sm" onClick={goForward}>
                    continue
                  </button>
                )}
              </div>
            </div>
          </div>
        </section>
      </div>
    </div>
  )
}
