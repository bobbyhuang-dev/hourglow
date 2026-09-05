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

# 父进程还活着时旧 app 必须保持原位，不能只测一个不存在的 PID。
mkdir -p "$ROOT/wait/unpacked/HourGlow.app"
printf 'next\n' > "$ROOT/wait/unpacked/HourGlow.app/version"
cp "$HELPER" "$ROOT/wait-helper"
sleep 2 &
PARENT_PID=$!
HOURGLOW_UPDATER_NO_RELAUNCH=1 HOURGLOW_UPDATER_LOG="$ROOT/updater.log" \
    "$ROOT/wait-helper" "$PARENT_PID" \
    "$ROOT/wait/unpacked/HourGlow.app" "$ROOT/install/HourGlow.app" \
    "$ROOT/wait-helper" "$ROOT/wait" &
UPDATER_PID=$!
sleep 0.3
test "$(tr -d '\n' < "$ROOT/install/HourGlow.app/version")" = "new"
wait "$PARENT_PID"
wait "$UPDATER_PID"
test "$(tr -d '\n' < "$ROOT/install/HourGlow.app/version")" = "next"
echo "updater helper: 父进程退出前不替换"

# 把测试 payload 放在旧 bundle 内，旧 bundle 移到备份后原 source 路径消失，
# 可稳定触发第二次 move 失败，验证真正执行过 oldMoved 的回滚分支。
mkdir -p "$ROOT/install/HourGlow.app/payload/HourGlow.app"
cp "$HELPER" "$ROOT/fail-helper"
if HOURGLOW_UPDATER_NO_RELAUNCH=1 HOURGLOW_UPDATER_LOG="$ROOT/updater.log" \
    "$ROOT/fail-helper" 999999 \
    "$ROOT/install/HourGlow.app/payload/HourGlow.app" "$ROOT/install/HourGlow.app" \
    "$ROOT/fail-helper" "$ROOT/unused-stage"; then
    echo "error: 故障注入应返回失败" >&2
    exit 1
fi
test "$(tr -d '\n' < "$ROOT/install/HourGlow.app/version")" = "next"
test ! -e "$ROOT/fail-helper"
if compgen -G "$ROOT/install/.HourGlow-backup-*.app" >/dev/null; then
    echo "error: 回滚后旧 bundle 没有恢复原位" >&2
    exit 1
fi
echo "updater helper: 替换失败恢复旧 app"
