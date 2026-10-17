#!/bin/zsh
# Builds "Claude Island.app".
#   ./build.sh            build and install into ~/Applications (restarts the running app)
#   ./build.sh --package  build and zip it into dist/Claude-Island.zip, for a release
# Run scripts/build-tmux.sh first to put tmux inside the app; without it, the app uses Homebrew's tmux.
set -euo pipefail
cd "$(dirname "$0")"

APP="Claude Island.app"
DEST="$HOME/Applications/$APP"
VERSION=${VERSION:-dev}   # releases set it from the tag; "dev" builds never update themselves
PACKAGE=false
[[ ${1:-} == --package ]] && PACKAGE=true

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

# The shell side, which the app copies to ~/.claude-island when it starts (see ShellSupport.swift):
# the zsh hook, the launcher, tmux's settings, the link opener, the screenshot relay (shell/relay.c,
# named tmux so Terminal treats windows running it like plain tmux windows) and tmux itself.
SHELL_DIR="build/$APP/Contents/Resources/shell"
mkdir -p "$SHELL_DIR/relay"
cp shell/claude-island.zsh shell/claude-tmux shell/tmux.conf shell/open-link "$SHELL_DIR/"
cc -O2 -Wall -mmacosx-version-min=14.0 -o "$SHELL_DIR/relay/tmux" shell/relay.c
if [[ -x build/tmux/tmux ]]; then
  mkdir -p "$SHELL_DIR/bin" && cp build/tmux/tmux "$SHELL_DIR/bin/tmux"
fi
# A copy next to the scripts, for a ~/.zshrc that sources this checkout directly.
mkdir -p shell/relay && cp "$SHELL_DIR/relay/tmux" shell/relay/tmux

cat > "build/$APP/Contents/Info.plist" <<PLIST
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
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
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

if $PACKAGE; then
  mkdir -p dist
  rm -f dist/Claude-Island.zip
  ditto -c -k --norsrc --noextattr --noqtn --keepParent "build/$APP" dist/Claude-Island.zip
  echo "Packaged dist/Claude-Island.zip"
  exit 0
fi

pkill -x ClaudeIsland 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "build/$APP" "$DEST"
echo "Installed $DEST"
