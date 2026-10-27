#!/usr/bin/env python3
"""Read Claude's subscription quota; change only explicitly requested defaults."""

import hashlib
import http.client
import json
import math
import os
import stat
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path

LIMIT = 1024 * 1024
# Explicit model versions avoid aliases silently resolving to another effort
# profile. These current Claude Code models support persisted per-model effort.
MODELS = ("claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5-5")
EFFORTS = ("low", "medium", "high", "xhigh")


class AccountError(Exception):
    pass


def read_json(path, optional=False, with_bytes=False):
    try:
        with path.open("rb") as stream:
            data = stream.read(LIMIT + 1)
    except FileNotFoundError:
        if optional:
            return ({}, None) if with_bytes else {}
        raise AccountError("Sign in to Claude Code with `claude auth login` first.") from None
    if len(data) > LIMIT:
        raise AccountError("Claude configuration exceeds the read limit.")
    value = json.loads(data)
    if not isinstance(value, dict):
        raise AccountError("Invalid Claude configuration.")
    return (value, data) if with_bytes else value


def identity(home, directory):
    # Claude keeps its login metadata separately from its secret OAuth tokens.
    config = read_json(home / ".claude.json", optional=True)
    account = config.get("oauthAccount") or {}
    if not isinstance(account, dict):
        raise AccountError("Claude account identity is unavailable.")
    email = str(account.get("emailAddress") or "").strip()[:256]
    account_id = str(account.get("accountUuid") or email).strip()
    organization = str(account.get("organizationUuid") or "").strip()
    if not account_id:
        raise AccountError("Claude account identity is unavailable. Run `claude auth login`.")
    key = hashlib.sha256((account_id + "\0" + organization).encode()).hexdigest()
    return {"slot": key, "name": email or "Claude account", "account_key": key}


def period(value):
    if value is None:
        return None
    if not isinstance(value, dict):
        raise AccountError("Claude returned an invalid quota window.")
    used = value.get("utilization")
    reset = value.get("resets_at")
    if isinstance(used, bool) or not isinstance(used, (int, float)) or not math.isfinite(used) or not 0 <= used <= 100:
        raise AccountError("Claude returned an invalid quota percentage.")
    if reset is None:
        return None
    try:
        parsed = datetime.fromisoformat(str(reset).replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError()
        reset_ms = round(parsed.timestamp() * 1000)
    except (ValueError, OverflowError):
        raise AccountError("Claude returned an invalid reset time.") from None
    return {"used_percent": used, "reset_at": reset_ms}


def fetch_usage(token):
    # Metadata only: no messages, inference, API-key fallback or redirects.
    connection = http.client.HTTPSConnection("api.anthropic.com", timeout=8)
    try:
        connection.request("GET", "/api/oauth/usage", headers={
            "Authorization": "Bearer " + token,
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            "User-Agent": "Context/1 (local Claude quota monitor)",
        })
        response = connection.getresponse()
        if response.status == 429:
            raise AccountError("Claude usage is rate-limited. Try again in a few minutes.")
        if response.status in (401, 403):
            raise AccountError("Claude rejected this login. Let Claude refresh it or run `claude auth login`.")
        if response.status != 200:
            raise AccountError("Claude usage is temporarily unavailable (HTTP %d)." % response.status)
        data = response.read(LIMIT + 1)
        if len(data) > LIMIT:
            raise AccountError("Claude usage response exceeds the read limit.")
        value = json.loads(data)
        if not isinstance(value, dict):
            raise AccountError("Invalid Claude usage response.")
        return value
    finally:
        connection.close()


def quota(home, directory, info, fetch):
    credentials = read_json(directory / ".credentials.json")
    oauth = credentials.get("claudeAiOauth")
    if not isinstance(oauth, dict) or not isinstance(oauth.get("accessToken"), str):
        raise AccountError("Claude subscription login not found. API-key billing has no subscription quota.")
    token = oauth["accessToken"]
    if not token or len(token) > 16384 or any(ord(c) < 33 or ord(c) > 126 for c in token):
        raise AccountError("Invalid Claude login credential.")
    usage = fetch(token)
    # Reject a login change while the HTTP request was outstanding.
    if identity(home, directory)["account_key"] != info["account_key"]:
        raise AccountError("Claude account changed during refresh. Refresh again.")
    info.update({
        "tier": str(oauth.get("subscriptionType") or "Claude subscription")[:100],
        "weekly": period(usage.get("seven_day")),
        "five_hour": period(usage.get("five_hour")),
        "observed_at": round(time.time() * 1000),
    })
    if info["weekly"] is None and info["five_hour"] is None:
        raise AccountError("Claude did not report subscription quota windows for this login.")
    return info


def account(home, directory, fetch=fetch_usage):
    info = identity(home, directory)
    try:
        info = quota(home, directory, info, fetch)
    except Exception as error:
        # Return the current identity even on failure, so the UI cannot attach
        # another login's cached quota to it. Secrets never leave this process.
        info = identity(home, directory)
        info["usage_error"] = str(error) if isinstance(error, AccountError) else "Claude usage is temporarily unavailable. Check the login and connection."
    return {"accounts": [info]}


def apply_defaults(home, directory, request):
    if request.get("model") not in MODELS or request.get("effort") not in EFFORTS:
        raise AccountError("Unsupported Claude model or effort.")
    if identity(home, directory)["account_key"] != request.get("account_key"):
        raise AccountError("Claude login changed. Re-arm downgrade for the current account.")
    path = directory / "settings.json"
    if path.is_symlink() or directory.is_symlink():
        raise AccountError("Claude settings must not be a symbolic link.")
    settings, before = read_json(path, optional=True, with_bytes=True)
    settings.update(model=request["model"], fastMode=False)
    # Preserve per-model effort choices while overriding the selected alias too.
    per_model = settings.setdefault("modelSettings", {})
    if not isinstance(per_model, dict):
        raise AccountError("Invalid per-model Claude settings; no settings were replaced.")
    selected = per_model.get(request["model"], {})
    if not isinstance(selected, dict):
        raise AccountError("Invalid per-model Claude settings; no settings were replaced.")
    per_model[request["model"]] = {**selected, "effortLevel": request["effort"]}
    descriptor, temporary = tempfile.mkstemp(prefix=".context-settings-", dir=directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(settings, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600)
        if (path.read_bytes() if path.exists() else None) != before:
            raise AccountError("Claude settings changed concurrently. No defaults were replaced.")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return {"defaults_saved": True, "commands": [
        "/model " + request["model"], "/effort " + request["effort"], "/fast off",
    ]}


def main(request, home=None):
    home = Path.home() if home is None else Path(home)
    directory = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(home / ".claude"))).expanduser()
    action = request.get("action")
    if action == "account":
        return account(home, directory)
    if action == "models":
        return {"models": [{"id": model, "name": model.removeprefix("claude-").replace("-5-5", " 5.5").title(), "efforts": list(EFFORTS),
                            "default_effort": "high"} for model in MODELS]}
    if action == "apply":
        return apply_defaults(home, directory, request)
    raise AccountError("Unsupported Claude account action.")


if __name__ == "__main__":
    try:
        raw = sys.argv[1]
        if len(raw) > 32768:
            raise AccountError("Claude account request exceeds its limit.")
        print(json.dumps(main(json.loads(raw)), separators=(",", ":")))
    except AccountError as error:
        print(json.dumps({"error": str(error)}))
    except Exception:
        # Network and parser exceptions can contain credential/request details.
        print(json.dumps({"error": "Could not read Claude account data. Check the login and connection."}))
