"""The relay's SSH link to the Tiger Mac: settings, keys, and diagnosis.

Three jobs:
  * read and write the Tiger Mac's address and user in config.sh, so they can
    be set from the relay app or by Tiger Build itself and not only by editing
    the file;
  * make the SSH key the relay logs in with, and remember the Mac's host key;
  * turn the terse errors ssh prints into a sentence a person can act on.
"""

import os
import re
import shlex
import subprocess
import sys
import threading

from mcp_bridge import load_shell_config, ssh_base
from paths import config_sh

_LOCK = threading.RLock()
HOST_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9._:-]{0,252}[A-Za-z0-9])?$")
USER_RE = re.compile(r"^[A-Za-z0-9._][A-Za-z0-9._-]{0,63}$")
HOME_RE = re.compile(r"^/[A-Za-z0-9 ._/+@-]{0,200}$")
EDITABLE = ("TIGER_HOST", "TIGER_USER", "TIGER_HOME")


def validate(name, value):
    value = (value or "").strip()
    if value == "":
        return value
    if name == "TIGER_HOST" and HOST_RE.match(value):
        return value
    if name == "TIGER_USER" and USER_RE.match(value):
        return value
    if name == "TIGER_HOME" and HOME_RE.match(value) and ".." not in value:
        return value.rstrip("/") or "/"
    labels = {
        "TIGER_HOST": "The Tiger Mac's address must be an IP address or name such as 192.168.1.20.",
        "TIGER_USER": "The Tiger Mac's user name must be the short name, such as jr.",
        "TIGER_HOME": "The home folder must be an absolute path such as /Users/jr.",
    }
    raise ValueError(labels.get(name, "Unsupported setting."))


def _render(value):
    return '"%s"' % value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")


def update_config(changes):
    """Set TIGER_HOST, TIGER_USER and TIGER_HOME in config.sh, keeping every
    other line. Blank removes the value. Returns the new settings."""
    clean = {}
    for name, value in changes.items():
        if name not in EDITABLE:
            raise ValueError("Unsupported setting %s." % name)
        clean[name] = validate(name, value)
    with _LOCK:
        path = config_sh()
        try:
            with open(path) as handle:
                lines = handle.read().splitlines()
        except OSError:
            lines = ["# Tiger Build Relay settings."]
        seen = set()
        out = []
        for line in lines:
            key = line.split("=", 1)[0].strip() if "=" in line and not line.lstrip().startswith("#") else ""
            if key in clean:
                if key in seen:
                    continue
                seen.add(key)
                out.append("%s=%s" % (key, _render(clean[key])))
            else:
                out.append(line)
        for key, value in clean.items():
            if key not in seen:
                out.append("%s=%s" % (key, _render(value)))
        temporary = path + ".tmp"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            handle.write("\n".join(out) + "\n")
        os.replace(temporary, path)
    return load_shell_config()


def _run(args, timeout=30):
    flags = 0
    if sys.platform == "win32":
        flags = 0x08000000  # CREATE_NO_WINDOW
    return subprocess.run(
        args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=timeout, creationflags=flags,
    )


def ensure_key(config=None):
    """Create the login key if it is missing. Returns the public key line."""
    config = config or load_shell_config()
    key = config["TIGER_KEY"]
    with _LOCK:
        if not os.path.isfile(key):
            folder = os.path.dirname(key)
            os.makedirs(folder, mode=0o700, exist_ok=True)
            # Tiger's OpenSSH 5.x signs only with ssh-rsa, so the key must be RSA.
            result = _run(["ssh-keygen", "-q", "-t", "rsa", "-b", "2048", "-N", "", "-C", "tiger-build-relay", "-f", key])
            if result.returncode != 0 or not os.path.isfile(key):
                raise RuntimeError("Could not make the SSH key: " + result.stderr.decode("utf-8", "replace").strip())
        pub = key + ".pub"
        if not os.path.isfile(pub):
            result = _run(["ssh-keygen", "-y", "-f", key])
            if result.returncode != 0:
                raise RuntimeError("Could not read the SSH key.")
            with open(pub, "w") as handle:
                handle.write(result.stdout.decode().strip() + " tiger-build-relay\n")
        with open(pub) as handle:
            return handle.read().strip()


