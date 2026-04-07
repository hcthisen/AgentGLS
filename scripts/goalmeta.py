#!/usr/bin/env python3
"""goalmeta.py - GoalLoop goal metadata parser and mutator for AgentGLS."""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
import uuid
from collections import OrderedDict
from contextlib import contextmanager
from datetime import date, datetime, time, timezone
from pathlib import Path

import yaml

try:
    import fcntl  # type: ignore[attr-defined]
except ImportError:  # pragma: no cover - used only for local Windows verification
    fcntl = None
    import msvcrt


PRIORITY_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3}
GOAL_STATUS_DIRS = {"active", "paused", "completed"}
FRONT_MATTER_RE = re.compile(r"^---\r?\n(.*?)\r?\n---\r?\n?(.*)$", re.DOTALL)
CHECKBOX_RE = re.compile(r"^\s*-\s\[(?P<done>[ xX])\]\s+(?P<text>.+?)\s*$")
TABLE_SEPARATOR_RE = re.compile(r"^\|\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?$")


def lock_handle(handle) -> None:
    if fcntl is not None:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        return
    handle.seek(0)
    if handle.tell() == 0 and handle.read(1) == "":
        handle.write("\0")
        handle.flush()
    handle.seek(0)
    msvcrt.locking(handle.fileno(), msvcrt.LK_LOCK, 1)


def unlock_handle(handle) -> None:
    if fcntl is not None:
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        return
    handle.seek(0)
    msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)


def utc_now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def utc_now_iso() -> str:
    return utc_now().isoformat().replace("+00:00", "Z")


def normalize_loaded_value(value):
    if isinstance(value, datetime):
        normalized = value if value.tzinfo else value.replace(tzinfo=timezone.utc)
        return normalized.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, list):
        return [normalize_loaded_value(item) for item in value]
    if isinstance(value, dict):
        return {str(key): normalize_loaded_value(item) for key, item in value.items()}
    return value


def parse_goal(filepath: str | Path) -> tuple[dict, str]:
    path = Path(filepath)
    text = path.read_text(encoding="utf-8")
    match = FRONT_MATTER_RE.match(text)
    if not match:
        return {}, text

    raw_front_matter, body = match.groups()
    front_matter = yaml.safe_load(raw_front_matter) or {}
    if not isinstance(front_matter, dict):
        raise ValueError(f"Front matter in {path} must be a mapping")
    normalized = {str(key): normalize_loaded_value(value) for key, value in front_matter.items()}
    return normalized, body


def write_goal(filepath: str | Path, front_matter: dict, body: str) -> None:
    path = Path(filepath)
    path.parent.mkdir(parents=True, exist_ok=True)

    front_matter_text = yaml.safe_dump(
        front_matter,
        sort_keys=False,
        allow_unicode=True,
        default_flow_style=False,
    ).strip()
    content = f"---\n{front_matter_text}\n---\n{body}"

    handle = tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    )
    try:
        with handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        if path.exists():
            os.chmod(handle.name, path.stat().st_mode)
        os.replace(handle.name, path)
    finally:
        if os.path.exists(handle.name):
            os.unlink(handle.name)


def level_two_heading(line: str) -> str | None:
    match = re.match(r"^\s*##\s+(.+?)\s*$", line)
    return match.group(1).strip() if match else None


def extract_criteria(body: str) -> list[dict[str, object]]:
    criteria: list[dict[str, object]] = []
    in_section = False

    for line in body.splitlines():
        heading = level_two_heading(line)
        if heading:
            if in_section:
                break
            in_section = heading.lower() == "finish criteria"
            continue
        if not in_section:
            continue
        match = CHECKBOX_RE.match(line)
        if match:
            criteria.append(
                {
                    "text": match.group("text").strip(),
                    "done": match.group("done").lower() == "x",
                }
            )

    return criteria


def parse_markdown_row(line: str) -> list[str]:
    stripped = line.strip()
    if not stripped.startswith("|"):
        return []
    return [column.strip() for column in stripped.strip("|").split("|")]


