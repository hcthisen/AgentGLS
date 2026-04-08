# AgentGLS GoalLoop System — v6

## What This Is

A goal-oriented execution loop for AgentGLS. A provider-neutral runtime wakes hourly, picks the single highest-priority eligible goal, works toward it through direction → production → verification → measurement, records proof, and sleeps. The runtime can be either **Claude Code** or **OpenAI Codex**, selected at install time. No multi-agent orchestration. No org chart. No delegation chains.

---

## What the Bootstrap Installs

The base system provides:

- Selected provider CLI (`claude` or `codex`) with headless resumable execution
- PostgreSQL + PostgREST (port 3001) via Docker, localhost only
- Dashboard on port 3000, ready to complete onboarding at `VPS_IP:3000`
- Supabase tables for sessions, memory, health, secrets
- Provider-neutral Telegram bridge (Bot API long-polling, no Claude plugin dependency)
- Scheduled tasks subsystem (`cc_scheduled_tasks`, `task-runner.sh`)
- Caddy reverse proxy with auto TLS (once domain is configured)
- `AGENTS.md` as canonical instruction file; `CLAUDE.md` as thin shim importing it

---

## Onboarding and Setup

The GoalLoop system is generically deployable. The primary operator flow is:

1. Spin up a VPS (Ubuntu 22.04+ / Debian 12+, 2GB+ RAM)
2. SSH in and run the bootstrap installer
3. Open `VPS_IP:3000` in a browser
4. Complete the setup wizard:
   - **Admin account** — set email and password
   - **Provider** — choose `claude` or `codex` as the active runtime
   - **Domain** — enter the exact public hostname for the dashboard (for example `dashboard.example.com`). A "Check DNS" button verifies that hostname points at the VPS. If it resolves, Caddy provisions TLS for that host. If not, the system continues on the raw VPS IP.
   - **Provider auth** — authenticate the selected provider through the onboarding sign-in flow (Claude opens a Claude subscription login and expects the callback URL/code back; Codex opens ChatGPT device auth and shows the one-time code)
   - **Telegram** — create a bot via BotFather, enter the token. The bridge handles pairing.
   - **Business context** — set the business name, describe what the business does and its current situation. This generates `_context.md`.
   - **Initial goal** — describe the first goal the system should work toward. This generates the first goal file in `goals/active/` with `brief_status: draft`.

The only required terminal action on the VPS is running the bootstrap installer. After that, the rest of the setup should happen through the onboarding flow exposed at `VPS_IP:3000`.

**Fallbacks**: AgentGLS remains operable without the browser for development, recovery, or unattended installs. Env-var or direct-config paths may still exist, but they are fallback/operator paths, not the primary setup UX.

### Generated Files

Onboarding produces:

**`/opt/agentgls/goals/_context.md`** — business context. Claude/Codex reads this on every heartbeat. Editable via Telegram or directly on disk.

**`/opt/agentgls/goals/active/<first-goal>.md`** — first goal file with `brief_status: draft`. User must confirm before the heartbeat will pick it up.

