#!/usr/bin/env python3
"""One-shot, read-only Windows Terminal + Ubuntu Codex session prototype.

Run in WSL: python3 scripts/probe-terminal-sessions.py [--json]
No dependencies beyond Python, Windows PowerShell and UI Automation.
No terminal input, focus changes, auth reads, transcript reads or background loop.
"""

import argparse
import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

UUID = re.compile(r"^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$")
MAX_PROCESSES = 4096
MAX_INDEX_BYTES = 1024 * 1024


def bounded_read(path, limit):
    with path.open("rb") as handle:
        data = handle.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"Size limit exceeded: {path}")
    return data


def launched_session(argv):
    # Do not mistake an ID in a prompt, --last, or a fork's parent for the live ID.
    if "--fork" in argv or "--last" in argv:
        return None
    if len(argv) >= 3 and argv[1] == "resume" and UUID.fullmatch(argv[2]):
        return argv[2].lower()
    return None


def agent_command(argv):
    """Recognize only executable/entrypoint positions, never prompt contents."""
    aliases = {"codex": "codex", "kimi": "kimi", "opencode": "opencode",
               "qwen": "qwen", "muse": "muse", "zcode": "zcode", "claude": "claude"}
    if not argv:
        return None
    name = Path(argv[0]).name
    offset = 0
    if name in ("node", "nodejs", "bun", "python", "python3", "uv"):
        offset = 1
        if len(argv) > 2 and argv[1] == "-m" and argv[2] in ("kimi_cli", "kimi"):
            return "kimi", ["kimi", *argv[3:]]
    if len(argv) <= offset:
        return None
    entry = argv[offset]
    name = Path(entry).name.removesuffix(".js")
    provider = aliases.get(name)
    if provider is None and name in ("cli", "index"):
        for package, key in (("@anthropic-ai/claude-code", "claude"),
                             ("@qwen-code/qwen-code", "qwen")):
            if f"/{package}/" in entry:
                provider = key
    return (provider, [provider, *argv[offset + 1:]]) if provider else None


def provider_session(provider, argv):
    if provider == "codex":
        return launched_session(argv)
    if any(flag in argv for flag in ("--fork", "--fork-session", "--continue", "-c")):
        return None
    flags = {
        "claude": ("--resume", "-r", "--session-id"),
        "kimi": ("--session", "--resume", "-s", "-r"),
        "opencode": ("--session", "-s"),
        "qwen": ("--resume", "-r"),
        "muse": ("resume", "--resume", "--session-id", "--session", "-r", "-s"),
        "zcode": ("--session", "-s"),
    }.get(provider, ())
    for index, arg in enumerate(argv[1:], 1):
        flag, equal, value = arg.partition("=")
        if flag not in flags:
            continue
        value = value if equal else (argv[index + 1] if index + 1 < len(argv) else "")
        if provider == "opencode":
            return value if re.fullmatch(r"ses_[A-Za-z0-9]+", value) else None
        if provider in ("kimi", "muse", "zcode"):
            return value if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,199}", value) else None
        # Names accepted by some CLIs are not session IDs.
        return value if UUID.fullmatch(value) else None
    return None


def index_names(home, ids):
    """Read only a bounded tail of the session-name index, never rollouts."""
    names = {}
    path = home / "session_index.jsonl"
    with path.open("rb") as handle:
        size = os.fstat(handle.fileno()).st_size
        offset = max(0, size - MAX_INDEX_BYTES)
        handle.seek(offset)
        if offset:
            handle.readline(MAX_INDEX_BYTES)  # Discard the partial first line.
        data = handle.read(MAX_INDEX_BYTES)
    for line in data.splitlines():
        try:
            entry = json.loads(line)
        except (ValueError, UnicodeError):
            continue
        if not isinstance(entry, dict):
            continue
        name = entry.get("thread_name")
        if entry.get("id") in ids and isinstance(name, str):
            names[entry["id"]] = name
    return names


