'use client'
import { useCallback, useEffect, useMemo, useState } from 'react'
import SecretsTab from './components/SecretsTab'
import TerminalTab from './components/TerminalTab'

function Stat({ label, value, status }) {
  return (
    <div className="stat">
      <div className="stat-label">{label}</div>
      <div className={`stat-value ${status || ''}`}>{value}</div>
    </div>
  )
}

function ServiceStatus({ name, status }) {
  const isOk = status === 'active' || status === 'reachable'
  return (
    <span style={{ marginRight: '1rem' }}>
      <span className={`dot ${isOk ? 'green' : 'red'}`}></span>
      {name}
    </span>
  )
}

function BarChart({ data }) {
  if (!data || !data.length) return <div style={{ color: 'var(--text-dim)' }}>No data</div>
  const max = Math.max(...data.map((d) => d.count), 1)
  return (
    <div className="bar-chart">
      {data.map((d, i) => (
        <div className="bar-row" key={i}>
          <div className="bar-label">{d.date || d.ip || d.label}</div>
          <div className="bar-track">
            <div className="bar-fill" style={{ width: `${(d.count / max) * 100}%` }}></div>
          </div>
          <div className="bar-value">{d.count}</div>
        </div>
      ))}
    </div>
  )
}

function LoginForm({ adminEmail, onLogin }) {
  const [email, setEmail] = useState(adminEmail || '')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    setEmail(adminEmail || '')
  }, [adminEmail])

  const handleSubmit = async (e) => {
    e.preventDefault()
    setLoading(true)
    setError('')

    try {
      const res = await fetch('/api/auth', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password }),
      })
      const data = await res.json().catch(() => ({}))
      if (res.ok) {
        onLogin()
      } else {
        setError(data.error || 'Invalid credentials')
      }
    } catch {
      setError('Connection error')
    }

    setLoading(false)
  }

  return (
    <div className="login-container">
      <form className="login-box" onSubmit={handleSubmit}>
        <h1>AgentGLS // login</h1>
        <p className="login-copy">Continue the VPS onboarding or open the operational dashboard.</p>
        {error && <div className="login-error">{error}</div>}
        <input
          type="email"
          placeholder="admin email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          autoFocus
        />
        <input
          type="password"
          placeholder="password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
        <button type="submit" disabled={loading}>
          {loading ? 'authenticating...' : 'authenticate'}
        </button>
      </form>
    </div>
  )
}

function SetupCard({ title, status, children }) {
  const statusClass = status === 'done' ? 'ok' : status === 'active' ? 'warn' : ''

  return (
    <div className="section setup-card">
      <div className="section-header setup-card-header">
        <span>{title}</span>
        <span className={`setup-badge ${statusClass}`}>{status}</span>
      </div>
      <div className="section-body">{children}</div>
    </div>
  )
}

