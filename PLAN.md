# PLAN.md — AgentGLS GoalLoop + Multi-Provider Migration Plan

## Objective

Update the current **AgentOS-CC** codebase into **AgentGLS** by implementing the **GoalLoop System — v6** and adding **runtime-provider choice** so the system can run on either:

- **Claude Code** (`claude`)
- **OpenAI Codex** (`codex`)

The result should remain a **single-VPS**, **file-first**, **GoalLoop** system with:

- provider-neutral Telegram access
- provider-neutral scheduled tasks and summaries
- provider-neutral autonomous GoalLoop heartbeats
- read-only dashboard visibility for goals

This plan is written for Codex to implement directly.

---

## Read This First

The previous plan assumed a Claude-only architecture with the Telegram plugin inside Claude Code. That is **no longer the right design** if Codex is a first-class runtime.

### New architecture rule

**Telegram must be provider-neutral.**

Do **not** build the new system around the Claude Telegram plugin. That plugin path is inherently Claude-specific. If Codex is a selectable runtime, the system must decouple:

- **message ingress/egress** (Telegram Bot API)
- from the **selected coding runtime** (`claude` or `codex`)

The right shape is:

```text
Telegram Bot API  ->  provider-neutral bridge  ->  provider runner  ->  selected CLI
                                                         |               |
                                                         |               +-> Claude Code OR Codex
                                                         +-> stdout -> Telegram reply
```

### New instruction-file rule

**`AGENTS.md` is the canonical instruction file.**

- Codex reads `AGENTS.md`
- Claude reads `CLAUDE.md`
- Claude supports importing `AGENTS.md` via `@AGENTS.md`

So:

- keep **one canonical instruction source** in `AGENTS.md`
- keep `CLAUDE.md` as a **thin shim** that imports `@AGENTS.md`
- put only Claude-specific additions below the import if needed

### New session model rule

Do **not** tie persistence to a permanently running provider REPL.

Both providers now support resuming prior work in headless/non-interactive mode, so the automation should be built around **provider resume commands**, not around trying to keep a live UI process running forever.

Use tmux for:

- operator visibility
- a stable shell target
- attach/detach troubleshooting

But use the provider CLIs in **resumable headless mode** for actual automation turns.

---

## Reference Repos

This repo includes `Reference-Code-Repos/` with two complete, known-good products. They are included as **implementation references only** for two specific areas:

- `Reference-Code-Repos/Telegram implementation referenc - AgenOS/`
  - Use as reference for **Telegram integration** implementation details and flow shape.
- `Reference-Code-Repos/Setup and Onboarding implementaion reference - Paperclip/`
  - Use as reference for the **setup and onboarding experience**.
  - This is the preferred reference for how AgentGLS onboarding should feel and behave.

Rules for using these references:

- Use them to understand how working features were implemented.
- Do not treat them as architecture to copy wholesale.
- Do not pull in unrelated product code or features from those repos.
- For onboarding and Telegram, study the reference implementations because they are known to work.

---

## Scope Decisions

These are requirements unless explicitly changed later.

- **External rebrand now; runtime compatibility names stay stable in this pass.**
  - Rebrand repo/docs/UI from **AgentOS-CC** to **AgentGLS**.
  - Keep the current runtime-compatible internal names for now:
    - `/opt/agentos`
    - `agentos` Linux user
    - `agentos-*` container names
    - existing `cc_*` tables
    - existing `AGENTOS_*` env vars
  - Reason: reduces migration risk.

- **One active provider at a time.**
  - The onboarding flow chooses `claude` or `codex`.
  - The selected provider becomes the active runtime for:
    - human chat turns
    - GoalLoop heartbeats
    - scheduled tasks
    - daily summaries / one-shot inference scripts
  - Manual switching later is acceptable via config + re-auth, but a polished in-product switching UI is **not required** in this pass.

- **Terminal install first; all normal setup happens in onboarding.**
  - The only required terminal action on the VPS is running the bootstrap installer.
  - Bootstrap must bring the system up far enough that the operator can open `VPS_IP:3000` and complete setup in the browser.
  - Provider selection, provider auth, domain configuration, Telegram setup, business context, and first-goal creation should all be handled in the onboarding flow.
  - Bootstrap prompt / env-var overrides / direct `.env` editing may still exist for unattended installs, recovery, or developer workflows, but they are not the primary operator path.