**`/opt/agentgls/goals/_runbook.md`** — created empty. Accumulates cross-goal learnings as the system operates.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  VPS                                                            │
│                                                                 │
│  Telegram Bot API                                               │
│       │                                                         │
│       ▼                                                         │
│  telegram-bridge.py ──▶ provider-run.sh human <prompt>          │
│  (long-polling,          │                                      │
│   pairing/allowlist)     ├─▶ claude -c -p "..."  (if claude)    │
│       ▲                  └─▶ codex exec "..."    (if codex)     │
│       │                                                         │
│       └── reply via send-telegram.sh                            │
│                                                                 │
│  tmux: "agent"             tmux: "goalloop"                     │
│  ┌───────────────────┐    ┌───────────────────────┐             │
│  │ shell session     │    │ shell session          │             │
│  │ (operator attach) │    │ (operator attach)      │             │
│  │ human turns run   │    │ heartbeat turns run    │             │
│  │ here via          │    │ here via               │             │
│  │ provider-run.sh   │    │ provider-run.sh        │             │
│  └───────────────────┘    └───────────────────────┘             │
│                                     ▲                           │
│  /opt/agentgls/goals/                │ heartbeat claims          │
│  ├── _context.md                    │ one eligible goal         │
│  ├── _runbook.md                    │                           │
│  ├── active/*.md  ◄─────────────────┘                          │
│  ├── paused/*.md                                               │
│  ├── completed/*.md                                            │
│  ├── templates/*.md                                            │
│  ├── proof/<goal-slug>/...                                     │
│  └── locks/*.lock                                              │
│                                                                 │
│  /opt/agentgls/runtime/           Provider session continuity    │
│  ├── human/                      (isolated per channel)         │
│  ├── goalloop/                                                  │
│  ├── scheduled/                                                 │
│  └── summary/                                                   │
│                                                                 │
│  goalmeta.py ── all goal file parsing and mutation              │
│  goalloop-heartbeat.sh ── atomic claim + provider-run.sh        │
│  goalloop-sync.sh ──▶ cc_goals (PG, port 3001)                │
│                       (read-only dashboard projection)          │
│                                                                 │
│  provider-lib.sh ── provider config, dir resolution             │
│  provider-run.sh ── single entrypoint for all automation turns  │
│  send-telegram.sh ── outbound Telegram messages                 │
└──────────────────────────────────────────────────────────────────┘
```

### Provider-Neutral Runtime Model

AgentGLS does not keep a permanently running provider REPL in tmux. Instead, automation sends **headless resumable CLI turns** through `provider-run.sh`:

| Channel | Working dir | Purpose |
|---|---|---|
| `human` | `/opt/agentgls/runtime/human/` | Telegram conversations |
| `goalloop` | `/opt/agentgls/runtime/goalloop/` | Autonomous goal execution |
| `scheduled` | `/opt/agentgls/runtime/scheduled/` | Scheduled tasks |
| `summary` | `/opt/agentgls/runtime/summary/` | Daily summaries |

Each channel gets isolated session continuity. Both providers discover instruction files (`AGENTS.md` / `CLAUDE.md`) by walking the project tree from cwd, so keeping working dirs inside `/opt/agentgls` ensures they load the correct instructions.

Provider commands:

| | First run | Resume |
|---|---|---|
| **Claude** | `claude -p "..."` | `claude -c -p "..."` |
| **Codex** | `codex exec "..."` | `codex exec resume --last "..."` |

### Two tmux Sessions

These are **shell sessions for operator visibility**, not provider-specific UIs.

- `agent` — human-facing operational shell. Telegram bridge and human turns run here.
- `goalloop` — autonomous operational shell. Heartbeat turns run here.

Operators can `tmux attach -t agent` or `tmux attach -t goalloop` to observe. The watchdog ensures both sessions exist.

### Instruction File Model

**`AGENTS.md`** is the canonical instruction file. Codex reads it natively. Claude reads `CLAUDE.md`, which imports it:

```markdown
@AGENTS.md

## Claude-specific notes
- [only truly Claude-specific additions here]
```

On the deployed VPS:
- `/opt/agentgls/AGENTS.md` — canonical operational protocol (GoalLoop, Telegram commands, verification rules)
- `/opt/agentgls/CLAUDE.md` — thin shim importing `@AGENTS.md`

### Why Not Build On tasks.sh

The scheduled tasks subsystem (`cc_scheduled_tasks` → cron → `task-runner.sh` → `provider-run.sh`) is optimized for isolated prompt execution. It's good for reminders, reports, and exact-time jobs. It's the wrong primitive for GoalLoop because GoalLoop needs stateful tool use, proof capture, ongoing goal memory, and multi-phase execution with session continuity. GoalLoop and scheduled tasks coexist — they solve different problems.

### Telegram — Provider-Neutral

Telegram is decoupled from the provider runtime. No Claude plugin dependency.

**`telegram-bridge.py`** long-polls the Telegram Bot API, handles pairing/allowlist, and routes inbound messages through `provider-run.sh human <prompt_file>`. Replies go back via `send-telegram.sh`. Works identically with Claude or Codex selected.

**`send-telegram.sh`** reads `TELEGRAM_BOT_TOKEN` from `/opt/agentgls/.env`, sends text to a target `chat_id`, chunks messages for Telegram limits.

---

## goalmeta.py — The Single Parsing and Mutation Helper

All goal file operations route through one Python helper. Deterministic YAML parsing, atomic writes, file-locking for all mutations.

**Dependency**: PyYAML is required. No fallback. Install via `pip3 install pyyaml` or `apt install python3-yaml` during bootstrap.

### Commands

```
goalmeta.py get <file> <field>              # Read a front-matter field
goalmeta.py set <file> <field> <value>      # Write a front-matter field (under flock)
goalmeta.py claim <active_dir>              # Atomic: select best eligible + mark running
goalmeta.py finalize <file>                 # Atomic: reset run_state, set last_run to now
goalmeta.py complete <file> <completed_dir> # Atomic: finalize + move to completed/
goalmeta.py pause <file> <paused_dir>       # Atomic: finalize + move to paused/
goalmeta.py criteria <file>                 # Return finish criteria as JSON
goalmeta.py scoreboard <file>              # Return scoreboard as JSON
goalmeta.py check-runnable <file>           # Exit 0 if runnable, 1 if not
goalmeta.py reconcile-parent <parent_file> <active_dir>  # Roll up child status
```

### Key Design Decisions

**Atomic claim**: `claim` selects the best eligible goal AND marks it `run_state: running` under a single global flock (`goals/locks/_claim.lock`). No race window between selection and claiming. Crash recovery (stale `running` > 2h) happens inside the same operation.

**Finalize**: Resets `run_state` to idle, clears `run_id` and `run_started_at`, sets `last_run` to the actual completion time (not the heartbeat start time).

**Complete / Pause**: Calls `finalize` then atomically moves the file. Avoids cleanup commands targeting paths that no longer exist.

**No `status` in front matter**: The goal's directory (`active/`, `paused/`, `completed/`) is the source of truth for status. The sync script infers status from directory location.

### Implementation

```python
#!/usr/bin/env python3
"""
goalmeta.py — Goal file parser and mutator for AgentGLS GoalLoop.
All goal file reads and writes route through this helper.
Requires: PyYAML (pip3 install pyyaml)
"""

import sys
import os
import json
import re
import fcntl
import uuid
from datetime import datetime, timezone
from pathlib import Path

import yaml  # Required — no fallback


PRIORITY_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3}


# ── Parsing ──

def parse_goal(filepath):
    """Parse a goal file into (front_matter_dict, body_str)."""
    text = Path(filepath).read_text(encoding="utf-8")
    if not text.startswith("---"):
        return {}, text
    parts = text.split("---", 2)
    if len(parts) < 3:
        return {}, text
    fm = yaml.safe_load(parts[1].strip()) or {}
    return fm, parts[2]


def write_goal(filepath, fm, body):
    """Write front matter + body. Atomic via temp+rename."""
    fm_str = yaml.dump(fm, default_flow_style=False, allow_unicode=True,
                       sort_keys=False).strip()
    content = f"---\n{fm_str}\n---\n{body}"
    tmp = filepath + ".tmp"
    Path(tmp).write_text(content, encoding="utf-8")
    os.rename(tmp, filepath)


def extract_criteria(body):
    """Extract finish criteria from ## Finish Criteria section only."""
    criteria = []
    in_section = False
    for line in body.splitlines():
        if line.strip().startswith("## Finish Criteria"):
            in_section = True
            continue
        if in_section and line.strip().startswith("## "):
            break
        if in_section and re.match(r"^- \[[ x]\]", line):
            done = "[x]" in line
            text = re.sub(r"^- \[[ x]\] ", "", line)
            criteria.append({"text": text, "done": done})
    return criteria


def extract_scoreboard(body):
    """Extract scoreboard from ## Scoreboard markdown table."""
    scoreboard = {}
    in_section = False
    past_separator = False
    for line in body.splitlines():
        if line.strip().startswith("## Scoreboard"):
            in_section = True
            continue
        if in_section and line.strip().startswith("## "):
            break
        if not in_section:
            continue
        stripped = line.strip()
        if not stripped.startswith("|"):
            continue
        if re.match(r"^\|[\s\-|]+\|$", stripped):
            past_separator = True
            continue
        if not past_separator:
            continue
        cols = [c.strip() for c in stripped.split("|")[1:-1]]
        if len(cols) >= 2 and cols[0]:
            scoreboard[cols[0]] = cols[1]
    return scoreboard


# ── Eligibility ──

def _now():
    return datetime.now(timezone.utc)


def _now_iso():
    return _now().strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_ts(val):
    if not val or str(val) == "null":
        return None
    try:
        return datetime.fromisoformat(str(val).replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def is_eligible(fm):
    """Check if a goal is eligible for heartbeat selection."""
    now = _now()

    if fm.get("brief_status") != "approved":
        return False

    if fm.get("run_state") not in (None, "idle", "null"):
        return False

    if fm.get("approval_policy") == "manual":
        if not fm.get("approved_for_next_run"):
            return False

    nea = _parse_ts(fm.get("next_eligible_at"))
    if nea and now < nea:
        return False

    last_run = _parse_ts(fm.get("last_run"))
    hb_min = fm.get("heartbeat_minutes", 60) or 60
    if last_run:
        elapsed_min = (now - last_run).total_seconds() / 60
        if elapsed_min < hb_min:
            return False

    return True


def compute_rank(fm):
    """Compute priority rank. Lower = higher priority."""
    now = _now()
    rank = PRIORITY_RANK.get(fm.get("priority", "medium"), 2)

    meas_due = _parse_ts(fm.get("measurement_due_at"))
    if meas_due and now >= meas_due:
        rank -= 1

    deadline = _parse_ts(fm.get("deadline_at"))
    if deadline:
        hours_left = (deadline - now).total_seconds() / 3600
        if hours_left < 24:
            rank -= 2
        elif hours_left < 72:
            rank -= 1

    return rank


# ── Atomic Operations ──

def do_claim(active_dir):
    """Atomic: select best eligible leaf + mark running. Returns dict or None."""
    active_dir = Path(active_dir)
    lock_dir = active_dir.parent / "locks"
    lock_dir.mkdir(parents=True, exist_ok=True)

    with open(lock_dir / "_claim.lock", "w") as lock_fd:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        try:
            all_files = list(active_dir.glob("*.md"))

            # Identify parent slugs
            parent_slugs = set()
            for f in all_files:
                fm, _ = parse_goal(str(f))
                p = fm.get("parent")
                if p and str(p) != "null":
                    parent_slugs.add(str(p))

            candidates = []
            for f in all_files:
                slug = f.stem
                if slug in parent_slugs:
                    continue

                fm, body = parse_goal(str(f))

                # Crash recovery: stale running > 2h
                if fm.get("run_state") == "running":
                    started = _parse_ts(fm.get("run_started_at"))
                    if started:
                        elapsed_h = (_now() - started).total_seconds() / 3600
                        if elapsed_h >= 2:
                            fm["run_state"] = "idle"
                            fm["run_id"] = None
                            fm["run_started_at"] = None
                            write_goal(str(f), fm, body)
                        else:
                            continue
                    else:
                        continue

                if not is_eligible(fm):
                    continue

                rank = compute_rank(fm)
                candidates.append((rank, slug, str(f), fm, body))

            if not candidates:
                return None

            candidates.sort(key=lambda x: x[0])
            rank, slug, filepath, fm, body = candidates[0]

            run_id = str(uuid.uuid4())
            now = _now_iso()
            fm["run_state"] = "running"
            fm["run_id"] = run_id
            fm["run_started_at"] = now
            if fm.get("approval_policy") == "manual":
                fm["approved_for_next_run"] = None
            write_goal(filepath, fm, body)

            return {"slug": slug, "file": filepath,
                    "run_id": run_id, "priority_rank": rank}
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)


def do_finalize(filepath):
    """Reset run_state to idle, set last_run to now."""
    fm, body = parse_goal(filepath)
    fm["run_state"] = "idle"
    fm["run_id"] = None
    fm["run_started_at"] = None
    fm["last_run"] = _now_iso()
    write_goal(filepath, fm, body)


def do_complete(filepath, completed_dir):
    """Finalize + move to completed/."""
    fm, body = parse_goal(filepath)
    fm["run_state"] = "idle"
    fm["run_id"] = None
    fm["run_started_at"] = None
    fm["last_run"] = _now_iso()
    write_goal(filepath, fm, body)
    dest = os.path.join(completed_dir, os.path.basename(filepath))
    os.rename(filepath, dest)
    return dest


def do_pause(filepath, paused_dir):
    """Finalize + move to paused/."""
    fm, body = parse_goal(filepath)
    fm["run_state"] = "idle"
    fm["run_id"] = None
    fm["run_started_at"] = None
    fm["last_run"] = _now_iso()
    write_goal(filepath, fm, body)
    dest = os.path.join(paused_dir, os.path.basename(filepath))
    os.rename(filepath, dest)
    return dest


def do_reconcile_parent(parent_file, active_dir):
    """Roll up child completion status to parent scoreboard."""
    parent_fm, parent_body = parse_goal(parent_file)
    parent_slug = Path(parent_file).stem
    active_dir = Path(active_dir)
    completed_dir = active_dir.parent / "completed"

    total = 0
    done = 0
    for d in [active_dir, completed_dir]:
        for f in d.glob("*.md"):
            fm, _ = parse_goal(str(f))
            if str(fm.get("parent")) == parent_slug:
                total += 1
                if d == completed_dir:
                    done += 1

    now = _now_iso()
    lines = parent_body.splitlines()
    new_lines = []
    in_sb = False
    wrote_total = wrote_done = False
    for line in lines:
        if line.strip().startswith("## Scoreboard"):
            in_sb = True
        elif in_sb and line.strip().startswith("## "):
            if not wrote_total:
                new_lines.append(f"| Children total | {total} | {now} |")
            if not wrote_done:
                new_lines.append(f"| Children completed | {done} | {now} |")
            in_sb = False
        if in_sb and "Children total" in line:
            new_lines.append(f"| Children total | {total} | {now} |")
            wrote_total = True
            continue
        if in_sb and "Children completed" in line:
            new_lines.append(f"| Children completed | {done} | {now} |")
            wrote_done = True
            continue
        new_lines.append(line)

    write_goal(parent_file, parent_fm, "\n".join(new_lines))
    return {"total": total, "done": done}


# ── CLI ──

def main():
    if len(sys.argv) < 2:
        print("Usage: goalmeta.py <command> [args]", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "get" and len(sys.argv) >= 4:
        fm, _ = parse_goal(sys.argv[2])
        val = fm.get(sys.argv[3])
        print("null" if val is None else val)

    elif cmd == "set" and len(sys.argv) >= 5:
        filepath = sys.argv[2]
        with open(filepath + ".lock", "w") as fd:
            fcntl.flock(fd, fcntl.LOCK_EX)
            try:
                fm, body = parse_goal(filepath)
                key, val = sys.argv[3], sys.argv[4]
                if val == "null":
                    val = None
                elif val.isdigit():
                    val = int(val)
                fm[key] = val
                write_goal(filepath, fm, body)
            finally:
                fcntl.flock(fd, fcntl.LOCK_UN)

    elif cmd == "claim" and len(sys.argv) >= 3:
        result = do_claim(sys.argv[2])
        if result:
            print(json.dumps(result))
        else:
            print("null")
            sys.exit(1)

    elif cmd == "finalize" and len(sys.argv) >= 3:
        do_finalize(sys.argv[2])
        print("OK")

    elif cmd == "complete" and len(sys.argv) >= 4:
        print(do_complete(sys.argv[2], sys.argv[3]))

    elif cmd == "pause" and len(sys.argv) >= 4:
        print(do_pause(sys.argv[2], sys.argv[3]))

    elif cmd == "criteria" and len(sys.argv) >= 3:
        _, body = parse_goal(sys.argv[2])
        print(json.dumps(extract_criteria(body)))

    elif cmd == "scoreboard" and len(sys.argv) >= 3:
        _, body = parse_goal(sys.argv[2])
        print(json.dumps(extract_scoreboard(body)))

    elif cmd == "check-runnable" and len(sys.argv) >= 3:
        fm, _ = parse_goal(sys.argv[2])
        if fm.get("brief_status") != "approved":
            print(f"NOT RUNNABLE: brief_status is {fm.get('brief_status')}")
            sys.exit(1)
        if fm.get("run_state") not in (None, "idle", "null"):
            print(f"NOT RUNNABLE: run_state is {fm.get('run_state')}")
            sys.exit(1)
        if fm.get("approval_policy") == "manual" and not fm.get("approved_for_next_run"):
            print("NOT RUNNABLE: manual approval required")
            sys.exit(1)
        print("RUNNABLE")

    elif cmd == "reconcile-parent" and len(sys.argv) >= 4:
        print(json.dumps(do_reconcile_parent(sys.argv[2], sys.argv[3])))

    else:
        print(f"Unknown command or wrong args: {cmd}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
```

---

## Goal File Format

YAML front matter for machine-readable state. Markdown body for human-readable content. No `status` field — directory is source of truth.

```markdown
---
title: "Grow Social Media Presence"
priority: high
brief_status: approved
run_state: idle
run_id: null
run_started_at: null
heartbeat_minutes: 60
created: "2026-04-06"
last_run: null
next_eligible_at: null
measurement_due_at: null
deadline_at: null
approval_policy: auto
approved_for_next_run: null
template: social-growth@v1
parent: null
notify_chat_id: "123456789"
---

## Objective

Grow social media presence across primary channels.

## Finish Criteria

- [ ] 10 posts scheduled for the next 5 days
- [ ] Each post has unique image and caption
- [ ] Posts are live in scheduler (verified)
- [ ] 5-day performance review completed
- [ ] Next batch strategy updated from results

## Context

- Brand: See _context.md
- Channels: [from _context.md]
- Tone: [from _context.md]
- Access: [from _context.md and custom.env]

## Constraints

- [From _context.md — language, content rules, platform limits]
- Budget: keep image generation under $2/batch

## Scoreboard

| Metric | Value | Updated |
|--------|-------|---------|
| Posts scheduled | 0 | - |
| Posts published | 0 | - |
| Engagement rate | - | - |

## Run Log

### 2026-04-06T14:00:00Z
- Phase: direction
- Action: Chose batch-of-10 strategy, split across channels
- Next: production

### 2026-04-06T14:12:00Z
- Phase: production + verification
- Action: Generated 10 posts, scheduled in platform
- Verification: All 10 confirmed — shipped_pending_verification → verified
- Proof: proof/social-growth/batch-001/ (screenshots + post IDs)
- Scoreboard: posts_scheduled = 10
- Next: measurement (set measurement_due_at to 2026-04-11)

## Runbook (goal-specific)

- [Learnings accumulate here as the goal progresses]
```

### Front Matter Fields

| Field | Purpose |
|---|---|
| `priority` | critical, high, medium, low |
| `brief_status` | draft, approved. Goal cannot execute until approved. |
| `run_state` | idle, running. Prevents double-selection. Stale runs (>2h) auto-recover. |
| `run_id` | UUID of current run. Null when idle. |
| `run_started_at` | When current run began. Used for crash recovery. |
| `heartbeat_minutes` | How often this goal is eligible (default 60). |
| `last_run` | Timestamp of last completed run. Set by `finalize` at actual completion time. |
| `next_eligible_at` | Earliest time this goal can be picked again. |
| `measurement_due_at` | When a measurement phase should run. |
| `deadline_at` | Hard deadline. < 24h: strong boost; < 72h: moderate boost. |
| `approval_policy` | `auto` or `manual`. Manual requires `approved_for_next_run: true` per run. |
| `approved_for_next_run` | Set `true` by human to authorize one run. Cleared after claim. |
| `template` | Which template was used (name@version). |
| `parent` | Slug of parent goal (one level max). |
| `notify_chat_id` | Telegram chat ID for notifications. |

### Output Verification States

Within a run, the provider tracks output verification in the run log with these states:

- **generated_not_shipped** — output created but not yet pushed
- **shipped_pending_verification** — pushed to destination, not yet confirmed
- **verified** — confirmed live/correct with proof captured
- **verification_failed** — confirmation check failed
- **needs_human_verification** — cannot verify automatically; human notified

A finish criterion can only be checked off when its outputs reach `verified`.

---

## Heartbeat Script

The heartbeat claims one goal via `goalmeta.py`, builds a prompt, and executes it through the **provider adapter** — not the vendor CLI directly.

```bash
#!/bin/bash
# /opt/agentgls/scripts/goalloop-heartbeat.sh
# Cron: 0 * * * *

GOALS_DIR="/opt/agentgls/goals"
ACTIVE_DIR="$GOALS_DIR/active"
SCRIPTS_DIR="/opt/agentgls/scripts"
LOG="/opt/agentgls/logs/goalloop.log"
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

source "$SCRIPTS_DIR/provider-lib.sh"

log() { echo "[$NOW_ISO] $*" >> "$LOG"; }

# ── Ensure goalloop tmux shell exists ──
if ! tmux has-session -t goalloop 2>/dev/null; then
    log "goalloop session not found. Creating..."
    tmux new-session -d -s goalloop -c "$GOALS_DIR"
fi

# ── Atomic claim ──
SELECTION=$(python3 "$SCRIPTS_DIR/goalmeta.py" claim "$ACTIVE_DIR" 2>/dev/null) || true

if [ -z "$SELECTION" ] || [ "$SELECTION" = "null" ]; then
    log "No eligible goals. Sleeping."
    exit 0
fi

BEST_SLUG=$(echo "$SELECTION" | python3 -c "import sys,json; print(json.load(sys.stdin)['slug'])")
BEST_FILE=$(echo "$SELECTION" | python3 -c "import sys,json; print(json.load(sys.stdin)['file'])")
RUN_ID=$(echo "$SELECTION" | python3 -c "import sys,json; print(json.load(sys.stdin)['run_id'])")
BEST_RANK=$(echo "$SELECTION" | python3 -c "import sys,json; print(json.load(sys.stdin)['priority_rank'])")

log "Claimed goal: $BEST_SLUG (run: $RUN_ID, rank: $BEST_RANK)"

# ── Build prompt ──
PROMPT_FILE=$(mktemp /tmp/goalloop-prompt.XXXXX)
cat > "$PROMPT_FILE" << PROMPT
--- GOALLOOP HEARTBEAT ---
Time: $NOW_ISO
Run ID: $RUN_ID
Selected goal: $BEST_SLUG
Goal file: $BEST_FILE
Context: $GOALS_DIR/_context.md
Runbook: $GOALS_DIR/_runbook.md
Proof dir: $GOALS_DIR/proof/$BEST_SLUG/
Locks dir: $GOALS_DIR/locks/

Execute the GoalLoop protocol from AGENTS.md for this goal.
Read the goal file, context, and runbook. Work through the phases.

When finished (success, failure, or blocked), run exactly ONE of:
  # Normal completion (goal continues on next heartbeat):
  python3 $SCRIPTS_DIR/goalmeta.py finalize $BEST_FILE

  # Goal fully done (all criteria verified):
  python3 $SCRIPTS_DIR/goalmeta.py complete $BEST_FILE $GOALS_DIR/completed

  # Goal needs to pause (waiting on human):
  python3 $SCRIPTS_DIR/goalmeta.py pause $BEST_FILE $GOALS_DIR/paused

For blocked goals, also notify via:
  bash $SCRIPTS_DIR/send-telegram.sh <chat_id> "🔴 Goal blocked: $BEST_SLUG — <reason>"
--- END HEARTBEAT ---
PROMPT

# ── Execute via provider adapter into goalloop tmux session ──
# Send the provider-run command into the goalloop shell for operator visibility
PROVIDER_CMD=$(build_provider_run_cmd goalloop "$PROMPT_FILE")
tmux send-keys -t goalloop "$PROVIDER_CMD" C-m

rm -f "$PROMPT_FILE"
log "Heartbeat injected for: $BEST_SLUG"
```

**Key difference from v5**: The heartbeat calls `provider-run.sh goalloop <prompt>` (via `build_provider_run_cmd` from `provider-lib.sh`), not a hardcoded `claude` command. This works with either provider.

---

## AGENTS.md — Canonical Operational Protocol

This is the canonical instruction file, read by Codex natively and imported by Claude via `CLAUDE.md`. Lives at `/opt/agentgls/AGENTS.md` on the deployed VPS.

The GoalLoop protocol section:

```markdown
## GoalLoop Execution Protocol

You operate a GoalLoop system. Goals are markdown files with YAML front matter
in /opt/agentgls/goals/. All front-matter operations go through goalmeta.py.

### Directory Layout

/opt/agentgls/goals/
├── _context.md          # Business context (generated at onboarding)
├── _runbook.md          # Cross-goal learnings
├── active/              # Goals eligible for execution
├── paused/              # Goals waiting on human input
├── completed/           # Goals with all finish criteria verified
├── templates/           # Goal templates (social-growth@v1.md, etc.)
├── proof/<goal-slug>/   # Verification proof
└── locks/               # File locks for shared external surfaces

### Goal File Operations

Use goalmeta.py for all front-matter operations:
  python3 /opt/agentgls/scripts/goalmeta.py get <file> <field>
  python3 /opt/agentgls/scripts/goalmeta.py set <file> <field> <value>
  python3 /opt/agentgls/scripts/goalmeta.py finalize <file>
  python3 /opt/agentgls/scripts/goalmeta.py complete <file> /opt/agentgls/goals/completed
  python3 /opt/agentgls/scripts/goalmeta.py pause <file> /opt/agentgls/goals/paused

You may read and edit the markdown body (below the second ---) directly.

### When a Human Gives You a New Task via Telegram

Do NOT execute immediately unless trivially small (< 5 min). Instead:

1. Draft a goal file from the closest template in goals/templates/
2. Set brief_status: draft
3. Define concrete finish criteria (externally testable, outcome-oriented)
4. Save to goals/active/<slug>.md
5. Reply with the brief summary and finish criteria
6. Ask the user to confirm or adjust
7. On confirmation: goalmeta.py set <file> brief_status approved
8. The next heartbeat will pick it up

### When a Heartbeat Wakes You

You receive a heartbeat prompt naming one selected goal and a run ID.
The goal's run_state is already "running" (claimed atomically by the heartbeat).

**1. Direction** (< 10% of effort)
Read the goal file, _context.md, _runbook.md.
Check which finish criteria are incomplete. Decide the next action.

**2. Production**
Do the work. Before mutating shared external surfaces, acquire a lock:
  flock -n /opt/agentgls/goals/locks/<resource>.lock -c "<command>"
If held, log as blocked and pause.

**3. Verification (NON-NEGOTIABLE)**
Track each output through verification states in the run log:
- generated_not_shipped → shipped_pending_verification → verified
- Or: verification_failed / needs_human_verification

Verify output exists where expected. Save proof to proof/<goal-slug>/.
A criterion CANNOT be checked off unless its outputs are "verified".

**4. Measurement + Logging**
- Append run log entry: timestamp, phase, action, result, proof, next
- Update scoreboard
- Check off verified finish criteria
- If setting measurement_due_at, also set next_eligible_at to match
- Update _runbook.md with anything learned

**5. Cleanup — Run Exactly ONE**
  goalmeta.py finalize <file>              # normal: continues next heartbeat
  goalmeta.py complete <file> <completed>  # all criteria verified
  goalmeta.py pause <file> <paused>        # blocked, needs human

Always run one before stopping. Never leave run_state as "running".

**6. Blocked Goals**
Log the blocker. Notify via send-telegram.sh:
  bash /opt/agentgls/scripts/send-telegram.sh <chat_id> "🔴 Goal blocked: <slug> — <reason>"
Then pause.

### Finish Criteria Rules

- Must be concrete and externally testable
- A goal CANNOT be completed unless every criterion is checked
- A criterion CANNOT be checked unless outputs are verified with proof
- brief_status: draft goals are NEVER eligible

### Resource Locks

Lock shared surfaces during mutation:
- locks/wordpress_prod_<domain>.lock
- locks/ghl_social_<locationId>.lock
- locks/email_outbound_<domain>.lock

Use flock -n. If held, log and pause.

### Cost Awareness

- If a single run would cost > $5, stop and notify via Telegram
- Log estimated cost in each run log entry

## Telegram Commands

"New goal: [description]" → draft with brief_status: draft, reply with criteria
"Approve goal: [name]" → set brief_status: approved
"Approve run: [name]" → set approved_for_next_run: true (manual-approval goals)
"Goal status" → summarize all active goals
"Pause goal: [name]" → move to paused/
"Resume goal: [name]" → move to active/
"Goal detail: [name]" → scoreboard + last 3 run log entries
"What did you do today?" → today's run logs across all goals
"Update context: [change]" → edit _context.md

## Communication Rules

- Outbound Telegram delivery is handled by send-telegram.sh, not by you
- Keep replies concise unless asked otherwise
- Do not extract or expose auth tokens from provider directories
```

### CLAUDE.md (Thin Shim)

```markdown
@AGENTS.md

## Claude-specific notes
- Use claude -p for one-shot inference when appropriate
- Session continuity maintained per channel working directory
```

---

## Watchdog

Provider-neutral. Ensures tmux shell sessions exist, not provider REPLs:

```bash
# In /opt/agentgls/scripts/watchdog.sh

for SESSION in agent goalloop; do
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
        echo "[$(date)] $SESSION session dead. Restarting..." \
            >> /opt/agentgls/logs/watchdog.log
        tmux new-session -d -s "$SESSION" -c /opt/agentgls
    fi
done

# Check telegram-bridge process
if ! pgrep -f "telegram-bridge.py" > /dev/null 2>&1; then
    echo "[$(date)] Telegram bridge dead. Restarting..." \
        >> /opt/agentgls/logs/watchdog.log
    nohup python3 /opt/agentgls/scripts/telegram-bridge.py \
        >> /opt/agentgls/logs/telegram-bridge.log 2>&1 &
fi
```

---

## Supabase Schema (Dashboard Projection)

```sql
-- supabase/migrations/006_goalloop.sql
-- Idempotent: safe to re-run

CREATE TABLE IF NOT EXISTS cc_goals (
    slug TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    priority TEXT NOT NULL DEFAULT 'medium',
    brief_status TEXT NOT NULL DEFAULT 'draft',
    run_state TEXT DEFAULT 'idle',
    objective TEXT,
    finish_criteria JSONB DEFAULT '[]'::jsonb,
    scoreboard JSONB DEFAULT '{}'::jsonb,
    heartbeat_minutes INT DEFAULT 60,
    last_run TIMESTAMPTZ,
    next_eligible_at TIMESTAMPTZ,
    measurement_due_at TIMESTAMPTZ,
    deadline_at TIMESTAMPTZ,
    approval_policy TEXT DEFAULT 'auto',
    parent TEXT,
    notify_chat_id TEXT,
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_goals_status ON cc_goals(status);
```

Migration number is `006` (repo already has `000`–`005`). Wire into `run-migrations.sh`. Bootstrap calls `run-migrations.sh` after services start.

---

## Goal Sync Script

```bash
#!/bin/bash
# /opt/agentgls/scripts/goalloop-sync.sh
# Cron: */30 * * * *

