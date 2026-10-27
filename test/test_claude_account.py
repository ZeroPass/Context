import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("claude_account", Path(__file__).resolve().parents[1] / "scripts/claude-account.py")
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class ClaudeAccountTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.directory = self.home / ".claude"
        self.directory.mkdir()
        self.write_identity("account-a")
        (self.directory / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {
            "accessToken": "fake-private-test-token", "refreshToken": "never-use-this",
            "subscriptionType": "max",
        }}))
        self.usage = {"seven_day": {"utilization": 72, "resets_at": "2026-11-01T10:00:00Z"},
                      "five_hour": {"utilization": 99, "resets_at": "2026-10-28T02:00:00+00:00"}}

    def write_identity(self, account):
        (self.home / ".claude.json").write_text(json.dumps({"oauthAccount": {
            "accountUuid": account, "organizationUuid": "org", "emailAddress": "test@example.invalid"}}))

    def test_separate_weekly_and_five_hour_with_no_credential_fields(self):
        result = module.account(self.home, self.directory, lambda token: self.usage)
        account = result["accounts"][0]
        self.assertEqual(account["weekly"]["used_percent"], 72)
        self.assertEqual(account["five_hour"]["used_percent"], 99)
        self.assertGreater(account["weekly"]["reset_at"], account["five_hour"]["reset_at"])
        self.assertNotIn("fake-private-test-token", json.dumps(result))
        self.assertNotIn("never-use-this", json.dumps(result))

    def test_zero_is_valid_but_missing_weekly_is_not_invented(self):
        self.usage["seven_day"]["utilization"] = 0
        result = module.account(self.home, self.directory, lambda _: self.usage)
        self.assertEqual(result["accounts"][0]["weekly"]["used_percent"], 0)
        self.usage["seven_day"] = None
        result = module.account(self.home, self.directory, lambda _: self.usage)
        self.assertIsNone(result["accounts"][0]["weekly"])

    def test_bad_percent_dates_and_empty_windows_report_error(self):
        for value in (True, -1, 101, float("nan"), "0"):
            with self.assertRaises(module.AccountError):
                module.period({"utilization": value, "resets_at": "2026-11-01T10:00:00Z"})
        with self.assertRaises(module.AccountError):
            module.period({"utilization": 1, "resets_at": "2026-11-01T10:00:00"})
        result = module.account(self.home, self.directory, lambda _: {})
        self.assertIn("usage_error", result["accounts"][0])

    def test_login_change_during_fetch_never_misattributed(self):
        before = module.identity(self.home, self.directory)
        def fetch(_):
            self.write_identity("account-b")
            return self.usage
        result = module.account(self.home, self.directory, fetch)["accounts"][0]
        self.assertNotEqual(result["account_key"], before["account_key"])
        self.assertIn("usage_error", result)
        self.assertNotIn("weekly", result)

    def test_network_exception_is_sanitized_and_auth_never_modified(self):
        credentials = self.directory / ".credentials.json"
        before = credentials.read_bytes()
        def fetch(_):
            raise RuntimeError("fake-private-test-token")
        result = module.account(self.home, self.directory, fetch)
        self.assertNotIn("fake-private-test-token", json.dumps(result))
        self.assertEqual(credentials.read_bytes(), before)

    def test_apply_preserves_other_settings_and_only_changes_defaults(self):
        path = self.directory / "settings.json"
        path.write_text(json.dumps({"permissions": {"deny": ["Read(.env)"]}, "theme": "dark",
            "modelSettings": {"claude-sonnet-5-5": {"autoCompactWindow": 200000},
                              "claude-opus-5-5": {"effortLevel": "medium"}}}))
        path.chmod(0o600)
        auth = (self.directory / ".credentials.json").read_bytes()
        request = {"action": "apply", "model": "claude-sonnet-5-5", "effort": "high",
                   "account_key": module.identity(self.home, self.directory)["account_key"]}
        result = module.apply_defaults(self.home, self.directory, request)
        settings = json.loads(path.read_text())
        self.assertEqual(settings["permissions"], {"deny": ["Read(.env)"]})
        self.assertEqual(settings["theme"], "dark")
        self.assertFalse(settings["fastMode"])
        self.assertEqual(settings["modelSettings"]["claude-sonnet-5-5"], {"effortLevel": "high", "autoCompactWindow": 200000})
        self.assertEqual(settings["modelSettings"]["claude-opus-5-5"], {"effortLevel": "medium"})
        self.assertTrue(result["defaults_saved"])
        self.assertEqual((self.directory / ".credentials.json").read_bytes(), auth)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_wrong_identity_bad_selection_or_link_cannot_write(self):
        path = self.directory / "settings.json"
        path.write_text("{}")
        request = {"model": "claude-sonnet-5-5", "effort": "high", "account_key": "wrong"}
        with self.assertRaises(module.AccountError):
            module.apply_defaults(self.home, self.directory, request)
        self.assertEqual(path.read_text(), "{}")
        request["account_key"] = module.identity(self.home, self.directory)["account_key"]
        request["effort"] = "max"  # session-only; cannot persist it
        with self.assertRaises(module.AccountError):
            module.apply_defaults(self.home, self.directory, request)
        request["effort"] = "high"
        path.unlink()
        target = self.home / "outside.json"
        target.write_text("{}")
        path.symlink_to(target)
        with self.assertRaises(module.AccountError):
            module.apply_defaults(self.home, self.directory, request)
        self.assertEqual(target.read_text(), "{}")


if __name__ == "__main__":
    unittest.main()
