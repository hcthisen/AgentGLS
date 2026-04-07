#!/usr/bin/env python3
"""setup-instance.py — host-side setup mutations for AgentGLS onboarding."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import sys
from collections import OrderedDict
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(os.environ.get("AGENTOS_DIR", "/opt/agentos"))
ENV_PATH = ROOT / ".env"
GOALS_DIR = ROOT / "goals"
ACTIVE_GOALS_DIR = GOALS_DIR / "active"
RUNBOOK_PATH = GOALS_DIR / "_runbook.md"
CONTEXT_PATH = GOALS_DIR / "_context.md"

ENV_ORDER = [
    "AGENTOS_DOMAIN",
    "AGENTGLS_PROVIDER",
    "AGENTGLS_ADMIN_NAME",
    "AGENTGLS_ADMIN_EMAIL",
    "AGENTGLS_DOMAIN_SKIPPED",
    "AGENTGLS_TELEGRAM_SKIPPED",
    "TELEGRAM_BOT_TOKEN",
    "POSTGRES_PASSWORD",
    "JWT_SECRET",
    "SUPABASE_ANON_KEY",
    "SUPABASE_SERVICE_ROLE_KEY",
    "DASHBOARD_PASSWORD_HASH",
]


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def load_env() -> OrderedDict[str, str]:
    env: OrderedDict[str, str] = OrderedDict()
    if not ENV_PATH.exists():
        return env

    for raw_line in ENV_PATH.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = raw_line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = shlex.split(f"VAR={value}", posix=True)[0].split("=", 1)[1]
        env[key] = value
    return env


def encode_env_value(value: str) -> str:
    if value == "":
        return ""
    if re.search(r'[\s"]', value):
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    return value


def write_env(env: OrderedDict[str, str]) -> None:
    ordered = OrderedDict()
    for key in ENV_ORDER:
        if key in env:
            ordered[key] = env[key]
    for key, value in env.items():
        if key not in ordered:
            ordered[key] = value

    content = "".join(f"{key}={encode_env_value(value)}\n" for key, value in ordered.items())
    ENV_PATH.write_text(content, encoding="utf-8")
    os.chmod(ENV_PATH, 0o600)


def ensure_goal_dirs() -> None:
    for directory in [
        GOALS_DIR / "active",
        GOALS_DIR / "paused",
        GOALS_DIR / "completed",
        GOALS_DIR / "templates",
        GOALS_DIR / "proof",
        GOALS_DIR / "locks",
    ]:
        directory.mkdir(parents=True, exist_ok=True)

    if not RUNBOOK_PATH.exists():
        RUNBOOK_PATH.write_text("", encoding="utf-8")
    if not CONTEXT_PATH.exists():
        CONTEXT_PATH.write_text("", encoding="utf-8")


def read_json_stdin() -> dict:
    payload = sys.stdin.read().strip()
    if not payload:
        return {}
    return json.loads(payload)


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return slug or "goal"


def find_first_goal() -> Path | None:
    if not ACTIVE_GOALS_DIR.exists():
        return None
    goals = sorted(path for path in ACTIVE_GOALS_DIR.glob("*.md") if not path.name.startswith("_"))
    return goals[0] if goals else None


def context_configured() -> bool:
    return CONTEXT_PATH.exists() and bool(CONTEXT_PATH.read_text(encoding="utf-8").strip())


def set_admin() -> None:
    data = read_json_stdin()
    name = str(data.get("name", "")).strip()
    email = str(data.get("email", "")).strip().lower()
    password_hash = str(data.get("password_hash", "")).strip()

    if not name or not email or not password_hash:
        raise SystemExit("name, email, and password_hash are required")

    env = load_env()
    env["AGENTGLS_ADMIN_NAME"] = name
    env["AGENTGLS_ADMIN_EMAIL"] = email
    env["DASHBOARD_PASSWORD_HASH"] = password_hash
    write_env(env)


def set_provider() -> None:
    data = read_json_stdin()
    provider = str(data.get("provider", "")).strip()
    if provider not in {"claude", "codex"}:
        raise SystemExit("provider must be claude or codex")

    env = load_env()
    env["AGENTGLS_PROVIDER"] = provider
    write_env(env)


def set_domain() -> None:
    data = read_json_stdin()
    skip = bool(data.get("skip"))
    domain = str(data.get("domain", "")).strip().lower()

    env = load_env()
    if skip or not domain:
        env["AGENTOS_DOMAIN"] = ""
        env["AGENTGLS_DOMAIN_SKIPPED"] = "1"
    else:
        env["AGENTOS_DOMAIN"] = domain
        env["AGENTGLS_DOMAIN_SKIPPED"] = "0"
    write_env(env)


def set_telegram() -> None:
    data = read_json_stdin()
    skip = bool(data.get("skip"))
    token = str(data.get("token", "")).strip()

    env = load_env()
    if skip:
        env["TELEGRAM_BOT_TOKEN"] = ""
        env["AGENTGLS_TELEGRAM_SKIPPED"] = "1"
    else:
        if not token:
            raise SystemExit("token is required unless skip=true")
        env["TELEGRAM_BOT_TOKEN"] = token
        env["AGENTGLS_TELEGRAM_SKIPPED"] = "0"
    write_env(env)


def write_context() -> None:
    data = read_json_stdin()
    text = str(data.get("text", "")).strip()
    if not text:
        raise SystemExit("text is required")

    ensure_goal_dirs()
    CONTEXT_PATH.write_text(text + "\n", encoding="utf-8")


def create_goal() -> None:
    data = read_json_stdin()
    title = str(data.get("title", "")).strip()
    summary = str(data.get("summary", "")).strip()
    if not title or not summary:
        raise SystemExit("title and summary are required")

    ensure_goal_dirs()

    slug_base = slugify(title)
    goal_path = ACTIVE_GOALS_DIR / f"{slug_base}.md"
    suffix = 2
    while goal_path.exists():
        goal_path = ACTIVE_GOALS_DIR / f"{slug_base}-{suffix}.md"
        suffix += 1

    timestamp = utc_now()
    front_matter = (
        "---\n"
        f"title: {json.dumps(title)}\n"
        'brief_status: "draft"\n'
        "priority: medium\n"
        "run_state: idle\n"
        f"created_at: {timestamp}\n"
        f"updated_at: {timestamp}\n"
        "---\n\n"
    )
    body = f"# Goal\n\n{summary}\n"
    goal_path.write_text(front_matter + body, encoding="utf-8")


def status() -> None:
    ensure_goal_dirs()
    env = load_env()
    goal_path = find_first_goal()

    payload = {
        "adminConfigured": bool(env.get("AGENTGLS_ADMIN_EMAIL")) and bool(env.get("DASHBOARD_PASSWORD_HASH")),
        "adminEmail": env.get("AGENTGLS_ADMIN_EMAIL", ""),
        "adminName": env.get("AGENTGLS_ADMIN_NAME", ""),
        "provider": env.get("AGENTGLS_PROVIDER", ""),
        "domain": env.get("AGENTOS_DOMAIN", ""),
        "domainSkipped": env.get("AGENTGLS_DOMAIN_SKIPPED", "0") == "1",
        "telegramConfigured": bool(env.get("TELEGRAM_BOT_TOKEN")),
        "telegramSkipped": env.get("AGENTGLS_TELEGRAM_SKIPPED", "0") == "1",
        "contextConfigured": context_configured(),
        "initialGoalConfigured": goal_path is not None,
        "initialGoalPath": str(goal_path) if goal_path else "",
    }
    json.dump(payload, sys.stdout)


def password_hash() -> None:
    data = read_json_stdin()
    password = str(data.get("password", ""))
    if not password:
        raise SystemExit("password is required")
    digest = hashlib.sha256(password.encode("utf-8")).hexdigest()
    json.dump({"password_hash": digest}, sys.stdout)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "action",
        choices=[
            "set-admin",
            "set-provider",
            "set-domain",
            "set-telegram",
            "write-context",
            "create-goal",
            "status",
            "password-hash",
        ],
    )
    args = parser.parse_args()

    ensure_goal_dirs()

    actions = {
        "set-admin": set_admin,
        "set-provider": set_provider,
        "set-domain": set_domain,
        "set-telegram": set_telegram,
        "write-context": write_context,
        "create-goal": create_goal,
        "status": status,
        "password-hash": password_hash,
    }
    actions[args.action]()


if __name__ == "__main__":
    main()
