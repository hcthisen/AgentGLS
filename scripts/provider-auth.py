"""provider-auth.py - host-side provider auth sessions for onboarding."""

from __future__ import annotations

import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import UTC, datetime, timedelta
from hashlib import sha256
from pathlib import Path
from secrets import token_urlsafe
from typing import Any


ROOT = Path(os.environ.get("AGENTGLS_DIR", "/opt/agentgls"))
STATE_DIR = ROOT / "runtime" / "provider-auth"
HOME_DIR = Path.home()
INSTALL_PROVIDER_SCRIPT = ROOT / "scripts" / "install-provider.sh"

DEVICE_AUTH_URL = "https://auth.openai.com/codex/device"
DEVICE_CODE_TTL_SECONDS = 15 * 60
ANTHROPIC_OAUTH_AUTHORIZE_URL = "https://claude.ai/oauth/authorize"
ANTHROPIC_OAUTH_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
ANTHROPIC_OAUTH_MANUAL_REDIRECT_URL = "https://platform.claude.com/oauth/code/callback"
ANTHROPIC_OAUTH_SCOPES = [
    "org:create_api_key",
    "user:profile",
    "user:inference",
    "user:sessions:claude_code",
    "user:mcp_servers",
    "user:file_upload",
]
ANTHROPIC_OAUTH_TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
ANSI_PATTERN = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")


def now_iso() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def ensure_state_dir() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)


def session_path(provider: str) -> Path:
    return STATE_DIR / f"{provider}.json"


def stdout_path(provider: str) -> Path:
    return STATE_DIR / f"{provider}.stdout.log"


def stderr_path(provider: str) -> Path:
    return STATE_DIR / f"{provider}.stderr.log"


def exit_path(provider: str) -> Path:
    return STATE_DIR / f"{provider}.exit"


def common_env() -> dict[str, str]:
    env = os.environ.copy()
    home = str(HOME_DIR)
    env.update(
        {
            "FORCE_COLOR": "0",
            "HOME": home,
            "NO_COLOR": "1",
            "TERM": "dumb",
            "USERPROFILE": home,
        }
    )
    return env


def claude_env() -> dict[str, str]:
    env = common_env()
    env.update(
        {
            "CLAUDE_CONFIG_DIR": str(HOME_DIR / ".claude"),
            "CLAUDE_CREDENTIALS_PATH": str(HOME_DIR / ".claude" / ".credentials.json"),
            "CLAUDE_LEGACY_CREDENTIALS_PATH": str(HOME_DIR / ".claude.json"),
        }
    )
    return env


def codex_env() -> dict[str, str]:
    env = common_env()
    env["CODEX_HOME"] = str(HOME_DIR / ".codex")
    return env


def read_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None

    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def write_json(path: Path, payload: dict[str, Any]) -> None:
    ensure_state_dir()
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def remove_artifacts(provider: str) -> None:
    for path in [stdout_path(provider), stderr_path(provider), exit_path(provider)]:
        try:
            path.unlink()
        except FileNotFoundError:
            pass


def strip_ansi(value: str) -> str:
    return ANSI_PATTERN.sub("", value)


def read_log(path: Path) -> str:
    if not path.exists():
        return ""
    return strip_ansi(path.read_text(encoding="utf-8", errors="ignore"))


def last_error_detail(provider: str) -> str:
    content = "\n".join(
        [part for part in [read_log(stderr_path(provider)).strip(), read_log(stdout_path(provider)).strip()] if part]
    ).strip()
    if not content:
        return ""
    lines = [line.strip() for line in content.splitlines() if line.strip()]
    return lines[-1] if lines else ""


def process_running(pid: int | None) -> bool:
    if not pid:
        return False

    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def kill_process_group(pid: int | None) -> None:
    if not process_running(pid):
        return

    try:
        os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError:
        return


def optional_string(value: Any) -> str | None:
    if isinstance(value, str):
        trimmed = value.strip()
        return trimmed or None
    return None


def encode_base64_url(value: bytes) -> str:
    return (
        __import__("base64")
        .urlsafe_b64encode(value)
        .decode("ascii")
        .rstrip("=")
    )


def generate_code_verifier() -> str:
    return token_urlsafe(32)


def generate_oauth_state() -> str:
    return token_urlsafe(32)


def create_code_challenge(code_verifier: str) -> str:
    return encode_base64_url(sha256(code_verifier.encode("utf-8")).digest())