function SetupPanel({ setupState, authenticated, onSetupUpdate, onAuthenticated }) {
  const [adminName, setAdminName] = useState(setupState?.adminName || '')
  const [adminEmail, setAdminEmail] = useState(setupState?.adminEmail || '')
  const [adminPassword, setAdminPassword] = useState('')
  const [provider, setProvider] = useState(setupState?.provider?.selected || 'claude')
  const [domain, setDomain] = useState(setupState?.domain?.value || '')
  const [domainResult, setDomainResult] = useState(null)
  const [telegramToken, setTelegramToken] = useState('')
  const [businessContext, setBusinessContext] = useState('')
  const [goalTitle, setGoalTitle] = useState('')
  const [goalSummary, setGoalSummary] = useState('')
  const [message, setMessage] = useState('')
  const [error, setError] = useState('')
  const [busyAction, setBusyAction] = useState('')

  useEffect(() => {
    setAdminName(setupState?.adminName || '')
    setAdminEmail(setupState?.adminEmail || '')
    setProvider(setupState?.provider?.selected || 'claude')
    setDomain(setupState?.domain?.value || '')
  }, [setupState])

  const runSetupAction = useCallback(
    async (action, payload = {}) => {
      setBusyAction(action)
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

        setMessage(data.installOutput || data.caddyMessage || 'Saved')
        return data
      } catch (actionError) {
        setError(actionError instanceof Error ? actionError.message : 'Setup action failed')
        return null
      } finally {
        setBusyAction('')
      }
    },
    [onAuthenticated, onSetupUpdate]
  )

  const checkDomain = async () => {
    setBusyAction('check_domain')
    setError('')
    setMessage('')
    try {
      const res = await fetch('/api/setup', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'check_domain', domain }),
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok) {
        throw new Error(data.error || 'DNS check failed')
      }
      setDomainResult(data)
      setMessage(data.matches ? 'DNS matches this VPS.' : 'DNS does not point at this VPS yet.')
    } catch (actionError) {
      setError(actionError instanceof Error ? actionError.message : 'DNS check failed')
    } finally {
      setBusyAction('')
    }
  }

  const providerStatus = useMemo(() => {
    if (!setupState?.provider?.selected) return 'pending'
    if (setupState.provider.installed && setupState.provider.authenticated) return 'done'
    if (setupState.provider.installed) return 'active'
    return 'pending'
  }, [setupState])

  const domainStatus = setupState?.domain?.done ? 'done' : 'pending'
  const telegramStatus = setupState?.telegram?.done ? 'done' : 'pending'
  const contextStatus = setupState?.context?.configured ? 'done' : 'pending'
  const goalStatus = setupState?.initialGoal?.configured ? 'done' : 'pending'

  return (
    <div className="dashboard">
      <div className="header">
        <div>
          <h1>AgentGLS // onboarding</h1>
          <div className="refresh">Bootstrap is done. Finish runtime setup here.</div>
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

      <div className="setup-grid">
        <SetupCard title="1. Admin account" status={setupState?.adminConfigured ? 'done' : 'active'}>
          <p className="setup-copy">
            Protect the dashboard first. This also unlocks the web terminal for provider auth.
          </p>
          <div className="setup-form-grid">
            <input
              type="text"
              placeholder="admin name"
              value={adminName}
              onChange={(e) => setAdminName(e.target.value)}
            />
            <input
              type="email"
              placeholder="admin email"
              value={adminEmail}
              onChange={(e) => setAdminEmail(e.target.value)}
            />
          </div>
          <input
            type="password"
            placeholder={setupState?.adminConfigured ? 'set a new password' : 'password'}
            value={adminPassword}
            onChange={(e) => setAdminPassword(e.target.value)}
          />
          <div className="form-actions">
            <button
              className="btn-action"
              disabled={busyAction === 'set_admin'}
              onClick={() =>
                runSetupAction('set_admin', {
                  name: adminName,
                  email: adminEmail,
                  password: adminPassword,
                })
              }
            >
              {busyAction === 'set_admin' ? 'saving...' : setupState?.adminConfigured ? 'update admin' : 'create admin'}
            </button>
          </div>
        </SetupCard>

        <SetupCard title="2. Provider selection" status={providerStatus}>
          <p className="setup-copy">
            Install only the active runtime now. You can add the other CLI later with the documented manual path.
          </p>
          <div className="provider-choice">
            <label className={`choice ${provider === 'claude' ? 'selected' : ''}`}>
              <input type="radio" checked={provider === 'claude'} onChange={() => setProvider('claude')} />
              <span>Claude Code</span>
            </label>
            <label className={`choice ${provider === 'codex' ? 'selected' : ''}`}>
              <input type="radio" checked={provider === 'codex'} onChange={() => setProvider('codex')} />
              <span>OpenAI Codex</span>
            </label>
          </div>
          {setupState?.provider?.selected && (
            <div className="setup-detail">
              <div>Selected: <code>{setupState.provider.selected}</code></div>
              <div>Install status: <code>{setupState.provider.installStatus}</code></div>
              <div>Auth status: <code>{setupState.provider.authStatus}</code></div>
            </div>
          )}
          <div className="form-actions">
            <button
              className="btn-action"
              disabled={busyAction === 'set_provider'}
              onClick={() => runSetupAction('set_provider', { provider })}
            >
              {busyAction === 'set_provider' ? 'installing...' : 'save + install provider'}
            </button>
          </div>
        </SetupCard>

        <SetupCard title="3. Provider auth" status={setupState?.provider?.authenticated ? 'done' : 'active'}>
          <p className="setup-copy">
            Use the embedded terminal below for the one-time login flow, then re-check status here.
          </p>
          <div className="setup-detail">
            <div>Recommended command: <code>{setupState?.provider?.authCommand || 'choose a provider first'}</code></div>
            <div>Manual install later: <code>{setupState?.provider?.manualInstallCommand || 'n/a'}</code></div>
          </div>
          <div className="form-actions">
            <button className="btn-action" disabled={busyAction === 'refresh'} onClick={() => onSetupUpdate(null)}>
              refresh status
            </button>
          </div>
          {setupState?.adminConfigured && (
            <div className="embedded-terminal">
              <TerminalTab />
            </div>
          )}
        </SetupCard>

        <SetupCard title="4. Domain" status={domainStatus}>
          <p className="setup-copy">
            Point <code>dashboard.yourdomain.com</code> at this VPS for automatic TLS, or skip and keep using the raw IP.
          </p>
          <input
            type="text"
            placeholder="example.com"
            value={domain}
            onChange={(e) => setDomain(e.target.value)}
          />
          {domainResult && (
            <div className={`setup-banner ${domainResult.matches ? 'ok' : 'warn'}`}>
              {domainResult.matches
                ? `${domainResult.domain} resolves to ${domainResult.expectedIp}`
                : `${domainResult.domain} resolves to ${domainResult.addresses.join(', ') || 'nothing yet'}; expected ${domainResult.expectedIp}`}
            </div>
          )}
          <div className="form-actions">
            <button className="btn-sm" disabled={busyAction === 'check_domain'} onClick={checkDomain}>
              check dns
            </button>
            <button
              className="btn-action"
              disabled={busyAction === 'set_domain'}
              onClick={() => runSetupAction('set_domain', { domain })}
            >
              {busyAction === 'set_domain' ? 'saving...' : 'save domain'}
            </button>
            <button className="btn-cancel" disabled={busyAction === 'set_domain'} onClick={() => runSetupAction('set_domain', { skip: true })}>
              skip for now
            </button>
          </div>
        </SetupCard>

        <SetupCard title="5. Telegram" status={telegramStatus}>
          <p className="setup-copy">
            Store the bot token here, then pair the operator chat with <code>/opt/agentos/scripts/telegram-setup.sh</code>.
          </p>
          <input
            type="password"
            placeholder={setupState?.telegram?.configured ? `configured: ${setupState.telegram.maskedToken}` : 'bot token'}
            value={telegramToken}
            onChange={(e) => setTelegramToken(e.target.value)}
          />
          <div className="form-actions">
            <button
              className="btn-action"
              disabled={busyAction === 'set_telegram'}
              onClick={() => runSetupAction('set_telegram', { token: telegramToken })}
            >
              {busyAction === 'set_telegram' ? 'saving...' : 'save token'}
            </button>
            <button className="btn-cancel" disabled={busyAction === 'set_telegram'} onClick={() => runSetupAction('set_telegram', { skip: true })}>
              skip for now
            </button>
          </div>
        </SetupCard>

        <SetupCard title="6. Business context" status={contextStatus}>
          <p className="setup-copy">
            This becomes <code>/opt/agentos/goals/_context.md</code> and is the standing context for future GoalLoop work.
          </p>
          <textarea
            rows={8}
            placeholder="What the business does, current situation, constraints, and what matters most right now."
            value={businessContext}
            onChange={(e) => setBusinessContext(e.target.value)}
          />
          <div className="form-actions">
            <button
              className="btn-action"
              disabled={busyAction === 'set_context'}
              onClick={() => runSetupAction('set_context', { text: businessContext })}
            >
              {busyAction === 'set_context' ? 'saving...' : 'save context'}
            </button>
          </div>
        </SetupCard>

        <SetupCard title="7. Initial goal" status={goalStatus}>
          <p className="setup-copy">
            The first goal file is created in <code>/opt/agentos/goals/active/</code> with <code>brief_status: draft</code>.
          </p>
          <input
            type="text"
            placeholder="goal title"
            value={goalTitle}
            onChange={(e) => setGoalTitle(e.target.value)}
          />
          <textarea
            rows={6}
            placeholder="Describe the first goal clearly enough that the runtime can refine and work it later."
            value={goalSummary}
            onChange={(e) => setGoalSummary(e.target.value)}
          />
          <div className="form-actions">
            <button
              className="btn-action"
              disabled={busyAction === 'set_initial_goal'}
              onClick={() => runSetupAction('set_initial_goal', { title: goalTitle, summary: goalSummary })}
            >
              {busyAction === 'set_initial_goal' ? 'creating...' : 'create first goal'}
            </button>
          </div>
        </SetupCard>
      </div>
    </div>
  )
}