- **Onboarding is part of AgentGLS in this repo.**
  - Do not assume a separate onboarding repo will implement the actual setup flow.
  - Use the Paperclip reference repo to inform the AgentGLS onboarding experience, not as a dependency.

- **GoalLoop remains file-first.**
  - Goal files in `/opt/agentos/goals/` are the source of truth.
  - PostgreSQL/PostgREST is only a read-only dashboard projection for goal status.

- **Scheduled tasks stay, but they become provider-neutral.**
  - Keep `cc_scheduled_tasks`, `tasks.sh`, and task history.
  - Do not remove the scheduled-task subsystem.
  - Replace direct `claude` assumptions with a provider adapter.

- **All goal metadata parsing/mutation lives in one Python helper.**
  - Use `goalmeta.py`.
  - No YAML parsing in shell.

- **Telegram becomes provider-neutral in this repo.**
  - Remove the Claude-plugin dependency from the core path.
  - Use the Telegram Bot API directly.

- **Use the next migration number in the current repo.**
  - The repo already contains migrations `000` through `005`.
  - GoalLoop migration must therefore be `006_goalloop.sql`.

---

## Current Repo Baseline To Preserve

Codex should preserve and build on the following existing behavior from the current repo:

- bootstrap installs the host stack and writes `/opt/agentos/.env`
- Docker Compose runs PostgreSQL, PostgREST, dashboard, and terminal
- PostgREST is on `127.0.0.1:3001`
- dashboard is on `127.0.0.1:3000`
- the expected operator flow is: run bootstrap in terminal, then complete setup at `VPS_IP:3000`
- the current repo already has scripts for watchdog, tasks, summaries, migrations, secrets sync, health sync, and session sync
- `run-migrations.sh` applies all SQL files in order to the running DB container
- Docker init currently mounts only early migrations, so later migrations must still be applied after services start

---

## Target Architecture

### Provider-neutral runtime model

```text
                       ┌─────────────────────────────────────┐
Telegram Bot API  ---> │ telegram-bridge.py                 │
                       │ - pairing / allowlist              │
                       │ - inbound message handling         │
                       │ - outbound reply helper            │
                       └────────────────┬────────────────────┘
                                        │
                                        ▼
                       ┌─────────────────────────────────────┐
                       │ provider-run.sh                     │
                       │ - reads ACTIVE_PROVIDER             │
                       │ - picks working directory           │
                       │ - runs headless turn                │
                       │ - resumes prior session             │
                       └───────┬─────────────────────┬───────┘
                               │                     │
                               ▼                     ▼
                   Claude path (`claude`)      Codex path (`codex`)
                   - claude -c -p              - codex exec resume --last
                   - claude -p first run       - codex exec first run
```

### Session continuity model

Create dedicated working directories under the repo root so both providers can keep separate conversation histories:

```text
/opt/agentos/runtime/
├── human/
├── goalloop/
├── scheduled/
└── summary/
```

Reason:

- Codex discovers `AGENTS.md` by walking from project root to cwd.
- Claude discovers `CLAUDE.md` in the project tree.
- Keeping these working dirs **inside** `/opt/agentos` ensures both providers load the same repo-level instructions.
- Each channel gets isolated session continuity.

### tmux model

Use two tmux sessions, but make them provider-neutral:

- `agent` — human-facing operational shell
- `goalloop` — autonomous operational shell

These are **shell sessions**, not provider-specific UI sessions.

The automation sends **headless provider commands** into them so operators can attach and observe runs.

### Instruction-file model

At the repo root:

- `AGENTS.md` — canonical instructions for Codex + humans
- `CLAUDE.md` — thin shim:

```md
@AGENTS.md

## Claude-specific notes
- ...only add truly Claude-specific instructions here...
```

On the deployed VPS under `/opt/agentos`:

- `/opt/agentos/AGENTS.md` — canonical operational protocol
- `/opt/agentos/CLAUDE.md` — shim importing `@AGENTS.md`

---

## New Runtime Config

Add the following to the host config model:

- `AGENTGLS_PROVIDER=claude|codex`
- `TELEGRAM_BOT_TOKEN=...`
- optional: `AGENTGLS_TELEGRAM_ALLOWED_CHAT_IDS=` (if later useful)

Store the active provider in `/opt/agentos/.env` for this pass.

Do **not** add a database-backed runtime-settings UI in this pass unless it is needed for the dashboard display.

---

## Deliverables

### New files

- `AGENTS.md`
- `CLAUDE.md`
- `config/runtime-agents.md`
- `config/claude-shim.md`
- `config/goal-templates/social-growth@v1.md`
- `config/goal-templates/website-repair@v1.md`
- `config/goal-templates/content-batch@v1.md`
- `scripts/provider-lib.sh`
- `scripts/provider-run.sh`
- `scripts/install-provider.sh`
- `scripts/send-telegram.sh`
- `scripts/telegram-bridge.py`
- `scripts/goalmeta.py`
- `scripts/goalloop-heartbeat.sh`
- `scripts/goalloop-sync.sh`
- `supabase/migrations/006_goalloop.sql`
- `dashboard/app/components/GoalsTab.js`
- `dashboard/app/api/goals/route.js`
- optionally: `systemd/agentgls-telegram-bridge.service`

### Modified files

- `README.md`
- `Architecture.md`
- `bootstrap.sh`
- `scripts/watchdog.sh`
- `scripts/task-runner.sh`
- `scripts/daily-summary.sh`
- `scripts/status.sh`
- `scripts/tasks.sh` (only if needed for provider-neutral helper usage)
- `scripts/telegram-setup.sh`
- `scripts/run-migrations.sh` (only if small safety improvement is needed)
- `dashboard/app/page.js`
- `dashboard/package.json` (branding only)

---

## Codex Execution Rules

- Implement phases in order.
- Keep diffs small and repo-local.
- Prefer the current stack and patterns over new frameworks.
- Use **Python 3 + PyYAML** for goal metadata work.
- Keep GoalLoop dashboard functionality **read-only** in this pass.
- Keep provider auth in provider-owned directories only.
- Never read or extract session tokens from `~/.claude` or `~/.codex`.
- Replace direct host-side `claude` invocations with provider adapters.
- Do not reintroduce the Claude Telegram plugin as a core dependency.

---

## Phase 1 — Rebrand + Canonical Instructions

### Goal

Rebrand the project to AgentGLS and establish a multi-provider instruction model.

### Tasks

- [x] Rebrand user-facing docs/UI strings from **AgentOS-CC** to **AgentGLS**.
- [x] Keep compatibility runtime names (`/opt/agentos`, `agentos`, `agentos-*`, `cc_*`) unchanged in this pass.
- [x] Add a root-level `AGENTS.md` as the **canonical** repo instructions.
- [x] Add a root-level `CLAUDE.md` that imports `@AGENTS.md`.
- [x] Update any existing repo-specific instruction docs so they no longer assume Claude-only behavior.
- [x] Add a short repo note explaining:
  - AgentGLS is the rebrand of AgentOS-CC
  - AGENTS.md is canonical
  - CLAUDE.md exists only for Claude compatibility

### Final task

- [x] Update `PLAN.md` to reflect the completed phase.

### Acceptance

- [x] Repo branding says AgentGLS.
- [x] `AGENTS.md` is canonical.
- [x] `CLAUDE.md` is a shim, not a second source of truth.

---

## Phase 2 — Provider Selection + Installer Foundation

### Goal

Add provider support to bootstrap, expose the dashboard immediately, and move normal runtime setup into onboarding.

### Tasks

- [x] Bootstrap should install the host stack and expose the dashboard on `VPS_IP:3000`.
- [x] The only required VPS terminal action for a normal install should be running bootstrap.
- [x] Add provider support so the normal path is onboarding-driven:
  - onboarding wizard chooses `claude` or `codex`
  - env var support via `AGENTGLS_PROVIDER=claude|codex` remains available for unattended installs or recovery
- [x] Add `scripts/install-provider.sh`.
- [x] Implement onboarding so the browser flow handles:
  - admin account creation
  - provider choice
  - provider auth
  - domain configuration
  - Telegram setup
  - business context capture
  - initial goal creation
