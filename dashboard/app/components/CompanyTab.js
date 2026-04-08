'use client'
import { useEffect, useState } from 'react'

export default function CompanyTab({ setupState, onSetupUpdate }) {
  const [contextText, setContextText] = useState(setupState?.context?.text || '')
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const [error, setError] = useState('')

  useEffect(() => {
    setContextText(setupState?.context?.text || '')
  }, [setupState?.context?.text])

  async function saveContext() {
    setBusy(true)
    setError('')
    setMessage('')

    try {
      const response = await fetch('/api/setup', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'set_context', text: contextText }),
      })
      const data = await response.json().catch(() => ({}))
      if (!response.ok) {
        throw new Error(data.error || 'Failed to save company context')
      }

      onSetupUpdate(data)
      setMessage('Company context saved')
    } catch (actionError) {
      setError(actionError instanceof Error ? actionError.message : 'Failed to save company context')
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      {(message || error) && (
        <div className={`setup-banner ${error ? 'error' : 'ok'}`}>{error || message}</div>
      )}

      <div className="section">
        <div className="section-header">Company Context</div>
        <div className="section-body">
          <div className="setup-copy">
            This is the standing company brief the runtime reads from <code>/opt/agentgls/goals/_context.md</code>.
            Keep the business identity, offer, audience, channels, assets, constraints, and current priorities here.
          </div>
          <textarea
            rows={20}
            placeholder="Company name, what the business does, offer, audience, channels, operating constraints, assets, and what matters right now."
            value={contextText}
            onChange={(event) => setContextText(event.target.value)}
          />
          <div className="form-actions">
            <button
              type="button"
              className="btn-action"
              disabled={busy || !contextText.trim()}
              onClick={() => void saveContext()}
            >
              {busy ? 'saving...' : 'save company info'}
            </button>
          </div>
        </div>
      </div>
    </>
  )
}