function OverviewTab({ setupState }) {
  const [data, setData] = useState(null)
  const [loading, setLoading] = useState(true)
  const [lastUpdate, setLastUpdate] = useState(null)

  const fetchData = useCallback(async () => {
    try {
      const res = await fetch('/api/security')
      if (res.status === 401) {
        window.location.reload()
        return
      }
      if (res.ok) {
        setData(await res.json())
        setLastUpdate(new Date())
      }
    } catch {
      /* retry next cycle */
    }
    setLoading(false)
  }, [])

  useEffect(() => {
    fetchData()
    const interval = setInterval(fetchData, 60000)
    return () => clearInterval(interval)
  }, [fetchData])

  if (loading) return <div className="loading">loading...</div>
  if (!data) return <div className="loading">failed to load data</div>

  const h = data.health || {}
  const s = data.stats || {}
  const services = h.services || {}
  const cpuStatus = (h.cpu_percent || 0) > 80 ? 'error' : (h.cpu_percent || 0) > 50 ? 'warn' : 'ok'
  const ramPercent = h.ram_total_mb ? ((h.ram_used_mb / h.ram_total_mb) * 100).toFixed(0) : 0
  const ramStatus = ramPercent > 80 ? 'error' : ramPercent > 60 ? 'warn' : 'ok'
  const diskPercent = h.disk_total_gb ? ((h.disk_used_gb / h.disk_total_gb) * 100).toFixed(0) : 0

  return (
    <>
      <div className="section-header-meta">
        <span className="refresh">{lastUpdate ? `updated ${lastUpdate.toLocaleTimeString()}` : ''}</span>
      </div>

      <div className="section">
        <div className="section-header">Server Health</div>
        <div className="section-body">
          <div className="stat-grid">
            <Stat label="CPU" value={`${h.cpu_percent || 0}%`} status={cpuStatus} />
            <Stat label="RAM" value={`${h.ram_used_mb || 0}/${h.ram_total_mb || 0} MB`} status={ramStatus} />
            <Stat label="Disk" value={`${h.disk_used_gb || 0}/${h.disk_total_gb || 0} GB (${diskPercent}%)`} />
            <Stat label="Load" value={h.load_avg || '-'} />
            <Stat label="Uptime" value={h.uptime || '-'} />
            <Stat label="Connections" value={h.active_connections || 0} />
          </div>
        </div>
      </div>

      <div className="section">
        <div className="section-header">Active Runtime</div>
        <div className="section-body">
          <div className="stat-grid">
            <Stat label="Provider" value={setupState?.provider?.selected || 'unset'} status={setupState?.provider?.selected ? 'ok' : 'warn'} />
            <Stat label="Installed" value={setupState?.provider?.installed ? 'yes' : 'no'} status={setupState?.provider?.installed ? 'ok' : 'error'} />
            <Stat label="Authenticated" value={setupState?.provider?.authenticated ? 'yes' : 'no'} status={setupState?.provider?.authenticated ? 'ok' : 'error'} />
            <Stat label="Telegram" value={setupState?.telegram?.configured ? 'token stored' : setupState?.telegram?.skipped ? 'skipped' : 'pending'} status={setupState?.telegram?.configured ? 'ok' : 'warn'} />
          </div>
        </div>
      </div>

      <div className="section">
        <div className="section-header">Services</div>
        <div className="section-body">
          {Object.entries(services).map(([name, status]) => (
            <ServiceStatus key={name} name={name} status={status} />
          ))}
        </div>
      </div>

      <div className="section">
        <div className="section-header">Security</div>
        <div className="section-body">
          <div className="stat-grid">
            <Stat label="Banned IPs" value={s.total_banned || 0} status={(s.total_banned || 0) > 50 ? 'warn' : 'ok'} />
            <Stat label="Failed Attempts" value={s.total_failed || 0} />
            <Stat label="Total Logins" value={s.total_logins || 0} />
          </div>
        </div>
      </div>

      {h.failed_per_day?.length > 0 && (
        <div className="section">
          <div className="section-header">Failed Logins / Day (7d)</div>
          <div className="section-body"><BarChart data={h.failed_per_day} /></div>
        </div>
      )}

      {h.top_attackers?.length > 0 && (
        <div className="section">
          <div className="section-header">Top Attackers</div>
          <div className="section-body"><BarChart data={h.top_attackers} /></div>
        </div>
      )}

      <div className="section">
        <div className="section-header">Recent Bans ({(data.bans || []).length})</div>
        <div className="section-body">
          <table>
            <thead><tr><th>IP</th><th>Country</th><th>Jail</th><th>Time</th></tr></thead>
            <tbody>
              {(data.bans || []).slice(0, 20).map((ban, i) => (
                <tr key={i}>
                  <td>{ban.ip}</td>
                  <td>{ban.country_code ? `${ban.country_code} ${ban.country || ''}` : '-'}</td>
                  <td>{ban.jail}</td>
                  <td>{ban.banned_at ? new Date(ban.banned_at).toLocaleString() : '-'}</td>
                </tr>
              ))}
              {(data.bans || []).length === 0 && (
                <tr><td colSpan="4" style={{ color: 'var(--text-dim)' }}>No bans recorded</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      <div className="section">
        <div className="section-header">Login History</div>
        <div className="section-body">
          <table>
            <thead><tr><th>User</th><th>IP</th><th>Type</th><th>Time</th><th>Duration</th></tr></thead>
            <tbody>
              {(data.logins || []).slice(0, 20).map((login, i) => (
                <tr key={i}>
                  <td>{login.user_name}</td>
                  <td>{login.ip || '-'}</td>
                  <td>{login.session_type}</td>
                  <td>{login.login_at || '-'}</td>
                  <td>{login.duration || '-'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </>
  )
}

const TABS = [
  { id: 'overview', label: 'overview' },
  { id: 'secrets', label: 'secrets' },
  { id: 'terminal', label: 'terminal' },
]

export default function Home() {
  const [authenticated, setAuthenticated] = useState(false)
  const [adminConfigured, setAdminConfigured] = useState(false)
  const [setupState, setSetupState] = useState(null)
  const [activeTab, setActiveTab] = useState('overview')
  const [loading, setLoading] = useState(true)

  const loadState = useCallback(async () => {
    setLoading(true)
    try {
      const authRes = await fetch('/api/auth/check')
      const auth = authRes.ok
        ? await authRes.json()
        : { authenticated: false, adminConfigured: false, adminEmail: '' }
      setAuthenticated(Boolean(auth.authenticated))
      setAdminConfigured(Boolean(auth.adminConfigured))

      if (!auth.adminConfigured || auth.authenticated) {
        const setupRes = await fetch('/api/setup')
        if (setupRes.ok) {
          setSetupState(await setupRes.json())
        }
      } else {
        setSetupState((prev) => ({ ...(prev || {}), adminEmail: auth.adminEmail || '' }))
      }
    } catch {
      setAuthenticated(false)
      setAdminConfigured(false)
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    loadState()
  }, [loadState])

  if (loading) return <div className="loading">...</div>

  const handleLogout = () => {
    document.cookie = 'dashboard_session=; Max-Age=0; path=/'
    setAuthenticated(false)
    loadState()
  }

  if (!adminConfigured) {
    return (
      <SetupPanel
        setupState={setupState}
        authenticated={authenticated}
        onAuthenticated={setAuthenticated}
        onSetupUpdate={(next) => {
          if (next) {
            setSetupState(next)
            setAdminConfigured(Boolean(next.adminConfigured))
          } else {
            loadState()
          }
        }}
      />
    )
  }

  if (!authenticated) {
    return <LoginForm adminEmail={setupState?.adminEmail || ''} onLogin={loadState} />
  }

  if (!setupState?.completed) {
    return (
      <SetupPanel
        setupState={setupState}
        authenticated={authenticated}
        onAuthenticated={(value) => {
          if (!value) handleLogout()
          else setAuthenticated(true)
        }}
        onSetupUpdate={(next) => {
          if (next) setSetupState(next)
          else loadState()
        }}
      />
    )
  }

  return (
    <div className="dashboard">
      <div className="header">
        <div>
          <h1>AgentGLS // dashboard</h1>
          <div className="refresh">
            provider {setupState?.provider?.selected || 'unset'} | {setupState?.adminEmail || 'admin'}
          </div>
        </div>
        <button className="logout-btn" onClick={handleLogout}>logout</button>
      </div>

      <div className="tab-nav">
        {TABS.map((tab) => (
          <button
            key={tab.id}
            className={`tab-item ${activeTab === tab.id ? 'active' : ''}`}
            onClick={() => setActiveTab(tab.id)}
          >
            {tab.label}
          </button>
        ))}
      </div>

      <div className="tab-content">
        {activeTab === 'overview' && <OverviewTab setupState={setupState} />}
        {activeTab === 'secrets' && <SecretsTab />}
        {activeTab === 'terminal' && <TerminalTab />}
      </div>
    </div>
  )
}