def extract_scoreboard(body: str) -> dict[str, str]:
    scoreboard: dict[str, str] = {}
    in_section = False
    saw_header = False

    for line in body.splitlines():
        heading = level_two_heading(line)
        if heading:
            if in_section:
                break
            in_section = heading.lower() == "scoreboard"
            continue
        if not in_section:
            continue

        stripped = line.strip()
        if not stripped.startswith("|"):
            continue
        if TABLE_SEPARATOR_RE.match(stripped):
            saw_header = True
            continue

        columns = parse_markdown_row(line)
        if not columns:
            continue
        if columns[0].lower() == "metric":
            continue
        if not saw_header and len(columns) >= 2:
            # Accept body rows even if the separator line is missing.
            saw_header = True
        if len(columns) >= 2 and columns[0]:
            scoreboard[columns[0]] = columns[1]

    return scoreboard


def parse_timestamp(value) -> datetime | None:
    if value is None:
        return None
    if isinstance(value, datetime):
        normalized = value if value.tzinfo else value.replace(tzinfo=timezone.utc)
        return normalized.astimezone(timezone.utc)
    if isinstance(value, date):
        return datetime.combine(value, time.min, tzinfo=timezone.utc)

    text = str(value).strip()
    if not text or text.lower() == "null":
        return None

    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def normalized_text(value) -> str:
    return str(value or "").strip().lower()


def is_truthy(value) -> bool:
    if isinstance(value, bool):
        return value
    return normalized_text(value) in {"1", "true", "yes", "on"}


def heartbeat_minutes(front_matter: dict) -> int:
    raw = front_matter.get("heartbeat_minutes", 60)
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return 60
    return value if value > 0 else 60


def goal_root_from_file(filepath: str | Path) -> Path:
    path = Path(filepath).resolve(strict=False)
    if path.parent.name in GOAL_STATUS_DIRS | {"templates"}:
        return path.parent.parent
    return path.parent


def goal_lock_path(filepath: str | Path) -> Path:
    root = goal_root_from_file(filepath)
    lock_dir = root / "locks"
    lock_dir.mkdir(parents=True, exist_ok=True)
    return lock_dir / f"{Path(filepath).stem}.lock"


@contextmanager
def locked_goal(filepath: str | Path):
    lock_path = goal_lock_path(filepath)
    with lock_path.open("a+", encoding="utf-8") as handle:
        lock_handle(handle)
        try:
            yield
        finally:
            unlock_handle(handle)


def iter_goal_files(directory: str | Path):
    path = Path(directory)
    if not path.exists():
        return []
    return sorted(
        item
        for item in path.glob("*.md")
        if item.is_file() and not item.name.startswith("_")
    )


def child_blockers(slug: str, goals_root: Path) -> list[Path]:
    blockers: list[Path] = []
    for directory_name in ("active", "paused"):
        for goal_file in iter_goal_files(goals_root / directory_name):
            front_matter, _ = parse_goal(goal_file)
            if normalized_text(front_matter.get("parent")) == slug:
                blockers.append(goal_file)
    return blockers


def eligibility_reason(goal_file: Path, front_matter: dict, active_dir: Path) -> str | None:
    if goal_file.parent.resolve() != active_dir.resolve():
        return "goal is not in the active directory"

    if normalized_text(front_matter.get("brief_status")) != "approved":
        return "brief_status is not approved"

    run_state = normalized_text(front_matter.get("run_state"))
    if run_state not in {"", "idle", "null"}:
        return f"run_state is {front_matter.get('run_state')}"

    if normalized_text(front_matter.get("approval_policy")) == "manual" and not is_truthy(
        front_matter.get("approved_for_next_run")
    ):
        return "manual approval required"

    next_eligible_at = parse_timestamp(front_matter.get("next_eligible_at"))
    now = utc_now()
    if next_eligible_at and now < next_eligible_at:
        return "next_eligible_at is in the future"

    last_run = parse_timestamp(front_matter.get("last_run"))
    if last_run:
        elapsed_minutes = (now - last_run).total_seconds() / 60
        if elapsed_minutes < heartbeat_minutes(front_matter):
            return "heartbeat interval has not elapsed"

    goals_root = active_dir.parent
    if child_blockers(goal_file.stem, goals_root):
        return "goal has active or paused child goals"

    return None


