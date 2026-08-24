#!/bin/bash
# 验证 app 不仅「签名有效」，还要在重编与升级后保持同一个代码身份。
set -euo pipefail

APP="${1:-build/HourGlow.app}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"

codesign --verify --deep --strict --verbose=2 "$APP"
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1)"
EXPECTED="designated => identifier \"$BUNDLE_ID\""

if [[ "$REQUIREMENT" != *"$EXPECTED"* ]]; then
    echo "error: designated requirement 不稳定" >&2
    echo "expected: $EXPECTED" >&2
    echo "actual:   $REQUIREMENT" >&2
    exit 1
fi
if [[ "$REQUIREMENT" == *"cdhash"* ]]; then
    echo "error: designated requirement 仍绑定单次构建的 cdhash" >&2
    exit 1
fi

echo "signature identity: $EXPECTED"
