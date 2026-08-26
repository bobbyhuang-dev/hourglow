#!/bin/bash
# 构建 hourglow-cli、验证靶子，以及菜单栏 app（M3）。
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

# 版本号。发布流水线用 tag 覆盖（如 HOURGLOW_VERSION=1.0.1），本地构建就用这里的默认值。
VERSION="${HOURGLOW_VERSION:-1.2.0}"
BUILD_NUMBER="${HOURGLOW_BUILD:-1}"
BUNDLE_ID="dev.bobbyhuang.hourglow"

COMMON=(Sources/Model/*.swift Sources/System/*.swift Sources/Engine/*.swift)
# 入口单列：panelshot 要复用界面代码，但不能把 @main 一起拖进去。
UI=(Sources/App/SlotDraft.swift Sources/App/AppUpdater.swift Sources/App/AppModel.swift Sources/UI/*.swift)
ENTRY=(Sources/App/HourGlowApp.swift)

swiftc -O "${COMMON[@]}" Sources/CLI/*.swift          -o build/hourglow-cli
swiftc -O "${COMMON[@]}" Tests/SolarCheck/main.swift -o build/solarcheck
swiftc -O "${COMMON[@]}" Tests/ModelCheck/main.swift -o build/modelcheck
swiftc -O "${COMMON[@]}" Tests/EngineCheck/main.swift -o build/enginecheck
swiftc -O "${COMMON[@]}" Tests/ImportCheck/main.swift -o build/importcheck
swiftc -O "${COMMON[@]}" Sources/App/SlotDraft.swift Tests/AppCheck/main.swift -o build/appcheck
swiftc -O Sources/App/AppUpdater.swift Tests/UpdateCheck/main.swift -o build/updatecheck
# 面板的离屏渲染，改版式时用来对照（见 Tests/PanelShot/main.swift）。
swiftc -O "${COMMON[@]}" "${UI[@]}" Tests/PanelShot/main.swift -o build/panelshot

# HourGlow.app —— 手工 bundle，不经过 Xcode。
# LSUIElement 让它没有 Dock 图标、没有主窗口；图标只在访达和「登录项」里露面。
APP=build/HourGlow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

swiftc -O "${COMMON[@]}" "${UI[@]}" "${ENTRY[@]}" -o "$APP/Contents/MacOS/HourGlow"
swiftc -O Sources/Updater/main.swift -o "$APP/Contents/Helpers/HourGlowUpdater"

# 图标已经生成好提交在仓库里，改它才需要重跑 `Tools/makeicon.swift`（用法见文件头）。
cp Resources/HourGlow.icns "$APP/Contents/Resources/HourGlow.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>HourGlow</string>
    <key>CFBundleDisplayName</key>          <string>HourGlow</string>
    <key>CFBundleExecutable</key>           <string>HourGlow</string>
    <key>CFBundleIdentifier</key>           <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundleVersion</key>              <string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key>             <string>HourGlow</string>
    <key>LSMinimumSystemVersion</key>       <string>26.0</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <!-- 菜单栏常驻：没有 Dock 图标，也没有主窗口。 -->
    <key>LSUIElement</key>                  <true/>
    <!-- 定位权限对话框上显示的理由。没有这一条系统直接拒，连框都不弹。 -->
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>HourGlow 用你的位置计算本地的日出日落时刻，只取一次，不上传。</string>
</dict>
</plist>
PLIST

# ad-hoc 签名默认把 designated requirement 写成当前二进制的 cdhash。
# 每次重编 cdhash 都变，macOS 26 的「允许在菜单栏中」会把新产物当成
# 另一个应用，甚至会误命中旧的 blocked 记录。显式写入稳定的 bundle-ID
# requirement，让本地重编与 Release 升级仍是同一个菜单栏应用。
# 仍然是 ad-hoc，不代表公证或 Developer ID 签名。
# helper 是 bundle 内的嵌套可执行文件，必须先单独签，再封住外层 app。
codesign --force --sign - "$APP/Contents/Helpers/HourGlowUpdater" >/dev/null 2>&1
codesign --force --sign - \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" \
    "$APP" >/dev/null 2>&1

echo "built: HourGlow $VERSION ($BUILD_NUMBER)"
echo "built: build/hourglow-cli, build/solarcheck, build/modelcheck, build/enginecheck, build/importcheck, build/appcheck, build/updatecheck, build/panelshot, $APP"
