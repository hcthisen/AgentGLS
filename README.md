# AgentGLS

AgentGLS is the rebrand of AgentOS-CC. It is a single-VPS agent system that is being migrated from a Claude-first baseline to the provider-neutral GoalLoop v6 architecture.

## Status

- Target architecture: [goalloop-design.md](./goalloop-design.md)
- Implementation plan: [PLAN.md](./PLAN.md)
- Canonical repo instructions: [AGENTS.md](./AGENTS.md)
- Claude compatibility shim: [CLAUDE.md](./CLAUDE.md)
- Runtime compatibility names remain unchanged in this pass:
  - `/opt/agentos`
  - `agentos`
  - `agentos-*`
  - `cc_*`
  - `AGENTOS_*`

## What This Repo Contains

- `bootstrap.sh` for VPS installation and updates
- `dashboard/` for the web dashboard
- `terminal/` for the web terminal bridge
- `scripts/` for automation, health, security, and runtime helpers
- `supabase/` for database migrations
- `goalloop-design.md` and `PLAN.md` for the AgentGLS migration target

## Install

Run the bootstrap installer on the VPS:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/hcthisen/AgentGLS/main/bootstrap.sh)"
```

Bootstrap now does the host installation only:

- installs Docker, Caddy, Node.js, and the local services
- writes `/opt/agentos/.env`
- creates `/opt/agentos/runtime/{human,goalloop,scheduled,summary}`
- exposes the dashboard immediately on `VPS_IP:3000`

The normal operator flow is now:

1. SSH into the VPS and run the bootstrap installer.
2. Open `http://VPS_IP:3000`.
3. Complete admin setup, provider choice, provider auth, domain, Telegram token, business context, and first goal in the browser.

For unattended installs or recovery, environment-variable overrides remain available:

```bash
AGENTGLS_PROVIDER=codex \
AGENTOS_DOMAIN=example.com \
AGENTGLS_ADMIN_EMAIL=ops@example.com \
AGENTOS_DASHBOARD_PASSWORD=yourpassword \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/hcthisen/AgentGLS/main/bootstrap.sh)"
```

Only the selected provider is installed by default. To install the other provider later on the VPS:

```bash
sudo -u agentos /opt/agentos/scripts/install-provider.sh install claude
sudo -u agentos /opt/agentos/scripts/install-provider.sh install codex
```

## Provider Auth

AgentGLS supports one active runtime at a time:

- `claude`
- `codex`

The onboarding flow installs the selected CLI, then guides auth through the web terminal.

### Claude Code

- Install path on Linux host: the official Claude Code installer (`curl -fsSL https://claude.ai/install.sh | bash`)
- Check auth: `claude auth status`
- Authenticate on the VPS: `claude auth login --claudeai`

### OpenAI Codex

- Install path on Linux host: the official Codex CLI npm package (`npm install -g @openai/codex`)
- Check auth: `codex login status`
- Authenticate on a remote/headless VPS: `codex login --device-auth`

Device auth is the recommended Codex path for remote VPS installs because it does not depend on a local browser session on the server itself.

This repo is being updated in phases. Until later phases land, some implementation details still reflect the older GoalLoop migration in progress.

## Reference Repos

This repo includes `Reference-Code-Repos/` with working reference implementations for:

- Telegram integration:
  - `Reference-Code-Repos/Telegram implementation referenc - AgenOS/`
- Setup and onboarding:
  - `Reference-Code-Repos/Setup and Onboarding implementaion reference - Paperclip/`

Use them as references for how those features were implemented successfully. Do not treat them as wholesale source material for unrelated AgentGLS architecture.

## Project Notes

- `AGENTS.md` is the canonical repo instruction file.
- `CLAUDE.md` exists only for Claude compatibility and should stay thin.
- The active migration should move the system toward provider-neutral runtime behavior rather than deepen the legacy Claude plugin architecture.

## License

Private.
