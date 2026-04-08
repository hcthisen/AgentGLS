#!/usr/bin/env python3
"""operator_chat.py — shared dashboard/Telegram operator chat for AgentGLS."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any

try:
    import fcntl  # type: ignore[attr-defined]
except ImportError:  # pragma: no cover - Windows local verification
    fcntl = None
    import msvcrt


ROOT = Path(os.environ.get("AGENTGLS_DIR", "/opt/agentgls"))
ENV_PATH = ROOT / ".env"
STATE_DIR = ROOT / "state" / "chat"
TRANSCRIPT_PATH = STATE_DIR / "messages.jsonl"
TRANSCRIPT_LOCK_PATH = STATE_DIR / "messages.lock"
HUMAN_CHANNEL_LOCK_PATH = STATE_DIR / "human.lock"
ALLOWLIST_PATH = ROOT / "state" / "telegram" / "allowlist.json"
TELEGRAM_LOG_PATH = ROOT / "logs" / "telegram-bridge.log"
PROVIDER_RUN_SCRIPT = ROOT / "scripts" / "provider-run.sh"
SEND_TELEGRAM_SCRIPT = ROOT / "scripts" / "send-telegram.sh"

GOAL_STATUS_PHRASES = [
    "goal status",
    "goals status",
    "status of the goals",
    "how are the goals",
    "how're the goals",
    "goal update",
    "goals update",
    "how is everything progressing",
    "how is every thing progressing",
]

LOG_LINE_RE = re.compile(r"^\[(?P<timestamp>[^\]]+)\]\s+INFO\s+(?P<body>.+)$")
LOG_INBOUND_RE = re.compile(
    r"^inbound chat_id=(?P<chat_id>\S+)\s+user=(?P<user>.+?)\s+text=(?P<text>.+)$"
)
LOG_OUTBOUND_RE = re.compile(
    r"^outbound chat_id=(?P<chat_id>\S+)\s+chars=\S+\s+text=(?P<text>.+)$"
)


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


@contextmanager
def locked_file(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+", encoding="utf-8") as handle:
        lock_handle(handle)
        try:
            yield handle
        finally:
            unlock_handle(handle)


def utc_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def ensure_layout() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)


def read_json(path: Path, default: dict[str, Any]) -> dict[str, Any]:
    if not path.exists():
        return default
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default
    return data if isinstance(data, dict) else default


def load_env_file() -> dict[str, str]:
    env: dict[str, str] = {}
    if not ENV_PATH.exists():
        return env

    for raw_line in ENV_PATH.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in raw_line:
            continue
        key, value = raw_line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
            value = value.replace('\\"', '"').replace("\\\\", "\\")
        env[key] = value
    return env


def env_value(key: str, default: str = "") -> str:
    if key in os.environ:
        return os.environ[key]
    return load_env_file().get(key, default)


def configured_allowlist_ids() -> set[str]:
    raw_value = env_value("AGENTGLS_TELEGRAM_ALLOWED_CHAT_IDS", "")
    return {item.strip() for item in raw_value.split(",") if item.strip()}


def load_allowlist() -> dict[str, dict[str, Any]]:
    data = read_json(ALLOWLIST_PATH, {"allowed_chats": {}})
    allowed = data.get("allowed_chats", {})
    return allowed if isinstance(allowed, dict) else {}


def all_allowlisted_chat_ids() -> list[str]:
    return sorted(configured_allowlist_ids() | set(load_allowlist().keys()))


def role_for_origin(origin: str) -> str:
    if origin == "assistant":
        return "assistant"
    return "user"


def visibility_for_origin(origin: str) -> tuple[bool, bool]:
    if origin == "dashboard_user":
        return True, False
    return True, True


def compact(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "")).strip()


def goal_status_requested(text: str) -> bool:
    lowered = text.strip().lower()
    return any(phrase in lowered for phrase in GOAL_STATUS_PHRASES)


def message_record(
    origin: str,
    text: str,
    *,
    display_name: str = "",
    chat_id: str = "",
    username: str = "",
    chat_type: str = "",
) -> dict[str, Any]:
    visible_in_dashboard, visible_in_telegram = visibility_for_origin(origin)
    return {
        "id": str(uuid.uuid4()),
        "created_at": utc_now(),
        "origin": origin,
        "role": role_for_origin(origin),
        "author": display_name.strip() or ("AgentGLS" if origin == "assistant" else "Operator"),
        "message": str(text).strip(),
        "chat_id": str(chat_id).strip(),
        "username": str(username).strip(),
        "chat_type": str(chat_type).strip(),
        "visible_in_dashboard": visible_in_dashboard,
        "visible_in_telegram": visible_in_telegram,
    }


def append_message(
    origin: str,
    text: str,
    *,
    display_name: str = "",
    chat_id: str = "",
    username: str = "",
    chat_type: str = "",
) -> dict[str, Any]:
    ensure_layout()
    record = message_record(
        origin,
        text,
        display_name=display_name,
        chat_id=chat_id,
        username=username,
        chat_type=chat_type,
    )
    with locked_file(TRANSCRIPT_LOCK_PATH):
        with TRANSCRIPT_PATH.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
    return record


def read_dashboard_messages(limit: int = 200) -> list[dict[str, Any]]:
    ensure_layout()
    if not TRANSCRIPT_PATH.exists():
        return read_log_backfill(limit)

    messages: list[dict[str, Any]] = []
    for raw_line in TRANSCRIPT_PATH.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(payload, dict):
            continue
        if payload.get("visible_in_dashboard") is False:
            continue
        messages.append(payload)

    if not messages:
        return read_log_backfill(limit)
    return messages[-max(limit, 1) :]


def read_log_backfill(limit: int = 200) -> list[dict[str, Any]]:
    if not TELEGRAM_LOG_PATH.exists():
        return []

    fallback: list[dict[str, Any]] = []
    lines = TELEGRAM_LOG_PATH.read_text(encoding="utf-8", errors="replace").splitlines()
    for raw_line in lines[-max(limit * 3, 60) :]:
        match = LOG_LINE_RE.match(raw_line.strip())
        if not match:
            continue
        timestamp = match.group("timestamp").replace(" ", "T", 1) + "Z"
        body = match.group("body")

        inbound = LOG_INBOUND_RE.match(body)
        if inbound:
            fallback.append(
                {
                    "id": f"log-inbound-{len(fallback)}",
                    "created_at": timestamp,
                    "origin": "telegram_user",
                    "role": "user",
                    "author": inbound.group("user").strip(),
                    "message": inbound.group("text").strip(),
                    "chat_id": inbound.group("chat_id").strip(),
                    "username": "",
                    "chat_type": "private",
                    "visible_in_dashboard": True,
                    "visible_in_telegram": True,
                }
            )
            continue

        outbound = LOG_OUTBOUND_RE.match(body)
        if outbound:
            fallback.append(
                {
                    "id": f"log-outbound-{len(fallback)}",
                    "created_at": timestamp,
                    "origin": "assistant",
                    "role": "assistant",
                    "author": "AgentGLS",
                    "message": outbound.group("text").strip(),
                    "chat_id": outbound.group("chat_id").strip(),
                    "username": "",
                    "chat_type": "private",
                    "visible_in_dashboard": True,
                    "visible_in_telegram": True,
                }
            )

    return fallback[-max(limit, 1) :]


def build_prompt_envelope(source: str, text: str, metadata: dict[str, Any] | None = None) -> str:
    details = metadata or {}
    source_label = "Telegram" if source == "telegram" else "Dashboard"
    display_name = compact(details.get("display_name")) or "Operator"
    username = compact(details.get("username")) or "(none)"
    chat_id = compact(details.get("chat_id")) or "(dashboard)"
    chat_type = compact(details.get("chat_type")) or ("private" if source == "telegram" else "dashboard")
    goal_status_hint = ""

    if goal_status_requested(text):
        goal_status_hint = (
            "- This message is a live goal-status request. Inspect the current goal files under "
            "`/opt/agentgls/goals/` and answer from the real filesystem state.\n"
            "- Do not ask the human to rephrase the request as `Goal status`.\n"
        )

    source_specific = (
        "- The dashboard user's prompt stays in the dashboard only, but your reply will be mirrored to paired Telegram chat(s).\n"
        if source == "dashboard"
        else "- The reply will be delivered back to the originating Telegram chat.\n"
    )

    return (
        f"source = {source_label}\n"
        f"chat_id = {chat_id}\n"
        f"chat_type = {chat_type}\n"
        f"display_name = {display_name}\n"
        f"username = {username}\n"
        f"received_at_utc = {utc_now()}\n\n"
        "message_text = <<EOF\n"
        f"{text}\n"
        "EOF\n\n"
        "Instructions:\n"
        "- Answer the human directly.\n"
        "- Keep the reply concise unless they explicitly ask for more detail.\n"
        "- This is the shared operator conversation for AgentGLS.\n"
        "- Outbound delivery is handled by AgentGLS after you respond.\n"
        "- You are running on the live VPS and should use direct file and shell access inside `/opt/agentgls` when needed.\n"
        "- Do not claim that shell access or goal access is blocked unless you attempted a concrete command and it failed.\n"
        f"{goal_status_hint}"
        f"{source_specific}"
        "- Reply with the message body only.\n"
    )


def run_provider(prompt: str) -> str:
    if not PROVIDER_RUN_SCRIPT.exists():
        raise RuntimeError(f"Missing provider runner: {PROVIDER_RUN_SCRIPT}")

    prompt_path = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            handle.write(prompt)
            prompt_path = handle.name

        result = subprocess.run(
            ["bash", str(PROVIDER_RUN_SCRIPT), "human", prompt_path],
            capture_output=True,
            text=True,
            check=False,
        )
    finally:
        if prompt_path:
            try:
                os.unlink(prompt_path)
            except OSError:
                pass

    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"provider-run exited {result.returncode}"
        raise RuntimeError(detail)

    reply = result.stdout.strip()
    return reply or "I ran the request but did not get a reply back."


def process_human_message(source: str, text: str, metadata: dict[str, Any] | None = None) -> dict[str, Any]:
    clean_text = str(text or "").strip()
    if source not in {"telegram", "dashboard"}:
        raise ValueError(f"Unsupported source: {source}")
    if not clean_text:
        raise ValueError("Message body is empty")

    details = metadata or {}
    origin = "telegram_user" if source == "telegram" else "dashboard_user"

    with locked_file(HUMAN_CHANNEL_LOCK_PATH):
        user_record = append_message(
            origin,
            clean_text,
            display_name=str(details.get("display_name", "")).strip(),
            chat_id=str(details.get("chat_id", "")).strip(),
            username=str(details.get("username", "")).strip(),
            chat_type=str(details.get("chat_type", "")).strip(),
        )

        try:
            reply = run_provider(build_prompt_envelope(source, clean_text, details))
        except Exception:
            reply = "The assistant hit an execution error before replying. Please try again in a moment."

        assistant_record = append_message("assistant", reply, display_name="AgentGLS")

    return {
        "user_message": user_record,
        "assistant_message": assistant_record,
        "reply": reply,
    }


def send_text(chat_id: str, text: str) -> None:
    if not SEND_TELEGRAM_SCRIPT.exists():
        raise RuntimeError(f"Missing send helper: {SEND_TELEGRAM_SCRIPT}")

    result = subprocess.run(
        ["bash", str(SEND_TELEGRAM_SCRIPT), str(chat_id)],
        input=text,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown send failure"
        raise RuntimeError(detail)


def deliver_reply_to_telegram(source: str, reply: str, *, chat_id: str = "") -> dict[str, list[str]]:
    if source == "telegram":
        target_ids = [str(chat_id).strip()] if str(chat_id).strip() else []
    elif source == "dashboard":
        target_ids = all_allowlisted_chat_ids()
    else:
        raise ValueError(f"Unsupported source: {source}")

    delivered: list[str] = []
    failed: list[str] = []
    for target_chat_id in target_ids:
        try:
            send_text(target_chat_id, reply)
            delivered.append(target_chat_id)
        except Exception as exc:
            failed.append(f"{target_chat_id}: {exc}")

    return {"delivered_chat_ids": delivered, "delivery_errors": failed}


def read_json_stdin() -> dict[str, Any]:
    payload = sys.stdin.read().strip()
    if not payload:
        return {}
    return json.loads(payload)


def recent(limit: int) -> int:
    json.dump({"messages": read_dashboard_messages(limit)}, sys.stdout)
    return 0


def send_dashboard_message() -> int:
    payload = read_json_stdin()
    text = str(payload.get("text", "")).strip()
    display_name = str(payload.get("display_name", "")).strip()
    if not text:
        raise SystemExit("text is required")

    result = process_human_message("dashboard", text, {"display_name": display_name or "Dashboard operator"})
    result.update(deliver_reply_to_telegram("dashboard", result["reply"]))
    result["messages"] = read_dashboard_messages(200)
    json.dump(result, sys.stdout)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Shared operator chat tools for AgentGLS")
    subparsers = parser.add_subparsers(dest="command", required=True)

    recent_parser = subparsers.add_parser("recent", help="Print recent dashboard-visible chat messages as JSON")
    recent_parser.add_argument("--limit", type=int, default=200)

    subparsers.add_parser("send-dashboard", help="Send a dashboard-originated operator message")
    return parser


def main() -> int:
    ensure_layout()
    args = build_parser().parse_args()

    if args.command == "recent":
        return recent(args.limit)
    if args.command == "send-dashboard":
        return send_dashboard_message()

    raise AssertionError(f"Unhandled command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
