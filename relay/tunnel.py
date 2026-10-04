"""Keep an SSH tunnel from the relay computer to a Tiger Mac, so the Mac can reach the relay at
http://127.0.0.1:PORT through an encrypted link instead of plain HTTP across the network.

The relay computer opens the connection (as it already does for Commander, with the same key and
the older algorithms Tiger's OpenSSH speaks) and asks the Tiger Mac to listen on its own loopback
address and pass what it receives to the relay. Run:

    python3 tunnel.py TIGER-ADDRESS [USER] [PORT]

and set the relay address in Tiger Build's Preferences to http://127.0.0.1:PORT. Press Control-C to stop.
"""
import subprocess
import sys
import time

from connection import ensure_key
from mcp_bridge import load_shell_config
from security import listen_address


def command(config, host, user, port):
    listen = listen_address(config)
    relay_port = config.get("LISTEN_PORT") or "8765"
    return [
        "ssh", "-N",
        "-R", "127.0.0.1:%s:%s:%s" % (port, listen, relay_port),
        "-i", config["TIGER_KEY"],
        "-o", "IdentitiesOnly=yes",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "ServerAliveInterval=30",
        "-o", "HostKeyAlgorithms=ssh-rsa",
        "-o", "PubkeyAcceptedAlgorithms=ssh-rsa",
        "-o", "KexAlgorithms=diffie-hellman-group-exchange-sha256,diffie-hellman-group14-sha1",
        "-o", "Ciphers=aes256-ctr,aes128-ctr",
        "-o", "MACs=hmac-sha1",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "UserKnownHostsFile=" + config["TIGER_KNOWN"],
        "%s@%s" % (user, host),
    ]


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    config = load_shell_config()
    host = argv[1]
    user = argv[2] if len(argv) > 2 else (config.get("TIGER_USER") or "")
    port = argv[3] if len(argv) > 3 else (config.get("LISTEN_PORT") or "8765")
    if not user:
        sys.stderr.write("Give the Tiger Mac's account name as the second argument.\n")
        return 2
    ensure_key(config)
    while True:
        sys.stderr.write("Tunnel to %s@%s: the Mac reaches the relay at http://127.0.0.1:%s\n" % (user, host, port))
        subprocess.call(command(config, host, user, port))
        sys.stderr.write("The tunnel closed. Reconnecting in 5 seconds (Control-C to stop).\n")
        time.sleep(5)


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except KeyboardInterrupt:
        raise SystemExit(0)