- [x] On Linux/VPS, install providers using their official supported paths for the current versions:
  - Claude Code native installer
  - Codex CLI install path suitable for Linux host deployment
- [x] Install only the selected provider by default.
- [x] Leave a documented manual path to install the other provider later.
- [x] Add auth-status checks to bootstrap/status flows:
  - Claude: `claude auth status`
  - Codex: `codex login` / `codex auth status` equivalent check or a safe wrapper around `codex` availability + auth cache detection
- [x] Update README post-install auth instructions:
  - Claude path
  - Codex path (device auth recommended for remote/headless VPS)
- [x] Create runtime session directories:

```bash
/opt/agentos/runtime/{human,goalloop,scheduled,summary}
```

### Final task

- [x] Update `PLAN.md` to reflect the completed phase.

### Acceptance

- [x] After bootstrap, the operator can open `VPS_IP:3000` and complete setup without more terminal work.
- [x] Onboarding can choose provider.
- [x] Selected provider is installed.
- [x] Runtime workdirs exist.
- [x] README shows separate auth flows for Claude and Codex.

---

## Phase 3 — Provider Adapter Layer

### Goal

Create one provider abstraction used by every automation path.

### Files

- `scripts/provider-lib.sh`
- `scripts/provider-run.sh`

### Required responsibilities

#### `provider-lib.sh`

- [x] Load `/opt/agentos/.env`
- [x] expose active provider
- [x] resolve channel working dirs:
  - `human`
  - `goalloop`
  - `scheduled`
  - `summary`
- [x] provide provider-specific executable checks
- [x] provide provider-specific first-run/resume command builders

#### `provider-run.sh`

Implement one stable entrypoint used by all host automation:

```bash
provider-run.sh <channel> <prompt_file>
```

- [x] `channel` determines working dir
- [x] command resumes prior conversation for that channel when possible
- [x] command falls back to first-run mode if no resumable session exists yet
- [x] stdout is emitted cleanly for caller capture
- [x] stderr is logged to provider-specific log files
- [x] non-zero exit on provider failure

### Provider command rules

#### Claude path

Use Claude’s documented resumable print mode:

- resume path: `claude -c -p "..."`
- first-run path: `claude -p "..."`

#### Codex path

Use Codex’s documented non-interactive exec flow:

- resume path: `codex exec resume --last "..."`
- first-run path: `codex exec "..."`

Use the CLI’s approval-bypass flag only inside the hardened VPS environment.

### Implementation rules

- [x] Keep the working dir inside `/opt/agentos/runtime/<channel>` so provider session discovery stays scoped.
- [x] Do not hardcode model names in v1 unless already required by the repo.
- [x] Keep model/provider tuning in one place if added later.
- [x] Make the adapter reusable from:
  - Telegram bridge
  - GoalLoop heartbeat
  - scheduled tasks
  - daily summaries

### Final task

- [x] Update `PLAN.md` to reflect the completed phase.

### Acceptance

- [x] `provider-run.sh human <prompt>` works with Claude.
- [x] `provider-run.sh human <prompt>` works with Codex.
- [x] Resume behavior is isolated by channel directory.

---

## Phase 4 — Provider-Neutral Telegram Bridge

### Goal

Replace the Claude Telegram plugin dependency with a provider-neutral Telegram Bot API bridge.

### Design choice for this repo

Implement **Bot API + long polling** in this repo.

Do **not** depend on the Claude plugin.

Webhook mode can be a later enhancement if desired, but long polling is sufficient for this pass and avoids coupling to dashboard routing.

### Files

- `scripts/telegram-bridge.py`
- `scripts/send-telegram.sh`
- update `scripts/telegram-setup.sh`

### Responsibilities

#### `send-telegram.sh`

- [x] read `TELEGRAM_BOT_TOKEN`
- [x] send text to a target `chat_id`
- [x] chunk messages safely for Telegram limits
- [x] escape/format conservatively
- [x] exit non-zero on failure

#### `telegram-bridge.py`

- [x] long-poll Telegram Bot API for updates
- [x] support pairing / allowlist mode
- [x] persist allowlist locally on disk under `/opt/agentos/state/telegram/`
- [x] ignore or reject messages from unpaired chats
- [x] for each accepted user message:
  - build a provider-neutral prompt envelope
  - call `provider-run.sh human <prompt_file>`
  - capture stdout
  - send stdout back via `send-telegram.sh`
