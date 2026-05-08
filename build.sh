#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

ARCH="$(uname -m)"
CONFIG="release"

echo "→ Building (config: $CONFIG, arch: $ARCH)"
swift build -c "$CONFIG" --arch "$ARCH"

BIN_PATH="$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)"
APP="MultiMonitor.app"

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/MultiMonitor" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

# Build / refresh AppIcon.icns from the iconset if needed.
if [ -d Resources/AppIcon.iconset ]; then
    if [ ! -f Resources/AppIcon.icns ] || \
       [ "$(find Resources/AppIcon.iconset -newer Resources/AppIcon.icns -print -quit 2>/dev/null)" != "" ]; then
        echo "→ Building AppIcon.icns"
        iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
    fi
fi
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi

# Ad-hoc sign so macOS lets us open the app without quarantine warnings
# even when copied between machines. No identity needed.
if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "✓ $(pwd)/$APP"
echo "  Doppelklicken zum Starten oder nach /Applications ziehen."