def compute_rank(front_matter: dict) -> int:
    now = utc_now()
    rank = PRIORITY_RANK.get(normalized_text(front_matter.get("priority")), PRIORITY_RANK["medium"])

    measurement_due_at = parse_timestamp(front_matter.get("measurement_due_at"))
    if measurement_due_at and now >= measurement_due_at:
        rank -= 1

    deadline_at = parse_timestamp(front_matter.get("deadline_at"))
    if deadline_at:
        hours_remaining = (deadline_at - now).total_seconds() / 3600
        if hours_remaining < 24:
            rank -= 2
        elif hours_remaining < 72:
            rank -= 1

    return rank


def candidate_sort_key(goal_file: Path, front_matter: dict) -> tuple:
    rank = compute_rank(front_matter)
    deadline_at = parse_timestamp(front_matter.get("deadline_at"))
    measurement_due_at = parse_timestamp(front_matter.get("measurement_due_at"))
    created_at = parse_timestamp(front_matter.get("created"))

    far_future = datetime.max.replace(tzinfo=timezone.utc)
    deadline_key = deadline_at or far_future
    measurement_key = measurement_due_at or far_future
    created_key = created_at or far_future
    return (rank, deadline_key, measurement_key, created_key, goal_file.stem)


def recover_stale_running_goal(goal_file: Path) -> None:
    front_matter, body = parse_goal(goal_file)
    if normalized_text(front_matter.get("run_state")) != "running":
        return

    started_at = parse_timestamp(front_matter.get("run_started_at"))
    if started_at is not None:
        age_hours = (utc_now() - started_at).total_seconds() / 3600
        if age_hours < 2:
            return

    front_matter["run_state"] = "idle"
    front_matter["run_id"] = None
    front_matter["run_started_at"] = None
    write_goal(goal_file, front_matter, body)


def safe_move(source_file: str | Path, destination_dir: str | Path) -> str:
    source = Path(source_file).resolve(strict=True)
    target_dir = Path(destination_dir)
    target_dir.mkdir(parents=True, exist_ok=True)
    resolved_target_dir = target_dir.resolve(strict=True)
    destination = resolved_target_dir / source.name
    if destination.parent != resolved_target_dir:
        raise ValueError(f"Unsafe destination for move: {destination}")
    os.replace(source, destination)
    return str(destination)


def do_claim(active_dir: str | Path):
    active_path = Path(active_dir).resolve(strict=False)
    active_path.mkdir(parents=True, exist_ok=True)
    lock_dir = active_path.parent / "locks"
    lock_dir.mkdir(parents=True, exist_ok=True)
    claim_lock_path = lock_dir / "_claim.lock"

    with claim_lock_path.open("a+", encoding="utf-8") as handle:
        lock_handle(handle)
        try:
            candidates = []
            for goal_file in iter_goal_files(active_path):
                recover_stale_running_goal(goal_file)
                front_matter, body = parse_goal(goal_file)
                reason = eligibility_reason(goal_file, front_matter, active_path)
                if reason is not None:
                    continue
                candidates.append((candidate_sort_key(goal_file, front_matter), goal_file, front_matter, body))

            if not candidates:
                return None

            _, goal_file, front_matter, body = min(candidates, key=lambda item: item[0])
            run_id = str(uuid.uuid4())
            now = utc_now_iso()
            rank = compute_rank(front_matter)
            front_matter["run_state"] = "running"
            front_matter["run_id"] = run_id
            front_matter["run_started_at"] = now
            if normalized_text(front_matter.get("approval_policy")) == "manual":
                front_matter["approved_for_next_run"] = None
            write_goal(goal_file, front_matter, body)

            return {
                "slug": goal_file.stem,
                "file": str(goal_file),
                "run_id": run_id,
                "rank": rank,
                "priority_rank": rank,
            }
        finally:
            unlock_handle(handle)


