"""Installer file safety and rollback checks. No real launchctl calls."""

import contextlib
import importlib.util
import io
from pathlib import Path
import plistlib
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("manage", Path(__file__).resolve().parents[1] / "scripts/manage.py")
manage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manage)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="stay-here-installer-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "source repo with spaces"
        self.app = self.root / "Applications/Stay Here.app"
        self.agent = self.root / "LaunchAgents" / (manage.LABEL + ".plist")
        self.logs = self.root / "Logs/Stay Here"
        self.make_app(self.repo / "build/Stay Here.app", "new")
        self.make_app(self.app, "old")
        self.agent.parent.mkdir(parents=True)
        self.old_agent = plistlib.dumps({"Label": manage.LABEL, "ProgramArguments": [str(self.app / "Contents/MacOS/StayHere")], "RunAtLoad": True})
        self.agent.write_bytes(self.old_agent)
        self.patch("REPO", self.repo)
        self.patch("paths", return_value=(self.app, self.agent, self.logs))
        self.patch("configured_spaces", return_value=True)
        self.patch("run", return_value=SimpleNamespace(returncode=0, stdout="", stderr=""))
        self.patch("service_loaded", return_value=True)
        self.stop = self.patch("stop_service")
        self.start = self.patch("start_service")

    def patch(self, name, *args, **kwargs):
        p = patch.object(manage, name, *args, **kwargs)
        value = p.start()
        self.addCleanup(p.stop)
        return value

    @staticmethod
    def make_app(path, marker, bundle=manage.LABEL):
        (path / "Contents/MacOS").mkdir(parents=True)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": bundle}))
        (path / "Contents/MacOS/StayHere").write_text(marker)

    def test_install_replaces_bundle_and_configures_login(self):
        with contextlib.redirect_stdout(io.StringIO()):
            manage.install(False)
        self.assertEqual((self.app / "Contents/MacOS/StayHere").read_text(), "new")
        config = plistlib.loads(self.agent.read_bytes())
        self.assertEqual(config["ProgramArguments"], [str(self.app / "Contents/MacOS/StayHere")])
        self.assertTrue(config["RunAtLoad"])
        self.assertEqual(config["Umask"], 0o077)
        self.stop.assert_called_once()
        self.start.assert_called_once_with(self.agent)

    def test_failed_start_restores_previous_app_and_agent(self):
        self.start.side_effect = [RuntimeError("startup failed"), None]
        with self.assertRaisesRegex(RuntimeError, "startup failed"):
            manage.install(False)
        self.assertEqual((self.app / "Contents/MacOS/StayHere").read_text(), "old")
        self.assertEqual(self.agent.read_bytes(), self.old_agent)
        self.assertEqual(self.start.call_count, 2)

    def test_dry_runs_do_not_touch_files_or_services(self):
        before = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        with contextlib.redirect_stdout(io.StringIO()):
            manage.install(True)
            manage.uninstall(True)
        after = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(before, after)
        self.assertFalse(self.logs.exists())
        self.stop.assert_not_called()
        self.start.assert_not_called()

    def test_uninstall_refuses_unrelated_app(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "example.other.app"}))
        with self.assertRaisesRegex(RuntimeError, "unexpected bundle"):
            manage.uninstall(False)
        self.assertTrue(self.app.exists())
        self.assertTrue(self.agent.exists())
        self.stop.assert_not_called()

    def test_uninstall_keeps_logs_and_unrelated_files(self):
        self.logs.mkdir(parents=True)
        (self.logs / "guard.log").write_text("local diagnostic log")
        other = self.app.parent / "unrelated.txt"
        other.write_text("keep me")
        with contextlib.redirect_stdout(io.StringIO()):
            manage.uninstall(False)
        self.assertFalse(self.app.exists())
        self.assertFalse(self.agent.exists())
        self.assertEqual((self.logs / "guard.log").read_text(), "local diagnostic log")
        self.assertEqual(other.read_text(), "keep me")


class LocationTests(unittest.TestCase):
    def test_existing_system_install_is_preserved(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder) / "home"
            system_app = Path(folder) / "system/Applications/Stay Here.app"
            agent = home / "Library/LaunchAgents" / (manage.LABEL + ".plist")
            agent.parent.mkdir(parents=True)
            agent.write_bytes(plistlib.dumps({"Label": manage.LABEL, "ProgramArguments": [str(system_app / "Contents/MacOS/StayHere")]}))
            with patch.object(manage.Path, "home", return_value=home), patch.object(manage, "SYSTEM_APP", system_app):
                self.assertEqual(manage.paths()[0], system_app)

    def test_agent_cannot_redirect_removal_to_arbitrary_location(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            agent = home / "Library/LaunchAgents" / (manage.LABEL + ".plist")
            agent.parent.mkdir(parents=True)
            agent.write_bytes(plistlib.dumps({"Label": manage.LABEL, "ProgramArguments": ["/some/unrelated/app/Contents/MacOS/StayHere"]}))
            with patch.object(manage.Path, "home", return_value=home):
                app, selected_agent, _ = manage.paths()
                self.assertEqual(app, home / "Applications/Stay Here.app")
                with self.assertRaisesRegex(RuntimeError, "unexpected contents"):
                    manage.verify_agent(selected_agent, app)


if __name__ == "__main__":
    unittest.main()
