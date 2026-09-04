#!/bin/bash
# 出 README 顶上的演示 GIF（docs/demo.gif）与分享卡片（官网的 og.png，GitHub Social Preview 也上传它）。
#
#   ./build.sh && Tools/makedemo.sh [壁纸目录]
#
# 壁纸目录里要有 tahoe-{morning,day,evening,night}.jpg，默认取旁边官网仓库的 assets/。
# 面板截图由 panelshot 现抓：拿一份一次性配置（深圳、Tahoe 四段预设、英文），
# 用 --now 把「现在」定在一天里的十二个时刻，每段三张 —— 时钟在走、倒计时在数，
# 每一帧里面板与菜单栏说的是同一个时间。日期钉死在 2026-09-04，重跑出来的图一样。
set -euo pipefail
cd "$(dirname "$0")/.."

WALLS="${1:-../hourglow-web/assets}"
OUT_GIF="${OUT_GIF:-docs/demo.gif}"
OUT_CARD="${OUT_CARD:-../hourglow-web/assets/og.png}"
DAY=2026-09-04

for f in build/hourglow-cli build/panelshot; do
    [ -x "$f" ] || { echo "缺 $f，先跑 ./build.sh"; exit 1; }
done
[ -f "$WALLS/tahoe-night.jpg" ] || { echo "$WALLS 里没有 tahoe-*.jpg"; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOURGLOW_HOME="$work/home" HOURGLOW_LANG=en
mkdir -p "$work/shots" "$work/tmp"
build/hourglow-cli location 22.5431 114.0579 Shenzhen >/dev/null

shoot() {   # shoot <phase> <HH:MM>
    build/panelshot "$work/tmp" --only timeline --now "${DAY}T$2" >/dev/null
    mv "$work/tmp/1-timeline.png" "$work/shots/$1-${2/:/}.png"
}
# 深圳 9 月初：日出 06:07、日落 18:38 → 四段起点 06:07 / 09:00 / 18:08 / 19:38。
shoot morning 06:20; shoot morning 07:15; shoot morning 08:30
shoot day     09:05; shoot day     12:40; shoot day     17:20
shoot evening 18:15; shoot evening 18:50; shoot evening 19:25
shoot night   19:45; shoot night   22:30; shoot night   23:55

swiftc -O Tools/makedemo.swift -o build/makedemo
build/makedemo gif  --shots "$work/shots" --walls "$WALLS" --icon Resources/HourGlow.icns --day "$DAY" --out "$OUT_GIF"
build/makedemo card --shots "$work/shots" --walls "$WALLS" --icon Resources/HourGlow.icns --day "$DAY" --out "$OUT_CARD"
ls -la "$OUT_GIF" "$OUT_CARD"