- [x] log inbound/outbound activity to `/opt/agentos/logs/telegram-bridge.log`

### Pairing rules

Recreate the existing safety goal of the Claude plugin:

- [x] first contact gets a short pairing code
- [x] operator approves/pairs once
- [x] bridge then treats the chat ID as allowlisted
- [x] only allowlisted chats can invoke the assistant

### Prompt-envelope rule

The message passed to `provider-run.sh` must include:

- source = Telegram
- chat ID
- message text
- instruction that the provider should answer the human directly and keep the reply concise unless asked otherwise
- reminder that outbound delivery is handled by the bridge, not by the model

### Final task

- [x] Update `PLAN.md` to reflect the completed phase.

### Acceptance

- [ ] Telegram round-trip works with Claude selected.
- [ ] Telegram round-trip works with Codex selected.
- [x] No Claude plugin is required.

---

## Phase 5 — Provider-Neutral Runtime Sessions + Watchdog

### Goal

Keep the operational tmux model, but make it provider-neutral and shell-based.

### Tasks

- [ ] Replace the old Claude-specific human tmux session with a provider-neutral shell session named:
  - `agent`
- [ ] Keep autonomous shell session:
  - `goalloop`
- [ ] Update `scripts/watchdog.sh` so it ensures these tmux shell sessions exist.
- [ ] Stop trying to keep a provider REPL running inside tmux.
- [ ] The provider CLI should run **per turn** through `provider-run.sh`.
- [ ] Update `scripts/status.sh` to show:
  - active provider
  - provider binary presence
  - tmux `agent` session exists
  - tmux `goalloop` session exists
  - Telegram bridge service/process health
  - goal counts

### Optional but useful

- [ ] keep backward-compatible detection of old `claude` tmux session during transition and warn the operator that `agent` is now canonical

### Final task

- [ ] Update `PLAN.md` to reflect the completed phase.

### Acceptance

- [ ] `agent` tmux session exists and is attachable.
- [ ] `goalloop` tmux session exists and is attachable.
- [ ] watchdog is no longer Claude-plugin-specific.

---

## Phase 6 — GoalLoop Foundation on Canonical AGENTS

### Goal

Add the GoalLoop runtime directories, templates, and canonical operational instructions.

### Tasks

- [ ] In bootstrap, install `python3-yaml`.
- [ ] Create GoalLoop dirs:

```bash
/opt/agentos/goals/
├── active/
├── paused/
├── completed/
├── templates/
├── proof/
└── locks/
```

- [ ] Create runtime files if absent:
  - `/opt/agentos/goals/_runbook.md`
  - `/opt/agentos/goals/_context.md`
- [ ] Add starter templates in repo + copy to `/opt/agentos/goals/templates/` if missing.
- [ ] Add `config/runtime-agents.md` as the canonical operational protocol.
- [ ] Add `config/claude-shim.md` for the VPS `CLAUDE.md` shim.
- [ ] Bootstrap should write:
  - `/opt/agentos/AGENTS.md` from the canonical runtime instructions
  - `/opt/agentos/CLAUDE.md` from the shim importing `@AGENTS.md`

### Runtime instruction requirements

The canonical runtime instructions must include:

- [ ] GoalLoop protocol from v6
- [ ] provider-neutral human chat rules
- [ ] explicit use of `goalmeta.py` for front matter
- [ ] explicit use of `send-telegram.sh` / bridge model
- [ ] draft/approve/manual-run/pause/resume flows
- [ ] output verification states in run logs
- [ ] lock usage for shared surfaces
- [ ] no auth/token extraction from provider directories

### Final task

- [ ] Update `PLAN.md` to reflect the completed phase.

### Acceptance

- [ ] `/opt/agentos/AGENTS.md` is canonical on the VPS.
- [ ] `/opt/agentos/CLAUDE.md` only imports it plus minimal Claude-only notes.
- [ ] GoalLoop dirs/templates exist.

---

## Phase 7 — Implement `goalmeta.py`

### Goal

Add one deterministic parser/mutator for all goal file operations.

### Commands to support

