# AgentGLS

AgentGLS is a single-VPS autonomous operations system for running goal-driven work through either Claude Code or OpenAI Codex. It combines a browser-based setup flow, a provider-backed execution loop, a Telegram bridge, and a lightweight dashboard so one operator can install, supervise, and steer the system from a single host.

## What AgentGLS Does

- Runs one active coding/runtime provider at a time: `claude` or `codex`
- Executes headless, resumable turns for human requests, GoalLoop heartbeats, scheduled jobs, and summaries
- Exposes a local dashboard on port `3000` with onboarding, status, goals, secrets, and a live terminal
- Proxies the dashboard and terminal websocket through Caddy when a public host is configured
- Uses Telegram Bot API for operator access without tying the runtime to a provider-specific plugin
- Keeps goals file-first under `/opt/agentgls/goals`, with PostgreSQL/PostgREST used for dashboard projection and system data

## Architecture

AgentGLS installs onto a single Ubuntu or Debian VPS and runs the host stack locally:

- Next.js dashboard on `localhost:3000`
- Terminal websocket bridge on `localhost:3002`
- PostgreSQL and PostgREST in Docker
- Caddy for HTTPS and reverse proxying
- Provider runner scripts for Claude Code and Codex
- Telegram bridge for inbound and outbound operator messaging

The runtime is organized around isolated working directories under `/opt/agentgls/runtime/`:

- `human/` for operator conversations
- `goalloop/` for autonomous goal execution
- `scheduled/` for scheduled tasks
- `summary/` for summaries and one-shot reporting

## Quick Start

Run the bootstrap installer on a fresh VPS:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/hcthisen/AgentGLS/main/bootstrap.sh)"
```

Bootstrap installs the base system and leaves the rest of setup to the dashboard onboarding flow. The installer prepares:

- Docker, Node.js, Caddy, and host dependencies
- the AgentGLS runtime under `/opt/agentgls`
- PostgreSQL, PostgREST, dashboard, and terminal services
- provider CLIs for Claude Code and Codex
- runtime directories, cron jobs, and supporting scripts

After bootstrap completes:

1. Open `http://VPS_IP:3000`
2. Create the admin account
3. Choose the active provider
4. Authenticate that provider in the embedded terminal
5. Configure the public dashboard host if you want HTTPS
6. Add the Telegram bot token
7. Enter business context and the first goal

## Unattended Install Overrides

Bootstrap also accepts environment-variable overrides for recovery workflows, automation, or partially preseeded installs:

```bash
AGENTGLS_PROVIDER=codex \
AGENTGLS_DASHBOARD_HOST=dashboard.example.com \
AGENTGLS_ADMIN_EMAIL=ops@example.com \
AGENTGLS_DASHBOARD_PASSWORD=yourpassword \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/hcthisen/AgentGLS/main/bootstrap.sh)"
```

Important runtime values:

- `AGENTGLS_DASHBOARD_HOST` sets the exact public host used by onboarding, DNS checks, and Caddy
- `AGENTGLS_PROVIDER` selects the active runtime
- `AGENTGLS_ADMIN_EMAIL` and `AGENTGLS_DASHBOARD_PASSWORD` preseed dashboard login

## Provider Authentication

AgentGLS installs both provider CLIs during bootstrap and lets onboarding choose the active one. Authentication is handled through the provider CLI itself in the embedded terminal.

### Claude Code

- Install path: official Claude Code installer
- Login command: `claude auth login --claudeai`
- Status command: `claude auth status --json`

### OpenAI Codex

- Install path: `npm install -g @openai/codex`
- Login command: `codex login --device-auth`
- Status command: `codex login status`

The onboarding flow is built around CLI login status, not API-key entry.

## Telegram Setup

AgentGLS uses a provider-neutral Telegram Bot API bridge.

1. Create a bot with `@BotFather`
2. Enter the bot token during onboarding, or run:

```bash
sudo -u agentgls /opt/agentgls/scripts/telegram-setup.sh
```

3. Send a message to the bot from your operator account
4. Approve the pairing code when prompted

Useful bridge commands:

```bash
python3 /opt/agentgls/scripts/telegram-bridge.py status
python3 /opt/agentgls/scripts/telegram-bridge.py list-pending
python3 /opt/agentgls/scripts/telegram-bridge.py list-allowed
tail -f /opt/agentgls/logs/telegram-bridge.log
```

## Operations

Useful day-to-day commands on the VPS:

```bash
bash /opt/agentgls/scripts/status.sh
tmux attach -t agent
tmux attach -t goalloop
tail -f /opt/agentgls/logs/goalloop-heartbeat.log
tail -f /opt/agentgls/logs/goalloop-sync.log
python3 -m unittest discover -s /opt/agentgls/tests
```

The two tmux sessions are operational shells:

- `agent` is the human-facing shell
- `goalloop` is the autonomous execution shell

## Repository Layout

- `bootstrap.sh` installs and updates the host stack
- `dashboard/` contains the Next.js dashboard
- `terminal/` contains the terminal websocket bridge
- `scripts/` contains provider adapters, GoalLoop runtime scripts, Telegram tooling, and host utilities
- `supabase/` contains SQL migrations
- `tests/` contains regression tests for the runtime helpers
- `config/` contains runtime templates and supporting configuration

## Documentation

- [goalloop-design.md](./goalloop-design.md) describes the runtime model and system behavior
- [PLAN.md](./PLAN.md) tracks the implementation plan
- [AGENTS.md](./AGENTS.md) is the canonical repo instruction file for coding agents working in this repo
- [Architecture.md](./Architecture.md) contains additional implementation notes

## License

Private.
