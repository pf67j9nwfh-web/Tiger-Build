"""Who may talk to the relay, and on which address it listens.

The relay can run shell commands on the Tiger Mac and spend API credit, so
every request except the bare /health line must carry the shared token in
X-TigerBuild-Token, and must come from an address in ALLOWED_CLIENTS.
"""

import hmac
import os
import secrets
import socket

TOKEN_HEADER = "X-TigerBuild-Token"


from paths import support_dir  # noqa: E402  (one place for every path)


def token_path():
    return os.path.join(support_dir(), "relay-token")


def relay_token(config):
    """RELAY_TOKEN from config.sh, or a random token kept in relay-token (0600)."""
    value = (config.get("RELAY_TOKEN") or "").strip()
    if value:
        return value
    path = token_path()
    try:
        handle = open(path, "r")
        try:
            value = handle.read().strip()
        finally:
            handle.close()
    except IOError:
        value = ""
    if value:
        return value
    value = secrets.token_hex(24)
    temporary = path + ".tmp"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    handle = os.fdopen(descriptor, "w")
    try:
        handle.write(value + "\n")
    finally:
        handle.close()
    os.replace(temporary, path)
    return value


def token_ok(offered, expected):
    if not expected or not isinstance(offered, str):
        return False
    return hmac.compare_digest(offered.strip().encode("utf-8"), expected.encode("utf-8"))


def address_toward(host):
    """The local address this Mac uses to reach host, without sending anything."""
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect((host, 9))
        return probe.getsockname()[0]
    finally:
        probe.close()


def listen_address(config):
    """LISTEN_ADDR, else the one interface that faces the Tiger Mac, else loopback.

    The relay never listens on every interface unless LISTEN_ADDR is set to
    0.0.0.0 on purpose.
    """
    chosen = (config.get("LISTEN_ADDR") or "").strip()
    if chosen:
        return chosen
    host = (config.get("TIGER_HOST") or "").strip()
    if host:
        try:
            return address_toward(host)
        except OSError:
            pass
    else:
        # No Tiger Mac yet: the address on the network this computer
        # reaches the internet through (nothing is sent to find it).
        try:
            found = address_toward("192.0.2.1")
            if found and not found.startswith("127."):
                return found
        except OSError:
            pass
    return "127.0.0.1"


def allowed_clients(config):
    raw = (config.get("ALLOWED_CLIENTS") or "").replace(",", " ").split()
    if raw:
        return set(raw)
    allowed = {"127.0.0.1", "::1"}
    host = (config.get("TIGER_HOST") or "").strip()
    if host:
        allowed.add(host)
    else:
        # No Tiger Mac is set up yet. Let computers on a private network
        # connect so Tiger Build can introduce itself; the token still applies.
        allowed.add("private")
    return allowed


def client_allowed(address, allowed):
    if not address:
        return False
    if address.startswith("::ffff:"):
        address = address[7:]
    if "private" in allowed:
        import ipaddress
        try:
            if ipaddress.ip_address(address).is_private:
                return True
        except ValueError:
            pass
    return "*" in allowed or address in allowed
