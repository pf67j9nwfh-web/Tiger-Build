#!/bin/bash
# Build a Debian/Ubuntu package. No API keys are included.
# Uses dpkg-deb on Linux, or scripts/pack_deb.py when that is not installed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="1.3.1"
STAGE="$(mktemp -d)"
DIST="$ROOT/dist"
mkdir -p "$DIST"
python3 "$ROOT/scripts/stage_tree.py" "$STAGE/opt/tiger-build-relay"
# No packaged service unit. setup.py writes the user unit for the copy it
# starts, so a package upgrade cannot launch a second relay from /opt.
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/bin"
cat > "$STAGE/DEBIAN/control" << EOF
Package: tiger-build-relay
Version: $VERSION
Section: net
Priority: optional
Architecture: all
Depends: python3 (>= 3.8), python3-tk, openssh-client (>= 1:9.1)
Maintainer: Tiger Build <tigerbuild@localhost>
Description: Tiger Build Relay
 Connects Mac OS X Tiger to current AI services. No API keys are included.
 After installing, run /opt/tiger-build-relay/scripts/setup.py as your user.
EOF
cat > "$STAGE/DEBIAN/postinst" << 'EOF'
#!/bin/sh
echo "Tiger Build Relay 1.3.1 is in /opt/tiger-build-relay."
echo "As your user, run: python3 /opt/tiger-build-relay/scripts/setup.py"
echo "Then open Tiger Build Relay from the application menu."
chmod 755 /opt/tiger-build-relay/scripts/setup.py /opt/tiger-build-relay/scripts/setup.sh /opt/tiger-build-relay/relay/chat_proxy.py 2>/dev/null || true
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"
mkdir -p "$STAGE/usr/share/applications" "$STAGE/usr/share/icons/hicolor/128x128/apps"
cp "$ROOT/assets/icon-128.png" "$STAGE/usr/share/icons/hicolor/128x128/apps/tiger-build-relay.png"
cat > "$STAGE/usr/share/applications/tiger-build-relay.desktop" << 'EOF'
[Desktop Entry]
Version=1.3.1
Type=Application
Name=Tiger Build Relay
GenericName=Relay settings
Comment=Start, stop, and configure Tiger Build Relay. Settings stay in your home folder.
Exec=/usr/bin/python3 /opt/tiger-build-relay/relay/settings_gui.py
Icon=tiger-build-relay
Terminal=false
Categories=Network;Settings;
StartupNotify=true
EOF
printf '%s\n' '#!/bin/sh' 'exec python3 /opt/tiger-build-relay/relay/settings_gui.py "$@"' > "$STAGE/usr/bin/tiger-build-relay-settings"
chmod 755 "$STAGE/usr/bin/tiger-build-relay-settings"
printf '%s\n' '#!/bin/sh' 'exec python3 /opt/tiger-build-relay/scripts/setup.py "$@"' > "$STAGE/usr/bin/tiger-build-relay"
chmod 755 "$STAGE/usr/bin/tiger-build-relay"
OUT="$DIST/tiger-build-relay_${VERSION}_all.deb"
if command -v dpkg-deb >/dev/null 2>&1; then
  dpkg-deb --root-owner-group -Zgzip --build "$STAGE" "$OUT"
else
  python3 "$ROOT/scripts/pack_deb.py" "$STAGE" "$OUT"
fi
rm -rf "$STAGE"
echo "Wrote $DIST/tiger-build-relay_${VERSION}_all.deb"