set -euo pipefail
source /opt/agentgls/.env

GOALS_DIR="/opt/agentgls/goals"
SCRIPTS_DIR="/opt/agentgls/scripts"
API="http://localhost:3001"
AUTH="Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY"
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

gm() { python3 "$SCRIPTS_DIR/goalmeta.py" "$@"; }

sync_dir() {
    local dir="$1" status="$2"
    for f in "$dir"/*.md; do
        [ -f "$f" ] || continue
        SLUG=$(basename "$f" .md)

        # Build JSON via Python for safe escaping
        JSON=$(python3 -c "
import json, sys, subprocess

def gm(*args):
    r = subprocess.run(
        ['python3', '$SCRIPTS_DIR/goalmeta.py'] + list(args),
        capture_output=True, text=True)
    return r.stdout.strip()

f = '$f'
slug = '$SLUG'
status = '$status'

d = {
    'slug': slug,
    'title': gm('get', f, 'title') or slug,
    'status': status,
    'priority': gm('get', f, 'priority') or 'medium',
    'brief_status': gm('get', f, 'brief_status') or 'draft',
    'run_state': gm('get', f, 'run_state') or 'idle',
    'heartbeat_minutes': int(gm('get', f, 'heartbeat_minutes') or 60),
    'approval_policy': gm('get', f, 'approval_policy') or 'auto',
    'finish_criteria': json.loads(gm('criteria', f) or '[]'),
    'scoreboard': json.loads(gm('scoreboard', f) or '{}'),
    'updated_at': '$NOW_ISO'
}

# Objective from body
import re
text = open(f).read()
m = re.search(r'## Objective\n(.*?)(?=\n## )', text, re.DOTALL)
if m:
    d['objective'] = m.group(1).strip()[:500]

# Optional timestamp fields
for field in ['last_run','next_eligible_at','measurement_due_at','deadline_at']:
    v = gm('get', f, field)
    if v and v != 'null':
        d[field] = v

for field in ['parent','notify_chat_id']:
    v = gm('get', f, field)
    if v and v != 'null':
        d[field] = v

# Replace 'null' string values
for k in list(d):
    if d[k] == 'null':
        del d[k]

print(json.dumps(d))
")

        curl -s -X POST "$API/cc_goals" \
            -H "$AUTH" \
            -H "Content-Type: application/json" \
            -H "Prefer: resolution=merge-duplicates" \
            -d "$JSON" > /dev/null
    done

    # Reconcile parent goals
    for f in "$dir"/*.md; do
        [ -f "$f" ] || continue
        SLUG=$(basename "$f" .md)
        if grep -rl "^parent: $SLUG" "$GOALS_DIR/active/"*.md "$GOALS_DIR/completed/"*.md \
            2>/dev/null | head -1 > /dev/null 2>&1; then
            gm reconcile-parent "$f" "$GOALS_DIR/active" > /dev/null 2>&1 || true
        fi
    done
}

sync_dir "$GOALS_DIR/active" "active"
sync_dir "$GOALS_DIR/paused" "paused"
sync_dir "$GOALS_DIR/completed" "completed"
```

---

## File Locks for Shared Surfaces

`flock` on files in `goals/locks/`. Implements resource leases without a database.

```bash
flock -n /opt/agentgls/goals/locks/wordpress_prod_example.com.lock -c \
    "wp post update 42 --post_content='...'"
# Exit 1 if held → log and pause
```

---

## Cron Summary

```
# Base AgentGLS
*/5  * * * *  watchdog.sh           # tmux sessions + telegram-bridge health
*/5  * * * *  sync-secrets.sh       # Dashboard secrets → .env
*/10 * * * *  security-sync.sh      # Bans + logins → DB
*/10 * * * *  server-health.sh      # Metrics → DB
*/30 * * * *  sync-sessions.sh      # Session JSONL → DB

# GoalLoop
0    * * * *  goalloop-heartbeat.sh  # Atomic claim + provider-run one goal
*/30 * * * *  goalloop-sync.sh       # Goal files → cc_goals + parent reconciliation
```

---

## What Done Looks Like

1. "New goal: X" via Telegram → brief with `brief_status: draft` → user approves → `approved`
2. Heartbeat atomically claims one eligible leaf goal per hour
3. Execution runs through `provider-run.sh` — works with Claude or Codex
4. `run_state` transitions cleanly: idle → running → idle. Crashed runs auto-recover.
5. Outputs tracked through verification states with proof
6. Goals only reach `completed/` when every criterion has verified outputs
7. `deadline_at` boosts priority ranking
8. `approval_policy: manual` blocks until human approves each run
9. Measurement delays block reselection via `next_eligible_at`
10. Shared surfaces are flock-protected
11. `_runbook.md` grows with real learnings
12. Dashboard shows goals from `cc_goals` (read-only, port 3001)
13. Blocked goals pause and notify via `send-telegram.sh` (provider-neutral)
14. Telegram bridge works identically with either provider
15. Scheduled tasks continue working independently through `provider-run.sh`
16. `AGENTS.md` is canonical; `CLAUDE.md` is a shim

## One-Sentence Test

Create a goal via Telegram on Monday, go dark until Friday, come back to verified outputs with proof, updated scoreboards, a smarter runbook, and Telegram messages for everything that needed your attention — and the provider that did the work could have been either Claude or Codex.
