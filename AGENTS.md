# AGENTS.md

This is the canonical repo instruction file for AgentGLS.

## Repo Status

- AgentGLS is the rebrand of AgentOS-CC.
- This repo is being migrated from a Claude-first baseline to the provider-neutral GoalLoop v6 design.
- Keep runtime compatibility names stable unless a task explicitly changes them:
  - `/opt/agentos`
  - `agentos`
  - `agentos-*`
  - `cc_*`
  - `AGENTOS_*`

## Canonical Sources

- `goalloop-design.md` defines the target GoalLoop v6 architecture.
- `PLAN.md` defines the phased implementation plan.
- `README.md` provides the operator-facing project overview.
- `CLAUDE.md` exists only as a Claude compatibility shim and must not become a second source of truth.

## Implementation Direction

- Prefer provider-neutral designs that work for both `claude` and `codex`.
- Do not reintroduce the Claude Telegram plugin as a required dependency.
- Build against the current repo structure rather than inventing a new one.
- Rebrand user-facing repo/docs/UI surfaces to AgentGLS while keeping compatibility runtime names stable unless a later phase explicitly changes them.

## Reference Repos

- Use `Reference-Code-Repos/Telegram implementation referenc - AgenOS/` only as a reference for Telegram integration patterns.
- Use `Reference-Code-Repos/Setup and Onboarding implementaion reference - Paperclip/` only as a reference for setup and onboarding UX. Prefer it as the benchmark for onboarding behavior.
- Do not pull unrelated architecture or product scope from those repos.
