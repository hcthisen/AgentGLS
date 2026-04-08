'use client'
import { useCallback, useEffect, useRef, useState } from 'react'

function formatTimestamp(value) {
  if (!value) return '-'
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return value
  return parsed.toLocaleString()
}

function messageSourceLabel(message) {
  switch (message.origin) {
    case 'telegram_user':
      return 'telegram'
    case 'dashboard_user':
      return 'dashboard'
    default:
      return 'assistant'
  }
}

function messageClassName(message) {
  if (message.origin === 'assistant') return 'assistant'
  if (message.origin === 'telegram_user') return 'telegram'
  return 'dashboard'
}

export default function ChatTab() {
  const [messages, setMessages] = useState([])
  const [draft, setDraft] = useState('')
  const [loading, setLoading] = useState(true)
  const [sending, setSending] = useState(false)
  const [lastUpdate, setLastUpdate] = useState(null)
  const [message, setMessage] = useState('')
  const [error, setError] = useState('')
  const streamRef = useRef(null)

  const fetchMessages = useCallback(async () => {
    try {
      const response = await fetch('/api/chat?limit=200', { cache: 'no-store' })
      if (response.status === 401) {
        window.location.reload()
        return
      }
      const payload = await response.json().catch(() => ({}))
      if (!response.ok) {
        throw new Error(payload.error || 'Failed to load chat')
      }
      setMessages(payload.messages || [])
      setLastUpdate(new Date())
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : 'Failed to load chat')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void fetchMessages()
    const interval = window.setInterval(() => {
      void fetchMessages()
    }, 5000)
    return () => window.clearInterval(interval)
  }, [fetchMessages])

  useEffect(() => {
    const node = streamRef.current
    if (!node) return
    node.scrollTop = node.scrollHeight
  }, [messages.length])

  async function sendMessage() {
    const text = draft.trim()
    if (!text) return

    setSending(true)
    setError('')
    setMessage('')

    try {
      const response = await fetch('/api/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text }),
      })
      const payload = await response.json().catch(() => ({}))
      if (!response.ok) {
        throw new Error(payload.error || 'Failed to send message')
      }

      setMessages(payload.messages || [])
      setDraft('')
      setLastUpdate(new Date())

      if (payload.delivery_errors?.length) {
        setMessage(`Reply saved, but Telegram mirror failed for ${payload.delivery_errors.join(' | ')}`)
      } else if (payload.delivered_chat_ids?.length) {
        setMessage('Reply mirrored to Telegram and dashboard')
      } else {
        setMessage('Reply saved in dashboard chat')
      }
    } catch (sendError) {
      setError(sendError instanceof Error ? sendError.message : 'Failed to send message')
    } finally {
      setSending(false)
    }
  }

  if (loading) return <div className="loading">loading chat...</div>

  return (
    <>
      {(message || error) && (
        <div className={`setup-banner ${error ? 'error' : 'ok'}`}>{error || message}</div>
      )}

      <div className="section-header-meta">
        <span className="refresh">{lastUpdate ? `updated ${lastUpdate.toLocaleTimeString()}` : ''}</span>
      </div>

      <div className="section">
        <div className="section-header">Operator Chat</div>
        <div className="section-body">
          <div className="setup-copy">
            Telegram and dashboard share the same assistant conversation. Telegram prompts appear
            here, dashboard prompts stay local to this tab, and assistant replies appear in both
            places when Telegram is paired.
          </div>

          <div className="chat-stream" ref={streamRef}>
            {messages.length === 0 ? (
              <div className="setup-empty-state">
                No operator chat messages yet. Send a message here or talk to the paired Telegram
                chat.
              </div>
            ) : (
              messages.map((entry) => (
                <div key={entry.id} className={`chat-message ${messageClassName(entry)}`}>
                  <div className="chat-message-meta">
                    <strong>{entry.author || 'Operator'}</strong>
                    <span>{messageSourceLabel(entry)}</span>
                    <span>{formatTimestamp(entry.created_at)}</span>
                  </div>
                  <div className="chat-message-body">{entry.message}</div>
                </div>
              ))
            )}
          </div>

          <div className="chat-compose">
            <textarea
              rows={4}
              placeholder="Write to AgentGLS here. Your message stays in the dashboard, but the assistant reply will also appear in Telegram."
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
            />
            <div className="form-actions">
              <button
                type="button"
                className="btn-action"
                disabled={sending || !draft.trim()}
                onClick={() => void sendMessage()}
              >
                {sending ? 'sending...' : 'send message'}
              </button>
              <button
                type="button"
                className="btn-sm"
                disabled={sending}
                onClick={() => void fetchMessages()}
              >
                refresh chat
              </button>
            </div>
          </div>
        </div>
      </div>
    </>
  )
}
