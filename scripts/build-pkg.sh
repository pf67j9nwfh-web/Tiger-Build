#!/bin/bash
# Build a macOS installer package of the source tree. It does not contain
# the API key or SSH private key. After installing, run scripts/setup.sh.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="1.3.1"
STAGE="$(mktemp -d)"
DIST="$ROOT/dist"
mkdir -p "$DIST" "$STAGE"
rsync -a \
  --exclude '.git' \
  --exclude '.env' \
  --exclude '.env.*' \
  --exclude 'providers.json' \
  --exclude 'integrations.json' \
  --exclude '*-settings.plist' \
  --exclude 'last-client.json' \
  --exclude 'docs' \
  --exclude 'agent-notes.txt' \
  --exclude 'config.sh' \
  --exclude 'dist' \
  --exclude '*.pyc' \
  --exclude '__pycache__' \
  --exclude '.DS_Store' \
  --exclude '*.orig' \
  --exclude 'relay-token' \
  --exclude 'models-cache.json' \
  --exclude 'TigerBuild.app' \
  --exclude 'tbtests' \
  --exclude '.ssh' \
  --exclude 'id_rsa' \
  --exclude 'id_rsa.pub' \
  --exclude 'ppc_tiger_rsa' \
  --exclude 'ppc_tiger_known_hosts' \
  --exclude '*.pem' \
  --exclude '*.key' \
  "$ROOT/" "$STAGE/"
# .env.example documents empty key names and is safe to ship.
cp "$ROOT/.env.example" "$STAGE/.env.example"
python3 - "$STAGE" << 'PY'
import os, re, sys
root = sys.argv[1]
needles = (
    "BEGIN OPENSSH PRIVATE " + "KEY",
    "BEGIN RSA PRIVATE " + "KEY",
    "BEGIN PRIVATE " + "KEY",
    "sk-" + "ant-",
    "sk-" + "proj-",
    "xa" + "i-",
    "AI" + "za",
)
bad = []
for dirpath, dirnames, files in os.walk(root):
    dirnames[:] = [name for name in dirnames if name not in (".git", "__pycache__")]
    for name in files:
        path = os.path.join(dirpath, name)
        try:
            data = open(path, "rb").read()
        except IOError:
            continue
        if b"\0" in data[:512]:
            continue
        text = data.decode("utf-8", "ignore")
        for needle in needles:
            if needle in text:
                bad.append("%s matches %s" % (os.path.relpath(path, root), needle))
        for line in text.splitlines():
            match = re.match(r'^(?:export\s+)?([A-Za-z0-9_]+)\s*=\s*(.*)$', line.strip())
            if not match or not match.group(1).endswith("API_KEY"):
                continue
            value = match.group(2).strip().strip('"').strip("'")
            if value and len(value) > 8:
                bad.append("%s has a filled API key line" % os.path.relpath(path, root))
                break
if bad:
    sys.stderr.write("Refusing to build the installer because it would contain secrets:\n")
    for item in bad:
        sys.stderr.write(item + "\n")
    sys.exit(1)
print("secret scan ok")
PY
chmod 755 "$ROOT/installer/postinstall"
COMPONENT="$(mktemp -d)"
mkdir -p "$COMPONENT/scripts"
cp "$ROOT/installer/postinstall" "$COMPONENT/scripts/postinstall"
chmod 755 "$COMPONENT/scripts/postinstall"
pkgbuild \
  --root "$STAGE" \
  --identifier local.tigerbuild.relay.pkg \
  --version "$VERSION" \
  --install-location /usr/local/tiger-build-relay \
  --scripts "$COMPONENT/scripts" \
  "$COMPONENT/TigerBuildRelay-component.pkg"
APP_STAGE="$(mktemp -d)"
RELAY_GUI_PORTABLE=1 RELAY_GUI_OUTPUT="$APP_STAGE/Tiger Build Relay.app" bash "$ROOT/scripts/build-relay-gui.sh"
python3 - "$COMPONENT/app-components.plist" << 'PY'
import plistlib, sys
row = {"RootRelativeBundlePath": "Tiger Build Relay.app", "BundleIsRelocatable": False,
       "BundleIsVersionChecked": True, "BundleHasStrictIdentifier": True, "BundleOverwriteAction": "upgrade"}
open(sys.argv[1], "wb").write(plistlib.dumps([row]))
PY
pkgbuild --root "$APP_STAGE" --identifier local.tigerbuild.relaygui.pkg --version "$VERSION" --install-location /Applications --component-plist "$COMPONENT/app-components.plist" "$COMPONENT/TigerBuildRelayApp-component.pkg"
productbuild \
  --distribution "$ROOT/installer/distribution.xml" \
  --resources "$ROOT/installer/resources" \
  --package-path "$COMPONENT" \
  "$DIST/TigerBuildRelay-$VERSION.pkg"
rm -rf "$STAGE" "$COMPONENT" "$APP_STAGE"
echo "Wrote $DIST/TigerBuildRelay-$VERSION.pkg"
