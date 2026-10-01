# Tiger Build Relay: which Tiger Mac to use.
# Copy to ~/Library/Application Support/Tiger Build Relay/config.sh and edit.
# scripts/setup.sh does the copy for you on its first run.

# The Tiger Mac's IP address or name, and the account on it that runs
# ppc-commander. Find the address in System Preferences > Network on that Mac.
TIGER_HOST=""
TIGER_USER=""

# The ssh-rsa key the relay uses to log in, and that Mac's saved host key.
TIGER_KEY="$HOME/.ssh/ppc_tiger_rsa"
TIGER_KNOWN="$HOME/.ssh/ppc_tiger_known_hosts"

# Expanded by the Tiger Mac, so leave $HOME in place.
REMOTE_COMMANDER='$HOME/ppc-commander/ppc_commander.py'

# The relay's port. Tiger Build's Preferences must use the same one.
LISTEN_PORT="8765"

# Optional:
#   LISTEN_ADDR="192.168.1.10"     address to listen on (default: the one facing TIGER_HOST)
#   ALLOWED_CLIENTS="192.168.1.20" who may connect (default: TIGER_HOST and this Mac)
#   RELAY_TOKEN="..."              fixed token (default: generated into relay-token)
#   TIGER_HOME="/Users/name"       the account's home folder, if it is not /Users/TIGER_USER