def build_claude_verification_url(code_verifier: str, state: str) -> str:
    from urllib.parse import urlencode

    query = urlencode(
        {
            "code": "true",
            "client_id": ANTHROPIC_OAUTH_CLIENT_ID,
            "response_type": "code",
            "redirect_uri": ANTHROPIC_OAUTH_MANUAL_REDIRECT_URL,
            "scope": " ".join(ANTHROPIC_OAUTH_SCOPES),
            "code_challenge": create_code_challenge(code_verifier),
            "code_challenge_method": "S256",
            "state": state,
        }
    )
    return f"{ANTHROPIC_OAUTH_AUTHORIZE_URL}?{query}"


def parse_claude_callback(value: str) -> dict[str, str] | None:
    trimmed = value.strip()
    if not trimmed:
        return None

    if trimmed.startswith("http://") or trimmed.startswith("https://"):
        from urllib.parse import urlparse, parse_qs

        try:
            parsed = urlparse(trimmed)
            query = parse_qs(parsed.query)
        except Exception:
            return None

        code = optional_string((query.get("code") or [None])[0])
        state = optional_string((query.get("state") or [None])[0])
        if code and state:
            return {"code": code, "state": state}
        return None

    match = re.match(r"^([A-Za-z0-9_-]+)#([A-Za-z0-9_-]+)$", trimmed)
    if not match:
        return None

    return {"code": match.group(1), "state": match.group(2)}


def parse_scope_list(value: Any) -> list[str]:
    if not isinstance(value, str):
        return []
    return [part for part in re.split(r"\s+", value.strip()) if part]


def extract_verification_url(value: str) -> str | None:
    match = re.search(r"https://\S+", value)
    if not match:
        return None
    return match.group(0).rstrip(").,")


def extract_codex_user_code(text: str) -> str | None:
    for line in text.splitlines():
        trimmed = line.strip()
        if not trimmed:
            continue
        lowered = trimmed.lower()
        if "code" not in lowered:
            continue

        contextual = re.search(r"(?:code|enter(?: this)? code)[^A-Z0-9-]*([A-Z0-9]{4,}(?:-[A-Z0-9]{4,})+)", trimmed)
        if contextual:
            return contextual.group(1)

        short_code = re.search(r"(?:code|enter(?: this)? code)[^A-Z0-9-]*([A-Z0-9]{6,8})\b", trimmed)
        if short_code:
            return short_code.group(1)

    return None


def claude_credentials_present() -> bool:
    return (HOME_DIR / ".claude" / ".credentials.json").exists() or (HOME_DIR / ".claude.json").exists()


def codex_credentials_present() -> bool:
    return (HOME_DIR / ".codex" / "auth.json").exists()


def get_claude_snapshot() -> dict[str, Any]:
    try:
        result = subprocess.run(
            ["claude", "auth", "status", "--json"],
            capture_output=True,
            cwd=HOME_DIR,
            encoding="utf-8",
            env=claude_env(),
            check=False,
        )
    except FileNotFoundError:
        return {
            "apiProvider": None,
            "authMethod": None,
            "email": None,
            "loggedIn": claude_credentials_present(),
            "organizationId": None,
            "organizationName": None,
            "subscriptionType": None,
        }

    raw = (result.stdout or "").strip()
    if not raw:
        return {
            "apiProvider": None,
            "authMethod": None,
            "email": None,
            "loggedIn": claude_credentials_present(),
            "organizationId": None,
            "organizationName": None,
            "subscriptionType": None,
        }

    try:
        parsed = json.loads(raw)
    except Exception:
        return {
            "apiProvider": None,
            "authMethod": None,
            "email": None,
            "loggedIn": claude_credentials_present(),
            "organizationId": None,
            "organizationName": None,
            "subscriptionType": None,
        }

    return {
        "apiProvider": optional_string(parsed.get("apiProvider")),
        "authMethod": optional_string(parsed.get("authMethod")),
        "email": optional_string(parsed.get("email")),
        "loggedIn": parsed.get("loggedIn") is True,
        "organizationId": optional_string(parsed.get("orgId")),
        "organizationName": optional_string(parsed.get("orgName")),
        "subscriptionType": optional_string(parsed.get("subscriptionType")),
    }


