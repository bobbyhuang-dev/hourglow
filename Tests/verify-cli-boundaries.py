#!/usr/bin/env python3
"""CLI boundary regressions: use disposable configuration throughout, without starting scheduling or writing real wallpapers."""
import json
import os
from pathlib import Path
import subprocess
import tempfile


binary = str(Path("build/hourglow-cli").resolve())
with tempfile.TemporaryDirectory(prefix="hourglow-cli-boundaries-") as root:
    config = Path(root) / "schedule.json"
    env = {**os.environ, "HOURGLOW_HOME": root, "HOURGLOW_LANG": "en",
           "TZ": "America/New_York"}

    def run(*arguments):
        return subprocess.run([binary, *arguments], env=env, capture_output=True,
                              text=True, timeout=30)

    config.write_text('{"slots":[]}')
    original = config.read_bytes()
    for lat, lon in [("91", "0"), ("0", "181"), ("nan", "0"), ("0", "inf")]:
        result = run("location", lat, lon)
        assert result.returncode == 1, result
        assert config.read_bytes() == original
    print("✓ CLI rejects out-of-range/non-finite coordinates without changing the original configuration")

    for lang in ["en", "zh-Hans"]:
        env["HOURGLOW_LANG"] = lang
        config.write_text(json.dumps({"slots": [{
            "trigger": {"type": "solar", "event": "sunrise",
                        "offsetMinutes": -(2**63)},
            "wallpaper": {"type": "image", "path": "/fixture"}}]}))
        result = run("list")
        assert result.returncode == 0 and str(2**63) in result.stdout, result
    print("✓ English and Chinese CLI output displays extreme offsets without crashing or truncating")
    env["HOURGLOW_LANG"] = "en"

    config.write_text(json.dumps({"slots": [
        {"trigger": {"type": "clock", "hour": hour, "minute": minute},
         "wallpaper": {"type": "image", "path": path}}
        for hour, minute, path in [(0, 0, "/midnight"), (23, 30, "/late-night")]
    ]}))
    for day in ["2026-03-08", "2026-11-01", "2026-09-05"]:
        result = run("simulate", day)
        assert result.returncode == 0, result
        transitions = [line.strip() for line in result.stdout.splitlines() if "→" in line]
        assert len(transitions) == 2, result.stdout
        assert transitions[0].startswith("00:00"), result.stdout
        assert transitions[1].startswith("23:30"), result.stdout
    print("✓ Local days of 23/24/25 hours are fully simulated without crossing midnight into the next day")

    config.write_text('{"slots":[{"trigger":{"type":"clock","hour":25},'
                      '"wallpaper":{"type":"image","path":"/fixture"}}]}')
    original = config.read_bytes()
    assert run("list").returncode == 1
    assert config.read_bytes() == original
    print("✓ Invalid times produce an error and preserve the original file")

print("All CLI boundary tests passed")
