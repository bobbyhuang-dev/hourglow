#!/bin/bash
# The helper must wait for the main process to exit before replacing the app in place; verify with two temporary fake bundles without launching the real HourGlow.
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
    echo "error: helper left behind the old bundle" >&2
    exit 1
fi

echo "updater helper: in-place replacement, cleanup, and no-relaunch checks passed"

# The old app must stay in place while the parent process is alive; testing only a nonexistent PID is insufficient.
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
echo "updater helper: no replacement before the parent process exits"

# Place the test payload inside the old bundle so that moving the old bundle to a backup removes the original source path.
# This reliably makes the second move fail, verifying that the oldMoved rollback branch actually runs.
mkdir -p "$ROOT/install/HourGlow.app/payload/HourGlow.app"
cp "$HELPER" "$ROOT/fail-helper"
if HOURGLOW_UPDATER_NO_RELAUNCH=1 HOURGLOW_UPDATER_LOG="$ROOT/updater.log" \
    "$ROOT/fail-helper" 999999 \
    "$ROOT/install/HourGlow.app/payload/HourGlow.app" "$ROOT/install/HourGlow.app" \
    "$ROOT/fail-helper" "$ROOT/unused-stage"; then
    echo "error: fault injection should return failure" >&2
    exit 1
fi
test "$(tr -d '\n' < "$ROOT/install/HourGlow.app/version")" = "next"
test ! -e "$ROOT/fail-helper"
if compgen -G "$ROOT/install/.HourGlow-backup-*.app" >/dev/null; then
    echo "error: rollback did not restore the old bundle to its original location" >&2
    exit 1
fi
echo "updater helper: failed replacement restores the old app"
