'use client'
import { useCallback, useEffect, useMemo, useState } from 'react'

function formatTimestamp(value) {
  if (!value) return '-'
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return value
  return parsed.toLocaleString()
}

function summarizeText(value, limit = 180) {
  const compact = String(value || '').replace(/\s+/g, ' ').trim()
  if (!compact) return '-'
  if (compact.length <= limit) return compact
  return `${compact.slice(0, limit - 3)}...`
}

function activeGoalTone(goal) {
  if (goal.run_state === 'running') return 'warn'
  if (goal.brief_status !== 'approved') return 'error'
  return 'ok'
}

export default function WorkTab() {
  const [data, setData] = useState(null)
  const [loading, setLoading] = useState(true)
  const [busyAction, setBusyAction] = useState('')
  const [lastUpdate, setLastUpdate] = useState(null)
  const [message, setMessage] = useState('')
  const [error, setError] = useState('')

  const fetchWork = useCallback(async () => {
    try {
      const response = await fetch('/api/work', { cache: 'no-store' })
      if (response.status === 401) {
        window.location.reload()
        return null
      }
      const payload = await response.json().catch(() => ({}))
      if (!response.ok) {
        throw new Error(payload.error || 'Failed to load work state')
      }
      setData(payload)
      setLastUpdate(new Date())
      return payload
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : 'Failed to load work state')
      return null
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void fetchWork()
    const interval = window.setInterval(() => {
      void fetchWork()
    }, 15000)
    return () => window.clearInterval(interval)
  }, [fetchWork])

  const activeGoals = data?.activeGoals || []
  const pausedGoals = data?.pausedGoals || []
  const completedGoals = data?.completedGoals || []
  const scheduledTasks = data?.scheduledTasks || []
  const taskHistory = data?.taskHistory || []
  const heartbeat = data?.heartbeat || { running: false, processes: [], logTail: [] }

  const workStats = useMemo(() => {
    const running = activeGoals.filter((goal) => goal.run_state === 'running').length
    const approved = activeGoals.filter((goal) => goal.brief_status === 'approved').length
    const draft = activeGoals.filter((goal) => goal.brief_status !== 'approved').length
    const scheduledEnabled = scheduledTasks.filter((task) => task.enabled).length
    return {
      running,
      approved,
      draft,
      paused: pausedGoals.length,
      completed: completedGoals.length,
      scheduledEnabled,
    }
  }, [activeGoals, completedGoals.length, pausedGoals.length, scheduledTasks])

  async function triggerHeartbeat() {
    setBusyAction('trigger_heartbeat')
    setError('')
    setMessage('')

    try {
      const response = await fetch('/api/work', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'trigger_heartbeat' }),
      })
      const payload = await response.json().catch(() => ({}))
      if (!response.ok) {
        throw new Error(payload.error || 'Failed to trigger GoalLoop heartbeat')
      }

      setData(payload)
      setLastUpdate(new Date())
      setMessage(payload.message || 'GoalLoop heartbeat triggered')
      window.setTimeout(() => {
        void fetchWork()
      }, 3000)
    } catch (actionError) {
      setError(actionError instanceof Error ? actionError.message : 'Failed to trigger GoalLoop heartbeat')
    } finally {
      setBusyAction('')
    }
  }

  if (loading) return <div className="loading">loading work...</div>

  return (
    <>
      {(message || error) && (
        <div className={`setup-banner ${error ? 'error' : 'ok'}`}>{error || message}</div>
      )}

      <div className="section-header-meta">
        <span className="refresh">{lastUpdate ? `updated ${lastUpdate.toLocaleTimeString()}` : ''}</span>
      </div>

      <div className="section">
        <div className="section-header">Current Work</div>
        <div className="section-body">
          <div className="stat-grid">
            <div className="stat">
              <div className="stat-label">Heartbeat</div>
              <div className={`stat-value ${heartbeat.running ? 'warn' : 'ok'}`}>
                {heartbeat.running ? 'running' : 'idle'}
              </div>
            </div>
            <div className="stat">
              <div className="stat-label">Running goals</div>
              <div className="stat-value warn">{workStats.running}</div>
            </div>
            <div className="stat">
              <div className="stat-label">Approved goals</div>
              <div className="stat-value ok">{workStats.approved}</div>
            </div>
            <div className="stat">
              <div className="stat-label">Draft goals</div>
              <div className="stat-value error">{workStats.draft}</div>
            </div>
            <div className="stat">
              <div className="stat-label">Paused goals</div>
              <div className="stat-value">{workStats.paused}</div>
            </div>
            <div className="stat">
              <div className="stat-label">Enabled schedules</div>
              <div className="stat-value">{workStats.scheduledEnabled}</div>
            </div>
          </div>

          <div className="setup-detail" style={{ marginTop: '0.75rem' }}>
            <div>
              Heartbeat process: <code>{heartbeat.running ? 'active' : 'not running'}</code>
            </div>
            <div>
              Current process count: <code>{heartbeat.processes?.length || 0}</code>
            </div>
            <div>
              Latest heartbeat log:{' '}
              <code>{heartbeat.logTail?.length ? heartbeat.logTail[heartbeat.logTail.length - 1] : 'no heartbeat log yet'}</code>
            </div>
          </div>

          <div className="form-actions" style={{ marginBottom: '0.9rem' }}>
            <button
              type="button"
              className="btn-action"
              disabled={busyAction === 'trigger_heartbeat' || heartbeat.running}
              onClick={() => void triggerHeartbeat()}
            >
              {busyAction === 'trigger_heartbeat' ? 'triggering...' : 'run heartbeat now'}
            </button>
            <button
              type="button"
              className="btn-sm"
              disabled={busyAction === 'refresh_work'}
              onClick={() => void fetchWork()}
            >
              refresh work
            </button>
          </div>

          <table>
            <thead>
              <tr>
                <th>Goal</th>
                <th>State</th>
                <th>Priority</th>
                <th>Next eligible</th>
                <th>Last run</th>
              </tr>
            </thead>
            <tbody>
              {activeGoals.map((goal) => (
                <tr key={`${goal.status}-${goal.slug}`}>
                  <td>
                    <div>{goal.title || goal.slug}</div>
                    <div style={{ color: 'var(--text-dim)', fontSize: '11px' }}>{summarizeText(goal.objective, 90)}</div>
                  </td>
                  <td>
                    <span className={`goal-state ${activeGoalTone(goal)}`}>
                      {goal.brief_status} / {goal.run_state}
                    </span>
                  </td>
                  <td>{goal.priority || 'medium'}</td>
                  <td>{formatTimestamp(goal.next_eligible_at)}</td>
                  <td>{formatTimestamp(goal.last_run)}</td>
                </tr>
              ))}
              {activeGoals.length === 0 && (
                <tr>
                  <td colSpan="5" style={{ color: 'var(--text-dim)' }}>
                    No active GoalLoop work files are present.
                  </td>
                </tr>
              )}
            </tbody>
          </table>

          {pausedGoals.length > 0 && (
            <div className="work-subsection">
              <div className="setup-subtitle">Paused Goals</div>
              <table>
                <thead>
                  <tr>
                    <th>Goal</th>
                    <th>Priority</th>
                    <th>Last run</th>
                    <th>Updated</th>
                  </tr>
                </thead>
                <tbody>
                  {pausedGoals.map((goal) => (
                    <tr key={`paused-${goal.slug}`}>
                      <td>{goal.title || goal.slug}</td>
                      <td>{goal.priority || 'medium'}</td>
                      <td>{formatTimestamp(goal.last_run)}</td>
                      <td>{formatTimestamp(goal.updated_at)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          {heartbeat.logTail?.length > 0 && (
            <div className="work-subsection">
              <div className="setup-subtitle">Heartbeat Log</div>
              <pre className="work-log">{heartbeat.logTail.join('\n')}</pre>
            </div>
          )}
        </div>
      </div>

      <div className="section">
        <div className="section-header">Scheduled Work</div>
        <div className="section-body">
          <table>
            <thead>
              <tr>
                <th>Name</th>
                <th>Cron</th>
                <th>Status</th>
                <th>Last run</th>
                <th>Last result</th>
              </tr>
            </thead>
            <tbody>
              {scheduledTasks.map((task) => (
                <tr key={task.id}>
                  <td>{task.name}</td>
                  <td><code>{task.cron_expr}</code></td>
                  <td>{task.enabled ? 'enabled' : 'disabled'}</td>
                  <td>{formatTimestamp(task.last_run)}</td>
                  <td>{summarizeText(task.last_result, 110)}</td>
                </tr>
              ))}
              {scheduledTasks.length === 0 && (
                <tr>
                  <td colSpan="5" style={{ color: 'var(--text-dim)' }}>
                    No scheduled tasks are configured yet.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      <div className="section">
        <div className="section-header">Past Work</div>
        <div className="section-body">
          <div className="work-subsection">
            <div className="setup-subtitle">Completed Goals</div>
            <table>
              <thead>
                <tr>
                  <th>Goal</th>
                  <th>Priority</th>
                  <th>Last run</th>
                  <th>Updated</th>
                </tr>
              </thead>
              <tbody>
                {completedGoals.slice(0, 20).map((goal) => (
                  <tr key={`completed-${goal.slug}`}>
                    <td>{goal.title || goal.slug}</td>
                    <td>{goal.priority || 'medium'}</td>
                    <td>{formatTimestamp(goal.last_run)}</td>
                    <td>{formatTimestamp(goal.updated_at)}</td>
                  </tr>
                ))}
                {completedGoals.length === 0 && (
                  <tr>
                    <td colSpan="4" style={{ color: 'var(--text-dim)' }}>
                      No completed goals yet.
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>

          <div className="work-subsection">
            <div className="setup-subtitle">Recent Scheduled Task Runs</div>
            <table>
              <thead>
                <tr>
                  <th>Task</th>
                  <th>When</th>
                  <th>Result</th>
                </tr>
              </thead>
              <tbody>
                {taskHistory.map((entry) => (
                  <tr key={entry.id}>
                    <td>{entry.task_name || entry.task_id}</td>
                    <td>{formatTimestamp(entry.created_at)}</td>
                    <td>{summarizeText(entry.result, 150)}</td>
                  </tr>
                ))}
                {taskHistory.length === 0 && (
                  <tr>
                    <td colSpan="3" style={{ color: 'var(--text-dim)' }}>
                      No scheduled task history yet.
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </>
  )
}
