'use client'
import { useState, useEffect, useCallback } from 'react'

export default function SecretsTab() {
  const [secrets, setSecrets] = useState([])
  const [loading, setLoading] = useState(true)
  const [revealedKeys, setRevealedKeys] = useState(new Set())
  const [revealedValues, setRevealedValues] = useState({})
  const [formKey, setFormKey] = useState('')
  const [formValue, setFormValue] = useState('')
  const [formDesc, setFormDesc] = useState('')
  const [editing, setEditing] = useState(null)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')

  const fetchSecrets = useCallback(async () => {
    try {
      const res = await fetch('/api/secrets')
      if (res.ok) setSecrets(await res.json())
    } catch { /* retry */ }
    setLoading(false)
  }, [])

  useEffect(() => { fetchSecrets() }, [fetchSecrets])

  const handleReveal = async (key) => {
    if (revealedKeys.has(key)) {
      setRevealedKeys(prev => { const s = new Set(prev); s.delete(key); return s })
      return
    }
    try {
      const res = await fetch('/api/secrets?reveal=true')
      if (res.ok) {
        const all = await res.json()
        const found = all.find(s => s.key === key)
        if (found) {
          setRevealedValues(prev => ({ ...prev, [key]: found.value }))
          setRevealedKeys(prev => new Set(prev).add(key))
        }
      }
    } catch { /* ignore */ }
  }

  const handleEdit = async (key) => {
    const res = await fetch('/api/secrets?reveal=true')
    if (res.ok) {
      const all = await res.json()
      const found = all.find(s => s.key === key)
      if (found) {
        setFormKey(found.key)
        setFormValue(found.value)
        setFormDesc(found.description || '')
        setEditing(key)
      }
    }
  }

  const handleDelete = async (key) => {
    if (!confirm(`Delete ${key}?`)) return
    const res = await fetch(`/api/secrets/${encodeURIComponent(key)}`, { method: 'DELETE' })
    if (res.ok) fetchSecrets()
  }

  const handleSubmit = async (e) => {
    e.preventDefault()
    setError('')
    if (!formKey || !formValue) { setError('Key and value are required'); return }
    if (!/^[A-Z][A-Z0-9_]*$/.test(formKey)) {
      setError('Key must be UPPERCASE_WITH_UNDERSCORES (e.g., OPENAI_API_KEY)')
      return
    }
    setSaving(true)
    try {
      const res = await fetch('/api/secrets', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ key: formKey, value: formValue, description: formDesc }),
      })
      if (res.ok) {
        setFormKey(''); setFormValue(''); setFormDesc(''); setEditing(null)
        fetchSecrets()
      } else {
        const data = await res.json()
        setError(data.error || 'Failed to save')
      }
    } catch { setError('Connection error') }
    setSaving(false)
  }

  const handleCancel = () => {
    setFormKey(''); setFormValue(''); setFormDesc(''); setEditing(null); setError('')
  }

  if (loading) return <div className="loading">loading...</div>

  return (
    <>
      <div className="section">
        <div className="section-header">{editing ? `Edit: ${editing}` : 'Add Secret'}</div>
        <div className="section-body">
          <form className="secrets-form" onSubmit={handleSubmit}>
            {error && <div className="login-error">{error}</div>}
            <div className="form-row">
              <input type="text" placeholder="KEY_NAME" value={formKey}
                onChange={(e) => setFormKey(e.target.value.toUpperCase())}
                disabled={!!editing} />
              <input type="password" placeholder="value" value={formValue}
                onChange={(e) => setFormValue(e.target.value)} />
            </div>
            <input type="text" placeholder="description (optional)" value={formDesc}
              onChange={(e) => setFormDesc(e.target.value)} />
            <div className="form-actions">
              <button type="submit" className="btn-action" disabled={saving}>
                {saving ? 'saving...' : editing ? 'update' : 'add secret'}
              </button>
              {editing && (
                <button type="button" className="btn-cancel" onClick={handleCancel}>cancel</button>
              )}
            </div>
          </form>
        </div>
      </div>

      <div className="section">
        <div className="section-header">Stored Secrets ({secrets.length})</div>
        <div className="section-body">
          <table>
            <thead>
              <tr><th>Key</th><th>Description</th><th>Updated</th><th>Actions</th></tr>
            </thead>
            <tbody>
              {secrets.map((s) => (
                <tr key={s.key}>
                  <td style={{ color: 'var(--green)' }}>{s.key}</td>
                  <td>{s.description || '-'}</td>
                  <td>{s.updated_at ? new Date(s.updated_at).toLocaleDateString() : '-'}</td>
                  <td className="actions-cell">
                    <button className="btn-sm" onClick={() => handleReveal(s.key)}>
                      {revealedKeys.has(s.key) ? 'hide' : 'show'}
                    </button>
                    <button className="btn-sm" onClick={() => handleEdit(s.key)}>edit</button>
                    <button className="btn-sm btn-danger" onClick={() => handleDelete(s.key)}>del</button>
                  </td>
                </tr>
              ))}
              {secrets.length === 0 && (
                <tr><td colSpan="4" style={{ color: 'var(--text-dim)' }}>
                  No secrets stored. Add API keys (e.g., OPENAI_API_KEY) above.
                </td></tr>
              )}
            </tbody>
          </table>
          {/* Revealed values */}
          {Array.from(revealedKeys).map(key => (
            <div key={key} className="revealed-secret">
              <span style={{ color: 'var(--green)' }}>{key}</span>
              <code>{revealedValues[key] || '...'}</code>
            </div>
          ))}
        </div>
      </div>
    </>
  )
}