- [ ] `get <file> <field>`
- [ ] `set <file> <field> <value>`
- [ ] `claim <active_dir>`
- [ ] `finalize <file>`
- [ ] `complete <file> <completed_dir>`
- [ ] `pause <file> <paused_dir>`
- [ ] `criteria <file>`
- [ ] `scoreboard <file>`
- [ ] `check-runnable <file>`
- [ ] `reconcile-parent <parent_file> <active_dir>`

### Implementation rules

- [ ] PyYAML required. No fallback parser.
- [ ] atomic writes = temp file + rename
- [ ] `claim` uses global lock `/opt/agentos/goals/locks/_claim.lock`
- [ ] `claim` must atomically:
  - recover stale `running` goals older than 2h
  - pick best eligible leaf
  - set `run_state: running`
  - set `run_id`
  - set `run_started_at`
  - clear `approved_for_next_run` for manual-approval goals
- [ ] `finalize` sets `last_run` to actual completion time
- [ ] `complete` = finalize + move to `completed/`
- [ ] `pause` = finalize + move to `paused/`
- [ ] directory is source of truth for goal status
- [ ] parent reconciliation updates scoreboard rollups

### Ranking rules

- [ ] priority order: `critical`, `high`, `medium`, `low`
- [ ] boost measurement-due goals
- [ ] boost near deadlines:
  - under 24h = strong boost
  - under 72h = moderate boost
- [ ] enforce:
  - `brief_status: approved`
  - `approval_policy: manual` requires `approved_for_next_run: true`
  - `next_eligible_at`
  - `heartbeat_minutes`
  - leaf-only selection

### Final task

- [ ] Update `PLAN.md` to reflect the completed phase.

### Acceptance

- [ ] `claim` returns JSON with slug/file/run_id/rank or nothing eligible.
- [ ] `finalize/complete/pause` are path-safe.
- [ ] criteria + scoreboard extraction are section-scoped and reliable.

---

## Phase 8 — Provider-Neutral GoalLoop Heartbeat

### Goal

Run GoalLoop on either provider using the shared `provider-run.sh` adapter.

### Files

- `scripts/goalloop-heartbeat.sh`
- `scripts/goalloop-sync.sh`

### Heartbeat tasks

- [ ] ensure `goalloop` tmux shell exists
- [ ] claim one eligible goal via `goalmeta.py claim`
- [ ] build the GoalLoop prompt file
- [ ] execute the turn by sending a provider-run command into the `goalloop` shell session
- [ ] do **not** depend on a permanently running Claude/Codex UI process
- [ ] instruct the runtime to run exactly one of:
  - `goalmeta.py finalize`
  - `goalmeta.py complete`
  - `goalmeta.py pause`
- [ ] log claimed goal, run ID, success/failure

### Important implementation rule

The heartbeat should call the provider adapter, not the vendor CLI directly.

Example shape:

```bash
provider-run.sh goalloop /tmp/goalloop-prompt.XXXX
```

### Final task

- [ ] Update `PLAN.md` to reflect the completed phase.

### Acceptance

- [ ] heartbeat works with Claude selected.
- [ ] heartbeat works with Codex selected.
- [ ] exactly one eligible leaf goal is claimed per run.

---

## Phase 9 — Make Existing One-Shot Automation Provider-Neutral

### Goal

Remove Claude-only assumptions from the rest of the automation.

### Files to audit and update

- `scripts/task-runner.sh`
- `scripts/daily-summary.sh`
- `scripts/tasks.sh` if needed
- any memory/summarization scripts that invoke Claude directly
- README/docs that mention `claude -p` as the only core path

### Required changes

- [ ] Route all host-side inference through `provider-run.sh` or a closely related provider helper.
- [ ] Keep scheduled tasks functional.
- [ ] Keep daily summaries functional.
- [ ] Keep goal loop separate from scheduled tasks.
- [ ] Do not break existing DB task history behavior.

### Final task

- [ ] Update `PLAN.md` to reflect the completed phase.

### Acceptance

- [ ] scheduled tasks still work with Claude
- [ ] scheduled tasks work with Codex
- [ ] daily summary path works with Claude
- [ ] daily summary path works with Codex

---

## Phase 10 — Database Projection + Goal Dashboard

### Goal

Add the read-only goal projection and show it in the dashboard.

