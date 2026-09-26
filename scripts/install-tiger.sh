#!/bin/bash
# Copy ppc-commander and Tiger Build onto the Power Mac and build the app.
# Requires config.sh and a working key login (scripts/ppc-ssh).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSH="$ROOT/ppc-commander/bin/ppc-ssh"
CONFIG="${TIGERDESK_CONFIG:-$HOME/Library/Application Support/TigerDesk/config.sh}"
if [ ! -f "$CONFIG" ]; then
  echo "Missing $CONFIG. Run scripts/setup.sh first." >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$CONFIG"

PORT="${LISTEN_PORT:-8765}"
IFACE="$(route -n get "$TIGER_HOST" 2>/dev/null | awk '/interface:/{print $2; exit}')"
LAN_IP=""
if [ -n "$IFACE" ]; then
  LAN_IP="$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)"
fi
if [ -z "$LAN_IP" ]; then
  echo "Could not find a LAN address toward $TIGER_HOST." >&2
  exit 1
fi

echo "Installing onto $TIGER_USER@$TIGER_HOST, chat relay at http://$LAN_IP:$PORT"
"$SSH" 'if [ -d "$HOME/AquaChat-build" ] && [ ! -d "$HOME/TigerBuild-build" ]; then mv "$HOME/AquaChat-build" "$HOME/TigerBuild-build"; fi
if [ -d "$HOME/Library/Application Support/AquaChat" ] && [ ! -d "$HOME/Library/Application Support/Tiger Build" ]; then mv "$HOME/Library/Application Support/AquaChat" "$HOME/Library/Application Support/Tiger Build"; fi
mkdir -p "$HOME/ppc-commander" "$HOME/TigerBuild-build/native" "$HOME/Library/Application Support/Tiger Build" "$HOME/Desktop"'
"$SSH" 'cat > "$HOME/ppc-commander/ppc_commander.py"' < "$ROOT/ppc-commander/ppc_commander.py"
"$SSH" "printf '%s\n' 'http://$LAN_IP:$PORT' > \"\$HOME/Library/Application Support/Tiger Build/server.txt\""
"$SSH" 'chmod 755 "$HOME/ppc-commander/ppc_commander.py"'
COPYFILE_DISABLE=1 tar -C "$ROOT/tiger-build" -cf - . | "$SSH" 'cd "$HOME/TigerBuild-build/native" && tar -xf -'
"$SSH" 'cat > "$HOME/TigerBuild-build/native/TigerBuild.icns"' < "$ROOT/assets/TigerBuild.icns"
"$SSH" 'cd "$HOME/TigerBuild-build/native" && make clean && make'
"$SSH" 'rm -rf "$HOME/Desktop/AquaChat.app" "$HOME/Desktop/Millrace.app" "$HOME/Desktop/Tiger Build.app" && cp -R "$HOME/TigerBuild-build/native/TigerBuild.app" "$HOME/Desktop/Tiger Build.app"'
echo "Tiger Build.app is on the Power Mac desktop."
