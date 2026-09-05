#!/usr/bin/env python3
"""Move a running test bundle to verify that the updater follows its actual path, without starting the engine or performing a real installation."""
import json
from pathlib import Path
import plistlib
import selectors
import shutil
import subprocess
import sys
import tempfile
from contextlib import contextmanager


def receive(process):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        assert selector.select(timeout=10), "Timed out waiting for the updater probe"
    line = process.stdout.readline()
    assert line, "Updater probe exited unexpectedly"
    return line.strip()


@contextmanager
def probe(executable):
    process = subprocess.Popen(
        [str(executable), "--installation-probe"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
    )
    try:
        assert receive(process) == "ready"
        yield process
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        process.stdout.close()


def inspect(process):
    process.stdin.write("inspect\n")
    process.stdin.flush()
    return json.loads(receive(process))


def check_location(process, app):
    result = inspect(process)
    assert result["available"], result
    assert Path(result["app"]).resolve() == app.resolve(), result
    assert Path(result["helper"]).resolve() == (
        app / "Contents/Helpers/HourGlowUpdater"
    ).resolve(), result
    assert "error" not in result, result
    return result


binary = Path(sys.argv[1] if len(sys.argv) > 1 else "build/updatecheck").resolve()
with probe(binary) as process:
    result = inspect(process)
    assert result["error"] == "notApp" and not result["available"], result
print("✓ A bare binary is not treated as an updatable app")

with tempfile.TemporaryDirectory(prefix="hourglow-updater-location-") as temporary:
    root = Path(temporary).resolve()
    original = root / "original"
    app = original / "HourGlow.app"
    executable = app / "Contents/MacOS/HourGlow"
    helper = app / "Contents/Helpers/HourGlowUpdater"
    executable.parent.mkdir(parents=True)
    helper.parent.mkdir(parents=True)
    shutil.copy2(binary, executable)
    # Check executable permissions only; never run this placeholder helper.
    helper.write_text("#!/bin/sh\nexit 99\n")
    helper.chmod(0o755)
    with (app / "Contents/Info.plist").open("wb") as output:
        plistlib.dump({
            "CFBundleIdentifier": "dev.bobbyhuang.hourglow",
            "CFBundleExecutable": "HourGlow",
            "CFBundlePackageType": "APPL",
        }, output)

    with probe(executable) as process:
        first = check_location(process, app)
        assert Path(first["initialBundle"]).resolve() == app.resolve(), first
        assert first["legacyAvailable"], first
        print("✓ A complete app can check for updates and pass installation-location checks")

        moved = root / "moved parent"
        original.rename(moved)
        app = moved / app.name
        moved_result = check_location(process, app)
        assert not moved_result["legacyAvailable"], moved_result
        print("✓ Moving the parent directory while running moves the update helper and installation target to the new location")

        # Even if another app appears at the old path, updates must not be installed into that copy.
        shutil.copytree(moved, original)
        check_location(process, app)
        print("✓ A copy at the old path does not prevent locating only the running app")

        renamed = app.with_name("HourGlow renamed.app")
        app.rename(renamed)
        app = renamed
        check_location(process, app)
        print("✓ The app remains updatable after being renamed while running")

        helper = app / "Contents/Helpers/HourGlowUpdater"
        helper.chmod(0o644)
        result = inspect(process)
        assert result["error"] == "helperUnavailable" and not result["available"], result
        helper.unlink()
        result = inspect(process)
        assert result["error"] == "helperUnavailable" and not result["available"], result
        print("✓ A missing or non-executable helper is reported with the correct reason")

        helper.write_text("#!/bin/sh\nexit 99\n")
        helper.chmod(0o755)
        check_location(process, app)
        print("✓ Restoring the helper restores update availability without restarting")

print("All updater path tests passed")
