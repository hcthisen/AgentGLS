#!/usr/bin/env python3
"""telegram-bridge.py — Provider-neutral Telegram Bot API bridge for AgentGLS."""

from __future__ import annotations

import argparse
import json
import logging
import os
import random
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


ROOT = Path(os.environ.get("AGENTOS_DIR", "/opt/agentos"))
ENV_PATH = ROOT / ".env"
STATE_DIR = ROOT / "state" / "telegram"
ALLOWLIST_PATH = STATE_DIR / "allowlist.json"
PENDING_PATH = STATE_DIR / "pending.json"
OFFSET_PATH = STATE_DIR / "update-offset.txt"
LOG_PATH = ROOT / "logs" / "telegram-bridge.log"
PROVIDER_RUN_SCRIPT = ROOT / "scripts" / "provider-run.sh"
SEND_TELEGRAM_SCRIPT = ROOT / "scripts" / "send-telegram.sh"

PAIR_CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
PAIR_CODE_LENGTH = 6
POLL_TIMEOUT_SECONDS = 30
RETRY_DELAY_SECONDS = 5
TOKEN_RETRY_DELAY_SECONDS = 15


def utc_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def ensure_layout() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)


def configure_logging() -> logging.Logger:
    ensure_layout()
    logging.Formatter.converter = time.gmtime

    logger = logging.getLogger("telegram-bridge")
    if logger.handlers:
        return logger

    logger.setLevel(logging.INFO)
    handler = logging.FileHandler(LOG_PATH, encoding="utf-8")
    handler.setFormatter(logging.Formatter("[%(asctime)s] %(levelname)s %(message)s"))
    logger.addHandler(handler)
    logger.propagate = False
    return logger


LOGGER = configure_logging()


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


def telegram_token() -> str:
    return env_value("TELEGRAM_BOT_TOKEN", "").strip()


def configured_allowlist_ids() -> set[str]:
    raw_value = env_value("AGENTGLS_TELEGRAM_ALLOWED_CHAT_IDS", "")
    return {item.strip() for item in raw_value.split(",") if item.strip()}


def read_json(path: Path, default: dict[str, Any]) -> dict[str, Any]:
    if not path.exists():
        return default
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        LOGGER.warning("State file unreadable, using default: %s", path)
        return default
    return data if isinstance(data, dict) else default


def write_atomic(path: Path, content: str) -> None:
    ensure_layout()
    temp_path = path.with_suffix(path.suffix + ".tmp")
    temp_path.write_text(content, encoding="utf-8")
    temp_path.replace(path)


def load_allowlist() -> dict[str, dict[str, Any]]:
    data = read_json(ALLOWLIST_PATH, {"allowed_chats": {}})
    allowed = data.get("allowed_chats", {})
    return allowed if isinstance(allowed, dict) else {}


def save_allowlist(chats: dict[str, dict[str, Any]]) -> None:
    write_atomic(ALLOWLIST_PATH, json.dumps({"allowed_chats": chats}, indent=2, sort_keys=True) + "\n")


def load_pending() -> dict[str, dict[str, Any]]:
    data = read_json(PENDING_PATH, {"pending_chats": {}})
    pending = data.get("pending_chats", {})
    return pending if isinstance(pending, dict) else {}


def save_pending(chats: dict[str, dict[str, Any]]) -> None:
    write_atomic(PENDING_PATH, json.dumps({"pending_chats": chats}, indent=2, sort_keys=True) + "\n")


def read_offset() -> int:
    if not OFFSET_PATH.exists():
        return 0
    try:
        return int(OFFSET_PATH.read_text(encoding="utf-8").strip() or "0")
    except ValueError:
        LOGGER.warning("Invalid Telegram offset file, resetting: %s", OFFSET_PATH)
        return 0


def write_offset(offset: int) -> None:
    write_atomic(OFFSET_PATH, f"{offset}\n")