def process_sessions(proc=Path("/proc")):
    records, warnings = [], []
    uid = os.getuid()
    count = 0
    with os.scandir(proc) as entries:
        for entry in entries:
            if not entry.name.isdigit():
                continue
            count += 1
            if count > MAX_PROCESSES:
                warnings.append("Process limit reached; inventory is incomplete.")
                break
            root = Path(entry.path)
            try:
                if root.stat().st_uid != uid:
                    continue
                comm = bounded_read(root / "comm", 256).strip().decode(errors="replace")
                if comm not in ("codex", "claude", "kimi", "opencode", "qwen", "muse",
                                "zcode", "node", "MainThread", "bun", "python", "python3"):
                    continue
                stat = bounded_read(root / "stat", 8192).decode()
                fields = stat[stat.rfind(")") + 2:].split()
                # Fields 7 and 22: controlling terminal and process start time.
                if int(fields[4]) == 0:
                    continue  # Exclude detached workers/subagents.
                argv = bounded_read(root / "cmdline", 65536).decode(
                    errors="replace"
                ).rstrip("\0").split("\0")
                agent = agent_command(argv)
                if agent is None:
                    continue
                provider, command = agent
                session_id = provider_session(provider, command)
                allowed = {"WT_SESSION", "WSL_DISTRO_NAME", "CODEX_HOME"}
                env = {}
                for value in bounded_read(root / "environ", 262144).split(b"\0"):
                    key, _, data = value.partition(b"=")
                    key = key.decode(errors="replace")
                    if key in allowed:
                        env[key] = data.decode(errors="replace")
                if not env.get("WT_SESSION"):
                    continue
                cwd = os.readlink(root / "cwd")
                latest = bounded_read(root / "stat", 8192).decode()
                if latest[latest.rfind(")") + 2:].split()[19] != fields[19]:
                    continue  # PID reused during the snapshot.
                tty_number = int(fields[4])
                records.append({
                    "pid": int(entry.name),
                    "ppid": int(fields[1]),
                    "start": fields[19],
                    "tty": f"{os.major(tty_number)}:{os.minor(tty_number)}",
                    "provider": provider,
                    "distro": env.get("WSL_DISTRO_NAME"),
                    "terminal_session": env["WT_SESSION"],
                    "launch_session_id": session_id,
                    "session_evidence": "explicit resume argument" if session_id else "unknown",
                    "cwd": cwd,
                    "name": None,
                    "_home": env.get("CODEX_HOME") or str(Path.home() / ".codex"),
                })
            except (FileNotFoundError, ProcessLookupError):
                continue
            except (OSError, ValueError, IndexError) as error:
                warnings.append(f"PID {entry.name}: {error}")
    # Node/Python entrypoint wrappers and their native child describe one TUI.
    parents = {row["ppid"] for row in records}
    records = [row for row in records if row["pid"] not in parents]
    for home in {row["_home"] for row in records if row["provider"] == "codex"}:
        ids = {row["launch_session_id"] for row in records
               if row["_home"] == home and row["provider"] == "codex"}
        try:
            names = index_names(Path(home), ids)
        except (OSError, ValueError) as error:
            warnings.append(f"Session names unavailable: {error}")
            names = {}
        for row in records:
            if row["_home"] == home and row["provider"] == "codex":
                row["name"] = names.get(row["launch_session_id"])
    for row in records:
        if row["provider"] == "codex":
            row["codex_home"] = row["_home"]
        del row["_home"]
    return sorted(records, key=lambda row: row["pid"]), warnings


def title_matches(title, session):
    name = session.get("name")
    if not name:
        return False
    title = title.strip()
    folder = Path(session["cwd"]).name
    if " | " in title:
        title, suffix = title.rsplit(" | ", 1)
        if suffix != folder:
            return False
    # Codex can prefix status glyphs; never strip arbitrary leading words.
    if not title.endswith(name):
        return False
    prefix = title[:-len(name)]
    return not any(char.isalnum() for char in prefix)


def associate(windows, sessions):
    candidates = []
    for window in windows:
        for number, tab in enumerate(window.get("tabs", []), 1):
            matches = [s for s in sessions if title_matches(tab["title"], s)]
            candidates.append((window, number, tab, matches))
    rows = []
    for window, number, tab, matches in candidates:
        unique = len(matches) == 1 and sum(
            any(s["pid"] == matches[0]["pid"] for s in other)
            for _, _, _, other in candidates
        ) == 1
        rows.append({
            "window": window["hwnd"], "tab": number,
            "selected": tab["selected"], "title": tab["title"],
            "match": "unique title + directory" if unique else (
                "ambiguous" if matches else "unmatched"
            ),
            "session": matches[0] if unique else None,
            "candidate_pids": [s["pid"] for s in matches],
        })
    return rows


def snapshot():
    script = Path(__file__).with_name("probe-terminal-tabs.ps1").resolve()
    winpath = subprocess.run(
        ["wslpath", "-w", str(script)], capture_output=True, text=True,
        check=True, timeout=5,
    ).stdout.strip()
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy",
         "Bypass", "-File", winpath],
        capture_output=True, encoding="utf-8", errors="replace",
        check=True, timeout=15,
    )
    windows = json.loads(result.stdout.lstrip("\ufeff"))
    sessions, warnings = process_sessions()
    rows = associate(windows, sessions)
    matched = {row["session"]["pid"] for row in rows if row["session"]}
    return {
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "read_only": True,
        "limits": (
            "Known coding TUIs in this WSL distro only. IDs describe explicit launch/resume "
            "arguments, not a later in-app switch/fork. Tab associations use "
            "unique names, not a native tab-to-session API. Snapshots are not atomic."
        ),
        "windows": windows, "tabs": rows,
        "unmatched_sessions": [s for s in sessions if s["pid"] not in matched],
        "warnings": warnings,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="Full read-only snapshot")
    parser.add_argument("--processes-json", action="store_true",
                        help="WSL process inventory only, for Context's native bridge")
    args = parser.parse_args()
    if args.processes_json:
        sessions, warnings = process_sessions()
        print(json.dumps({"sessions": sessions, "warnings": warnings}))
        return
    try:
        data = snapshot()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Probe failed: {error}\n")
    if args.json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return
    for row in data["tabs"]:
        selected = "selected" if row["selected"] else "background"
        print(f'Tab {row["tab"]} [{selected}]: {row["title"]}')
        session = row["session"]
        if session:
            print(f'  {session["provider"]} session: {session["launch_session_id"]}')
            print(f'  {session["distro"]}, PID {session["pid"]}; {row["match"]}')
        else:
            print(f'  {row["match"]}; no session ID assumed')
    print(f'\n{len(data["tabs"])} tab(s); '
          f'{sum(bool(r["session"]) for r in data["tabs"])} matched.')
    for session in data["unmatched_sessions"]:
        print(f'Unmatched process {session["pid"]}: '
              f'{session["launch_session_id"] or "unknown launch session"}')
    for window in data["windows"]:
        if window["limited"] or window["errors"]:
            print(f'UI Automation incomplete for window {window["hwnd"]}: '
                  f'{window["errors"]}')
    for warning in data["warnings"]:
        print(f"Warning: {warning}")
    print(data["limits"])


if __name__ == "__main__":
    main()
