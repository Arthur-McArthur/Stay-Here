#!/usr/bin/env python3
"""Install or uninstall this user's Stay Here app and login agent. No sudo."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

LABEL = "com.arthurmcarthur.stay-here"
REPO = Path(__file__).resolve().parent.parent


def run(*args, check=True):
    return subprocess.run(args, check=check, text=True, capture_output=True)


def paths():
    user_dir = Path.home()
    return (
        user_dir / "Applications/Stay Here.app",
        user_dir / "Library/LaunchAgents" / (LABEL + ".plist"),
        user_dir / "Library/Logs/Stay Here",
    )


def verify_app(app):
    if app.is_symlink():
        raise RuntimeError("Refusing an application path that is a symbolic link")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != LABEL:
        raise RuntimeError("Application has an unexpected bundle identifier")
    run("codesign", "--verify", "--strict", str(app))


def verify_agent(agent, app):
    if agent.is_symlink():
        raise RuntimeError("Refusing a login-agent path that is a symbolic link")
    config = plistlib.loads(agent.read_bytes())
    if config.get("Label") != LABEL or config.get("ProgramArguments") != [str(app / "Contents/MacOS/StayHere")]:
        raise RuntimeError("Existing login agent has unexpected contents")


def configured_spaces():
    commands = [
        ("defaults", "read", "-g", "AppleSpacesSwitchOnActivate"),
        ("defaults", "read", "com.apple.dock", "workspaces-auto-swoosh"),
    ]
    return all(run(*args, check=False).stdout.strip().lower() in {"0", "false", "no"} for args in commands)


def service_loaded():
    return run("launchctl", "print", f"gui/{os.getuid()}/{LABEL}", check=False).returncode == 0


def stop_service():
    if service_loaded():
        run("launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}")


def start_service(agent):
    # bootout may return before launchd finishes removing the old service.
    import time
    for attempt in range(10):
        result = run("launchctl", "bootstrap", f"gui/{os.getuid()}", str(agent), check=False)
        if result.returncode == 0:
            return
        if attempt < 9:
            time.sleep(0.5)
    raise RuntimeError(result.stderr.strip() or "Could not start the login agent")


def install(dry_run):
    app, agent, logs = paths()
    source = REPO / "build/Stay Here.app"
    if dry_run:
        print(json.dumps({"app": str(app), "login_agent": str(agent), "logs": str(logs), "starts_at_login": True}, indent=2))
        return
    if not configured_spaces():
        raise RuntimeError("Configure the two Spaces settings in README.md before installing. No settings were changed.")
    if not source.exists():
        subprocess.run([str(REPO / "scripts/build.sh")], check=True)
    verify_app(source)
    if app.exists():
        verify_app(app)
    if agent.exists():
        verify_agent(agent, app)
    app.parent.mkdir(parents=True, exist_ok=True)
    agent.parent.mkdir(parents=True, exist_ok=True)
    logs.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".stay-here-update-", dir=app.parent) as staging_dir:
        staged = Path(staging_dir) / "Stay Here.app"
        shutil.copytree(source, staged)
        previous = Path(staging_dir) / "previous.app"
        old_agent = agent.read_bytes() if agent.exists() else None
        was_loaded = service_loaded()
        stop_service()
        try:
            if app.exists():
                app.rename(previous)
            staged.rename(app)
            config = {
                "Label": LABEL,
                "ProgramArguments": [str(app / "Contents/MacOS/StayHere")],
                "RunAtLoad": True,
                "LimitLoadToSessionType": "Aqua",
                "StandardOutPath": str(logs / "guard.log"),
                "StandardErrorPath": str(logs / "errors.log"),
                "Umask": 0o077,
            }
            agent.write_bytes(plistlib.dumps(config))
            agent.chmod(0o600)
            start_service(agent)
        except Exception:
            stop_service()
            if app.exists():
                shutil.rmtree(app)
            if previous.exists():
                previous.rename(app)
            if old_agent is None:
                agent.unlink(missing_ok=True)
            else:
                agent.write_bytes(old_agent)
            if was_loaded and agent.exists():
                start_service(agent)
            raise
    print("Stay Here is installed, running, and enabled at login.")


def uninstall(dry_run):
    app, agent, logs = paths()
    if dry_run:
        print(json.dumps({"remove_app": str(app), "remove_login_agent": str(agent), "retain_logs": str(logs)}, indent=2))
        return
    if app.exists():
        verify_app(app)
    if agent.exists():
        verify_agent(agent, app)
    stop_service()
    if agent.exists():
        agent.unlink()
    if app.exists():
        shutil.rmtree(app)
    print("Stay Here was removed. Desktop assignments, Spaces settings, and local logs were preserved.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "uninstall"])
    parser.add_argument("--dry-run", action="store_true", help="Show paths without writing files or starting/stopping anything")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Stay Here requires macOS")
    if os.getuid() == 0:
        parser.error("Run this as your own user, without sudo")
    try:
        (install if args.action == "install" else uninstall)(args.dry_run)
    except (OSError, RuntimeError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        print(f"Stay Here: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
