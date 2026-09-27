#!/bin/bash
# Build a macOS installer package of the source tree. It does not contain
# the API key or SSH private key. After installing, run scripts/setup.sh.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="1.1"
STAGE="$(mktemp -d)"
DIST="$ROOT/dist"
mkdir -p "$DIST" "$STAGE"
rsync -a \
  --exclude '.git' \
  --exclude '.env' \
  --exclude '.env.*' \
  --exclude 'providers.json' \
  --exclude 'config.sh' \
  --exclude 'dist' \
  --exclude '*.pyc' \
  --exclude '__pycache__' \
  --exclude '.DS_Store' \
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
  --identifier local.jr.tigerdesk \
  --version "$VERSION" \
  --install-location /usr/local/tiger-desk \
  --scripts "$COMPONENT/scripts" \
  "$COMPONENT/TigerDesk-component.pkg"
productbuild \
  --distribution "$ROOT/installer/distribution.xml" \
  --resources "$ROOT/installer/resources" \
  --package-path "$COMPONENT" \
  "$DIST/TigerDesk-$VERSION.pkg"
rm -rf "$STAGE" "$COMPONENT"
echo "Wrote $DIST/TigerDesk-$VERSION.pkg"
