#!/bin/bash
# Build the Tiger Build Relay app into ~/Applications. Needs Apple's command
# line tools (xcode-select --install) and macOS 12 or later.
#   RELAY_GUI_OUTPUT=/path/App.app scripts/build-relay-gui.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${RELAY_GUI_OUTPUT:-$HOME/Applications/Tiger Build Relay.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
rm -f "$APP/Contents/MacOS/TigerDesk"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
for ARCH in arm64 x86_64; do
  swiftc -target "$ARCH-apple-macosx12.0" -swift-version 5 -O "$ROOT/relay-gui/main.swift" -o "$BUILD/$ARCH" -framework Cocoa
done
lipo -create "$BUILD/arm64" "$BUILD/x86_64" -output "$APP/Contents/MacOS/TigerBuildRelay"
if [ "${RELAY_GUI_PORTABLE:-0}" = 1 ]; then
  printf '%s\n' /usr/bin/python3 > "$APP/Contents/Resources/python.txt"
else
  command -v python3 > "$APP/Contents/Resources/python.txt"
fi
cp "$ROOT/assets/TigerBuild.icns" "$APP/Contents/Resources/TigerBuild.icns"
python3 - "$APP" <<'PY'
import plistlib, sys
from pathlib import Path
app = Path(sys.argv[1])
info = {
    "CFBundleExecutable": "TigerBuildRelay",
    "CFBundleName": "Tiger Build Relay",
    "CFBundleDisplayName": "Tiger Build Relay",
    "CFBundleIdentifier": "local.tigerbuild.relaygui",
    "CFBundleVersion": "1.2",
    "CFBundleShortVersionString": "1.2",
    "CFBundlePackageType": "APPL",
    "CFBundleIconFile": "TigerBuild.icns",
    "LSMinimumSystemVersion": "12.0",
    "NSHumanReadableCopyright": "MIT License",
}
with open(app / "Contents/Info.plist", "wb") as handle:
    plistlib.dump(info, handle)
PY
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf 'Built %s\n' "$APP"
