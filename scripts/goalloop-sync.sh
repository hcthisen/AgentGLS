#!/bin/bash
# goalloop-sync.sh - Project GoalLoop files into cc_goals via direct database upserts.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/provider-lib.sh"

load_agentgls_env

INSTALL_DIR="$(provider_install_dir)"
GOALS_DIR="$INSTALL_DIR/goals"
GOALMETA_SCRIPT="$SCRIPT_DIR/goalmeta.py"
DB_CONTAINER="${AGENTGLS_DB_CONTAINER:-agentgls-db}"

python3 - "$GOALS_DIR" "$GOALMETA_SCRIPT" "$DB_CONTAINER" <<'PY'
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

GOALS_DIR = Path(sys.argv[1])
GOALMETA = sys.argv[2]
DB_CONTAINER = sys.argv[3]
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


def run_psql(sql: str) -> str:
    result = subprocess.run(
        [
            "docker",
            "exec",
            "-i",
            DB_CONTAINER,
            "psql",
            "-U",
            "postgres",
            "-d",
            "postgres",
            "-v",
            "ON_ERROR_STOP=1",
            "-t",
            "-A",
            "-f",
            "-",
        ],
        input=sql,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "psql command failed")
    return result.stdout


def sql_text(value) -> str:
    if value in (None, ""):
        return "NULL"
    return "'" + str(value).replace("'", "''") + "'"


def sql_json(value) -> str:
    return sql_text(json.dumps(value, ensure_ascii=False)) + "::jsonb"


def sql_int(value) -> str:
    return str(int(value))


def sql_timestamptz(value) -> str:
    if value in (None, ""):
        return "NULL"
    return sql_text(value) + "::timestamptz"


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


UPSERT_COLUMNS = [
    "slug",
    "title",
    "status",
    "priority",
    "brief_status",
    "run_state",
    "objective",
    "finish_criteria",
    "scoreboard",
    "heartbeat_minutes",
    "last_run",
    "next_eligible_at",
    "measurement_due_at",
    "deadline_at",
    "approval_policy",
    "parent",
    "notify_chat_id",
    "updated_at",
]


def build_upsert_sql(payload: dict) -> str:
    assignments = {
        "slug": sql_text(payload["slug"]),
        "title": sql_text(payload["title"]),
        "status": sql_text(payload["status"]),
        "priority": sql_text(payload["priority"]),
        "brief_status": sql_text(payload["brief_status"]),
        "run_state": sql_text(payload["run_state"]),
        "objective": sql_text(payload["objective"]),
        "finish_criteria": sql_json(payload["finish_criteria"]),
        "scoreboard": sql_json(payload["scoreboard"]),
        "heartbeat_minutes": sql_int(payload["heartbeat_minutes"]),
        "last_run": sql_timestamptz(payload.get("last_run")),
        "next_eligible_at": sql_timestamptz(payload.get("next_eligible_at")),
        "measurement_due_at": sql_timestamptz(payload.get("measurement_due_at")),
        "deadline_at": sql_timestamptz(payload.get("deadline_at")),
        "approval_policy": sql_text(payload["approval_policy"]),
        "parent": sql_text(payload.get("parent")),
        "notify_chat_id": sql_text(payload.get("notify_chat_id")),
        "updated_at": sql_timestamptz(payload["updated_at"]),
    }
    values_sql = ", ".join(assignments[column] for column in UPSERT_COLUMNS)
    updates_sql = ", ".join(
        f"{column} = EXCLUDED.{column}" for column in UPSERT_COLUMNS if column != "slug"
    )
    return (
        "INSERT INTO public.cc_goals ("
        + ", ".join(UPSERT_COLUMNS)
        + ") VALUES ("
        + values_sql
        + ") ON CONFLICT (slug) DO UPDATE SET "
        + updates_sql
        + ";"
    )


def sync_once() -> set[str]:
    seen_parents: set[str] = set()
    seen_slugs: set[str] = set()
    upserts: list[str] = []

    for directory_name, status in STATUS_DIRS.items():
        for goal_file in goal_files(GOALS_DIR / directory_name):
            payload = build_payload(goal_file, status)
            upserts.append(build_upsert_sql(payload))
            seen_slugs.add(payload["slug"])
            parent = payload.get("parent")
            if isinstance(parent, str) and parent.strip():
                seen_parents.add(parent.strip())

    statements = ["BEGIN;"]
    statements.extend(upserts)
    if seen_slugs:
        keep = ", ".join(sql_text(slug) for slug in sorted(seen_slugs))
        statements.append(f"DELETE FROM public.cc_goals WHERE slug NOT IN ({keep});")
    else:
        statements.append("DELETE FROM public.cc_goals;")
    statements.append("COMMIT;")
    run_psql("\n".join(statements) + "\n")

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
        run_psql(build_upsert_sql(build_payload(parent_path, STATUS_DIRS[parent_status])) + "\n")
PY
