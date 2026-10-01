#!/bin/bash
# Push ppc-commander and Tiger Build to the Tiger Mac, build the app there,
# and point it at this Mac's relay (address, port, and token).
#
# Run on the modern Mac after scripts/setup.sh. Needs a working key login
# (ppc-commander/bin/ppc-ssh 'echo ok' should print ok).
#
#   scripts/install-tiger.sh            install and open the app
#   NO_OPEN=1 scripts/install-tiger.sh  install without opening it

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSH="$ROOT/ppc-commander/bin/ppc-ssh"
LIBRARY="$HOME/Library/Application Support"
SUPPORT="${TIGERBUILD_RELAY_HOME:-$LIBRARY/Tiger Build Relay}"
if [ -z "${TIGERBUILD_RELAY_HOME:-}" ] && [ ! -d "$SUPPORT" ] && [ -d "$LIBRARY/TigerDesk" ]; then
  SUPPORT="$LIBRARY/TigerDesk"   # not yet moved by setup.sh
fi
export TIGERBUILD_RELAY_HOME="$SUPPORT"
CONFIG="${TIGERBUILD_RELAY_CONFIG:-${TIGERDESK_CONFIG:-$SUPPORT/config.sh}}"
if [ ! -f "$CONFIG" ]; then
  echo "Missing $CONFIG. Run scripts/setup.sh first." >&2
  exit 1
fi
# The installed relay is the one that runs; fall back to this checkout.
RELAY="$SUPPORT/app/relay/chat_proxy.py"
[ -f "$RELAY" ] || RELAY="$ROOT/relay/chat_proxy.py"

# shellcheck disable=SC1090
. "$CONFIG"
PORT="${LISTEN_PORT:-8765}"
ADDRESS="$(python3 "$RELAY" --print-address)"
case "$ADDRESS" in
  127.*|::1|localhost)
    echo "The relay listens on $ADDRESS, which the Tiger Mac cannot reach." >&2
    echo "Set LISTEN_ADDR in $CONFIG to this Mac's LAN address, or remove it." >&2
    exit 1 ;;
  0.0.0.0|::)
    echo "The relay listens on every interface. Set LISTEN_ADDR to one address." >&2
    exit 1 ;;
esac
TOKEN="$(python3 "$RELAY" --print-token)"
BASE="http://$ADDRESS:$PORT"

echo "Checking the key login to $TIGER_USER@$TIGER_HOST..."
"$SSH" 'echo ok' >/dev/null

echo "Installing onto $TIGER_USER@$TIGER_HOST; relay at $BASE"
"$SSH" 'killall TigerBuild >/dev/null 2>&1 || true
mkdir -p "$HOME/ppc-commander" "$HOME/TigerBuild-build/native" "$HOME/Library/Application Support/Tiger Build" "$HOME/Desktop"'

# ppc-commander. Its config.json and history stay as they are.
"$SSH" 'cat > "$HOME/ppc-commander/ppc_commander.py.new" && chmod 755 "$HOME/ppc-commander/ppc_commander.py.new" && mv "$HOME/ppc-commander/ppc_commander.py.new" "$HOME/ppc-commander/ppc_commander.py"' \
  < "$ROOT/ppc-commander/ppc_commander.py"
"$SSH" 'cd "$HOME/ppc-commander" && /usr/bin/python ppc_commander.py --self-test >/dev/null 2>"$HOME/ppc-commander/self-test.log" && echo "ppc-commander self-test passed" || { echo "ppc-commander self-test failed; see ~/ppc-commander/self-test.log" >&2; exit 1; }'

"$SSH" 'cat > "$HOME/ppc-commander/service.py" && chmod 755 "$HOME/ppc-commander/service.py"' < "$ROOT/ppc-commander/service.py"

# Relay address and token for the app. token.txt is readable only by its owner.
"$SSH" "printf '%s\n' '$BASE' > \"\$HOME/Library/Application Support/Tiger Build/server.txt\"
umask 077; printf '%s\n' '$TOKEN' > \"\$HOME/Library/Application Support/Tiger Build/token.txt\""

# Source, icon, and the model list built into the app for when the relay is
# unreachable. The app replaces it with the relay's live list at launch.
MODELS="$(mktemp)"
python3 "$RELAY" --models-text > "$MODELS"
"$SSH" 'rm -rf "$HOME/TigerBuild-build/native.new" && mkdir -p "$HOME/TigerBuild-build/native.new"'
COPYFILE_DISABLE=1 tar -C "$ROOT/tiger-build" --exclude '*.orig' --exclude 'TigerBuild.app' --exclude 'tbtests' -cf - . \
  | "$SSH" 'cd "$HOME/TigerBuild-build/native.new" && tar -xf -'
"$SSH" 'cat > "$HOME/TigerBuild-build/native.new/TigerBuild.icns"' < "$ROOT/assets/TigerBuild.icns"
"$SSH" 'cat > "$HOME/TigerBuild-build/native.new/models.txt"' < "$MODELS"
rm -f "$MODELS"

echo "Building on $TIGER_HOST (make test, then make)..."
"$SSH" 'cd "$HOME/TigerBuild-build/native.new" || exit 1
if ! make test > test.log 2>&1; then grep -v "^PASS" test.log; echo "make test failed" >&2; exit 1; fi
tail -1 test.log
if ! make > build.log 2>&1; then cat build.log; echo "make failed" >&2; exit 1; fi
grep -i "warning" build.log || true
test -x TigerBuild.app/Contents/MacOS/TigerBuild'
"$SSH" 'cd "$HOME/TigerBuild-build" && rm -rf native.old && mv native native.old && mv native.new native
rm -rf "$HOME/Desktop/Tiger Build.app" && cp -R native/TigerBuild.app "$HOME/Desktop/Tiger Build.app"'

# The root-owned policy file can only tighten ppc-commander. It needs sudo on
# the Tiger Mac, so it is optional: set TIGER_SUDO_POLICY=1 to be prompted.
if "$SSH" 'test -f /etc/ppc-commander.json'; then
  echo "/etc/ppc-commander.json is already in place."
elif [ "${TIGER_SUDO_POLICY:-0}" = "1" ]; then
  "$SSH" 'cat > /tmp/ppc-commander.json' << 'JSON'
{"blockedCommands":["mkfs","mkfs_hfs","newfs","newfs_hfs","fdisk","dd","shutdown","reboot","halt","poweroff"]}
JSON
  PPC_SSH_TTY=1 "$SSH" 'sudo sh -c "mv /tmp/ppc-commander.json /etc/ppc-commander.json && chown root:wheel /etc/ppc-commander.json && chmod 644 /etc/ppc-commander.json"' \
    || echo "Could not install the policy file; ppc-commander still works without it." >&2
else
  echo "Optional: TIGER_SUDO_POLICY=1 $0 installs /etc/ppc-commander.json (asks for the password of $TIGER_USER on $TIGER_HOST)."
fi

if [ "${NO_OPEN:-0}" != "1" ]; then
  "$SSH" 'open "$HOME/Desktop/Tiger Build.app"'
fi
echo "Tiger Build.app is on the desktop of $TIGER_USER@$TIGER_HOST, set to use the relay at $BASE."
