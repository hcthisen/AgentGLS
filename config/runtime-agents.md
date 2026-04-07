# AGENTS.md

This is the canonical operational instruction file for the deployed AgentGLS runtime.

## Runtime Model

- Work from `/opt/agentos`.
- Treat `AGENTS.md` as canonical and `CLAUDE.md` as a thin compatibility shim.
- The active provider may be `claude` or `codex`.
- Human chat, GoalLoop heartbeats, scheduled tasks, and summaries all run through provider-neutral host adapters.
- Never rely on a permanently running provider REPL. Session continuity comes from the provider working directory for the current channel.

## GoalLoop Execution Protocol

You operate a GoalLoop system. Goals are markdown files with YAML front matter in `/opt/agentos/goals/`.
All front-matter reads and writes must go through `goalmeta.py`.

### Directory Layout

`/opt/agentos/goals/`
- `_context.md` for standing business context
- `_runbook.md` for cross-goal learnings
- `active/` for runnable goals
- `paused/` for goals waiting on human input
- `completed/` for goals with verified completion
- `templates/` for starter goal templates
- `proof/<goal-slug>/` for verification artifacts
- `locks/` for shared-surface flock files

### Goal File Operations

Use `python3 /opt/agentos/scripts/goalmeta.py` for all front-matter mutations:
- `get <file> <field>`
- `set <file> <field> <value>`
- `finalize <file>`
- `complete <file> /opt/agentos/goals/completed`
- `pause <file> /opt/agentos/goals/paused`
- `criteria <file>`
- `scoreboard <file>`
- `check-runnable <file>`
- `reconcile-parent <parent_file> /opt/agentos/goals/active`

You may edit the markdown body directly, but do not hand-edit front matter.

### Human Chat Rules

- Telegram ingress and egress are provider-neutral.
- Inbound human messages arrive through `telegram-bridge.py`.
- Outbound Telegram delivery is handled by `bash /opt/agentos/scripts/send-telegram.sh <chat_id> "<text>"`.
- Reply to the human directly and keep the answer concise unless they ask for depth.
- Do not tell the model to send its own Telegram message. The bridge delivers outbound text.

### Draft, Approve, Manual-Run, Pause, Resume

When a human gives a non-trivial task through Telegram:
1. Draft a goal from the closest file in `goals/templates/`.
2. Save it under `goals/active/<slug>.md`.
3. Set `brief_status: draft`.
4. Define concrete finish criteria that are externally testable.
5. Reply with the draft summary and criteria.
6. Ask the human to confirm or adjust it.
7. On approval, use `goalmeta.py set <file> brief_status approved`.

When a goal uses `approval_policy: manual`:
1. Wait for the human to approve the next run.
2. Use `goalmeta.py set <file> approved_for_next_run true`.
3. The next claim clears that flag automatically.

Pause and resume flow:
1. When blocked on human input, log the blocker and use `goalmeta.py pause <file> /opt/agentos/goals/paused`.
2. Notify the human through `send-telegram.sh`.
3. To resume later, move the file back into `goals/active/` and keep the same slug unless a rename is necessary.

### Heartbeat Flow

When a heartbeat wakes you:
1. Read the selected goal file, `_context.md`, and `_runbook.md`.
2. Spend less than 10% of the run on direction.
3. Do the work.
4. Verify every output before marking progress complete.
5. Update the run log, scoreboard, and any verified finish criteria.
6. Run exactly one cleanup action:
   - `goalmeta.py finalize <file>`
   - `goalmeta.py complete <file> /opt/agentos/goals/completed`
   - `goalmeta.py pause <file> /opt/agentos/goals/paused`

Never leave `run_state: running` behind.

### Output Verification States

Track output state explicitly in the run log:
- `generated_not_shipped`
- `shipped_pending_verification`
- `verified`
- `verification_failed`
- `needs_human_verification`

A finish criterion can be checked only after its outputs are `verified`.

### Resource Locks

Before mutating a shared surface, acquire a lock under `/opt/agentos/goals/locks/`:
- `wordpress_prod_<domain>.lock`
- `ghl_social_<location_id>.lock`
- `email_outbound_<domain>.lock`

Use `flock -n`. If the lock is held, log the blocker, notify the human if needed, and pause the goal instead of racing.

### Safety Rules

- Do not read, extract, or expose auth tokens from provider-owned directories.
- Do not scrape `~/.claude`, `~/.codex`, or browser storage for credentials.
- Use provider-owned auth flows only.
- Keep GoalLoop work file-first. The goal markdown files are the source of truth.

## Telegram Commands

- `New goal: ...` drafts a goal in `goals/active/` with `brief_status: draft`
- `Approve goal: ...` sets `brief_status: approved`
- `Approve run: ...` sets `approved_for_next_run: true`
- `Pause goal: ...` moves the goal to `paused/`
- `Resume goal: ...` moves the goal back to `active/`
- `Goal status` summarizes active goals
- `Goal detail: ...` returns scoreboard and recent run-log context
- `What did you do today?` summarizes today’s run logs
- `Update context: ...` edits `_context.md`
