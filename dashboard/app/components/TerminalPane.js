'use client'
import { useCallback, useEffect, useRef, useState } from 'react'

export default function TerminalPane({ className = '' }) {
  const termRef = useRef(null)
  const wsRef = useRef(null)
  const xtermRef = useRef(null)
  const fitRef = useRef(null)
  const resizeCleanupRef = useRef(null)
  const observerRef = useRef(null)
  const [status, setStatus] = useState('disconnected')

  const resolveWebSocketUrl = useCallback(() => {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
    const host = window.location.hostname
    const isDirectBootstrapPort =
      window.location.port === '3000' || /^\d{1,3}(\.\d{1,3}){3}$/.test(host)

    if (isDirectBootstrapPort) {
      return `${protocol}//${host}:3002`
    }

    return `${protocol}//${window.location.host}/ws/terminal`
  }, [])

  const teardown = useCallback(() => {
    if (wsRef.current) {
      wsRef.current.onclose = null
      wsRef.current.onerror = null
      wsRef.current.onmessage = null
      wsRef.current.close()
      wsRef.current = null
    }
    if (resizeCleanupRef.current) {
      resizeCleanupRef.current()
      resizeCleanupRef.current = null
    }
    if (observerRef.current) {
      observerRef.current.disconnect()
      observerRef.current = null
    }
    if (xtermRef.current) {
      xtermRef.current.dispose()
      xtermRef.current = null
    }
    fitRef.current = null
  }, [])

  const connect = useCallback(async () => {
    teardown()
    setStatus('connecting')

    let Terminal
    let FitAddon
    let WebLinksAddon

    try {
      const xtermModule = await import('@xterm/xterm')
      const fitModule = await import('@xterm/addon-fit')
      const linksModule = await import('@xterm/addon-web-links')
      Terminal = xtermModule.Terminal
      FitAddon = fitModule.FitAddon
      WebLinksAddon = linksModule.WebLinksAddon
      await import('@xterm/xterm/css/xterm.css')
    } catch {
      setStatus('error: xterm not installed')
      return
    }

    const term = new Terminal({
      theme: {
        background: '#0a0a0a',
        foreground: '#c8c8c8',
        cursor: '#00ff41',
        cursorAccent: '#0a0a0a',
        selectionBackground: '#333',
        black: '#0a0a0a',
        green: '#00ff41',
        red: '#ff3333',
        yellow: '#ffcc00',
        blue: '#4da6ff',
      },
      fontFamily: "'JetBrains Mono', 'Fira Code', 'SF Mono', monospace",
      fontSize: 13,
      cursorBlink: true,
      convertEol: true,
      scrollback: 5000,
    })

    const fit = new FitAddon()
    term.loadAddon(fit)
    term.loadAddon(new WebLinksAddon())

    if (termRef.current) {
      termRef.current.innerHTML = ''
      term.open(termRef.current)
      fit.fit()
    }

    xtermRef.current = term
    fitRef.current = fit

    const ws = new WebSocket(resolveWebSocketUrl())
    wsRef.current = ws
    ws.binaryType = 'arraybuffer'

    ws.onopen = () => {
      setStatus('connected')
      const dims = JSON.stringify({ cols: term.cols, rows: term.rows })
      ws.send(new Uint8Array([0, ...new TextEncoder().encode(dims)]))
    }

    ws.onmessage = (event) => {
      if (event.data instanceof ArrayBuffer) {
        term.write(new Uint8Array(event.data))
      } else {
        term.write(event.data)
      }
    }

    ws.onclose = () => {
      setStatus('disconnected')
      wsRef.current = null
      term.write('\r\n\x1b[31m[session ended — switch tabs or click reconnect]\x1b[0m\r\n')
    }

    ws.onerror = () => {
      setStatus('error')
      wsRef.current = null
    }

    term.onData((data) => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(new TextEncoder().encode(data))
      }
    })

    const sendResize = () => {
      if (ws.readyState === WebSocket.OPEN) {
        const dims = JSON.stringify({ cols: term.cols, rows: term.rows })
        ws.send(new Uint8Array([0, ...new TextEncoder().encode(dims)]))
      }
    }

    const handleResize = () => {
      fit.fit()
      sendResize()
    }

    term.onResize(sendResize)
    window.addEventListener('resize', handleResize)
    resizeCleanupRef.current = () => window.removeEventListener('resize', handleResize)

    if (typeof ResizeObserver !== 'undefined' && termRef.current) {
      const observer = new ResizeObserver(() => {
        fit.fit()
        sendResize()
      })
      observer.observe(termRef.current)
      observerRef.current = observer
    }
  }, [resolveWebSocketUrl, teardown])

  useEffect(() => {
    connect()

    const handleBeforeUnload = () => teardown()
    window.addEventListener('beforeunload', handleBeforeUnload)

    return () => {
      window.removeEventListener('beforeunload', handleBeforeUnload)
      teardown()
    }
  }, [connect, teardown])

  const statusColor = {
    connected: 'var(--green)',
    connecting: 'var(--yellow)',
    disconnected: 'var(--text-dim)',
    error: 'var(--red)',
  }

  return (
    <div className={`terminal-wrapper ${className}`.trim()}>
      <div className="terminal-toolbar">
        <div className="terminal-status">
          <span className="dot" style={{ background: statusColor[status] || 'var(--text-dim)' }}></span>
          {status}
        </div>
        <div>
          {(status === 'disconnected' || status === 'error') && (
            <button className="btn-sm" onClick={connect}>reconnect</button>
          )}
          {status === 'connected' && (
            <button className="btn-sm" onClick={() => { teardown(); setStatus('disconnected') }}>disconnect</button>
          )}
        </div>
      </div>
      <div ref={termRef} className="terminal-container"></div>
    </div>
  )
}
