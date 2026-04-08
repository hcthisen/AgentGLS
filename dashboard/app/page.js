'use client'
import { useCallback, useEffect, useState } from 'react'
import ChatTab from './components/ChatTab'
import CompanyTab from './components/CompanyTab'
import GoalsTab from './components/GoalsTab'
import SecretsTab from './components/SecretsTab'
import SettingsTab from './components/SettingsTab'
import SetupWizard from './components/SetupWizard'
import TerminalTab from './components/TerminalTab'
import WorkTab from './components/WorkTab'

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
            <Stat
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
              status={setupState?.telegram?.operational ? 'ok' : 'warn'}
            />
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
  { id: 'work', label: 'work' },
  { id: 'goals', label: 'goals' },
  { id: 'chat', label: 'chat' },
  { id: 'company', label: 'company' },
  { id: 'secrets', label: 'secrets' },
  { id: 'terminal', label: 'terminal' },
  { id: 'settings', label: 'settings' },
]

export default function Home() {
  const [authenticated, setAuthenticated] = useState(false)
  const [adminConfigured, setAdminConfigured] = useState(false)
  const [setupState, setSetupState] = useState(null)
  const [activeTab, setActiveTab] = useState('overview')
  const [loading, setLoading] = useState(true)
  const [redirectTarget, setRedirectTarget] = useState('')

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

  useEffect(() => {
    if (typeof window === 'undefined') return undefined

    const configuredHost = String(setupState?.domain?.value || '').trim().toLowerCase()
    const completed = Boolean(setupState?.completed)
    const currentHost = window.location.hostname.toLowerCase()
    const isLocalHost =
      currentHost === 'localhost' || currentHost === '127.0.0.1' || currentHost === '::1'

    if (!authenticated || !completed || !configuredHost || currentHost === configuredHost || isLocalHost) {
      setRedirectTarget('')
      return undefined
    }

    const target = `https://${configuredHost}`
    setRedirectTarget(target)
    const timer = window.setTimeout(() => {
      window.location.assign(target)
    }, 1200)

    return () => window.clearTimeout(timer)
  }, [authenticated, setupState?.completed, setupState?.domain?.value])

  if (loading) return <div className="loading">...</div>
  if (redirectTarget) {
    return <div className="loading">redirecting to {redirectTarget}...</div>
  }

  const handleLogout = () => {
    document.cookie = 'dashboard_session=; Max-Age=0; path=/'
    setAuthenticated(false)
    loadState()
  }

  if (!adminConfigured) {
    return (
      <SetupWizard
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
      <SetupWizard
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
        {activeTab === 'work' && <WorkTab />}
        {activeTab === 'goals' && <GoalsTab />}
        {activeTab === 'chat' && <ChatTab />}
        {activeTab === 'company' && <CompanyTab setupState={setupState} onSetupUpdate={setSetupState} />}
        {activeTab === 'secrets' && <SecretsTab />}
        {activeTab === 'terminal' && <TerminalTab />}
        {activeTab === 'settings' && <SettingsTab setupState={setupState} onSetupUpdate={setSetupState} />}
      </div>
    </div>
  )
}