### Migration

Add `supabase/migrations/006_goalloop.sql`.

### SQL requirements

- [ ] use idempotent SQL
- [ ] table: `cc_goals`
- [ ] fields:
  - `slug`
  - `title`
  - `status`
  - `priority`
  - `brief_status`
  - `run_state`
  - `objective`
  - `finish_criteria`
  - `scoreboard`
  - `heartbeat_minutes`
  - `last_run`
  - `next_eligible_at`
  - `measurement_due_at`
  - `deadline_at`
  - `approval_policy`
  - `parent`
  - `notify_chat_id`
  - `updated_at`
- [ ] read access pattern consistent with the current dashboard/PostgREST stack

### Sync script

`goalloop-sync.sh` must:

- [ ] infer status from directory
- [ ] use `goalmeta.py` for criteria/scoreboard
- [ ] JSON-encode safely
- [ ] upsert to `cc_goals` via PostgREST on localhost:3001
- [ ] reconcile parent goals after sync

### Bootstrap/update requirement

- [ ] bootstrap must call `scripts/run-migrations.sh` after services start
- [ ] fresh installs must receive `006_goalloop.sql` automatically

### Dashboard tasks

- [ ] add `goals` tab to current dashboard
- [ ] add `GoalsTab.js`
- [ ] add `/api/goals`
- [ ] keep goals UI read-only
- [ ] display at minimum:
  - title
  - status
  - priority
  - brief status
  - run state
  - last run
  - next eligible at
  - measurement due at
  - finish criteria progress
  - scoreboard summary
  - parent/child info if present
- [ ] optionally show active provider in overview or header

### Final task

- [ ] Update `PLAN.md` to reflect the completed phase.

### Acceptance

- [ ] `cc_goals` is populated from goal files.
- [ ] dashboard shows a read-only Goals tab.
- [ ] dashboard auth still works.

---

## Phase 11 — Bootstrap and Ops Documentation

### Goal

Make installation and operations clear for either provider.

### Tasks

- [ ] Update README install section to show provider selection.
- [ ] Document provider auth flows separately:
  - Claude Code auth
  - Codex device-auth / login path
- [ ] Replace Telegram-plugin setup instructions with provider-neutral Bot API setup.
- [ ] Update attach/troubleshooting commands:
  - `tmux attach -t agent`
  - `tmux attach -t goalloop`
- [ ] Explain that the runtime now uses resumable headless turns rather than a permanently running provider UI.
- [ ] Keep a short migration note for old installs that previously used the Claude Telegram plugin.

### Final task

- [ ] Update `PLAN.md` to reflect the completed phase.

### Acceptance

- [ ] README no longer implies Claude-only runtime.
- [ ] README no longer treats the Claude Telegram plugin as required.

---

## Phase 12 — Testing and Verification

### Goal

Prove the multi-provider GoalLoop system works end to end.

### Automated tests

- [ ] Add focused tests for `goalmeta.py`
- [ ] Add at least one smoke test for `provider-run.sh`
  - first-run vs resume behavior
  - channel isolation
- [ ] Add at least one smoke test for Telegram helper scripts if practical

### Manual verification checklist

#### Provider selection

- [ ] fresh install with `AGENTGLS_PROVIDER=claude` works
- [ ] fresh install with `AGENTGLS_PROVIDER=codex` works
- [ ] status output shows the active provider correctly

#### Instruction loading

- [ ] Codex sees repo `AGENTS.md`
- [ ] Claude sees repo `CLAUDE.md` and imported `AGENTS.md`
- [ ] deployed `/opt/agentos/AGENTS.md` is canonical

#### Telegram bridge

- [ ] pair one Telegram account successfully
- [ ] unpaired account cannot issue commands
- [ ] paired account round-trips with Claude
- [ ] paired account round-trips with Codex

#### GoalLoop

- [ ] draft goal is ignored until approved
- [ ] approved goal can be claimed
- [ ] manual-approval goal requires `approved_for_next_run: true`
- [ ] manual-approval flag clears after claim
- [ ] stale `running` goal older than 2h recovers on next claim
- [ ] measurement delay blocks early reselection
- [ ] deadline boost changes ranking
- [ ] heartbeat works with Claude
- [ ] heartbeat works with Codex

