# AGENTS.md

This is the canonical repo instruction file for AgentGLS.

## Repo Status

- This repo now uses the AgentGLS runtime names end to end.
- This repo is being migrated from a Claude-first baseline to the provider-neutral GoalLoop v6 design.
- Runtime defaults:
  - `/opt/agentgls`
  - `agentgls`
  - `agentgls-*`
  - `cc_*`
  - `AGENTGLS_*`

## Canonical Sources

- `goalloop-design.md` defines the target GoalLoop v6 architecture.
- `PLAN.md` defines the phased implementation plan.
- `README.md` provides the operator-facing project overview.
- `CLAUDE.md` exists only as a Claude compatibility shim and must not become a second source of truth.

## Implementation Direction

- Prefer provider-neutral designs that work for both `claude` and `codex`.
- Do not reintroduce the Claude Telegram plugin as a required dependency.
- Build against the current repo structure rather than inventing a new one.
- Keep repo/docs/UI surfaces aligned with the AgentGLS runtime names unless a task explicitly introduces a new naming scheme.
