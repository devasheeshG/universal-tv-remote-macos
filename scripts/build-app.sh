#!/bin/bash
#
# build-app.sh — compile the Swift package and wrap it into a proper
# "Universal TV Remote.app" bundle.
#
# A menu-bar app cannot ship as a bare executable: LSUIElement (hide from
# Dock), the local-network usage string, ATS local-networking exemption, and
# the icon all live in the bundle's Info.plist. SwiftPM has no bundling step,
# so this script is it.
#
# Usage:
#   scripts/build-app.sh [version]     # version defaults to 0.0.0-dev
#
# Output: build/Universal TV Remote.app  (ad-hoc signed, ready to run)
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.0.0-dev}"
APP_NAME="Universal TV Remote"
BUNDLE_ID="com.devasheesh.universaltvremote"
APP="build/${APP_NAME}.app"

echo "▸ swift build -c release"
swift build -c release

echo "▸ assembling ${APP} (version ${VERSION})"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/UniversalTVRemote "$APP/Contents/MacOS/$APP_NAME"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# The Info.plist is generated here (not checked in) so the CI-provided
# version number lands in CFBundleShortVersionString.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>       <string>Universal TV Remote for Mac</string>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>        <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>

    <!-- Menu-bar app: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>               <true/>

    <!-- Shown in the macOS local-network permission prompt (required since
         macOS 15 for Bonjour/SSDP/direct LAN connections). -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>Universal TV Remote discovers and controls TVs on your local network.</string>
    <!-- Bonjour service types we browse (also part of the LAN privacy system). -->
    <key>NSBonjourServices</key>
    <array>
        <string>_androidtvremote2._tcp</string>
        <string>_amzn-wplay._tcp</string>
    </array>

    <!-- TVs speak plain HTTP (Roku :8060, Samsung :8001, Fire TV wake :8009).
         Allow that for local devices only; everything else stays ATS-default. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
</dict>
</plist>
PLIST

# Ad-hoc signature: fine for personal use and GitHub releases (downloaders
# right-click → Open once). Swap "-" for a Developer ID to notarize later.
echo "▸ codesign (ad-hoc)"
codesign --force --sign - "$APP"

echo "✓ built $APP"
