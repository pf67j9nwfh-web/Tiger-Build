#!/bin/bash
# Compile Tiger Build on the Power Mac and pack a 10.4 installer.
# The package contains the app only. It does not contain API keys.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSH="$ROOT/ppc-commander/bin/ppc-ssh"
DIST="$ROOT/dist"
VERSION="1.1"
mkdir -p "$DIST"

"$SSH" 'killall TigerBuild >/dev/null 2>&1 || true'
bash "$ROOT/scripts/install-tiger.sh"

"$SSH" bash -s << 'REMOTE'
set -e
APP="$HOME/TigerBuild-build/native/TigerBuild.app"
PAYLOAD="$HOME/TigerBuild-pkg-payload"
PKG="$HOME/TigerBuild-1.1.pkg"
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
  <string>Tiger Build 1.1</string>
  <key>CFBundleIdentifier</key>
  <string>local.jr.tigerbuild.pkg</string>
  <key>CFBundleName</key>
  <string>Tiger Build</string>
  <key>CFBundleShortVersionString</key>
  <string>1.1</string>
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
  <string>1.1</string>
  <key>IFPkgDescriptionDescription</key>
  <string>Tiger Build 1.1 for Mac OS X 10.4. The app does not contain API keys. Point it at the bridge from Preferences or server.txt.</string>
</dict>
</plist>
PLIST
printf 'major: 1\nminor: 1\n' > "$PKG/Contents/Resources/package_version"
rm -rf "$PAYLOAD"
echo "PACKAGED"
REMOTE

rm -rf "$DIST/TigerBuild-$VERSION.pkg"
"$SSH" 'tar -C "$HOME" -cf - TigerBuild-1.1.pkg' | tar -C "$DIST" -xf -
echo "Wrote $DIST/TigerBuild-$VERSION.pkg"
"$SSH" 'open "$HOME/Desktop/Tiger Build.app"'
