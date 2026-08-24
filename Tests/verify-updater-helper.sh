#!/bin/bash
# helper 必须等主进程退出后原位替换 app；用两个临时假 bundle 验证，不启动真实 HourGlow。
set -euo pipefail

HELPER="${1:-build/HourGlow.app/Contents/Helpers/HourGlowUpdater}"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hourglow-updater.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT/stage/unpacked/HourGlow.app" "$ROOT/install/HourGlow.app"
printf 'new\n' > "$ROOT/stage/unpacked/HourGlow.app/version"
printf 'old\n' > "$ROOT/install/HourGlow.app/version"
cp "$HELPER" "$ROOT/helper"

HOURGLOW_UPDATER_NO_RELAUNCH=1 HOURGLOW_UPDATER_LOG="$ROOT/updater.log" \
    "$ROOT/helper" 999999 \
    "$ROOT/stage/unpacked/HourGlow.app" "$ROOT/install/HourGlow.app" \
    "$ROOT/helper" "$ROOT/stage"

test "$(tr -d '\n' < "$ROOT/install/HourGlow.app/version")" = "new"
test ! -e "$ROOT/stage"
test ! -e "$ROOT/helper"
if compgen -G "$ROOT/install/.HourGlow-backup-*.app" >/dev/null; then
    echo "error: helper 留下了旧 bundle" >&2
    exit 1
fi

echo "updater helper: 原位替换、清理与免重启验证通过"
