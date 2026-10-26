#!/usr/bin/env python3
"""Bounded Codex control; retries only explicitly authorized failed turns."""

import base64
import hashlib
import json
import os
import socket
import struct
import sys
import time
from pathlib import Path

MAX_FRAME = 2 * 1024 * 1024
MAX_TRAFFIC = 8 * 1024 * 1024


class ControlError(Exception):
    pass


class CodexRpc:
    def __init__(self, home, deadline=None):
        self.deadline = deadline or time.monotonic() + 12
        self.serial = 0
        self.traffic = 0
        self.sock = socket.socket(socket.AF_UNIX)
        self.buffer = bytearray()
        try:
            self.sock.settimeout(self.remaining())
            self.sock.connect(str(home / "app-server-control/app-server-control.sock"))
            key = base64.b64encode(os.urandom(16)).decode()
            self.sock.sendall((
                "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                "Sec-WebSocket-Version: 13\r\n\r\n"
            ).encode())
            while b"\r\n\r\n" not in self.buffer:
                if len(self.buffer) > 8192:
                    raise ControlError("Invalid Codex connection handshake.")
                self.receive()
            header, rest = self.buffer.split(b"\r\n\r\n", 1)
            self.buffer = bytearray(rest)
            lines = header.decode("ascii").split("\r\n")
            headers = {line.split(":", 1)[0].lower(): line.split(":", 1)[1].strip()
                       for line in lines[1:] if ":" in line}
            expected = base64.b64encode(hashlib.sha1(
                (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
            ).digest()).decode()
            if (lines[0].split()[1] != "101" or
                    headers.get("sec-websocket-accept") != expected or
                    headers.get("upgrade", "").lower() != "websocket" or
                    "upgrade" not in headers.get("connection", "").lower().split(", ")):
                raise ControlError("Codex daemon rejected the local connection.")
            self.request("initialize", {
                "clientInfo": {"name": "context_session_control", "version": "1"},
                "capabilities": {"experimentalApi": True},
            })
            self.send({"method": "initialized", "params": {}})
        except Exception:
            self.close()
            raise

    def remaining(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise ControlError("Codex control timed out.")
        return remaining

    def receive(self):
        self.sock.settimeout(self.remaining())
        data = self.sock.recv(65536)
        self.traffic += len(data)
        if not data or self.traffic > MAX_TRAFFIC:
            raise ControlError("Codex connection closed or exceeded its read limit.")
        self.buffer.extend(data)

    def take(self, count):
        while len(self.buffer) < count:
            self.receive()
        value = bytes(self.buffer[:count])
        del self.buffer[:count]
        return value

    def frame(self, payload, opcode=1):
        self.sock.settimeout(self.remaining())
        mask = os.urandom(4)
        size = len(payload)
        length = bytes([size | 128]) if size < 126 else (
            bytes([254]) + struct.pack("!H", size) if size <= 65535 else
            bytes([255]) + struct.pack("!Q", size)
        )
        encoded = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        self.sock.sendall(bytes([128 | opcode]) + length + mask + encoded)

    def send(self, message):
        self.frame(json.dumps(message, separators=(",", ":")).encode())

    def message(self):
        message = bytearray()
        fragmented = False
        for _ in range(1024):
            first, second = self.take(2)
            opcode, final = first & 15, bool(first & 128)
            size = second & 127
            if size == 126:
                size = struct.unpack("!H", self.take(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", self.take(8))[0]
            if first & 112 or second & 128 or size > MAX_FRAME:
                raise ControlError("Unsupported Codex WebSocket frame.")
            payload = self.take(size)
            if opcode >= 8:
                if not final or size > 125 or opcode not in (8, 9, 10):
                    raise ControlError("Invalid Codex WebSocket control frame.")
                if opcode == 8:
                    raise ControlError("Codex daemon disconnected.")
                if opcode == 9:
                    self.frame(payload, 10)
                continue
            if opcode not in (0, 1) or (opcode == 0) != fragmented:
                raise ControlError("Invalid Codex WebSocket message.")
            message.extend(payload)
            if len(message) > MAX_FRAME:
                raise ControlError("Codex response exceeded its size limit.")
            if final:
                return json.loads(message)
            fragmented = True
        raise ControlError("Codex response exceeded its frame limit.")

    def request(self, method, params):
        self.serial += 1
        request_id = self.serial
        self.send({"id": request_id, "method": method, "params": params})
        for _ in range(512):
            response = self.message()
            if response.get("id") != request_id:
                # Notifications and server requests are not acted on. This client
                # never subscribes to a thread or takes over its approval handling.
                continue
            if "error" in response:
                raise ControlError(f"Codex rejected {method}.")
            if "result" not in response:
                raise ControlError("Invalid Codex response.")
            return response["result"]
        raise ControlError("Codex response exceeded its message limit.")

    def close(self):
        self.sock.close()


def catalog(rpc):
    models, cursor = [], None
    for _ in range(4):
        result = rpc.request("model/list", {"limit": 100, "cursor": cursor})
        for model in result["data"]:
            if model.get("hidden"):
                continue
            models.append({
                "id": model["model"],
                "name": model.get("displayName", model["model"]),
                "efforts": [entry["reasoningEffort"] for entry in model["supportedReasoningEfforts"]],
                "default_effort": model["defaultReasoningEffort"],
            })
        cursor = result.get("nextCursor")
        if not cursor:
            return models
    raise ControlError("Codex model catalog exceeded its limit.")


def apply(rpc, model, effort, sessions, live_client=None):
    available = catalog(rpc)
    if not any(entry["id"] == model and effort in entry["efforts"] for entry in available):
        raise ControlError("The selected model/thinking level is no longer available. Re-arm with another choice.")
    loaded, cursor = set(), None
    for _ in range(4):
        result = rpc.request("thread/loaded/list", {"limit": 100, "cursor": cursor})
        loaded.update(result["data"])
        cursor = result.get("nextCursor")
        if not cursor:
            break
    else:
        raise ControlError("Loaded Codex sessions exceeded their limit.")
    updated, skipped, failed = [], [], []
    busy = []
    seen = set()
    for session in sessions:
        thread_id = session.get("launch_session_id")
        if session.get("unsupported_home"):
            skipped.append(thread_id or "unknown")
            continue
        if not thread_id or thread_id not in loaded:
            skipped.append(thread_id or "unknown")
            continue
        if thread_id in seen:
            continue
        seen.add(thread_id)
        try:
            thread = rpc.request("thread/read", {"threadId": thread_id, "includeTurns": False})["thread"]
            if thread.get("parentThreadId"):
                skipped.append(thread_id)
                continue
            # Null explicitly clears Fast/Ultrafast. Omission would preserve it.
            rpc.request("thread/settings/update", {
                "threadId": thread_id, "model": model, "effort": effort, "serviceTier": None,
            })
            if thread.get("status", {}).get("type") == "active":
                busy.append(thread_id)
            updated.append(thread_id)
        except (ControlError, OSError, ValueError):
            failed.append(thread_id)
    result = {"updated": updated, "skipped": skipped, "failed": failed}
    # Save settings for every tab before any potentially slow legacy turn lookup.
    # Separate bounded connections prevent a stuck lookup starving later tabs.
    if busy:
        result.update(live_updated=[], live_failed=[])
    for thread_id in busy:
        live = None
        try:
            live = live_client() if live_client else rpc
            turns = live.request("thread/turns/list", {
                "threadId": thread_id, "limit": 1,
                "sortDirection": "desc", "itemsView": "notLoaded",
            })["data"]
            if turns and turns[0].get("status") == "inProgress":
                try:
                    live.request("turn/settings/update", {
                        "threadId": thread_id, "turnId": turns[0]["id"],
                        "model": model, "effort": effort, "serviceTier": None,
                    })
                except ControlError:
                    # A completed turn no longer needs an active-turn override.
                    latest = live.request("thread/read", {
                        "threadId": thread_id, "includeTurns": False,
                    })["thread"]
                    if latest.get("status", {}).get("type") == "active":
                        raise
            result["live_updated"].append(thread_id)
        except (ControlError, OSError, ValueError):
            result["live_failed"].append(thread_id)
        finally:
            if live is not None and live is not rpc:
                live.close()
    return result


RETRY_TEXT = ("Continue only the unfinished work from the last failed turn. "
              "Do not repeat completed actions.")


def retry_kind(error):
    info = error.get("codexErrorInfo")
    code = info if isinstance(info, str) else next(iter(info or {}), "")
    message = " ".join(str(error.get("message", "")).split()).casefold()
    if code in ("", "other") and message == (
            "selected model is at capacity. please try a different model."):
        return "temporary"
    if code in ("usageLimitExceeded", "rateLimitExceeded"):
        return "usage"
    if code in ("serverOverloaded", "flexUnavailable", "internalServerError"):
        return "temporary"
    if code in ("httpConnectionFailed", "responseStreamConnectionFailed",
                "responseStreamDisconnected", "responseTooManyFailedAttempts"):
        status = info[code].get("httpStatusCode")
        if status == 429:
            return "usage"
        if status is None or status in (408, 500, 502, 503, 504):
            return "temporary"
    return "attention"


def recovery_state(rpc, thread_id):
    thread = rpc.request("thread/read", {
        "threadId": thread_id, "includeTurns": False,
    })["thread"]
    if (thread.get("parentThreadId") or thread.get("canAcceptDirectInput") is False or
            thread.get("status", {}).get("type") != "idle"):
        return {"state": "untouched"}
    turns = rpc.request("thread/turns/list", {
        "threadId": thread_id, "limit": 1,
        "sortDirection": "desc", "itemsView": "notLoaded",
    })["data"]
    if not turns or turns[0].get("status") != "failed" or not turns[0].get("error"):
        return {"state": "untouched"}
    turn = turns[0]
    kind = retry_kind(turn["error"])
    if kind == "attention":
        return {"state": "attention"}
    goal = rpc.request("thread/goal/get", {"threadId": thread_id}).get("goal")
    if goal is not None and goal.get("status") != "active":
        return {"state": "attention"}
    if kind == "usage":
        limits = rpc.request("account/rateLimits/read", {})
        # Never infer recovery from cached percentages or an elapsed reset date.
        if limits.get("ordinaryUsageAllowed") is not True:
            return {"state": "waiting_usage"}
        snapshots = [limits.get("rateLimits", {})]
        snapshots.extend((limits.get("rateLimitsByLimitId") or {}).values())
        for snapshot in snapshots:
            reached = snapshot.get("rateLimitReachedType")
            if snapshot.get("spendControlReached") or reached not in (None, "rate_limit_reached"):
                return {"state": "attention"}
            if snapshot.get("normalModelSlug") == thread.get("model") or snapshot.get("limitId") == thread.get("model"):
                if any((snapshot.get(w) or {}).get("usedPercent", 0) >= 100
                       for w in ("primary", "secondary")):
                    return {"state": "waiting_usage"}
    return {"state": "retryable", "turn_id": turn["id"], "kind": kind}


def keep_alive(rpc, request, sessions):
    results = []
    for target in request["targets"]:
        thread_id = target["id"]
        matching = [s for s in sessions if s.get("launch_session_id") == thread_id]
        result = {"id": thread_id, "state": "unavailable"}
        if (len(matching) != 1 or matching[0].get("unsupported_home") or
                str(matching[0].get("pid")) != target["pid"] or
                str(matching[0].get("start")) != target["start"]):
            results.append(result)
            continue
        try:
            state = recovery_state(rpc, thread_id)
            result.update(state)
            if request["action"] == "recover" and state.get("state") == "retryable":
                if state["turn_id"] != target["turn_id"]:
                    result["state"] = "changed"
                else:
                    # Recheck after the quota/goal lookups. The protocol has no
                    # atomic idle-only turn/start; never interrupt or type keys.
                    latest = rpc.request("thread/read", {
                        "threadId": thread_id, "includeTurns": False,
                    })["thread"]
                    turns = rpc.request("thread/turns/list", {
                        "threadId": thread_id, "limit": 1,
                        "sortDirection": "desc", "itemsView": "notLoaded",
                    })["data"]
                    if (latest.get("status", {}).get("type") != "idle" or not turns or
                            turns[0].get("id") != target["turn_id"] or
                            turns[0].get("status") != "failed"):
                        result["state"] = "changed"
                    else:
                        rpc.request("turn/start", {
                            "threadId": thread_id,
                            "input": [{"type": "text", "text": RETRY_TEXT}],
                        })
                        result["state"] = "retried"
        except (ControlError, OSError, ValueError, KeyError, TypeError):
            # A lost reply may mean the request was accepted. The UI persists
            # its failed-turn claim before dispatch and never replays that ID.
            result["state"] = "unavailable"
        results.append(result)
    return {"sessions": results}


def run(request, probe_source):
    home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    rpc = CodexRpc(home)
    try:
        if request.get("action") == "models":
            return {"models": catalog(rpc)}
        if request.get("action") not in ("apply", "status", "recover"):
            raise ControlError("Unknown Codex control action.")
        probe = {"__name__": "context_terminal_probe"}
        exec(probe_source, probe)
        sessions, warnings = probe["process_sessions"]()
        if any(not warning.startswith("Session names unavailable:") for warning in warnings):
            raise ControlError("Terminal inventory is incomplete. Nothing was changed.")
        sessions = [session for session in sessions if session["provider"] == "codex"]
        for session in sessions:
            if Path(session.get("codex_home", home)).resolve() != home.resolve():
                session["unsupported_home"] = True
        if len(sessions) > 64:
            raise ControlError("Too many active Codex tabs. No settings were changed.")
        result = (apply(rpc, request["model"], request["effort"], sessions,
                        lambda: CodexRpc(home, min(rpc.deadline, time.monotonic() + 3)))
                  if request["action"] == "apply" else keep_alive(rpc, request, sessions))
        result["warnings"] = warnings[:8]
        return result
    finally:
        rpc.close()


if __name__ == "__main__":
    try:
        # PROBE_SOURCE is embedded by the native launcher, never user code.
        print(json.dumps(run(json.loads(sys.argv[1]), PROBE_SOURCE)))
    except (ControlError, OSError, ValueError, KeyError) as error:
        print(json.dumps({"error": str(error) if isinstance(error, ControlError) else
                          "Could not connect to the running Codex daemon. No Terminal input was sent."}))
