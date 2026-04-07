'use client'
import { useCallback, useEffect, useMemo, useState } from 'react'

function formatTimestamp(value) {
  if (!value) return '-'
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return value
  return parsed.toLocaleString()
}

function finishCriteriaProgress(criteria) {
  const list = Array.isArray(criteria) ? criteria : []
  const total = list.length
  const done = list.filter((item) => item?.done).length
  return { done, total }
}

function scoreboardSummary(scoreboard) {
  const entries = Object.entries(scoreboard || {})
  if (!entries.length) return 'No scoreboard data'
  return entries
    .slice(0, 3)
    .map(([metric, value]) => `${metric}: ${value}`)
    .join(' | ')
}

function statusTone(goal) {
  if (goal.run_state === 'running') return 'warn'
  if (goal.status === 'completed') return 'ok'
  if (goal.status === 'paused') return 'error'
  return 'ok'
}

export default function GoalsTab() {
  const [data, setData] = useState(null)
  const [loading, setLoading] = useState(true)
  const [lastUpdate, setLastUpdate] = useState(null)

  const fetchGoals = useCallback(async () => {
    try {
      const response = await fetch('/api/goals')
      if (response.status === 401) {
        window.location.reload()
        return
      }
      if (response.ok) {
        setData(await response.json())
        setLastUpdate(new Date())
      }
    } catch {
      /* retry on next interval */
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    fetchGoals()
    const interval = setInterval(fetchGoals, 60000)
    return () => clearInterval(interval)
  }, [fetchGoals])

  const childMap = useMemo(() => {
    const map = new Map()
    for (const goal of data?.goals || []) {
      if (!goal.parent) continue
      const current = map.get(goal.parent) || []
      current.push(goal)
      map.set(goal.parent, current)
    }
    return map
  }, [data])

  if (loading) return <div className="loading">loading goals...</div>
  if (!data) return <div className="loading">failed to load goals</div>

  const goals = data.goals || []
  const stats = data.stats || {}

  return (
    <>
      <div className="section-header-meta">
        <span className="refresh">{lastUpdate ? `updated ${lastUpdate.toLocaleTimeString()}` : ''}</span>
      </div>

      <div className="section">
        <div className="section-header">Goals Overview</div>
        <div className="section-body">
          <div className="stat-grid">
            <div className="stat">
              <div className="stat-label">Total goals</div>
              <div className="stat-value">{stats.total || 0}</div>
            </div>
            <div className="stat">
              <div className="stat-label">Active</div>
              <div className="stat-value ok">{stats.active || 0}</div>
            </div>
            <div className="stat">
              <div className="stat-label">Paused</div>
              <div className="stat-value error">{stats.paused || 0}</div>
            </div>
            <div className="stat">
              <div className="stat-label">Completed</div>
              <div className="stat-value ok">{stats.completed || 0}</div>
            </div>
            <div className="stat">
              <div className="stat-label">Running now</div>
              <div className="stat-value warn">{stats.running || 0}</div>
            </div>
            <div className="stat">
              <div className="stat-label">Manual approval</div>
              <div className="stat-value">{stats.manualApproval || 0}</div>
            </div>
          </div>
        </div>
      </div>

      {goals.length === 0 ? (
        <div className="section">
          <div className="section-body" style={{ color: 'var(--text-dim)' }}>
            No projected goals yet. Goal files will appear here after `goalloop-sync.sh` runs.
          </div>
        </div>
      ) : (
        <div className="goal-grid">
          {goals.map((goal) => {
            const children = childMap.get(goal.slug) || []
            const criteria = finishCriteriaProgress(goal.finish_criteria)

            return (
              <div className="goal-card" key={goal.slug}>
                <div className="goal-card-header">
                  <div>
                    <div className="goal-title">{goal.title || goal.slug}</div>
                    <div className="goal-slug">{goal.slug}</div>
                  </div>
                  <div className={`goal-state ${statusTone(goal)}`}>
                    {goal.status} / {goal.run_state || 'idle'}
                  </div>
                </div>

                <div className="goal-meta-grid">
                  <div className="goal-meta-item">
                    <span>Priority</span>
                    <strong>{goal.priority || 'medium'}</strong>
                  </div>
                  <div className="goal-meta-item">
                    <span>Brief</span>
                    <strong>{goal.brief_status || 'draft'}</strong>
                  </div>
                  <div className="goal-meta-item">
                    <span>Approval</span>
                    <strong>{goal.approval_policy || 'auto'}</strong>
                  </div>
                  <div className="goal-meta-item">
                    <span>Heartbeat</span>
                    <strong>{goal.heartbeat_minutes || 60} min</strong>
                  </div>
                </div>

                {goal.objective && <div className="goal-objective">{goal.objective}</div>}

                <div className="goal-summary-row">
                  <span>Finish criteria</span>
                  <strong>
                    {criteria.done}/{criteria.total || 0} complete
                  </strong>
                </div>
                <div className="goal-summary-row">
                  <span>Scoreboard</span>
                  <strong>{scoreboardSummary(goal.scoreboard)}</strong>
                </div>
                <div className="goal-summary-row">
                  <span>Last run</span>
                  <strong>{formatTimestamp(goal.last_run)}</strong>
                </div>
                <div className="goal-summary-row">
                  <span>Next eligible</span>
                  <strong>{formatTimestamp(goal.next_eligible_at)}</strong>
                </div>
                <div className="goal-summary-row">
                  <span>Measurement due</span>
                  <strong>{formatTimestamp(goal.measurement_due_at)}</strong>
                </div>
                <div className="goal-summary-row">
                  <span>Deadline</span>
                  <strong>{formatTimestamp(goal.deadline_at)}</strong>
                </div>

                {(goal.parent || children.length > 0) && (
                  <div className="goal-relations">
                    {goal.parent && (
                      <div>
                        <span>Parent</span>
                        <strong>{goal.parent}</strong>
                      </div>
                    )}
                    {children.length > 0 && (
                      <div>
                        <span>Children</span>
                        <strong>{children.map((child) => child.title || child.slug).join(', ')}</strong>
                      </div>
                    )}
                  </div>
                )}
              </div>
            )
          })}
        </div>
      )}
    </>
  )
}