def chat_display_name(chat: dict[str, Any]) -> str:
    first = str(chat.get("first_name", "")).strip()
    last = str(chat.get("last_name", "")).strip()
    title = str(chat.get("title", "")).strip()
    username = str(chat.get("username", "")).strip()

    if title:
        return title
    if first or last:
        return " ".join(part for part in [first, last] if part)
    if username:
        return f"@{username}"
    return "Telegram user"


def chat_metadata(chat: dict[str, Any]) -> dict[str, str]:
    username = str(chat.get("username", "")).strip()
    return {
        "display_name": chat_display_name(chat),
        "username": username,
        "chat_type": str(chat.get("type", "")).strip(),
    }


def sanitize_excerpt(text: str, limit: int = 180) -> str:
    compact = re.sub(r"\s+", " ", text).strip()
    if len(compact) <= limit:
        return compact
    return compact[: limit - 3] + "..."


def is_allowlisted(chat_id: str) -> bool:
    return chat_id in configured_allowlist_ids() or chat_id in load_allowlist()


def clear_pending_chat(chat_id: str) -> None:
    pending = load_pending()
    if chat_id in pending:
        del pending[chat_id]
        save_pending(pending)


def update_allowlist_metadata(chat_id: str, chat: dict[str, Any]) -> None:
    allowed = load_allowlist()
    if chat_id not in allowed:
        return

    metadata = chat_metadata(chat)
    changed = False
    for key, value in metadata.items():
        if allowed[chat_id].get(key) != value:
            allowed[chat_id][key] = value
            changed = True

    if changed:
        allowed[chat_id]["updated_at"] = utc_now()
        save_allowlist(allowed)


def generate_pair_code(existing_codes: set[str]) -> str:
    rng = random.SystemRandom()
    while True:
        code = "".join(rng.choice(PAIR_CODE_CHARS) for _ in range(PAIR_CODE_LENGTH))
        if code not in existing_codes:
            return code


def register_pending_chat(chat_id: str, chat: dict[str, Any]) -> tuple[dict[str, Any], bool]:
    pending = load_pending()
    now = utc_now()
    entry = pending.get(chat_id)
    created = entry is None

    if entry is None:
        entry = {
            "chat_id": chat_id,
            "code": generate_pair_code({item.get("code", "") for item in pending.values()}),
            "first_seen_at": now,
        }

    entry.update(chat_metadata(chat))
    entry["last_seen_at"] = now
    pending[chat_id] = entry
    save_pending(pending)
    return entry, created


def approve_pair_code(code: str) -> dict[str, Any] | None:
    pending = load_pending()
    pending_chat_id = None
    pending_entry = None
    normalized_code = code.strip().upper()

    for chat_id, entry in pending.items():
        if str(entry.get("code", "")).upper() == normalized_code:
            pending_chat_id = chat_id
            pending_entry = entry
            break

    if pending_chat_id is None or pending_entry is None:
        return None

    allowed = load_allowlist()
    record = dict(pending_entry)
    record["paired_at"] = utc_now()
    record["approved_via"] = "pair-code"
    allowed[pending_chat_id] = record
    del pending[pending_chat_id]

    save_allowlist(allowed)
    save_pending(pending)
    return record


def telegram_api(method: str, payload: dict[str, Any]) -> dict[str, Any]:
    token = telegram_token()
    if not token:
        raise RuntimeError("TELEGRAM_BOT_TOKEN is not configured")

    request = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/{method}",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=POLL_TIMEOUT_SECONDS + 10) as response:
            body = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Telegram API {method} failed with HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Telegram API {method} failed: {exc.reason}") from exc

    parsed = json.loads(body)
    if not parsed.get("ok"):
        raise RuntimeError(f"Telegram API {method} failed: {body}")
    return parsed


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