def do_finalize(filepath: str | Path) -> dict[str, str]:
    path = Path(filepath)
    with locked_goal(path):
        front_matter, body = parse_goal(path)
        front_matter["run_state"] = "idle"
        front_matter["run_id"] = None
        front_matter["run_started_at"] = None
        front_matter["last_run"] = utc_now_iso()
        write_goal(path, front_matter, body)
    return {"file": str(path)}


def do_complete(filepath: str | Path, completed_dir: str | Path) -> dict[str, str]:
    path = Path(filepath)
    with locked_goal(path):
        front_matter, body = parse_goal(path)
        front_matter["run_state"] = "idle"
        front_matter["run_id"] = None
        front_matter["run_started_at"] = None
        front_matter["last_run"] = utc_now_iso()
        write_goal(path, front_matter, body)
        destination = safe_move(path, completed_dir)
    return {"file": destination}


def do_pause(filepath: str | Path, paused_dir: str | Path) -> dict[str, str]:
    path = Path(filepath)
    with locked_goal(path):
        front_matter, body = parse_goal(path)
        front_matter["run_state"] = "idle"
        front_matter["run_id"] = None
        front_matter["run_started_at"] = None
        front_matter["last_run"] = utc_now_iso()
        write_goal(path, front_matter, body)
        destination = safe_move(path, paused_dir)
    return {"file": destination}


def format_scoreboard_row(metric: str, value, updated: str) -> str:
    return f"| {metric} | {value} | {updated} |"


def upsert_scoreboard_rows(body: str, updates: OrderedDict[str, tuple[object, str]]) -> str:
    lines = body.splitlines()
    scoreboard_index = None
    section_end = len(lines)

    for index, line in enumerate(lines):
        heading = level_two_heading(line)
        if heading is None:
            continue
        if scoreboard_index is None and heading.lower() == "scoreboard":
            scoreboard_index = index
            continue
        if scoreboard_index is not None:
            section_end = index
            break

    if scoreboard_index is None:
        result = list(lines)
        while result and result[-1] == "":
            result.pop()
        if result:
            result.append("")
        result.extend(
            [
                "## Scoreboard",
                "",
                "| Metric | Value | Updated |",
                "|--------|-------|---------|",
            ]
        )
        for metric, (value, updated) in updates.items():
            result.append(format_scoreboard_row(metric, value, updated))
        return "\n".join(result) + "\n"

    existing_rows: OrderedDict[str, tuple[str, str]] = OrderedDict()
    for line in lines[scoreboard_index + 1 : section_end]:
        stripped = line.strip()
        if not stripped.startswith("|") or TABLE_SEPARATOR_RE.match(stripped):
            continue
        columns = parse_markdown_row(line)
        if not columns or columns[0].lower() == "metric":
            continue
        metric = columns[0]
        value = columns[1] if len(columns) > 1 else ""
        updated = columns[2] if len(columns) > 2 else ""
        existing_rows[metric] = (value, updated)

    for metric, payload in updates.items():
        existing_rows[metric] = (str(payload[0]), payload[1])

    rebuilt_section = [
        "",
        "| Metric | Value | Updated |",
        "|--------|-------|---------|",
    ]
    for metric, (value, updated) in existing_rows.items():
        rebuilt_section.append(format_scoreboard_row(metric, value, updated))

    rebuilt = lines[: scoreboard_index + 1] + rebuilt_section
    if section_end < len(lines) and lines[section_end] != "":
        rebuilt.append("")
    rebuilt.extend(lines[section_end:])
    return "\n".join(rebuilt) + ("\n" if body.endswith("\n") else "")


