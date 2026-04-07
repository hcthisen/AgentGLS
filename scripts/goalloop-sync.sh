#!/bin/bash
# goalloop-sync.sh - Project GoalLoop files into cc_goals via PostgREST.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/provider-lib.sh"

load_agentgls_env

INSTALL_DIR="$(provider_install_dir)"
GOALS_DIR="$INSTALL_DIR/goals"
GOALMETA_SCRIPT="$SCRIPT_DIR/goalmeta.py"
SUPABASE_URL="${SUPABASE_URL:-http://localhost:3001}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"

if [[ -z "$SUPABASE_KEY" ]]; then
  echo "SUPABASE_SERVICE_ROLE_KEY is required for goal sync" >&2
  exit 1
fi

python3 - "$GOALS_DIR" "$GOALMETA_SCRIPT" "$SUPABASE_URL" "$SUPABASE_KEY" <<'PY'
import json
import re
import subprocess
import sys
import urllib.parse
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

GOALS_DIR = Path(sys.argv[1])
GOALMETA = sys.argv[2]
SUPABASE_URL = sys.argv[3].rstrip("/")
SUPABASE_KEY = sys.argv[4]
STATUS_DIRS = {"active": "active", "paused": "paused", "completed": "completed"}
OBJECTIVE_RE = re.compile(r"(?ms)^##\s+Objective\s*\n+(.*?)(?=^\s*##\s+|\Z)")


def goal_files(directory: Path) -> list[Path]:
    if not directory.exists():
        return []
    return sorted(
        path
        for path in directory.glob("*.md")
        if path.is_file() and not path.name.startswith("_")
    )


def gm(*args: str) -> str:
    result = subprocess.run(
        [sys.executable, GOALMETA, *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"goalmeta {' '.join(args)} failed")
    return result.stdout.strip()


def gm_value(path: Path, field: str):
    raw = gm("get", str(path), field)
    if raw == "null" or raw == "":
        return None
    if raw in {"true", "false"}:
        return raw == "true"
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return raw


def extract_objective(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    match = OBJECTIVE_RE.search(text)
    return match.group(1).strip() if match else ""


def iso_mtime(path: Path) -> str:
    return datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def postgrest_upsert(payload: dict) -> None:
    request = urllib.request.Request(
        f"{SUPABASE_URL}/cc_goals",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "apikey": SUPABASE_KEY,
            "Authorization": f"Bearer {SUPABASE_KEY}",
            "Content-Type": "application/json",
            "Prefer": "resolution=merge-duplicates,return=minimal",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"PostgREST upsert failed ({exc.code}): {detail}") from exc


def postgrest_get(endpoint: str) -> list[dict]:
    request = urllib.request.Request(
        f"{SUPABASE_URL}/{endpoint}",
        headers={
            "apikey": SUPABASE_KEY,
            "Authorization": f"Bearer {SUPABASE_KEY}",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"PostgREST fetch failed ({exc.code}): {detail}") from exc


def postgrest_delete_slug(slug: str) -> None:
    encoded_slug = urllib.parse.quote(slug, safe="")
    request = urllib.request.Request(
        f"{SUPABASE_URL}/cc_goals?slug=eq.{encoded_slug}",
        headers={
            "apikey": SUPABASE_KEY,
            "Authorization": f"Bearer {SUPABASE_KEY}",
        },
        method="DELETE",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"PostgREST delete failed ({exc.code}): {detail}") from exc


def build_payload(path: Path, status: str) -> dict:
    payload = {
        "slug": path.stem,
        "title": gm_value(path, "title") or path.stem,
        "status": status,
        "priority": gm_value(path, "priority") or "medium",
        "brief_status": gm_value(path, "brief_status") or "draft",
        "run_state": gm_value(path, "run_state") or "idle",
        "objective": extract_objective(path),
        "finish_criteria": json.loads(gm("criteria", str(path)) or "[]"),
        "scoreboard": json.loads(gm("scoreboard", str(path)) or "{}"),
        "heartbeat_minutes": int(gm_value(path, "heartbeat_minutes") or 60),
        "approval_policy": gm_value(path, "approval_policy") or "auto",
        "updated_at": iso_mtime(path),
    }

    for field in ("last_run", "next_eligible_at", "measurement_due_at", "deadline_at", "parent", "notify_chat_id"):
        value = gm_value(path, field)
        if value not in (None, ""):
            payload[field] = value

    return payload


def find_goal_path(slug: str) -> Path | None:
    for directory in STATUS_DIRS:
        candidate = GOALS_DIR / directory / f"{slug}.md"
        if candidate.exists():
            return candidate
    return None


def sync_once() -> set[str]:
    seen_parents: set[str] = set()
    seen_slugs: set[str] = set()

    for directory_name, status in STATUS_DIRS.items():
        for goal_file in goal_files(GOALS_DIR / directory_name):
            payload = build_payload(goal_file, status)
            postgrest_upsert(payload)
            seen_slugs.add(payload["slug"])
            parent = payload.get("parent")
            if isinstance(parent, str) and parent.strip():
                seen_parents.add(parent.strip())

    existing_rows = postgrest_get("cc_goals?select=slug")
    for row in existing_rows:
        slug = row.get("slug")
        if isinstance(slug, str) and slug and slug not in seen_slugs:
            postgrest_delete_slug(slug)

    return seen_parents


parents = sync_once()

for parent_slug in sorted(parents):
    parent_path = find_goal_path(parent_slug)
    if parent_path is None:
        continue
    subprocess.run(
        [sys.executable, GOALMETA, "reconcile-parent", str(parent_path), str(GOALS_DIR / "active")],
        capture_output=True,
        text=True,
        check=False,
    )
    parent_status = parent_path.parent.name
    if parent_status in STATUS_DIRS:
        postgrest_upsert(build_payload(parent_path, STATUS_DIRS[parent_status]))
PY
