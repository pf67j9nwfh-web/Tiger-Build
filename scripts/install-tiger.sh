#!/bin/bash
# Push Tiger Build (and its Commander) to an old Mac, build the app there and put it on the desktop.
#
# Needs a working key login: ppc-commander/bin/ppc-ssh 'echo ok' should print ok (see the settings it reads, in that script).
#
#   scripts/install-tiger.sh            install and open the app
#   NO_OPEN=1 scripts/install-tiger.sh  install without opening it

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSH="${PPC_SSH:-$ROOT/ppc-commander/bin/ppc-ssh}"

echo "Checking the key login..."
"$SSH" 'echo ok' >/dev/null

"$SSH" 'killall TigerBuild >/dev/null 2>&1 || true
mkdir -p "$HOME/TigerBuild-build/native" "$HOME/Library/Application Support/Tiger Build" "$HOME/Desktop"'

# Source and icon, and the libraries the Makefile finds in ../third_party.
"$SSH" 'rm -rf "$HOME/TigerBuild-build/native.new" && mkdir -p "$HOME/TigerBuild-build/native.new" "$HOME/TigerBuild-build/third_party"'
COPYFILE_DISABLE=1 tar --no-xattrs --format gnutar -C "$ROOT/tiger-build" --exclude '*.orig' --exclude 'TigerBuild.app' --exclude 'tbtests' -cf - . \
  | "$SSH" 'cd "$HOME/TigerBuild-build/native.new" && tar -xf -'
COPYFILE_DISABLE=1 tar --no-xattrs --format gnutar -C "$ROOT/third_party" -cf - mbedtls/include mbedtls/lib mbedtls/tb_config.h libwebp/include libwebp/lib libde265/include libde265/lib libde265/LICENSE libaom/include libaom/lib libaom/LICENSE libaom/PATENTS openssh/bin openssh/LICENSE \
  | "$SSH" 'cd "$HOME/TigerBuild-build/third_party" && tar -xf -'
"$SSH" 'cat > "$HOME/TigerBuild-build/native.new/TigerBuild.icns"' < "$ROOT/assets/TigerBuild.icns"
# Commander is built with the app (the Makefile finds it in ../commander) and goes inside it.
"$SSH" 'rm -rf "$HOME/TigerBuild-build/commander" && mkdir -p "$HOME/TigerBuild-build/commander"'
COPYFILE_DISABLE=1 tar --no-xattrs --format gnutar -C "$ROOT/commander" --exclude 'ppc-commander*' --exclude build -cf - . \
  | "$SSH" 'cd "$HOME/TigerBuild-build/commander" && tar -xf -'

echo "Building (make test, then make)..."
"$SSH" 'cd "$HOME/TigerBuild-build/native.new" || exit 1
if ! make test > test.log 2>&1; then grep -v "^PASS" test.log; echo "make test failed" >&2; exit 1; fi
tail -1 test.log
if ! make > build.log 2>&1; then cat build.log; echo "make failed" >&2; exit 1; fi
grep -i "warning" build.log || true
test -x TigerBuild.app/Contents/MacOS/TigerBuild'
"$SSH" 'cd "$HOME/TigerBuild-build" && rm -rf native.old && mv native native.old && mv native.new native
rm -rf "$HOME/Desktop/Tiger Build.app" && cp -R native/TigerBuild.app "$HOME/Desktop/Tiger Build.app"'

# The root-owned policy file can only tighten Commander. It needs sudo on
# the Mac, so it is optional: set TIGER_SUDO_POLICY=1 to be prompted.
if "$SSH" 'test -f /etc/ppc-commander.json'; then
  echo "/etc/ppc-commander.json is already in place."
elif [ "${TIGER_SUDO_POLICY:-0}" = "1" ]; then
  "$SSH" 'cat > /tmp/ppc-commander.json' << 'JSON'
{"blockedCommands":["mkfs","mkfs_hfs","newfs","newfs_hfs","fdisk","dd","shutdown","reboot","halt","poweroff"]}
JSON
  PPC_SSH_TTY=1 "$SSH" 'sudo sh -c "mv /tmp/ppc-commander.json /etc/ppc-commander.json && chown root:wheel /etc/ppc-commander.json && chmod 644 /etc/ppc-commander.json"' \
    || echo "Could not install the policy file; Commander still works without it." >&2
else
  echo "Optional: TIGER_SUDO_POLICY=1 $0 installs /etc/ppc-commander.json (asks for the account's password)."
fi

if [ "${NO_OPEN:-0}" != "1" ]; then
  "$SSH" 'open "$HOME/Desktop/Tiger Build.app"'
fi
echo "Tiger Build.app is on the desktop. Open Preferences and add a key."
