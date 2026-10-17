#!/bin/zsh
# Builds "Claude Island.app" and installs it into ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="Claude Island.app"
DEST="$HOME/Applications/$APP"

swift build -c release
rm -rf "build/$APP"
mkdir -p "build/$APP/Contents/MacOS" "build/$APP/Contents/Resources"
cp .build/release/ClaudeIsland "build/$APP/Contents/MacOS/ClaudeIsland"
# SwiftPM records the deployment target (14.0) as the SDK the app was built with, so macOS draws it
# with the old controls. Record the real SDK, so switches and the like get the current (Liquid Glass) look.
vtool -set-build-version macos 14.0 "$(xcrun --show-sdk-version)" -replace \
    -output "build/$APP/Contents/MacOS/ClaudeIsland" "build/$APP/Contents/MacOS/ClaudeIsland"
[[ build/AppIcon.icns -nt scripts/make-icon.swift ]] || swift scripts/make-icon.swift build
cp build/AppIcon.icns "build/$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/clawd "build/$APP/Contents/Resources/clawd"

cat > "build/$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.arjun.claude-island</string>
    <key>CFBundleName</key><string>Claude Island</string>
    <key>CFBundleDisplayName</key><string>Claude Island</string>
    <key>CFBundleExecutable</key><string>ClaudeIsland</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Claude Island reads your Terminal windows to show where each Claude Code session is, and moves them when you press Reorganise.</string>
</dict>
</plist>
PLIST

# Ad-hoc signatures change with every build, and macOS forgets privacy permissions (Automation, folders)
# when they do. Tying the app's identity to its bundle ID keeps them across rebuilds.
codesign --force --sign - -r='designated => identifier "com.arjun.claude-island"' "build/$APP"

# The relay between Terminal windows and tmux (see shell/relay.c). Named tmux so Terminal treats
# windows running it like plain tmux windows.
mkdir -p shell/relay
cc -O2 -Wall -o shell/relay/tmux shell/relay.c

pkill -x ClaudeIsland 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "build/$APP" "$DEST"
echo "Installed $DEST"
