#!/bin/bash
# Compile Tiger Build on the Tiger Mac and pack a 10.4 installer.
# The package installs the app, which carries its own Commander. Nothing else is installed.
# It does not contain API keys.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSH="${PPC_SSH:-$ROOT/ppc-commander/bin/ppc-ssh}"
DIST="$ROOT/dist"
VERSION="2.0"
mkdir -p "$DIST"

"$SSH" 'killall TigerBuild >/dev/null 2>&1 || true'
NO_OPEN=1 bash "$ROOT/scripts/install-tiger.sh"

"$SSH" bash -s << 'REMOTE'
set -e
APP="$HOME/TigerBuild-build/native/TigerBuild.app"
PAYLOAD="$HOME/TigerBuild-pkg-payload"
PKG="$HOME/TigerBuild-2.0.pkg"
if [ ! -d "$APP" ]; then
  echo "Missing $APP" >&2
  exit 1
fi
rm -rf "$PAYLOAD" "$PKG"
mkdir -p "$PAYLOAD" "$PKG/Contents/Resources/English.lproj"
cp -R "$APP" "$PAYLOAD/Tiger Build.app"
cd "$PAYLOAD"
pax -w . | gzip -c > "$PKG/Contents/Archive.pax.gz"
mkbom . "$PKG/Contents/Archive.bom"
SIZE=$(du -k -s "$PAYLOAD" | awk '{print $1}')
printf 'pmkrpkg1' > "$PKG/Contents/PkgInfo"
cat > "$PKG/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleGetInfoString</key>
  <string>Tiger Build 2.0</string>
  <key>CFBundleIdentifier</key>
  <string>local.tigerbuild.TigerBuild.pkg</string>
  <key>CFBundleName</key>
  <string>Tiger Build</string>
  <key>CFBundleShortVersionString</key>
  <string>2.0</string>
  <key>IFMajorVersion</key>
  <integer>1</integer>
  <key>IFMinorVersion</key>
  <integer>1</integer>
  <key>IFPkgFlagAllowBackRev</key>
  <true/>
  <key>IFPkgFlagAuthorizationAction</key>
  <string>RootAuthorization</string>
  <key>IFPkgFlagDefaultLocation</key>
  <string>/Applications</string>
  <key>IFPkgFlagInstallFat</key>
  <false/>
  <key>IFPkgFlagInstalledSize</key>
  <integer>$SIZE</integer>
  <key>IFPkgFlagOverwritePermissions</key>
  <false/>
  <key>IFPkgFlagRelocatable</key>
  <true/>
  <key>IFPkgFlagRestartAction</key>
  <string>NoRestart</string>
  <key>IFPkgFlagRootVolumeOnly</key>
  <true/>
  <key>IFPkgFlagUpdateInstalledLanguages</key>
  <false/>
  <key>IFPkgFormatVersion</key>
  <real>0.10000000149011612</real>
</dict>
</plist>
PLIST
cat > "$PKG/Contents/Resources/English.lproj/Description.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>IFPkgDescriptionTitle</key>
  <string>Tiger Build</string>
  <key>IFPkgDescriptionVersion</key>
  <string>2.0</string>
  <key>IFPkgDescriptionDescription</key>
  <string>Installs Tiger Build on Mac OS X 10.4 to 10.6; Commander, which lets a chat use this Mac's files and shell, is inside the application. No API keys are included: in Tiger Build Preferences, add a key for each service you use, or the address of a local LLM server. No other computer is needed.</string>
</dict>
</plist>
PLIST
printf 'major: 1\nminor: 2\n' > "$PKG/Contents/Resources/package_version"
rm -rf "$PAYLOAD"
echo "PACKAGED"
REMOTE

rm -rf "$DIST/TigerBuild-$VERSION.pkg"
"$SSH" 'tar -C "$HOME" -cf - TigerBuild-2.0.pkg' | tar -C "$DIST" -xf -
echo "Wrote $DIST/TigerBuild-$VERSION.pkg"
"$SSH" 'open "$HOME/Desktop/Tiger Build.app"'
