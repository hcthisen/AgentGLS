#!/bin/bash
# watchdog.sh — Ensure Claude Code is running in tmux with Telegram channel
# Runs every 5 minutes via cron

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

TMUX_SESSION="claude"
CLAUDE_BIN="$HOME/.local/bin/claude"
CHANNEL_FLAG="--channels plugin:telegram@claude-plugins-official"
CLAUDE_CMD="$CLAUDE_BIN --continue --dangerously-skip-permissions $CHANNEL_FLAG"

# Check if tmux session exists
if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  log "tmux session '$TMUX_SESSION' not found, creating..."
  tmux new-session -d -s "$TMUX_SESSION"
  sleep 1
fi

# Get pane PID
PANE_PID=$(tmux list-panes -t "$TMUX_SESSION" -F '#{pane_pid}' 2>/dev/null | head -1)

if [[ -z "$PANE_PID" ]]; then
  log "ERROR: Could not get pane PID"
  exit 1
fi

# Check if claude is running as a child or grandchild of the pane
claude_pid=""
for child in $(pgrep -P "$PANE_PID" 2>/dev/null); do
  if ps -p "$child" -o comm= 2>/dev/null | grep -q "claude"; then
    claude_pid="$child"
    break
  fi
  for grandchild in $(pgrep -P "$child" 2>/dev/null); do
    if ps -p "$grandchild" -o comm= 2>/dev/null | grep -q "claude"; then
      claude_pid="$grandchild"
      break 2
    fi
  done
done

if [[ -n "$claude_pid" ]]; then
  # Claude is running — verify it has --channels in its command line
  cmdline=$(tr '\0' ' ' < "/proc/$claude_pid/cmdline" 2>/dev/null)
  if echo "$cmdline" | grep -q -- "--channels"; then
    log "Claude Code is running with channels (PID: $claude_pid)"
    exit 0
  fi

  # Running but without channels — also check tmux pane as fallback
  pane_content=$(tmux capture-pane -t "$TMUX_SESSION" -p 2>/dev/null)
  if echo "$pane_content" | grep -q "Listening for channel messages"; then
    log "Claude Code is running with channels (confirmed via pane, PID: $claude_pid)"
    exit 0
  fi

  # Running without channels — need to restart
  log "Claude Code running WITHOUT channels (PID: $claude_pid), restarting..."
  tmux send-keys -t "$TMUX_SESSION" "/exit" Enter
  sleep 3
  # Fall through to start with channels
fi

# Claude not running (or was just stopped) — start with channels
log "Starting Claude Code with Telegram channel..."
tmux send-keys -t "$TMUX_SESSION" "$CLAUDE_CMD" Enter
# Auto-accept "trust this folder" prompt (option 1 is pre-selected)
sleep 5
tmux send-keys -t "$TMUX_SESSION" Enter
# Auto-accept "dangerously skip permissions" prompt (select option 2)
sleep 2
tmux send-keys -t "$TMUX_SESSION" Down Enter
log "Start command sent to tmux session (auto-accepted prompts)"
