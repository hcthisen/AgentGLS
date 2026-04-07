# AgentGLS — Architecture Framework Document

This document captures the legacy AgentOS-CC / Claude-first architecture that this repo started from. It remains useful as a baseline reference, but it is not the authoritative target architecture for the AgentGLS migration.

> Status:
> - `AGENTS.md` is the canonical repo instruction file.
> - `CLAUDE.md` exists only as a compatibility shim.
> - The target provider-neutral architecture is defined in `goalloop-design.md`.
> - The phased implementation path is defined in `PLAN.md`.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [System Components](#2-system-components)
3. [Data Flow](#3-data-flow)
4. [Decision Log](#4-decision-log)
5. [Security Architecture](#5-security-architecture)
6. [Automation Matrix](#6-automation-matrix)
7. [Folder Structure](#7-folder-structure)
8. [Credential Management](#8-credential-management)
9. [Failure Modes & Recovery](#9-failure-modes--recovery)
10. [Setup Order](#10-setup-order)

---

## 1. Architecture Overview

```
                           +--------------------+
                           |   User (Phone)     |
                           |   Telegram App     |
                           +--------+-----------+
                                    |
                                    | Telegram Bot API
                                    |
+-----------------------------------------------------------------------------------------------+
|  VPS (domain.com + *.domain.com)                                                              |
|                                                                                               |
|  +---------------------------+      +-------------------+      +---------------------------+  |
|  |   tmux session "claude"   |      |  Cron Scheduler   |      |   Caddy                   |  |
|  |                           |      |                   |      |   (Reverse Proxy + TLS)   |  |
|  |  +---------------------+  |      |  */5  watchdog    |      |                           |  |
|  |  |   Claude Code CLI   |  |      |  */10 security    |      |  dashboard.domain.com     |  |
|  |  |   + Telegram Plugin |  |      |  */10 health      |      |    -> Next.js :3000       |  |
|  |  +----------+----------+  |      |  */30 sync        |      |                           |  |
|  |             |             |      |  2h   summary     |      |  Auto TLS via Let's       |  |
|  |  +----------+----------+  |      |                   |      |  Encrypt                  |  |
|  |  |  fail2ban           |  |      +--------+----------+      +---------------------------+  |
|  |  |  (SSH brute-force)  |  |               |                                                |
|  |  +---------------------+  |               |                                                |
|  +-------------|-------------+               |                                                |
|                |                             | executes scripts                               |
|                | reads CLAUDE.md             |                                                |
|                | writes .jsonl files         |                                                |
|                |                             |                                                |
|  +-------------v-----------------------------v-----------------------------------------+      |
|  |   ~/.claude/                                                                        |      |
|  |                                                                                     |      |
|  |   scripts/            credentials/          projects/-root/        logs/             |      |
|  |   - memory.sh         - supabase.env        - *.jsonl (sessions)  - sync.log        |      |
|  |   - sync-sessions.sh                        - MEMORY.md           - summary.log     |      |
|  |   - daily-summary.sh                                              - watchdog.log    |      |
|  |   - security-sync.sh                                              - security.log    |      |
|  |   - server-health.sh                                                                |      |
|  |   - watchdog.sh                                                                     |      |
|  |   - system-overview.sh                                                              |      |
|  |   - memory-load.sh                                                                  |      |
|  +-------|---------|----------------------------------------------------------------+  |      |
|          |         |                                                                   |      |
|          |         | curl REST API calls (localhost)                                   |      |
|          |         |                                                                   |      |
|  +-------v---------v-----------------------------------------------------------------+  |      |
|  |  Self-Hosted Supabase (Docker Compose)                                             |  |      |
|  |                                                                                    |  |      |
|  |  PostgreSQL                                                                        |  |      |
|  |  +------------------+  +------------------+  +-------------------+  +-------------+|  |      |
|  |  | cc_sessions      |  | cc_memory        |  | cc_security_bans  |  | cc_server   ||  |      |
|  |  | - id (UUID)      |  | - type           |  | - ip              |  |   _health   ||  |      |
|  |  | - content        |  | - topic          |  | - jail            |  | - cpu_%     ||  |      |
|  |  | - summary        |  | - content        |  | - country         |  | - ram       ||  |      |
|  |  | - detail_summary |  | - tags[]         |  | - country_code    |  | - services  ||  |      |
|  |  | - tags[]         |  | - project        |  +-------------------+  | - claude    ||  |      |
|  |  | - project        |  +------------------+                         |   _status   ||  |      |
|  |  | - session_date   |                        +-------------------+  | - docker    ||  |      |
|  |  +------------------+  +------------------+  | cc_security_stats |  +-------------+|  |      |
|  |                        | cc_projects      |  | - total_banned    |                 |  |      |
|  |  +------------------+  | - name (PK)      |  | - total_failed    |                 |  |      |
|  |  | cc_user_profile  |  | - tech_stack[]   |  | - total_logins    |                 |  |      |
|  |  | - category       |  | - status         |  +-------------------+                 |  |      |
|  |  | - key            |  +------------------+                                        |  |      |
|  |  | - value          |                                                              |  |      |
|  |  +------------------+                                                              |  |      |
|  +------------------------------------------------------------------------------------+  |      |
|                                                                                          |      |
|  +------------------------------------------------------------------------------------+  |      |
|  |  Security Dashboard (Next.js, running on :3000)                                    |  |      |
|  |                                                                                    |  |      |
|  |  +------------------------------------------+  +--------------------------------+ |  |      |
|  |  |  Next.js App                              |  |  API Routes (server-side)      | |  |      |
|  |  |                                           |  |                                | |  |      |
|  |  |  app/page.js                              |  |  /api/auth       POST (login)  | |  |      |
|  |  |  - Password login screen                  |  |  /api/auth/check GET (verify)  | |  |      |
|  |  |  - Security dashboard (bans, logins,      |  |  /api/security   GET (data)    | |  |      |
|  |  |    server health, Claude status,          |  |                                | |  |      |
|  |  |    attack charts, port overview)          |  |  Supabase via localhost         | |  |      |
|  |  +------------------------------------------+  +--------------------------------+ |  |      |
|  +------------------------------------------------------------------------------------+  |      |
+-----------------------------------------------------------------------------------------------+
```

### Data Flow Summary (One Sentence)

User messages arrive via Telegram, Claude Code processes them on the VPS, session data flows into local JSONL files, cron scripts extract/sync/summarize that data into Supabase (running on the same VPS), and the dashboard (proxied by Caddy on a subdomain) reads Supabase via localhost to display security and health metrics.

### Zero API Keys for Core Functionality

This system requires **ZERO API keys** for core functionality. Session summaries are generated via `claude -p --model haiku`, which uses the Claude Code CLI subscription — no Anthropic API key, no per-call billing, no credential file needed. The only external credentials required are Supabase connection details (auto-generated and self-hosted) and an optional Telegram bot token.

---

## 2. System Components

### 2.1 Claude Code CLI (Core Engine)

**What:** Anthropic's official CLI for Claude, running in a tmux session with the Telegram plugin.

**Why it exists:** Provides a stateful, always-running Claude instance that can be accessed from a phone via Telegram. The `--continue` flag resumes the last conversation, maintaining context across crashes and restarts.

**Key flags:**
- `--continue` — resume last session instead of starting fresh
- `--channels plugin:telegram@claude-plugins-official` — enable Telegram input/output

### 2.2 Memory System (memory.sh)

**What:** A bash script wrapping Supabase REST API calls that provides CRUD operations for memories, sessions, projects, and user profile data.

**Why it exists:** Claude Code has no built-in persistent memory across sessions. This script gives Claude a searchable, structured memory that survives restarts, crashes, and even server migrations.

**Key operations:**
- `load` — fetches recent memories, sessions, projects, and user profile at session start
- `search` / `deep-search` / `full-search` — three tiers of increasing search depth
- `add-memory` / `add-project` / `add-profile` — structured data entry
- `save-session` — manual session save (now largely replaced by automatic sync)

**Why 3-tier search:** Searching full session logs is slow and expensive. Quick summaries (tier 1) are loaded by default; detail summaries (tier 2) are searched on demand; full content (tier 3) is a last resort. This keeps the SessionStart hook fast while still making everything findable.

### 2.3 Session Sync (sync-sessions.sh)

**What:** Reads Claude Code's native `.jsonl` session files, extracts human-readable content (user + assistant messages only), and upserts into Supabase.

**Why it exists:** Claude Code stores sessions as JSONL files with a lot of internal metadata (tool calls, system prompts, binary data). This script extracts only the meaningful conversation text, making it searchable and summarizable.

**Key design choices:**
- Truncates individual messages to 500 characters (prevents bloat from large code dumps)
- Filters out `<system-reminder>` blocks (no sensitive context leaks)
- Default mode syncs only the most recently modified file (fast); `--all` syncs everything (initial setup)

### 2.4 Summary Generator (daily-summary.sh)

**What:** Finds sessions with content but no summary, checks that they have been inactive for 2+ hours, and uses `claude -p --model haiku` (Claude Code CLI subscription, no API key needed) to generate structured JSON summaries.

**Why it exists:** Raw session content is too long to load at session start. AI-generated summaries create a searchable index of all past work with key decisions, problems, and outcomes preserved.

**Key design choices:**
- Uses `claude -p --model haiku` via CLI subscription (fast, no per-call cost, sufficient quality for summaries)
- 2-hour inactivity threshold prevents summarizing sessions that are still in progress
- Content truncated to 80k chars (40k head + 40k tail) to fit Haiku's context window
- Generates both `summary` (2-3 sentences) and `detail_summary` (10-15 lines) for the two search tiers
- Regex fallback for JSON parsing (handles cases where Haiku wraps JSON in markdown)

### 2.5 Watchdog (watchdog.sh)

**What:** Checks every 5 minutes if Claude Code is running inside the tmux session. If not, restarts it.

**Why it exists:** Claude Code can crash, timeout, or exit after long idle periods. The watchdog ensures it is always available for Telegram messages.

**Process detection logic:**
1. Check if tmux session "claude" exists; if not, create it
2. Get the pane PID from tmux
3. Check direct children for a "claude" process
4. If not found, check grandchildren (shell -> claude)
5. If still not found, send the start command to the tmux pane

### 2.6 Security Sync (security-sync.sh)

**What:** Collects fail2ban bans (with GeoIP lookup), login history (via `last`), and aggregate stats, then pushes everything to Supabase.

**Why it exists:** Feeds the security dashboard with real-time ban/login data. Also provides historical tracking of attack patterns.

**Key design choices:**
- GeoIP via free ip-api.com (45 req/min limit, sufficient for ban-rate)
- Login history uses delete-all-then-reinsert strategy (simpler than upsert with timestamp keys)
- Includes tmux sessions in login data (labeled as "tmux (Claude Code)" for dashboard visibility)

### 2.7 Server Health (server-health.sh)

**What:** Collects comprehensive server metrics (CPU, RAM, disk, load, Docker containers, service statuses, open ports, attack data, Claude Code status) and pushes to Supabase as a single row.

**Why it exists:** Powers the server health section of the dashboard. Also calls `system-overview.sh` to capture the full system inventory.

**Metrics collected:**
- Hardware: CPU%, RAM, disk, load average
- Network: active connections, open ports with process names
- Services: Caddy, fail2ban, docker, ssh, Supabase reachability
- Claude: process running, Telegram plugin active, tmux session, last activity, total sessions
- Security: top attackers (from fail2ban log), failed logins per day (last 7 days)
- Cronjob health: last log entry from each cron script

### 2.8 System Overview (system-overview.sh)

**What:** Inventories all skills, credentials, scripts, cronjobs, logs, projects, and git repos, then stores the result as a JSON blob in `cc_server_health.system_overview`.

**Why it exists:** Gives the dashboard a complete picture of the Claude Code installation without needing SSH access.

### 2.9 Security Dashboard (Next.js on VPS)

**What:** A password-protected web dashboard displaying security events, server health, Claude Code status, and attack analytics. Runs as a Node.js process on the VPS, served via Caddy on `dashboard.domain.com`.

**Why it exists:** Provides a visual overview of the entire system without needing SSH access. Accessible from a phone browser.

**Architecture:**
- `app/page.js` — single-page React app with login screen and dashboard
- `app/api/auth/route.js` — password login, sets httpOnly cookie (7-day expiry)
- `app/api/auth/check/route.js` — session validation endpoint
- `app/api/security/route.js` — fetches all data from Supabase via localhost, returns aggregated JSON

### 2.10 Caddy (Reverse Proxy + Auto TLS)

**What:** Caddy serves as the reverse proxy for all web-facing services, automatically provisioning and renewing TLS certificates via Let's Encrypt.

**Why it exists:** With the domain and wildcard (`*.domain.com`) pointed at the VPS, Caddy routes subdomains to the correct internal services and handles HTTPS without manual certificate management.

**Routing:**
- `dashboard.domain.com` → Next.js dashboard (`:3000`)
- Additional subdomains can be added for future services

---

## 3. Data Flow

### 3.1 Message Flow (Telegram to Response)

```
User (Telegram)
    |
    | Bot API
    v
Claude Code (tmux)
    |
    | Processes message, writes to .jsonl
    v
~/.claude/projects/-root/<session-id>.jsonl
    |
    | (Every 30 min) sync-sessions.sh
    v
Supabase: cc_sessions.content
    |
    | (Every 2h) daily-summary.sh
    v
Supabase: cc_sessions.summary + detail_summary + tags
```

### 3.2 Memory Flow (Session Start)

```
Claude Code starts new session
    |
    | SessionStart hook triggers
    v
memory-load.sh
    |
    | Calls memory.sh load
    v
Supabase REST API (localhost)
    |
    | Returns: cc_memory (20), cc_sessions (30 summaries),
    |          cc_projects (active), cc_user_profile (all)
    v
Claude Code receives context as tool output
    |
    | Claude has full memory context
    v
Ready to respond with historical awareness
```

### 3.3 Security Data Flow

```
SSH brute-force attempt
    |
    +---> fail2ban detects -> bans IP
    |
    | (Every 10 min) security-sync.sh
    v
Supabase: cc_security_bans, cc_security_logins, cc_security_stats
    |
    | Dashboard reads via localhost
    v
Next.js API route: /api/security
    |
    | JSON response
    v
Browser (dashboard.domain.com): renders charts, tables, stats
```

### 3.4 Health Data Flow

```
VPS (system metrics)
    |
    | (Every 10 min) server-health.sh
    |   + system-overview.sh
    v
Supabase: cc_server_health (single row, id=1)
    |
    | Includes: CPU, RAM, disk, Docker, services,
    |           Claude status, ports, attackers,
    |           failed logins/day, system inventory
    v
Dashboard: displays real-time server state
```

---

## 4. Decision Log

### 4.1 Why Supabase for Memory (Not Local Files)

**Problem:** Claude Code sessions are ephemeral. Local files can be lost, are not searchable with SQL, and cannot be accessed from a dashboard.

**Alternatives considered:**
- Local JSON/SQLite files: no remote access, no dashboard integration, fragile on disk failure
- PostgreSQL directly: no REST API, need custom API server, more ops overhead
- Firebase/Firestore: vendor lock-in, no self-hosting option

**Decision:** Self-hosted Supabase provides:
- PostgreSQL with a REST API (PostgREST) out of the box
- No additional API server needed — bash scripts talk directly to REST endpoints
- Row Level Security available if needed
- Self-hosted = full data control, no vendor dependency
- Free (runs on the same VPS infrastructure)

### 4.2 Why tmux + Watchdog (Not systemd)

**Problem:** Claude Code needs to stay running 24/7, but it is an interactive CLI that expects a terminal.

**Alternatives considered:**
- systemd service: Claude Code is interactive, needs a PTY; systemd services run headless. Attaching to debug is awkward. Restart logic is less flexible.
- screen: functionally equivalent to tmux but less widely used
- Docker container: overkill for a single CLI process; complicates Telegram plugin access

**Decision:** tmux + cron watchdog because:
- tmux provides a real terminal (Claude Code needs it)
- `tmux attach` gives instant debugging access
- Watchdog via cron is simple, stateless, and self-healing
- `--continue` flag means Claude resumes its last session automatically
- No PID files, no socket files, no service manager complexity

### 4.3 Why Haiku for Summaries (Not Opus)

**Problem:** Sessions need to be summarized into searchable metadata. This runs automatically every 2 hours.

**Alternatives considered:**
- Opus/Sonnet: higher quality but 10-50x the cost; summary quality from Haiku is sufficient for search keywords and brief overviews
- Local LLM: not available on this VPS; would need GPU
- No summaries (search raw content): too slow, too much noise

**Decision:** Haiku via `claude -p --model haiku` (Claude Code CLI) because:
- Cost: included in Claude Code subscription (no per-call API charges)
- Speed: fast enough to summarize 10+ sessions in one cron run
- Quality: sufficient for generating keywords, tags, and structured summaries
- No API key needed: uses the same Claude Code CLI subscription already installed on the VPS

### 4.4 Why JSONL Sync (Not Manual Save)

**Problem:** Earlier versions required Claude to manually run `save-session` at the end of each session. This was unreliable — sessions were lost when Claude crashed, timed out, or the user simply disconnected.

**Alternatives considered:**
- Manual save-session: relies on Claude remembering to save; fails on crashes
- Hook on session end: Claude Code has no reliable "session end" hook
- Real-time streaming to Supabase: too complex, too many writes

**Decision:** Cron-based JSONL sync because:
- Claude Code already writes `.jsonl` files natively — no custom logging needed
- Syncing every 30 minutes means at most 30 minutes of data loss on crash
- The sync script is idempotent (upsert logic) — safe to re-run
- Decouples data capture from data storage (Claude does not need to know about Supabase)

### 4.5 Why Caddy (Not nginx)

**Problem:** The VPS needs a reverse proxy to route subdomains to internal services and terminate TLS.

**Alternatives considered:**
- nginx: manual certificate management (certbot cron, renewal hooks), verbose config syntax, more moving parts
- Traefik: Docker-native but complex label-based config, overkill for a handful of services
- No reverse proxy (expose services directly): no TLS, no subdomain routing

**Decision:** Caddy because:
- Automatic HTTPS — provisions and renews Let's Encrypt certificates with zero configuration
- Simple Caddyfile syntax — a few lines per service vs. nginx's verbose server blocks
- Wildcard support — with DNS already pointed, adding new subdomains is trivial
- Single binary — no dependencies, no modules to compile

### 4.6 Why Dashboard on VPS (Not Vercel or External Hosting)

**Problem:** The dashboard needs to display data from Supabase. It could be hosted externally (Vercel, Netlify) or locally on the VPS.

**Alternatives considered:**
- Vercel: adds external dependency, requires exposing Supabase to the internet, credentials in third-party env vars
- Netlify/Cloudflare Pages: same exposure issues as Vercel
- Static site + client-side Supabase SDK: exposes database endpoint and keys in the browser

**Decision:** Next.js on VPS behind Caddy because:
- Supabase never needs to be exposed to the internet — dashboard connects via localhost
- All credentials stay on the VPS — no third-party env var stores
- Caddy handles TLS automatically on `dashboard.domain.com`
- One fewer external dependency — everything runs on the same machine
- Server-side API routes aggregate Supabase queries and enforce auth before any data fetch

### 4.7 Why Password Auth on Dashboard (Not OAuth)

**Problem:** The dashboard shows sensitive server data and needs access control.

**Alternatives considered:**
- NextAuth.js + OAuth: complex setup for a single user; needs OAuth provider or database
- Supabase Auth: adds another auth layer, more moving parts
- HTTP Basic Auth: not user-friendly on mobile

**Decision:** Simple password hash + httpOnly cookie because:
- Single-user system — one password is sufficient
- Password hash stored in environment variable on VPS (never in code)
- Session token is a SHA-256 hash, stored in httpOnly + secure + sameSite=strict cookie
- 7-day expiry — practical for daily mobile use
- Zero external dependencies
- Total implementation: ~30 lines of code

### 4.8 Why Single Bootstrap Script (Not Manual Multi-Phase Setup)

**Problem:** The system has many components (Docker, Supabase, scripts, crons, Caddy, dashboard) that must be configured in the right order with correct credentials.

**Alternatives considered:**
- Manual step-by-step guide: error-prone, tedious, hard to reproduce
- Ansible/Terraform: heavy tooling for a single-server setup
- Docker-only (everything in compose): Claude Code needs an interactive terminal, doesn't fit the container model

**Decision:** Single `bootstrap.sh` script with guided prompts because:
- One command to deploy the entire system
- Interactive prompts collect required config (domain, credentials, Telegram token)
- Can also run fully automated via environment variables (no prompts)
- Generates secrets automatically (Postgres password, JWT, Supabase keys)
- Idempotent — safe to re-run (updates existing installation)
- Creates systemd service for auto-start on reboot

---

## 5. Security Architecture

### Layer 1: Brute-Force Protection (fail2ban)

```
SSH connection attempt
    |
    v
fail2ban monitors /var/log/auth.log
    |
    +-- 5 failed attempts --> BAN IP for 10 minutes
    |
    +-- Repeated bans --> Longer ban durations
```

- **Tool:** fail2ban with `sshd` jail
- **Purpose:** Prevents SSH brute-force attacks by banning IPs after repeated failures
- **Integration:** Banned IPs synced to Supabase with GeoIP data every 10 minutes

**Note:** Network-level firewall rules (port filtering, etc.) are managed by the VPS hosting provider's firewall service, not by the VPS itself.

### Layer 2: Application Security (Dashboard)

```
Browser request to dashboard.domain.com
    |
    v
Caddy (TLS termination)
    |
    v
Next.js /api/auth/check — is dashboard_session cookie valid?
    |
    +-- NO  --> Show login screen
    +-- YES --> /api/security fetches data from Supabase (localhost)
                |
                v
                JSON response to browser
```

- **Auth:** SHA-256 password hash comparison
- **Session:** httpOnly, secure, sameSite=strict cookie
- **Supabase:** only accessible via localhost — never exposed to the internet
- **API routes:** validate session cookie before every data fetch

### Layer 3: Credential Isolation

```
~/.claude/credentials/     (chmod 600, root only)
    |
    +-- supabase.env        — SUPABASE_URL, keys

Dashboard environment:
    |
    +-- SUPABASE_URL         (localhost)
    +-- SUPABASE_ANON_KEY
    +-- DASHBOARD_PASSWORD_HASH
```

- Credentials are sourced by scripts, never printed or logged
- CLAUDE.md explicitly instructs: "Never share credentials over Telegram"
- No credentials are committed to git
- Supabase is only accessible via localhost — no external exposure

---

## 6. Automation Matrix

| Schedule      | Script              | Purpose                                           | Dependencies                        | Log File                  |
|---------------|---------------------|---------------------------------------------------|-------------------------------------|---------------------------|
| `*/5 * * * *` | `watchdog.sh`       | Ensure Claude Code is running in tmux             | tmux, claude CLI                    | `~/.claude/logs/watchdog.log` |
| `*/10 * * * *`| `security-sync.sh`  | Sync fail2ban bans + login history to Supabase    | fail2ban, supabase.env, python3     | `~/.claude/logs/security.log` |
| `*/10 * * * *`| `server-health.sh`  | Collect server metrics, push to Supabase          | supabase.env, python3, docker       | (stdout only)             |
| `*/30 * * * *`| `sync-sessions.sh`  | Sync active JSONL session content to Supabase     | supabase.env, python3, .jsonl files | `~/.claude/logs/sync.log` |
| `0 */2 * * *` | `daily-summary.sh`  | Generate Haiku summaries for inactive sessions    | claude CLI, supabase.env, python3   | `~/.claude/logs/summary-YYYY-MM-DD.log` |

**Implicit automation:**
- `system-overview.sh` is called by `server-health.sh` (not scheduled separately)
- `memory-load.sh` is triggered by Claude Code's SessionStart hook (not a cronjob)

---

## 7. Folder Structure

```
/opt/agentos/                          — Installation root
├── bootstrap.sh                       — Installer / updater script
├── docker-compose.yml                 — Supabase + dashboard services
├── Caddyfile                          — Reverse proxy configuration
├── .env                               — Generated secrets + user config
│
├── dashboard/                         — Security dashboard (Next.js)
│   ├── app/
│   │   ├── page.js                    — Dashboard UI
│   │   ├── layout.js                  — Root layout
│   │   ├── globals.css                — Styles
│   │   └── api/
│   │       ├── auth/
│   │       │   ├── route.js           — Password login
│   │       │   └── check/
│   │       │       └── route.js       — Session validation
│   │       └── security/
│   │           └── route.js           — Data fetch (via localhost Supabase)
│   └── package.json
│
├── scripts/                           — All automation scripts
│   ├── memory.sh                      — Memory CRUD operations (main interface)
│   ├── memory-load.sh                 — SessionStart hook wrapper
│   ├── sync-sessions.sh              — JSONL -> Supabase sync
│   ├── daily-summary.sh              — Haiku summary generator
│   ├── watchdog.sh                    — Claude Code auto-restart
│   ├── security-sync.sh              — fail2ban + logins -> Supabase
│   ├── server-health.sh              — Server metrics -> Supabase
│   └── system-overview.sh            — System inventory -> Supabase
│
├── supabase/                          — Supabase configuration
│   └── migrations/                    — SQL migrations (table creation)
│
└── logs/                              — Cronjob output logs
    ├── watchdog.log
    ├── sync.log
    ├── summary-YYYY-MM-DD.log
    └── security.log

/root/
├── CLAUDE.md                          — System instructions for Claude Code
├── .claude/
│   ├── settings.json                  — Claude Code config (hooks, permissions)
│   ├── credentials/                   — All secrets (chmod 600)
│   │   └── supabase.env               — SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
│   │
│   ├── skills/                        — Custom slash commands (*.md files)
│   ├── plugins/                       — Installed plugins (Telegram, etc.)
│   │
│   ├── projects/
│   │   └── -root/                     — Session storage for /root working dir
│   │       ├── <uuid>.jsonl           — Individual session files (Claude native)
│   │       └── MEMORY.md              — Auto-memory index (Claude-managed)
│   │
│   └── projects-config/               — Project-specific configs
```

---

## 8. Credential Management

### Where Secrets Live

| Secret                        | Location                                    | Used By                          |
|-------------------------------|---------------------------------------------|----------------------------------|
| `SUPABASE_URL`                | `~/.claude/credentials/supabase.env`        | All sync scripts, memory.sh      |
| `SUPABASE_SERVICE_ROLE_KEY`   | `~/.claude/credentials/supabase.env`        | All sync scripts (full DB access)|
| `SUPABASE_ANON_KEY`           | `~/.claude/credentials/supabase.env`        | Dashboard API route (read-only)  |
| `JWT_SECRET`                  | `/opt/agentos/.env` (auto-generated)        | Supabase internal auth           |
| `POSTGRES_PASSWORD`           | `/opt/agentos/.env` (auto-generated)        | Supabase internal                |
| `DASHBOARD_PASSWORD_HASH`     | `/opt/agentos/.env`                         | Dashboard auth                   |

### Access Patterns

- **VPS scripts** use `source ~/.claude/credentials/supabase.env`. This loads `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` as shell variables.
- **Dashboard** uses `process.env.*` in Next.js API routes. Supabase keys are loaded from `/opt/agentos/.env` and are never bundled into client-side JavaScript.
- **Summaries** are generated via `claude -p --model haiku` using the Claude Code CLI subscription — no API key file needed.
- **Auto-generated secrets** (Postgres password, JWT secret, Supabase keys) are created by the bootstrap script and stored in `/opt/agentos/.env`.

### Security Rules

1. All credential files are `chmod 600` (root read/write only)
2. CLAUDE.md explicitly forbids sharing credentials over Telegram
3. The dashboard uses `SUPABASE_ANON_KEY` (not service role key) — limited to read access via RLS
4. No credentials are committed to git
5. Supabase is only accessible via localhost — never exposed externally

---

## 9. Failure Modes & Recovery

### 9.1 Claude Code Crashes / Exits

| What happens | Detection | Recovery |
|---|---|---|
| Claude CLI process dies | watchdog.sh (cron, every 5 min) | Sends `claude --continue` to tmux pane |
| tmux session dies entirely | watchdog.sh detects missing session | Creates new tmux session with Claude command |
| Claude enters error loop | Manual observation via `tmux attach` | Kill process, watchdog restarts in 5 min |

**Data loss:** None. JSONL files are written by Claude Code in real-time. Last sync to Supabase is at most 30 minutes old.

### 9.2 Supabase Unreachable

| What happens | Detection | Recovery |
|---|---|---|
| Supabase container goes down | server-health.sh marks "unreachable" | Docker auto-restarts container; sync scripts retry on next cycle |
| Database full | API returns 500 errors | Manual cleanup of old sessions |

**Data loss:** JSONL files remain on local disk. Once Supabase recovers, run `sync-sessions.sh --all` to backfill. Summaries will be generated on next `daily-summary.sh` run.

**Impact on Claude:** Claude Code continues working normally. SessionStart hook will fail to load memories (Claude starts without context). Memory search commands will return errors.

### 9.3 VPS Reboots

| Component | Auto-recovery |
|---|---|
| tmux + Claude Code | watchdog.sh cron (within 5 min of cron starting) |
| Cronjobs | crontab survives reboot |
| fail2ban | systemd auto-start |
| Docker (Supabase + Dashboard) | systemd auto-start (restart: always) |
| Caddy | systemd auto-start |

### 9.4 Summary Generation Fails (claude -p)

| What happens | Detection | Recovery |
|---|---|---|
| Claude CLI not authenticated | daily-summary.sh logs error | Re-authenticate Claude Code CLI on the VPS |
| Rate limit / subscription issue | daily-summary.sh logs error | Check Claude Code subscription status; automatic retry on next 2h cycle |

**Impact:** Summaries stop being generated. Session content is still synced. Search tier 1 (summaries) returns nothing new; tiers 2-3 still work on existing data.

### 9.5 Dashboard Auth Compromised

| What happens | Detection | Recovery |
|---|---|---|
| Password leaked | Unauthorized access observed | Update `DASHBOARD_PASSWORD_HASH` in `/opt/agentos/.env`; restart dashboard |

**Impact limited to:** Read-only view of security data. Dashboard has no write access to Supabase (uses anon key). No server control possible through the dashboard.

### 9.6 Disk Full on VPS

| What happens | Detection | Recovery |
|---|---|---|
| JSONL files fill disk | server-health.sh reports disk_used approaching disk_total | Delete old .jsonl files (already synced to Supabase) |
| Logs fill disk | Checking log file sizes | Rotate logs; summary logs already date-stamped |
| Docker volumes fill disk | `docker system df` | Prune unused images/volumes |

**Prevention:** Monitor disk via dashboard. JSONL files can safely be deleted after sync + summarization.

---

## 10. Setup Order (Fresh Install)

The entire system is deployable in a single session via a bootstrap script with guided prompts. The user needs only a VPS with SSH access and a domain pointed at it.

### Prerequisites

Before running the installer:

| Requirement | Details |
|---|---|
| VPS | Any Linux VPS with root access (Ubuntu 22.04+ recommended) |
| Domain DNS | `domain.com` A record → VPS IP |
| Wildcard DNS | `*.domain.com` A record → VPS IP |
| Claude Code CLI | Authenticated Claude Code subscription (provides `claude -p` for summaries) |

### Bootstrap Installation

**Interactive install (guided prompts):**

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/<repo>/main/bootstrap.sh)"
```

**Fully automated (no prompts):**

```bash
AGENTOS_DOMAIN=example.com \
AGENTOS_DASHBOARD_PASSWORD=supersecretpassword \
TELEGRAM_BOT_TOKEN=123456:ABC-DEF... \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/<repo>/main/bootstrap.sh)"
```

### What the Bootstrap Script Does

```
Phase 1: System Dependencies
  1. Install Docker + Docker Compose (if missing)
  2. Install tmux, fail2ban, python3, curl, jq
  3. Clone/update the repo to /opt/agentos

Phase 2: Configuration
  4. Prompt for domain (or read AGENTOS_DOMAIN env var)
  5. Prompt for dashboard password (or read env var)
  6. Prompt for Telegram bot token (optional, or read env var)
  7. Auto-generate secrets: Postgres password, JWT secret, Supabase anon/service keys

Phase 3: Supabase + Database
  9. Write /opt/agentos/.env with all config
  10. Start Supabase via Docker Compose
  11. Run SQL migrations to create all tables:
      cc_sessions, cc_memory, cc_projects, cc_user_profile,
      cc_security_bans, cc_security_logins, cc_security_stats, cc_server_health

Phase 4: Dashboard + Caddy
  12. Build/start the Next.js dashboard container
  13. Write Caddyfile with subdomain routing
  14. Start/reload Caddy (auto-provisions TLS certificates)

Phase 5: Claude Code + Scripts
  15. Deploy scripts to /opt/agentos/scripts/
  16. Create ~/.claude/credentials/ with supabase.env
  17. Configure Claude Code SessionStart hook in ~/.claude/settings.json
  18. Install cronjobs (watchdog, security-sync, health, session-sync, summary)
  19. Install Claude Code CLI (if missing)

Phase 6: Telegram + Launch
  20. Start tmux session with Claude Code + Telegram plugin
  21. Run initial data sync (security, health, sessions)

Phase 7: Verification
  22. Verify Supabase is reachable
  23. Verify dashboard loads at https://dashboard.domain.com
  24. Verify Claude Code is running in tmux
  25. Print summary with access details
```

### Environment Variables (Bootstrap)

| Variable | Required | Description |
|----------|----------|-------------|
| `AGENTOS_DOMAIN` | Yes* | Root domain pointed at the VPS |
| `AGENTOS_DASHBOARD_PASSWORD` | Yes* | Dashboard login password |
| `TELEGRAM_BOT_TOKEN` | No* | Telegram bot token (from @BotFather) |
| `AGENTOS_DIR` | No | Install directory (default: `/opt/agentos`) |

\* Prompted interactively if not set as environment variable.

### Auto-Generated Secrets

On first run, the bootstrap script generates and stores in `/opt/agentos/.env`:

- `POSTGRES_PASSWORD`
- `JWT_SECRET`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `DASHBOARD_PASSWORD_HASH` (SHA-256 of the provided password)

These are never manually managed. Re-running the bootstrap preserves existing secrets.

### Post-Install Operations

```bash
cd /opt/agentos

# Check system status
bash scripts/status.sh

# View logs
tail -f logs/watchdog.log
tail -f logs/security.log

# Attach to Claude Code session
tmux attach -t claude

# Restart services
docker compose restart

# Update installation
git pull && bash bootstrap.sh
```

### Dependency Graph

```
Prerequisites (VPS + DNS + Claude Code CLI subscription)
  |
  +-- Phase 1 (System deps: Docker, tmux, fail2ban)
        |
        +-- Phase 2 (Collect config / read env vars)
              |
              +-- Phase 3 (Supabase + DB tables)
              |     |
              |     +-- Phase 4 (Dashboard + Caddy)
              |     |
              |     +-- Phase 5 (Claude Code + scripts + crons)
              |           |
              |           +-- Phase 6 (Telegram + launch)
              |                 |
              |                 +-- Phase 7 (Verification)
```

---

## Appendix: Database Schema (Complete SQL)

```sql
-- Core memory tables
CREATE TABLE cc_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_date TIMESTAMPTZ DEFAULT now(),
  project TEXT,
  summary TEXT,
  detail_summary TEXT,
  content TEXT DEFAULT '',
  tags TEXT[] DEFAULT ARRAY[]::TEXT[],
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE cc_memory (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  type TEXT NOT NULL,
  topic TEXT NOT NULL,
  content TEXT NOT NULL,
  tags TEXT[] DEFAULT ARRAY[]::TEXT[],
  project TEXT,
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE cc_projects (
  name TEXT PRIMARY KEY,
  description TEXT,
  tech_stack TEXT[] DEFAULT ARRAY[]::TEXT[],
  status TEXT DEFAULT 'active'
);

CREATE TABLE cc_user_profile (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  category TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  UNIQUE(category, key)
);

-- Security tables
CREATE TABLE cc_security_bans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ip TEXT NOT NULL UNIQUE,
  jail TEXT DEFAULT 'sshd',
  country TEXT,
  country_code TEXT,
  banned_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE cc_security_logins (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_name TEXT,
  ip TEXT,
  login_at TEXT,
  session_type TEXT,
  duration TEXT
);

CREATE TABLE cc_security_stats (
  id INTEGER PRIMARY KEY,
  total_banned INTEGER DEFAULT 0,
  total_failed INTEGER DEFAULT 0,
  total_logins INTEGER DEFAULT 0,
  last_updated TIMESTAMPTZ DEFAULT now()
);

-- Server health (single row, upserted)
CREATE TABLE cc_server_health (
  id INTEGER PRIMARY KEY,
  uptime TEXT,
  cpu_percent FLOAT,
  ram_used_mb INTEGER,
  ram_total_mb INTEGER,
  disk_used_gb FLOAT,
  disk_total_gb FLOAT,
  load_avg TEXT,
  active_connections INTEGER,
  docker_containers JSONB,
  services JSONB,
  claude_status JSONB,
  open_ports JSONB,
  top_attackers JSONB,
  failed_per_day JSONB,
  system_overview JSONB,
  last_updated TIMESTAMPTZ DEFAULT now()
);
```

---