def exchange_claude_authorization_code(authorization_code: str, code_verifier: str, state: str) -> dict[str, Any]:
    payload = json.dumps(
        {
            "client_id": ANTHROPIC_OAUTH_CLIENT_ID,
            "code": authorization_code,
            "code_verifier": code_verifier,
            "grant_type": "authorization_code",
            "redirect_uri": ANTHROPIC_OAUTH_MANUAL_REDIRECT_URL,
            "state": state,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        ANTHROPIC_OAUTH_TOKEN_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(request) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="ignore").strip()
        if body:
            raise RuntimeError(f"Claude token exchange failed ({error.code}): {body}") from error
        raise RuntimeError(f"Claude token exchange failed ({error.code}).") from error


def install_claude_refresh_token(refresh_token: str, scopes: list[str]) -> None:
    env = claude_env()
    env.update(
        {
            "CLAUDE_CODE_OAUTH_REFRESH_TOKEN": refresh_token,
            "CLAUDE_CODE_OAUTH_SCOPES": " ".join(scopes),
        }
    )

    result = subprocess.run(
        ["claude", "auth", "login"],
        capture_output=True,
        cwd=HOME_DIR,
        encoding="utf-8",
        env=env,
        check=False,
    )

    if result.returncode == 0:
        return

    detail = "\n".join(
        [part for part in [(result.stderr or "").strip(), (result.stdout or "").strip()] if part]
    ).strip()
    if detail:
        raise RuntimeError(f"Claude credential install failed: {detail}")
    raise RuntimeError(f"Claude credential install failed with code {result.returncode}.")


def serialize_claude_idle(snapshot: dict[str, Any]) -> dict[str, Any]:
    auth_detected = bool(snapshot["loggedIn"])
    return {
        "apiProvider": snapshot["apiProvider"],
        "authDetected": auth_detected,
        "authMethod": snapshot["authMethod"],
        "codeRequired": not auth_detected,
        "completedAt": None,
        "createdAt": None,
        "email": snapshot["email"],
        "error": None,
        "organizationId": snapshot["organizationId"],
        "organizationName": snapshot["organizationName"],
        "sessionId": None,
        "status": "complete" if auth_detected else "idle",
        "subscriptionType": snapshot["subscriptionType"],
        "updatedAt": None,
        "verificationUrl": None,
    }


def serialize_claude_session(session: dict[str, Any]) -> dict[str, Any]:
    snapshot = session.get("snapshot") or {}
    return {
        "apiProvider": snapshot.get("apiProvider"),
        "authDetected": bool(session.get("authDetected")),
        "authMethod": snapshot.get("authMethod"),
        "codeRequired": not bool(session.get("authDetected")),
        "completedAt": session.get("completedAt"),
        "createdAt": session.get("createdAt"),
        "email": snapshot.get("email"),
        "error": session.get("error"),
        "organizationId": snapshot.get("organizationId"),
        "organizationName": snapshot.get("organizationName"),
        "sessionId": session.get("id"),
        "status": session.get("status", "idle"),
        "subscriptionType": snapshot.get("subscriptionType"),
        "updatedAt": session.get("updatedAt"),
        "verificationUrl": session.get("verificationUrl"),
    }


def refresh_claude_session(session: dict[str, Any]) -> None:
    snapshot = get_claude_snapshot()
    auth_detected = bool(snapshot["loggedIn"]) or claude_credentials_present()
    session["snapshot"] = snapshot
    session["authDetected"] = auth_detected

    if auth_detected and session.get("status") != "canceled":
        session["status"] = "complete"
        if not session.get("completedAt"):
            session["completedAt"] = now_iso()
    elif session.get("status") == "starting" and session.get("verificationUrl"):
        session["status"] = "waiting"

    session["updatedAt"] = now_iso()


def get_claude_state() -> dict[str, Any]:
    ensure_state_dir()
    snapshot = get_claude_snapshot()
    auth_detected = bool(snapshot["loggedIn"]) or claude_credentials_present()
    snapshot["loggedIn"] = auth_detected

    session = read_json(session_path("claude"))
    if not session:
        return serialize_claude_idle(snapshot)

    refresh_claude_session(session)
    write_json(session_path("claude"), session)
    return serialize_claude_session(session)


def start_claude_auth() -> dict[str, Any]:
    ensure_state_dir()
    snapshot = get_claude_snapshot()
    auth_detected = bool(snapshot["loggedIn"]) or claude_credentials_present()
    if auth_detected:
        return serialize_claude_idle({**snapshot, "loggedIn": True})

    session = read_json(session_path("claude"))
    if session:
        refresh_claude_session(session)
        if session.get("status") in {"starting", "waiting"}:
            write_json(session_path("claude"), session)
            return serialize_claude_session(session)

    code_verifier = generate_code_verifier()
    oauth_state = generate_oauth_state()
    created_at = now_iso()
    session = {
        "authDetected": False,
        "codeVerifier": code_verifier,
        "completedAt": None,
        "createdAt": created_at,
        "error": None,
        "id": token_urlsafe(16),
        "killedByOperator": False,
        "oauthState": oauth_state,
        "snapshot": snapshot,
        "status": "waiting",
        "updatedAt": created_at,
        "verificationUrl": build_claude_verification_url(code_verifier, oauth_state),
    }
    write_json(session_path("claude"), session)
    return serialize_claude_session(session)


def submit_claude_auth(value: str) -> dict[str, Any]:
    session = read_json(session_path("claude"))
    if not session:
        return serialize_claude_idle(get_claude_snapshot())

    refresh_claude_session(session)
    payload = parse_claude_callback(value)
    if not payload:
        raise RuntimeError("Paste the Claude callback URL or the full code#state value.")

    if session.get("status") not in {"starting", "waiting"}:
        raise RuntimeError("Claude sign-in is not waiting for an authentication code.")

    if payload["state"] != session.get("oauthState"):
        session["error"] = "This Claude callback belongs to a different sign-in attempt. Start Claude sign-in again."
        session["updatedAt"] = now_iso()
        write_json(session_path("claude"), session)
        raise RuntimeError(session["error"])

    session["error"] = None
    session["status"] = "starting"
    session["updatedAt"] = now_iso()
    write_json(session_path("claude"), session)

    try:
        token_response = exchange_claude_authorization_code(
            payload["code"], session["codeVerifier"], session["oauthState"]
        )
        refresh_token = optional_string(token_response.get("refresh_token"))
        if not refresh_token:
            raise RuntimeError("Claude token exchange did not return a refresh token.")

        scopes = parse_scope_list(token_response.get("scope")) or ANTHROPIC_OAUTH_SCOPES
        install_claude_refresh_token(refresh_token, scopes)

        refresh_claude_session(session)
        if not session.get("authDetected"):
            raise RuntimeError("Claude login finished without persisted subscription credentials.")
    except Exception as error:
        session["error"] = str(error)
        session["status"] = "failed"
        session["updatedAt"] = now_iso()
        write_json(session_path("claude"), session)
        raise

    session["error"] = None
    session["status"] = "complete"
    if not session.get("completedAt"):
        session["completedAt"] = now_iso()
    session["updatedAt"] = now_iso()
    write_json(session_path("claude"), session)
    return serialize_claude_session(session)


def cancel_claude_auth() -> dict[str, Any]:
    snapshot = get_claude_snapshot()
    session = read_json(session_path("claude"))
    if not session:
        return serialize_claude_idle(snapshot)

    session["killedByOperator"] = True
    session["status"] = "canceled"
    session["updatedAt"] = now_iso()
    session["snapshot"] = snapshot
    session["authDetected"] = bool(snapshot["loggedIn"]) or claude_credentials_present()
    write_json(session_path("claude"), session)
    return serialize_claude_session(session)


def serialize_codex_idle(auth_detected: bool) -> dict[str, Any]:
    return {
        "authDetected": auth_detected,
        "completedAt": None,
        "createdAt": None,
        "error": None,
        "expiresAt": None,
        "sessionId": None,
        "status": "complete" if auth_detected else "idle",
        "updatedAt": None,
        "userCode": None,
        "verificationUrl": None,
    }


def serialize_codex_session(session: dict[str, Any]) -> dict[str, Any]:
    return {
        "authDetected": bool(session.get("authDetected")),
        "completedAt": session.get("completedAt"),
        "createdAt": session.get("createdAt"),
        "error": session.get("error"),
        "expiresAt": session.get("expiresAt"),
        "sessionId": session.get("id"),
        "status": session.get("status", "idle"),
        "updatedAt": session.get("updatedAt"),
        "userCode": session.get("userCode"),
        "verificationUrl": session.get("verificationUrl") or DEVICE_AUTH_URL,
    }


def refresh_codex_session(session: dict[str, Any]) -> None:
    combined = "\n".join(
        [part for part in [read_log(stdout_path("codex")).strip(), read_log(stderr_path("codex")).strip()] if part]
    )
    auth_detected = codex_credentials_present()
    session["authDetected"] = auth_detected

    if not session.get("verificationUrl"):
        session["verificationUrl"] = extract_verification_url(combined) or DEVICE_AUTH_URL
    if not session.get("userCode"):
        session["userCode"] = extract_codex_user_code(combined)

    exit_file = exit_path("codex")
    exit_code = None
    if exit_file.exists():
        raw_exit = exit_file.read_text(encoding="utf-8", errors="ignore").strip()
        if raw_exit:
            try:
                exit_code = int(raw_exit)
            except ValueError:
                exit_code = None

    running = process_running(session.get("pid"))

    if auth_detected and session.get("status") != "canceled":
        session["status"] = "complete"
        if not session.get("completedAt"):
            session["completedAt"] = now_iso()
    elif session.get("status") == "starting" and (session.get("verificationUrl") or session.get("userCode")):
        session["status"] = "waiting"
    elif session.get("status") != "canceled":
        if exit_code is not None:
            session["status"] = "failed"
            if not session.get("error"):
                detail = last_error_detail("codex")
                session["error"] = detail or f"Codex sign-in exited with code {exit_code}."
        elif not running and session.get("status") in {"starting", "waiting"}:
            session["status"] = "failed"
            if not session.get("error"):
                detail = last_error_detail("codex")
                session["error"] = detail or "Codex sign-in stopped before authentication completed."

    session["updatedAt"] = now_iso()


def get_codex_state() -> dict[str, Any]:
    ensure_state_dir()
    auth_detected = codex_credentials_present()
    session = read_json(session_path("codex"))
    if not session:
        return serialize_codex_idle(auth_detected)

    refresh_codex_session(session)
    write_json(session_path("codex"), session)
    return serialize_codex_session(session)


def start_codex_auth() -> dict[str, Any]:
    ensure_state_dir()
    if codex_credentials_present():
        return serialize_codex_idle(True)

    session = read_json(session_path("codex"))
    if session:
        refresh_codex_session(session)
        if session.get("status") in {"starting", "waiting"}:
            write_json(session_path("codex"), session)
            return serialize_codex_session(session)

    remove_artifacts("codex")
    created_at = now_iso()
    expires_at = (datetime.now(UTC) + timedelta(seconds=DEVICE_CODE_TTL_SECONDS)).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    session = {
        "authDetected": False,
        "completedAt": None,
        "createdAt": created_at,
        "error": None,
        "expiresAt": expires_at,
        "id": token_urlsafe(16),
        "killedByOperator": False,
        "pid": None,
        "status": "starting",
        "updatedAt": created_at,
        "userCode": None,
        "verificationUrl": DEVICE_AUTH_URL,
    }

    stdout_q = shlex.quote(str(stdout_path("codex")))
    stderr_q = shlex.quote(str(stderr_path("codex")))
    exit_q = shlex.quote(str(exit_path("codex")))
    root_q = shlex.quote(str(ROOT))
    command = (
        f"cd {root_q} && "
        f"export HOME={shlex.quote(str(HOME_DIR))} USERPROFILE={shlex.quote(str(HOME_DIR))} "
        f"NO_COLOR=1 FORCE_COLOR=0 TERM=dumb CODEX_HOME={shlex.quote(str(HOME_DIR / '.codex'))} && "
        f"codex login --device-auth > {stdout_q} 2> {stderr_q}; "
        f"printf '%s' \"$?\" > {exit_q}"
    )
    process = subprocess.Popen(
        ["bash", "-lc", command],
        cwd=ROOT,
        env=codex_env(),
        start_new_session=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    session["pid"] = process.pid
    write_json(session_path("codex"), session)

    for _ in range(10):
        time.sleep(0.2)
        refresh_codex_session(session)
        if session.get("userCode") or session.get("verificationUrl") or session.get("authDetected"):
            break

    write_json(session_path("codex"), session)
    return serialize_codex_session(session)


def cancel_codex_auth() -> dict[str, Any]:
    auth_detected = codex_credentials_present()
    session = read_json(session_path("codex"))
    if not session:
        return serialize_codex_idle(auth_detected)

    session["killedByOperator"] = True
    session["status"] = "canceled"
    session["updatedAt"] = now_iso()
    kill_process_group(session.get("pid"))
    write_json(session_path("codex"), session)
    return serialize_codex_session(session)


def read_payload() -> dict[str, Any]:
    raw = sys.stdin.read().strip()
    if not raw:
        return {}
    return json.loads(raw)


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit("Usage: provider-auth.py <status|start|submit|cancel> <claude|codex>")

    action = sys.argv[1].strip()
    provider = sys.argv[2].strip()
    if provider not in {"claude", "codex"}:
        raise SystemExit("Provider must be claude or codex")

    payload = read_payload()

    if action == "status":
        result = get_claude_state() if provider == "claude" else get_codex_state()
    elif action == "start":
        result = start_claude_auth() if provider == "claude" else start_codex_auth()
    elif action == "submit":
        if provider != "claude":
            raise SystemExit("Only Claude accepts a submitted auth code")
        result = submit_claude_auth(str(payload.get("value") or payload.get("code") or ""))
    elif action == "cancel":
        result = cancel_claude_auth() if provider == "claude" else cancel_codex_auth()
    else:
        raise SystemExit("Unknown action")

    print(json.dumps(result))


if __name__ == "__main__":
    main()
