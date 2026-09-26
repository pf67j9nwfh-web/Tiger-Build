#!/bin/bash
# Install Tiger Desk for the current user: config, relay, and ssh helpers.
# Run this on the modern Mac, from a checkout of this repository or from
# /usr/local/tiger-desk after the installer package.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/TigerDesk"
mkdir -p "$SUPPORT" "$HOME/Library/LaunchAgents" "$HOME/.ssh"
chmod 755 "$ROOT/ppc-commander/bin/"* "$ROOT/scripts/"*.sh "$ROOT/relay/chat_proxy.py" || true

if [ ! -f "$SUPPORT/config.sh" ]; then
  cp "$ROOT/config.example.sh" "$SUPPORT/config.sh"
  echo "Wrote $SUPPORT/config.sh"
  echo "Edit TIGER_HOST and TIGER_USER, then run this script again."
fi

# Keep a key file from an older checkout working without copying it into git.
if [ ! -f "$ROOT/.env" ] && [ -f "$HOME/AquaChat/.env" ]; then
  cp "$HOME/AquaChat/.env" "$ROOT/.env"
  chmod 600 "$ROOT/.env"
fi
if [ ! -f "$ROOT/.env" ]; then
  echo "Copy .env.example to $ROOT/.env and add the provider keys before chatting."
fi

PYTHON="$(command -v python3)"
if [ -f "$ROOT/.env" ] || [ -f "$HOME/AquaChat/.env" ]; then
  "$PYTHON" "$ROOT/relay/chat_proxy.py" --write-config
fi

# Leave the previous Grok MCP path working.
if [ -d "$HOME/ppc-commander/bin" ]; then
  ln -sfn "$ROOT/ppc-commander/bin/ppc-ssh" "$HOME/ppc-commander/bin/ppc-ssh"
  ln -sfn "$ROOT/ppc-commander/bin/ppc-commander-ssh" "$HOME/ppc-commander/bin/ppc-commander-ssh"
fi

PLIST="$HOME/Library/LaunchAgents/local.jr.tigerdesk.relay.plist"
cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.jr.tigerdesk.relay</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PYTHON</string>
    <string>$ROOT/relay/chat_proxy.py</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$ROOT</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardErrorPath</key>
  <string>$SUPPORT/relay.log</string>
  <key>StandardOutPath</key>
  <string>$SUPPORT/relay.log</string>
</dict>
</plist>
EOF

UID_NUM="$(id -u)"
launchctl bootout "gui/$UID_NUM/local.jr.tigerdesk.relay" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl enable "gui/$UID_NUM/local.jr.tigerdesk.relay" >/dev/null 2>&1 || true
launchctl kickstart -k "gui/$UID_NUM/local.jr.tigerdesk.relay"
echo "Relay installed. Log: $SUPPORT/relay.log"
echo "Push the Power Mac side with: $ROOT/scripts/install-tiger.sh"
