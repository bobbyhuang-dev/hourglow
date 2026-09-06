#!/bin/bash
# Build hourglow-cli, verification targets, and the menu bar app (M3).
set -euo pipefail
BUILD_CHECKS=1
PRODUCTION_FLAGS=(-O)
if [ "$#" -ne 0 ]; then
    if [ "$#" -eq 1 ] && [ "$1" = "--production-only" ]; then
        BUILD_CHECKS=0
        # CodeQL traces each frontend process; extract each complete module once.
        PRODUCTION_FLAGS+=(-whole-module-optimization)
    else
        echo "Usage: $0 [--production-only]" >&2
        exit 2
    fi
fi

cd "$(dirname "$0")"
mkdir -p build

# Version. Release pipelines override it from the tag (e.g. HOURGLOW_VERSION=1.0.1); local builds use this default.
VERSION="${HOURGLOW_VERSION:-1.6.0}"
BUILD_NUMBER="${HOURGLOW_BUILD:-1}"
BUNDLE_ID="dev.bobbyhuang.hourglow"

# Compile catalogs into every executable: standalone binaries have no bundle for Localizable.strings lookups.
L10N=(Sources/L10n/L10n.swift Sources/L10n/Catalogs/*.swift)
COMMON=("${L10N[@]}" Sources/Model/*.swift Sources/System/*.swift Sources/Engine/*.swift)
# Keep the entry point separate: panelshot reuses the UI code without pulling in @main.
UI=(Sources/App/SlotDraft.swift Sources/App/Onboarding.swift Sources/App/AppUpdater.swift Sources/App/AppModel.swift Sources/UI/*.swift)
ENTRY=(Sources/App/HourGlowApp.swift)

echo "building: hourglow-cli"
swiftc "${PRODUCTION_FLAGS[@]}" "${COMMON[@]}" Sources/CLI/*.swift          -o build/hourglow-cli
# CodeQL needs production targets only; CI and releases still build every verification target.
if [ "$BUILD_CHECKS" -eq 1 ]; then
    echo "building: verification targets"
    swiftc -O "${COMMON[@]}" Tests/SolarCheck/main.swift -o build/solarcheck
    swiftc -O "${COMMON[@]}" Tests/ModelCheck/main.swift -o build/modelcheck
    swiftc -O "${COMMON[@]}" Tests/EngineCheck/main.swift -o build/enginecheck
    swiftc -O "${COMMON[@]}" Tests/ImportCheck/main.swift -o build/importcheck
    swiftc -O "${L10N[@]}" Tests/L10nCheck/main.swift  -o build/l10ncheck
    swiftc -O "${COMMON[@]}" Sources/App/SlotDraft.swift Sources/App/Onboarding.swift Tests/AppCheck/main.swift -o build/appcheck
    swiftc -O "${L10N[@]}" Sources/App/AppUpdater.swift Tests/UpdateCheck/main.swift -o build/updatecheck
    # Offscreen panel rendering for layout comparisons (see Tests/PanelShot/main.swift).
    swiftc -O "${COMMON[@]}" "${UI[@]}" Tests/PanelShot/main.swift -o build/panelshot
    swiftc -O "${COMMON[@]}" "${UI[@]}" Tests/AppStartupCheck/main.swift -o build/appstartupcheck
    swiftc -O Sources/UI/PanelVisibilityObserver.swift Tests/PanelVisibilityCheck/main.swift -o build/panelvisibilitycheck
fi

# HourGlow.app — assemble the bundle manually, without Xcode.
# LSUIElement hides the Dock icon and main window; the icon appears only in Finder and Login Items.
APP=build/HourGlow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

echo "building: HourGlow.app"
swiftc "${PRODUCTION_FLAGS[@]}" "${COMMON[@]}" "${UI[@]}" "${ENTRY[@]}" -o "$APP/Contents/MacOS/HourGlow"
echo "building: HourGlowUpdater"
swiftc "${PRODUCTION_FLAGS[@]}" "${L10N[@]}" Sources/Updater/main.swift -o "$APP/Contents/Helpers/HourGlowUpdater"

# The generated icon is checked in; rerun Tools/makeicon.swift only when changing it (usage in its header).
cp Resources/HourGlow.icns "$APP/Contents/Resources/HourGlow.icns"

# Derive supported languages from the catalogs instead of maintaining another list: adding a language
# should only require changes in Sources/L10n/. Without this, macOS treats the app as supporting only
# its development language, and HourGlow does not appear under Language & Region > Applications.
LOCALIZATIONS=$(grep -h -o 'code: "[^"]*"' Sources/L10n/Catalogs/*.swift \
    | sed -e 's/code: "//' -e 's/"//' \
    | sort \
    | awk '{ printf "        <string>%s</string>\n", $0 }')

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
    <key>CFBundleDevelopmentRegion</key>    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
$LOCALIZATIONS
    </array>
    <key>NSHighResolutionCapable</key>      <true/>
    <!-- Menu bar resident: no Dock icon or main window. -->
    <key>LSUIElement</key>                  <true/>
    <!-- Reason shown in the location permission dialog. Without it, macOS denies access without prompting. -->
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>HourGlow uses your location to calculate local sunrise and sunset times and can refresh it daily as you travel. You can turn automatic location updates off.</string>
</dict>
</plist>
PLIST

# Ad-hoc signing defaults to using the current binary's cdhash as its designated requirement.
# The cdhash changes on every rebuild, so macOS 26's "Allow in the Menu Bar" treats the new build
# as a different app and may even match an old blocked record. Specify a stable bundle-ID
# requirement so local rebuilds and release upgrades retain the same menu bar app identity.
# This is still ad-hoc signing, not notarization or Developer ID signing.
# The helper is a nested executable: sign it separately before sealing the outer app.
codesign --force --sign - "$APP/Contents/Helpers/HourGlowUpdater" >/dev/null 2>&1
codesign --force --sign - \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" \
    "$APP" >/dev/null 2>&1

echo "built: HourGlow $VERSION ($BUILD_NUMBER)"
echo "built: build/hourglow-cli, $APP"
if [ "$BUILD_CHECKS" -eq 1 ]; then
    echo "built: build/solarcheck, build/modelcheck, build/enginecheck, build/importcheck, build/l10ncheck, build/appcheck, build/appstartupcheck, build/panelvisibilitycheck, build/updatecheck, build/panelshot"
fi