def build_prompt_envelope(chat_id: str, chat: dict[str, Any], text: str) -> str:
    metadata = chat_metadata(chat)
    username_line = metadata["username"] or "(none)"

    return (
        "source = Telegram\n"
        f"chat_id = {chat_id}\n"
        f"chat_type = {metadata['chat_type'] or 'private'}\n"
        f"display_name = {metadata['display_name']}\n"
        f"username = {username_line}\n"
        f"received_at_utc = {utc_now()}\n\n"
        "message_text = <<EOF\n"
        f"{text}\n"
        "EOF\n\n"
        "Instructions:\n"
        "- Answer the human directly.\n"
        "- Keep the reply concise unless they explicitly ask for more detail.\n"
        "- Outbound Telegram delivery is handled by the bridge, not by you.\n"
        "- Reply with the message body only.\n"
    )


def run_provider_for_message(chat_id: str, chat: dict[str, Any], text: str) -> str:
    if not PROVIDER_RUN_SCRIPT.exists():
        raise RuntimeError(f"Missing provider runner: {PROVIDER_RUN_SCRIPT}")

    prompt = build_prompt_envelope(chat_id, chat, text)
    prompt_path = None

    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            handle.write(prompt)
            prompt_path = handle.name

        result = subprocess.run(
            ["bash", str(PROVIDER_RUN_SCRIPT), "human", prompt_path],
            text=True,
            capture_output=True,
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


def handle_unpaired_message(chat_id: str, chat: dict[str, Any], text: str) -> None:
    entry, created = register_pending_chat(chat_id, chat)
    pair_code = entry["code"]
    LOGGER.info(
        "pairing_requested chat_id=%s code=%s created=%s user=%s text=%s",
        chat_id,
        pair_code,
        created,
        entry.get("display_name", ""),
        sanitize_excerpt(text),
    )

    reply = (
        "This bot is locked until the operator pairs this chat.\n"
        f"Your pairing code is: {pair_code}\n\n"
        "After approval, send your message again."
    )
    send_text(chat_id, reply)


def handle_allowlisted_message(chat_id: str, chat: dict[str, Any], text: str) -> None:
    update_allowlist_metadata(chat_id, chat)
    clear_pending_chat(chat_id)
    LOGGER.info(
        "inbound chat_id=%s user=%s text=%s",
        chat_id,
        chat_display_name(chat),
        sanitize_excerpt(text),
    )

    try:
        reply = run_provider_for_message(chat_id, chat, text)
    except Exception as exc:
        LOGGER.error("provider_error chat_id=%s detail=%s", chat_id, str(exc))
        reply = "The assistant hit an execution error before replying. Please try again in a moment."

    try:
        send_text(chat_id, reply)
        LOGGER.info(
            "outbound chat_id=%s chars=%s text=%s",
            chat_id,
            len(reply),
            sanitize_excerpt(reply),
        )
    except Exception as exc:
        LOGGER.error("send_error chat_id=%s detail=%s", chat_id, str(exc))


def process_message(message: dict[str, Any]) -> None:
    chat = message.get("chat") or {}
    chat_id = str(chat.get("id", "")).strip()
    if not chat_id:
        LOGGER.info("ignored update without chat id")
        return

    if str(chat.get("type", "")).strip() != "private":
        LOGGER.info("ignored non-private chat_id=%s type=%s", chat_id, chat.get("type", ""))
        return

    text = str(message.get("text") or message.get("caption") or "").strip()
    if not text:
        LOGGER.info("ignored non-text private message chat_id=%s", chat_id)
        if is_allowlisted(chat_id):
            try:
                send_text(chat_id, "Text messages only right now.")
            except Exception as exc:
                LOGGER.error("non_text_send_error chat_id=%s detail=%s", chat_id, str(exc))
        return

    if is_allowlisted(chat_id):
        handle_allowlisted_message(chat_id, chat, text)
    else:
        handle_unpaired_message(chat_id, chat, text)


def run_loop() -> int:
    LOGGER.info("telegram bridge starting root=%s", ROOT)
    next_offset = read_offset()

    while True:
        token = telegram_token()
        if not token:
            LOGGER.warning("TELEGRAM_BOT_TOKEN is not configured; sleeping")
            time.sleep(TOKEN_RETRY_DELAY_SECONDS)
            continue

        try:
            response = telegram_api(
                "getUpdates",
                {
                    "offset": next_offset,
                    "timeout": POLL_TIMEOUT_SECONDS,
                    "allowed_updates": ["message"],
                },
            )
            for update in response.get("result", []):
                update_id = int(update.get("update_id", 0))
                if update_id:
                    next_offset = max(next_offset, update_id + 1)
                    write_offset(next_offset)
                message = update.get("message")
                if isinstance(message, dict):
                    process_message(message)
        except KeyboardInterrupt:
            LOGGER.info("telegram bridge interrupted; exiting")
            return 0
        except Exception as exc:
            LOGGER.error("poll_error detail=%s", str(exc))
            time.sleep(RETRY_DELAY_SECONDS)


def print_pending() -> int:
    pending = load_pending()
    if not pending:
        print("No pending Telegram pair requests.")
        return 0

    for entry in sorted(pending.values(), key=lambda item: item.get("last_seen_at", "")):
        print(
            f"{entry.get('code', '------')}  chat_id={entry.get('chat_id', '')}  "
            f"user={entry.get('display_name', 'unknown')}  last_seen={entry.get('last_seen_at', '')}"
        )
    return 0


def print_allowlist() -> int:
    allowed = load_allowlist()
    env_allowed = configured_allowlist_ids()

    if not allowed and not env_allowed:
        print("No allowlisted Telegram chats.")
        return 0

    for chat_id in sorted(env_allowed):
        print(f"{chat_id}  source=env")

    for chat_id, entry in sorted(allowed.items()):
        print(
            f"{chat_id}  source=disk  user={entry.get('display_name', 'unknown')}  "
            f"paired_at={entry.get('paired_at', '')}"
        )
    return 0


def print_status() -> int:
    payload = {
        "root": str(ROOT),
        "token_configured": bool(telegram_token()),
        "pending_pairs": len(load_pending()),
        "allowlisted_chats": len(load_allowlist()),
        "env_allowlisted_chats": len(configured_allowlist_ids()),
        "next_offset": read_offset(),
        "log_file": str(LOG_PATH),
    }
    print(json.dumps(payload, indent=2))
    return 0


def pair_code(code: str) -> int:
    record = approve_pair_code(code)
    if record is None:
        print(f"Pairing code not found: {code}", file=sys.stderr)
        return 1

    chat_id = str(record.get("chat_id", "")).strip()
    LOGGER.info("pairing_approved chat_id=%s code=%s", chat_id, record.get("code", ""))

    try:
        send_text(chat_id, "Pairing approved. This chat is now allowlisted.")
    except Exception as exc:
        LOGGER.error("pairing_confirmation_send_error chat_id=%s detail=%s", chat_id, str(exc))

    print(
        f"Paired chat {chat_id} ({record.get('display_name', 'unknown')}) with code {record.get('code', '')}."
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Provider-neutral Telegram bridge for AgentGLS")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("run", help="Run the Telegram long-poll bridge")
    pair_parser = subparsers.add_parser("pair", help="Approve a pending pairing code")
    pair_parser.add_argument("code", help="Pending six-character pairing code")
    subparsers.add_parser("list-pending", help="List pending pairing requests")
    subparsers.add_parser("list-allowed", help="List allowlisted chat IDs")
    subparsers.add_parser("status", help="Print bridge status as JSON")
    return parser


def main() -> int:
    args = build_parser().parse_args()

    if args.command == "run":
        return run_loop()
    if args.command == "pair":
        return pair_code(args.code)
    if args.command == "list-pending":
        return print_pending()
    if args.command == "list-allowed":
        return print_allowlist()
    if args.command == "status":
        return print_status()

    raise AssertionError(f"Unhandled command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
