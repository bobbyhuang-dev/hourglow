#!/bin/bash
# Verify not only that the app's signature is valid, but that its code identity survives rebuilds and upgrades.
set -euo pipefail

APP="${1:-build/HourGlow.app}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"

codesign --verify --deep --strict --verbose=2 "$APP"
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1)"
EXPECTED="designated => identifier \"$BUNDLE_ID\""

if [[ "$REQUIREMENT" != *"$EXPECTED"* ]]; then
    echo "error: designated requirement is unstable" >&2
    echo "expected: $EXPECTED" >&2
    echo "actual:   $REQUIREMENT" >&2
    exit 1
fi
if [[ "$REQUIREMENT" == *"cdhash"* ]]; then
    echo "error: designated requirement is still bound to a single build's cdhash" >&2
    exit 1
fi

echo "signature identity: $EXPECTED"
