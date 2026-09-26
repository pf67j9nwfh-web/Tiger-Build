#!/bin/bash
# Build a macOS installer package of the source tree. It does not contain
# the API key or SSH private key. After installing, run scripts/setup.sh.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="1.0.0"
STAGE="$(mktemp -d)"
DIST="$ROOT/dist"
mkdir -p "$DIST" "$STAGE"
rsync -a \
  --exclude '.git' \
  --exclude '.env' \
  --exclude 'dist' \
  --exclude '*.pyc' \
  --exclude '__pycache__' \
  --exclude '.DS_Store' \
  "$ROOT/" "$STAGE/"
chmod 755 "$ROOT/installer/postinstall"
pkgbuild \
  --root "$STAGE" \
  --identifier local.jr.tigerdesk \
  --version "$VERSION" \
  --install-location /usr/local/tiger-desk \
  --scripts "$ROOT/installer" \
  "$DIST/TigerDesk-$VERSION.pkg"
rm -rf "$STAGE"
echo "Wrote $DIST/TigerDesk-$VERSION.pkg"