#### Existing automation

- [ ] scheduled task still runs with Claude
- [ ] scheduled task runs with Codex
- [ ] daily summary still runs with Claude
- [ ] daily summary runs with Codex

#### Dashboard

- [ ] goals tab renders
- [ ] data comes from `cc_goals`
- [ ] existing tabs still work

### Final task

- [ ] Update `PLAN.md` to reflect the completed phase.

### Acceptance

- [ ] core human chat works on both providers
- [ ] GoalLoop works on both providers
- [ ] scheduled tasks/summaries work on both providers
- [ ] dashboard remains functional

---

## Definition of Done

The migration is done when all of the following are true:

- [ ] project is rebranded to AgentGLS in docs/UI
- [ ] runtime compatibility names remain stable where planned
- [ ] provider selection exists in bootstrap and config
- [ ] selected runtime can be either Claude or Codex
- [ ] `AGENTS.md` is canonical
- [ ] `CLAUDE.md` is only a shim that imports `AGENTS.md`
- [ ] Telegram no longer depends on the Claude plugin
- [ ] Telegram round-trip works with either provider
- [ ] `provider-run.sh` is the single host-side runtime adapter
- [ ] GoalLoop heartbeat uses `provider-run.sh`
- [ ] scheduled tasks and summaries use provider-neutral runtime invocation
- [ ] `goalmeta.py` is the single goal metadata parser/mutator
- [ ] `cc_goals` is projected from files and visible in the dashboard
- [ ] read-only Goals tab works
- [ ] no host-side automation path is still hardwired to Claude only

---

## Explicit Non-Goals For This Pass

Do **not** do these unless forced by implementation reality:

- [ ] full rename from `/opt/agentos` to `/opt/agentgls`
- [ ] full rename of `agentos-*` containers
- [ ] full rename of `cc_*` DB tables
- [ ] a separate standalone onboarding repo for the core setup flow
- [ ] full admin chat / task-queue architecture from `agent-os`
- [ ] multi-agent orchestration
- [ ] structured `cc_goal_runs`
- [ ] write-capable dashboard goal management
- [ ] webhook-first Telegram architecture
- [ ] reintroducing Claude plugin as a required dependency

---

## Suggested Implementation Order

1. Rebrand + root AGENTS/CLAUDE model
2. Bootstrap provider choice + provider installer
3. Provider adapter layer (`provider-lib.sh`, `provider-run.sh`)
4. Provider-neutral Telegram bridge
5. tmux/watchdog/status updates
6. GoalLoop foundation files + runtime AGENTS/CLAUDE
7. `goalmeta.py`
8. GoalLoop heartbeat + sync
9. make scheduled tasks / summaries provider-neutral
10. migration + dashboard Goals tab
11. tests
12. final README / Architecture cleanup

---

## References For The Implementer

Use these as source material while implementing:

- GoalLoop System — v6 (user-provided spec in this repo)
- `Reference-Code-Repos/Telegram implementation referenc - AgenOS/` for Telegram integration reference
- `Reference-Code-Repos/Setup and Onboarding implementaion reference - Paperclip/` for setup/onboarding reference
- Prefer the Paperclip onboarding flow as the benchmark for setup UX
- AgentOS-CC repo: current bootstrap, scripts, migrations, dashboard structure
- `agent-os` repo: provider-neutral runtime model, AGENTS/CLAUDE co-existence, Telegram decoupled from provider runtime
- Codex docs:
  - AGENTS.md discovery
  - Codex CLI install/auth
  - `codex exec` and `codex exec resume --last`
- Claude Code docs:
  - `CLAUDE.md` import support via `@AGENTS.md`
  - `claude -p`
  - `claude -c -p`

---

## Final Note For Codex

Implement this against the **current AgentOS-CC repository structure**, not a greenfield redesign.

The most important architectural pivots in this updated plan are:

1. **Provider choice is first-class** (`claude` or `codex`)
2. **Telegram is provider-neutral** (no Claude-plugin dependency)
3. **AGENTS.md is canonical**
4. **Headless resumable CLI turns replace permanently running provider UIs**
5. **GoalLoop stays file-first**
6. **The only required VPS terminal action is bootstrap; the rest of setup happens in browser onboarding**
