#!/bin/sh
# Keep an encrypted SSH tunnel from this (the relay) computer to a Tiger Mac.
#   scripts/relay-tunnel.sh TIGER-ADDRESS [USER] [PORT]
# Then set Tiger Build > Preferences > relay address on that Mac to http://127.0.0.1:PORT (default 8765).
exec python3 "$(dirname "$0")/../relay/tunnel.py" "$@"
