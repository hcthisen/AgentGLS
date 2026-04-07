#!/bin/bash
# sync-sessions.sh - Sync Claude and Codex JSONL session files to Supabase.
# Usage: sync-sessions.sh [--all]

set -euo pipefail

CRED_FILE="$HOME/.claude/credentials/supabase.env"
SYNC_ALL="${1:-}"

if [[ -f "$CRED_FILE" ]]; then
  source "$CRED_FILE"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Credentials not found at $CRED_FILE" >&2
  exit 1
fi

SUPABASE_URL="${SUPABASE_URL:-http://localhost:3001}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY}"

SYNC_MODE="latest"
if [[ "$SYNC_ALL" == "--all" ]]; then
  SYNC_MODE="all"
fi

export SUPABASE_URL SUPABASE_KEY SYNC_MODE

python3 <<'PYEOF'
import json
import os
import re
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_KEY = os.environ["SUPABASE_KEY"]
SYNC_MODE = os.environ.get("SYNC_MODE", "latest")

SOURCES = [
    ("claude", Path.home() / ".claude" / "projects" / "-root", "*.jsonl"),
    ("codex", Path.home() / ".codex" / "sessions", "**/*.jsonl"),
]


def log(message: str) -> None:
    print(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} {message}")


def discover_files():
    discovered = []
    for provider, root, pattern in SOURCES:
        if not root.exists():
            continue
        for path in root.glob(pattern):
            if path.is_file():
                discovered.append((provider, path))
    return discovered


def truncate_message(text: str) -> str:
    cleaned = re.sub(r"<system-reminder>.*?</system-reminder>", "", text, flags=re.DOTALL).strip()
    if len(cleaned) > 500:
        return cleaned[:500] + "..."
    return cleaned


def extract_claude_message(entry: dict) -> tuple[str, str] | None:
    role = entry.get("role", "")
    if role not in {"human", "assistant"}:
        return None

    content_field = entry.get("content", "")
    if isinstance(content_field, str):
        text = content_field
    else:
        parts = []
        for block in content_field or []:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text":
                parts.append(str(block.get("text", "")))
        text = " ".join(parts)

    text = truncate_message(text)
    if not text:
        return None
    return role, text


def extract_codex_message(entry: dict) -> tuple[str, str] | None:
    if entry.get("type") != "response_item":
        return None

    payload = entry.get("payload")
    if not isinstance(payload, dict) or payload.get("type") != "message":
        return None

    role = payload.get("role", "")
    if role not in {"user", "assistant"}:
        return None

    text_parts = []
    for block in payload.get("content") or []:
        if not isinstance(block, dict):
            continue
        block_type = block.get("type")
        if block_type in {"input_text", "output_text", "text"}:
            text_parts.append(str(block.get("text", "")))

    text = truncate_message(" ".join(text_parts))
    if not text:
        return None

    return ("human" if role == "user" else "assistant"), text


def extract_content(provider: str, path: Path) -> str:
    messages = []
    with path.open("r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            if provider == "claude":
                parsed = extract_claude_message(entry)
            else:
                parsed = extract_codex_message(entry)

            if parsed is None:
                continue

            role, text = parsed
            messages.append(f"[{role}] {text}")

    return "\n".join(messages)


def stable_session_id(provider: str, path: Path) -> str:
    stem = path.stem
    try:
        return str(uuid.UUID(stem))
    except ValueError:
        return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{provider}:{path.as_posix()}"))


def session_timestamp(path: Path) -> str:
    return datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def sync_file(provider: str, path: Path) -> bool:
    content = extract_content(provider, path)
    if not content:
        return False

    payload = {
        "id": stable_session_id(provider, path),
        "project": "root",
        "content": content,
        "session_date": session_timestamp(path),
    }

    result = subprocess.run(
        [
            "curl",
            "-sf",
            "-X",
            "POST",
            f"{SUPABASE_URL}/cc_sessions",
            "-H",
            f"apikey: {SUPABASE_KEY}",
            "-H",
            f"Authorization: Bearer {SUPABASE_KEY}",
            "-H",
            "Content-Type: application/json",
            "-H",
            "Prefer: resolution=merge-duplicates,return=minimal",
            "-d",
            json.dumps(payload),
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"Failed to sync {path}")

    log(f"Synced {provider}: {path.name} ({len(content)} bytes)")
    return True


all_files = discover_files()
if not all_files:
    log("No Claude or Codex session directories found")
    raise SystemExit(0)

if SYNC_MODE == "all":
    selected = sorted(all_files, key=lambda item: item[1].stat().st_mtime, reverse=True)
else:
    selected = [max(all_files, key=lambda item: item[1].stat().st_mtime)]

log("Starting session sync...")
count = 0
for provider, path in selected:
    try:
        if sync_file(provider, path):
            count += 1
    except Exception as exc:
        log(f"Failed to sync {provider} session {path}: {exc}")

log(f"Sync complete: {count} file(s) processed")
PYEOF
