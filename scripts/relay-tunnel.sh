#!/bin/sh
# Keep an SSH tunnel to the Tiger Build relay open, so the chat and its files are encrypted on the network.
# Run on the Tiger Mac:   scripts/relay-tunnel.sh RELAY-ADDRESS [USER] [PORT]
# Then set Tiger Build > Preferences > relay address to http://127.0.0.1:PORT (default 8765).
RELAY="$1"
USER_NAME="${2:-$USER}"
PORT="${3:-8765}"
if [ -z "$RELAY" ]; then
    echo "usage: $0 RELAY-ADDRESS [USER] [PORT]" >&2
    exit 2
fi
while true; do
    ssh -N -L "$PORT:$RELAY:$PORT" -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes \
        -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa "$USER_NAME@$RELAY"
    echo "Tunnel closed; reconnecting in 5 seconds (Control-C to stop)." >&2
    sleep 5
done
