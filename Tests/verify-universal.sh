#!/bin/bash
# Reject an archive missing either CPU slice, including its nested update helper.
set -euo pipefail
APP="${1:-build/HourGlow.app}"
CLI="${2:-build/hourglow-cli}"
for binary in "$APP/Contents/MacOS/HourGlow" "$APP/Contents/Helpers/HourGlowUpdater" "$CLI"; do
    lipo "$binary" -verify_arch arm64 x86_64
    codesign --verify --strict --all-architectures "$binary"
    echo "Universal 2 verified: $binary"
done
bash "$(dirname "$0")/verify-app-signature.sh" "$APP"
