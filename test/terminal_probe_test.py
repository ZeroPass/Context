"""Pure regression checks for the standalone, read-only terminal prototype."""

import importlib.util
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "terminal_probe",
    Path(__file__).resolve().parents[1] / "scripts/probe-terminal-sessions.py",
)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
SESSION_ID = "11111111-2222-3333-4444-555555555555"


def session(pid=10, name="Example"):
    return {
        "pid": pid, "name": name, "cwd": "/home/example/project",
        "launch_session_id": SESSION_ID,
    }


def window(*titles):
    return [{
        "hwnd": 123,
        "tabs": [
            {"title": title, "selected": index == 0}
            for index, title in enumerate(titles)
        ],
    }]


class TerminalProbeTest(unittest.TestCase):
    def test_explicit_resume(self):
        self.assertEqual(
            probe.launched_session(["codex", "resume", SESSION_ID]), SESSION_ID
        )

    def test_other_arguments_are_not_session_evidence(self):
        for args in (
            ["codex", "fork", SESSION_ID],
            ["codex", SESSION_ID],
            ["codex", "exec", SESSION_ID],
            ["codex", "resume", "--last"],
            ["codex", "resume", SESSION_ID, "--fork"],
            ["codex", "resume", SESSION_ID, "--last"],
            ["codex", "resume", "invalid"],
        ):
            with self.subTest(args=args):
                self.assertIsNone(probe.launched_session(args))

    def test_status_glyph_does_not_break_name_match(self):
        self.assertTrue(probe.title_matches("\u2819 Example | project", session()))

    def test_no_fuzzy_or_wrong_directory_match(self):
        for title in (
            "Another Example | project", "Example | other", "Exam | project",
        ):
            self.assertFalse(probe.title_matches(title, session()))

    def test_unknown_name_is_not_assumed(self):
        self.assertFalse(probe.title_matches("Example", session(name=None)))

    def test_unique_match_preserves_tab_selection(self):
        rows = probe.associate(window("Example | project"), [session()])
        self.assertEqual(rows[0]["session"]["pid"], 10)
        self.assertTrue(rows[0]["selected"])

    def test_duplicate_process_names_are_ambiguous(self):
        rows = probe.associate(
            window("Example | project"), [session(10), session(11)]
        )
        self.assertEqual(rows[0]["match"], "ambiguous")
        self.assertIsNone(rows[0]["session"])

    def test_duplicate_tabs_cannot_claim_one_process(self):
        rows = probe.associate(
            window("Example | project", "Example | project"), [session()]
        )
        self.assertTrue(all(row["match"] == "ambiguous" for row in rows))
        self.assertTrue(all(row["session"] is None for row in rows))

    def test_unknown_tab_is_preserved(self):
        rows = probe.associate(window("Ubuntu"), [session()])
        self.assertEqual(rows[0]["match"], "unmatched")
        self.assertIsNone(rows[0]["session"])

    def test_multiple_windows_do_not_duplicate_matches(self):
        windows = window("Example | project") + window("Example | project")
        windows[1]["hwnd"] = 456
        rows = probe.associate(windows, [session()])
        self.assertTrue(all(row["session"] is None for row in rows))

    def test_all_provider_entrypoints(self):
        for provider in ("codex", "kimi", "claude", "qwen", "opencode", "muse", "zcode"):
            with self.subTest(provider=provider):
                self.assertEqual(probe.agent_command([f"/bin/{provider}"])[0], provider)
        self.assertEqual(probe.agent_command(["node", "/opt/@anthropic-ai/claude-code/cli.js"])[0], "claude")
        self.assertEqual(probe.agent_command(["python3", "-m", "kimi_cli"])[0], "kimi")
        self.assertIsNone(probe.agent_command(["bash", "-c", "codex resume " + SESSION_ID]))
        self.assertIsNone(probe.agent_command(["node", "unrelated.js", "claude"]))

    def test_provider_id_flags_and_unknown_forks(self):
        for provider, args in (
            ("claude", ["--resume", SESSION_ID]),
            ("kimi", ["--session=" + SESSION_ID]),
            ("qwen", ["-r", SESSION_ID]),
            ("muse", ["resume", SESSION_ID]),
        ):
            self.assertEqual(probe.provider_session(provider, [provider, *args]), SESSION_ID)
        self.assertEqual(probe.provider_session("opencode", ["opencode", "-s", "ses_example"]), "ses_example")
        self.assertEqual(probe.provider_session("kimi", ["kimi", "--session", "session_example"]), "session_example")
        self.assertEqual(probe.provider_session("muse", ["muse", "resume", "abc-1234"]), "abc-1234")
        self.assertIsNone(probe.provider_session("claude", ["claude", "-r", "Display name"]))
        self.assertIsNone(probe.provider_session("claude", ["claude", "-r", SESSION_ID, "--fork-session"]))


if __name__ == "__main__":
    unittest.main()
