#!/bin/bash
# Install Tiger Build Relay for the current user and start it.
# macOS and Linux. Windows runs: python scripts\\setup.py
exec python3 "$(cd "$(dirname "$0")" && pwd)/setup.py" "$@"
