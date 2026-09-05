#!/usr/bin/env python3
"""CLI 边界回归：全程使用一次性配置，不启动排程、不写真实壁纸。"""
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
    print("✓ CLI 拒绝越界/非有限坐标且不改原配置")

    for lang in ["en", "zh-Hans"]:
        env["HOURGLOW_LANG"] = lang
        config.write_text(json.dumps({"slots": [{
            "trigger": {"type": "solar", "event": "sunrise",
                        "offsetMinutes": -(2**63)},
            "wallpaper": {"type": "image", "path": "/fixture"}}]}))
        result = run("list")
        assert result.returncode == 0 and str(2**63) in result.stdout, result
    print("✓ 中英文 CLI 展示极端偏移均不崩溃、不截断")
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
    print("✓ 23/24/25 小时的本地日都完整模拟，且不越过次日午夜")

    config.write_text('{"slots":[{"trigger":{"type":"clock","hour":25},'
                      '"wallpaper":{"type":"image","path":"/fixture"}}]}')
    original = config.read_bytes()
    assert run("list").returncode == 1
    assert config.read_bytes() == original
    print("✓ 非法时刻报错且保留原文件")

print("全部 CLI 边界测试通过")
