#!/bin/bash
# Generate the README demo GIF (docs/demo.gif) and sharing card (the website's og.png, also used for GitHub Social Preview).
#
#   ./build.sh && Tools/makedemo.sh [wallpaper-directory]
#
# The wallpaper directory must contain tahoe-{morning,day,evening,night}.jpg; defaults to the sibling website repo's assets/.
# panelshot captures panels using a disposable configuration (Shenzhen, the four-phase Tahoe preset, English).
# --now fixes the time at twelve points throughout the day, three per phase: the clock advances and the countdown runs,
# with the panel and menu bar showing the same time in each frame. The fixed date, 2026-09-04, makes output reproducible.
# Tahoe Evening / Night wallpapers are dark, so those six panels use dark appearance: as the desktop darkens,
# the panel follows, demonstrating dark mode as well.
set -euo pipefail
cd "$(dirname "$0")/.."

WALLS="${1:-../hourglow-web/assets}"
OUT_GIF="${OUT_GIF:-docs/demo.gif}"
OUT_CARD="${OUT_CARD:-../hourglow-web/assets/og.png}"
DAY=2026-09-04

for f in build/hourglow-cli build/panelshot; do
    [ -x "$f" ] || { echo "Missing $f; run ./build.sh first"; exit 1; }
done
[ -f "$WALLS/tahoe-night.jpg" ] || { echo "No tahoe-*.jpg wallpapers in $WALLS"; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOURGLOW_HOME="$work/home" HOURGLOW_LANG=en
mkdir -p "$work/shots" "$work/tmp"
build/hourglow-cli location 22.5431 114.0579 Shenzhen >/dev/null

shoot() {   # shoot <phase> <HH:MM>
    local appearance=light
    case $1 in evening|night) appearance=dark;; esac
    build/panelshot "$work/tmp" --only timeline --now "${DAY}T$2" --appearance $appearance >/dev/null
    mv "$work/tmp/1-timeline.png" "$work/shots/$1-${2/:/}.png"
}
# Early September in Shenzhen: sunrise 06:07, sunset 18:38 → phase starts 06:07 / 09:00 / 18:08 / 19:38.
shoot morning 06:20; shoot morning 07:15; shoot morning 08:30
shoot day     09:05; shoot day     12:40; shoot day     17:20
shoot evening 18:15; shoot evening 18:50; shoot evening 19:25
shoot night   19:45; shoot night   22:30; shoot night   23:55

swiftc -O Tools/makedemo.swift -o build/makedemo
build/makedemo gif  --shots "$work/shots" --walls "$WALLS" --icon Resources/HourGlow.icns --day "$DAY" --out "$OUT_GIF"
build/makedemo card --shots "$work/shots" --walls "$WALLS" --icon Resources/HourGlow.icns --day "$DAY" --out "$OUT_CARD"
ls -la "$OUT_GIF" "$OUT_CARD"