def do_reconcile_parent(parent_file: str | Path, active_dir: str | Path) -> dict[str, int]:
    parent_path = Path(parent_file)
    active_path = Path(active_dir).resolve(strict=False)
    goals_root = active_path.parent
    parent_slug = parent_path.stem

    total_children = 0
    completed_children = 0
    for directory_name in ("active", "paused", "completed"):
        for goal_file in iter_goal_files(goals_root / directory_name):
            front_matter, _ = parse_goal(goal_file)
            if normalized_text(front_matter.get("parent")) != parent_slug:
                continue
            total_children += 1
            if directory_name == "completed":
                completed_children += 1

    with locked_goal(parent_path):
        front_matter, body = parse_goal(parent_path)
        body = upsert_scoreboard_rows(
            body,
            OrderedDict(
                [
                    ("Children total", (total_children, utc_now_iso())),
                    ("Children completed", (completed_children, utc_now_iso())),
                ]
            ),
        )
        write_goal(parent_path, front_matter, body)

    return {"total": total_children, "done": completed_children}


def parse_cli_value(raw: str):
    lowered = raw.strip().lower()
    if lowered == "null":
        return None
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if re.fullmatch(r"-?\d+", raw.strip()):
        return int(raw.strip())
    if re.fullmatch(r"-?\d+\.\d+", raw.strip()):
        return float(raw.strip())
    if raw.strip().startswith(("{", "[")):
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            pass
    return raw


def print_value(value) -> None:
    if value is None:
        print("null")
    elif isinstance(value, bool):
        print("true" if value else "false")
    elif isinstance(value, (dict, list)):
        print(json.dumps(value))
    else:
        print(value)


def check_runnable(filepath: str | Path) -> str | None:
    path = Path(filepath)
    if path.parent.name != "active":
        return "goal is not in active/"
    front_matter, _ = parse_goal(path)
    return eligibility_reason(path, front_matter, path.parent)


def usage() -> int:
    print("Usage: goalmeta.py <command> [args]", file=sys.stderr)
    return 1


def main() -> int:
    if len(sys.argv) < 2:
        return usage()

    command = sys.argv[1]

    try:
        if command == "get" and len(sys.argv) == 4:
            front_matter, _ = parse_goal(sys.argv[2])
            print_value(front_matter.get(sys.argv[3]))
            return 0

        if command == "set" and len(sys.argv) == 5:
            path = Path(sys.argv[2])
            with locked_goal(path):
                front_matter, body = parse_goal(path)
                front_matter[sys.argv[3]] = parse_cli_value(sys.argv[4])
                write_goal(path, front_matter, body)
            return 0

        if command == "claim" and len(sys.argv) == 3:
            result = do_claim(sys.argv[2])
            if result is None:
                print("null")
                return 1
            print(json.dumps(result))
            return 0

        if command == "finalize" and len(sys.argv) == 3:
            print(json.dumps(do_finalize(sys.argv[2])))
            return 0

        if command == "complete" and len(sys.argv) == 4:
            print(json.dumps(do_complete(sys.argv[2], sys.argv[3])))
            return 0

        if command == "pause" and len(sys.argv) == 4:
            print(json.dumps(do_pause(sys.argv[2], sys.argv[3])))
            return 0

        if command == "criteria" and len(sys.argv) == 3:
            _, body = parse_goal(sys.argv[2])
            print(json.dumps(extract_criteria(body)))
            return 0

        if command == "scoreboard" and len(sys.argv) == 3:
            _, body = parse_goal(sys.argv[2])
            print(json.dumps(extract_scoreboard(body)))
            return 0

        if command == "check-runnable" and len(sys.argv) == 3:
            reason = check_runnable(sys.argv[2])
            if reason is None:
                print("RUNNABLE")
                return 0
            print(f"NOT RUNNABLE: {reason}")
            return 1

        if command == "reconcile-parent" and len(sys.argv) == 4:
            print(json.dumps(do_reconcile_parent(sys.argv[2], sys.argv[3])))
            return 0
    except FileNotFoundError as error:
        print(str(error), file=sys.stderr)
        return 1
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1

    return usage()


if __name__ == "__main__":
    sys.exit(main())
