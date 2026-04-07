#!/bin/bash
# send-telegram.sh — Send a plain-text Telegram message via the Bot API.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/provider-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  send-telegram.sh <chat_id> <message>
  echo "message" | send-telegram.sh <chat_id>
EOF
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

load_agentgls_env

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "TELEGRAM_BOT_TOKEN is not configured" >&2
  exit 1
fi

chat_id="$1"
shift

message_file="$(mktemp)"
trap 'rm -f "$message_file"' EXIT

if [[ $# -gt 0 ]]; then
  printf '%s' "$*" > "$message_file"
elif [[ ! -t 0 ]]; then
  cat > "$message_file"
else
  usage >&2
  exit 1
fi

if [[ ! -s "$message_file" ]]; then
  echo "Message body is empty" >&2
  exit 1
fi

python3 - "$chat_id" "$message_file" <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

MAX_MESSAGE_LEN = 4000


def split_text(raw_text: str) -> list[str]:
    text = raw_text.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not text:
        return []

    parts: list[str] = []
    remaining = text

    while remaining:
        if len(remaining) <= MAX_MESSAGE_LEN:
            parts.append(remaining)
            break

        window = remaining[:MAX_MESSAGE_LEN]
        split_at = max(window.rfind("\n\n"), window.rfind("\n"), window.rfind(" "))
        if split_at < MAX_MESSAGE_LEN // 2:
            split_at = MAX_MESSAGE_LEN

        part = remaining[:split_at].rstrip()
        if not part:
            part = remaining[:MAX_MESSAGE_LEN]

        parts.append(part)
        remaining = remaining[len(part):].lstrip("\n ")

    return parts


def send_chunk(token: str, chat_id: str, chunk: str) -> None:
    payload = json.dumps(
        {
            "chat_id": chat_id,
            "text": chunk,
            "disable_web_page_preview": True,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Telegram send failed with HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Telegram send failed: {exc.reason}") from exc

    parsed = json.loads(body)
    if not parsed.get("ok"):
        raise RuntimeError(f"Telegram send failed: {body}")


def main() -> int:
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    chat_id = sys.argv[1]
    message_path = sys.argv[2]

    with open(message_path, "r", encoding="utf-8") as handle:
        raw_text = handle.read()

    chunks = split_text(raw_text)
    if not chunks:
        raise RuntimeError("Message body is empty after normalization")

    for chunk in chunks:
        send_chunk(token, chat_id, chunk)

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # pragma: no cover - surfaced to shell caller
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
PY