def known_host_present(config):
    path = config["TIGER_KNOWN"]
    host = config.get("TIGER_HOST") or ""
    if not host or not os.path.isfile(path):
        return False
    try:
        result = _run(["ssh-keygen", "-F", host, "-f", path], timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0 and bool(result.stdout.strip())


def remember_host_key(config=None):
    """Save the Tiger Mac's ssh-rsa host key on first contact. Called only
    after the person at that Mac has agreed to connect, so the key a LAN
    scan returns is the one they expect."""
    config = config or load_shell_config()
    host = config.get("TIGER_HOST") or ""
    if not host:
        raise RuntimeError("The Tiger Mac's address is not set.")
    if known_host_present(config):
        return False
    result = _run(["ssh-keyscan", "-t", "rsa", "-T", "8", host], timeout=20)
    text = result.stdout.decode("utf-8", "replace")
    lines = [line for line in text.splitlines() if line and not line.startswith("#")]
    if not lines:
        raise RuntimeError(
            "Could not read a host key from %s. Check that Remote Login is on "
            "(System Preferences, Sharing) and the address is right." % host)
    path = config["TIGER_KNOWN"]
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    with open(path, "a") as handle:
        handle.write("\n".join(lines) + "\n")
    return True


def forget_host_key(config=None):
    """Drop the saved host key so the next connection learns it again. For a
    Mac that was reinstalled or got a new address."""
    config = config or load_shell_config()
    host = config.get("TIGER_HOST") or ""
    path = config["TIGER_KNOWN"]
    if not host or not os.path.isfile(path):
        return False
    result = _run(["ssh-keygen", "-R", host, "-f", path])
    return result.returncode == 0


# What each ssh failure means and what to do. Matched in order.
DIAGNOSES = (
    ("unlinked", ("This Mac has not been connected",),
     "This Mac is not connected to the relay for Commander yet. In Tiger Build choose Configuration, "
     "Connect Commander over SSH."),
    ("stopped", ("Commander is stopped",),
     "Commander is stopped on the Tiger Mac. In Tiger Build there, choose Commander, Start."),
    ("host_key_changed", ("REMOTE HOST IDENTIFICATION HAS CHANGED", "Host key verification failed"),
     "The Tiger Mac's SSH identity changed since the relay first connected (a reinstall, or a different "
     "computer at this address). If you expected that, choose Forget Saved Host Key in the relay app "
     "or in Tiger Build's Configuration menu, then connect again."),
    ("auth", ("Permission denied", "no mutual signature", "Too many authentication failures"),
     "The Tiger Mac refused the relay's SSH key. Tiger Build can install it: choose Configuration, "
     "Connect Commander over SSH in Tiger Build on that Mac. Also check that the user name is right."),
    ("refused", ("Connection refused",),
     "The Tiger Mac is not accepting SSH connections. Turn on Remote Login in System Preferences, "
     "Sharing on that Mac."),
    ("unreachable", ("No route to host", "Network is unreachable", "Host is down"),
     "The relay cannot reach the Tiger Mac. Check that it is awake, on the network, and that the "
     "address in the relay settings is current."),
    ("timeout", ("timed out", "Connection timed out", "Operation timed out"),
     "The Tiger Mac did not answer. It may be asleep, or a firewall blocks port 22."),
    ("dns", ("Could not resolve hostname", "Name or service not known", "nodename nor servname"),
     "The Tiger Mac's address could not be looked up. Use its IP address in the relay settings."),
    ("key_missing", ("No such file or directory", "no such identity", "not accessible"),
     "The relay's SSH key file is missing. Tiger Build can make and install a new one: choose "
     "Configuration, Connect Commander over SSH."),
    ("kex", ("no matching key exchange", "no matching cipher", "no matching host key type", "no matching MAC"),
     "The Tiger Mac and the relay's SSH could not agree on an algorithm. The relay needs OpenSSH 9.1 "
     "or later (see the README)."),
    ("old_ssh", ("unknown option", "Bad configuration option", "unsupported option"),
     "This computer's OpenSSH is too old for the relay. Update it to 9.1 or later."),
)


def diagnose(stderr, exc=None, config=None):
    """(code, message) for an ssh failure. code is "" when it is not a known
    SSH problem; message then repeats the raw text."""
    text = (stderr or "").strip()
    config = config or {}
    if not config.get("TIGER_HOST") or not config.get("TIGER_USER"):
        return ("unset", "The Tiger Mac's address or user name is not set. Open the relay app's settings, "
                "or choose Configuration, Connect Commander over SSH in Tiger Build.")
    for code, needles, message in DIAGNOSES:
        for needle in needles:
            if needle.lower() in text.lower():
                return (code, message)
    detail = text.splitlines()[-1] if text else (str(exc) if exc else "")
    if exc is not None and "closed the connection" in str(exc) and not text:
        return ("closed", "The Tiger Mac closed the connection straight away. Check that ppc-commander is "
                "installed at %s on that Mac and that Remote Login allows this user." % config.get("REMOTE_COMMANDER", ""))
    return ("", detail)


def test(config=None):
    """Try the login and look for ppc-commander. {ok, code, message}."""
    config = config or load_shell_config()
    if not config.get("TIGER_HOST") or not config.get("TIGER_USER"):
        code, message = diagnose("", None, config)
        return {"ok": False, "code": code, "message": message}
    if not os.path.isfile(config["TIGER_KEY"]):
        code, message = diagnose("no such identity file", None, config)
        return {"ok": False, "code": code, "message": message}
    command = ssh_base(config) + ["test -f %s && echo commander-ok || echo commander-missing" % (
        config["REMOTE_COMMANDER"].replace("'", ""))]
    try:
        result = _run(command, timeout=25)
    except subprocess.TimeoutExpired:
        code, message = diagnose("Connection timed out", None, config)
        return {"ok": False, "code": code, "message": message}
    except OSError as exc:
        return {"ok": False, "code": "no_ssh", "message": "The ssh program could not be run: %s" % exc}
    out = result.stdout.decode("utf-8", "replace")
    if result.returncode == 0 and "commander-ok" in out:
        return {"ok": True, "code": "", "message": "Connected to %s@%s." % (config["TIGER_USER"], config["TIGER_HOST"])}
    if result.returncode == 0 and "commander-missing" in out:
        return {"ok": False, "code": "no_commander",
                "message": "SSH works, but ppc-commander is not installed on the Tiger Mac. Open Tiger Build "
                           "on that Mac; it installs ppc-commander when it starts."}
    code, message = diagnose(result.stderr.decode("utf-8", "replace"), None, config)
    return {"ok": False, "code": code, "message": message or "SSH failed."}


def install_key_interactive(config=None):
    """Put the relay's public key on the Tiger Mac with one ssh login. ssh asks
    for that account's password on the person's own terminal; nothing here sees
    it. Only for a terminal: Tiger Build can do the same without a password."""
    config = config or load_shell_config()
    public = ensure_key(config)
    if not config.get("TIGER_HOST") or not config.get("TIGER_USER"):
        raise RuntimeError("Set the Tiger Mac's address and user first.")
    os.makedirs(os.path.dirname(config["TIGER_KNOWN"]), mode=0o700, exist_ok=True)
    command = [
        "ssh",
        "-o", "HostKeyAlgorithms=ssh-rsa",
        "-o", "PubkeyAcceptedAlgorithms=ssh-rsa",
        "-o", "KexAlgorithms=diffie-hellman-group-exchange-sha256,diffie-hellman-group14-sha1",
        "-o", "Ciphers=aes256-ctr,aes128-ctr",
        "-o", "MACs=hmac-sha1",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "UserKnownHostsFile=" + config["TIGER_KNOWN"],
        "-o", "ConnectTimeout=15",
        "%s@%s" % (config["TIGER_USER"], config["TIGER_HOST"]),
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys",
    ]
    result = subprocess.run(command, input=(public + "\n").encode(), timeout=300)
    return result.returncode == 0


# ---- one link per Tiger Build computer ----
#
# Commander runs on the Mac that is chatting. The relay remembers, for each
# computer that has connected, which account to sign in as; a computer that has
# not connected gets no Commander rather than someone else's.

def clients_path():
    from paths import support_dir
    return os.path.join(support_dir(), "ssh-clients.json")


def _plain(address):
    address = (address or "").strip()
    return address[7:] if address.startswith("::ffff:") else address


def load_clients():
    import json
    try:
        with open(clients_path()) as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def register_client(address, user, home="", host=""):
    """Remember how to reach the Mac at this address. host defaults to the
    address itself; a different host sends this computer's tools elsewhere."""
    import json
    address = _plain(address)
    user = validate("TIGER_USER", user)
    home = validate("TIGER_HOME", home) if home else ""
    host = validate("TIGER_HOST", host) if host else address
    if not address or not user:
        raise ValueError("A client address and user name are needed.")
    with _LOCK:
        data = load_clients()
        data[address] = {"host": host, "user": user, "home": home}
        path = clients_path()
        temporary = path + ".tmp"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            json.dump(data, handle, indent=2)
        os.replace(temporary, path)
    return data[address]


def target_config(config, address):
    """The settings for running Commander for the computer at address, or None
    when that computer has not been connected."""
    address = _plain(address)
    cfg = dict(config)
    entry = load_clients().get(address)
    if entry:
        cfg["TIGER_HOST"] = entry.get("host") or address
        cfg["TIGER_USER"] = entry.get("user") or ""
        cfg["TIGER_HOME"] = entry.get("home") or ""
        return cfg
    if address in ("", "127.0.0.1", "::1"):
        return cfg  # the relay computer itself: tests and health checks
    default = (config.get("TIGER_HOST") or "").strip()
    if default and (default == address or _resolves_to(default, address)):
        return cfg
    return None


def _resolves_to(name, address):
    import socket
    try:
        return socket.gethostbyname(name) == address
    except OSError:
        return False


def describe(config=None):
    """Settings and key state for the apps. No secrets."""
    config = config or load_shell_config()
    key = config["TIGER_KEY"]
    return {
        "host": config.get("TIGER_HOST", ""),
        "user": config.get("TIGER_USER", ""),
        "home": config.get("TIGER_HOME", ""),
        "key": key,
        "key_exists": os.path.isfile(key),
        "host_key_saved": bool(config.get("TIGER_HOST")) and known_host_present(config),
    }


def shell_quote(text):
    return shlex.quote(text)
