#!/usr/bin/env python3
"""移动仍在运行的测试 bundle，验证更新器跟随实际路径；不启动引擎或真实安装。"""
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
        assert selector.select(timeout=10), "等待更新器探针超时"
    line = process.stdout.readline()
    assert line, "更新器探针意外退出"
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
print("✓ 裸二进制不会被当成可更新的 app")

with tempfile.TemporaryDirectory(prefix="hourglow-updater-location-") as temporary:
    root = Path(temporary).resolve()
    original = root / "original"
    app = original / "HourGlow.app"
    executable = app / "Contents/MacOS/HourGlow"
    helper = app / "Contents/Helpers/HourGlowUpdater"
    executable.parent.mkdir(parents=True)
    helper.parent.mkdir(parents=True)
    shutil.copy2(binary, executable)
    # 只检查可执行权限，绝不运行这个占位 helper。
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
        print("✓ 完整 app 能检查更新并通过安装位置检查")

        moved = root / "moved parent"
        original.rename(moved)
        app = moved / app.name
        moved_result = check_location(process, app)
        assert not moved_result["legacyAvailable"], moved_result
        print("✓ 运行中移动父目录，更新助手和安装目标跟随新位置")

        # 旧路径即使又有另一份 app，也不能把更新装到那份副本。
        shutil.copytree(moved, original)
        check_location(process, app)
        print("✓ 旧路径出现副本时仍只定位正在运行的 app")

        renamed = app.with_name("HourGlow renamed.app")
        app.rename(renamed)
        app = renamed
        check_location(process, app)
        print("✓ 运行中重命名 app 后仍可更新")

        helper = app / "Contents/Helpers/HourGlowUpdater"
        helper.chmod(0o644)
        result = inspect(process)
        assert result["error"] == "helperUnavailable" and not result["available"], result
        helper.unlink()
        result = inspect(process)
        assert result["error"] == "helperUnavailable" and not result["available"], result
        print("✓ 助手缺失或不可执行时准确报告原因")

        helper.write_text("#!/bin/sh\nexit 99\n")
        helper.chmod(0o755)
        check_location(process, app)
        print("✓ 恢复助手后无需重启即可恢复更新能力")

print("全部更新路径测试通过")
