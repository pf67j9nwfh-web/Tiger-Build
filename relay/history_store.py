"""Owner-private Tiger Build history snapshots; authenticated by Handler."""
import os
import plistlib
import threading
LOCK = threading.Lock()
from security import support_dir


def snapshot_path():
    folder = os.path.join(support_dir(), "history")
    os.makedirs(folder, mode=0o700, exist_ok=True)
    os.chmod(folder, 0o700)
    return os.path.join(folder, "TigerBuild-history.plist")


def save_snapshot(payload):
    with LOCK:
        return _save_snapshot(payload)


def _check_chats(chats):
    if not isinstance(chats, list):
        raise ValueError("History must contain a chats list.")
    if any(not isinstance(c, dict) or not isinstance(c.get("messages"), list) for c in chats):
        raise ValueError("Malformed chat history.")


def _save_snapshot(payload):
    if not payload or len(payload) > 16 * 1024 * 1024:
        raise ValueError("History must be between 1 byte and 16 MB.")
    try:
        root = plistlib.loads(payload)
    except Exception:
        raise ValueError("Not a valid history property list.")
    if not isinstance(root, dict):
        raise ValueError("History must contain a chats list.")
    if root.get("format") == "TigerBuild-history":
        # 1.3: every workspace in one file.
        spaces = root.get("workspaces")
        if not isinstance(spaces, dict) or not spaces:
            raise ValueError("History must contain workspaces.")
        for name, space in spaces.items():
            if not isinstance(name, str) or not isinstance(space, dict):
                raise ValueError("Malformed workspace.")
            _check_chats(space.get("chats"))
    else:
        _check_chats(root.get("chats"))
    path = snapshot_path()
    temporary = path + ".tmp"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(plistlib.dumps(root, fmt=plistlib.FMT_XML))
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def read_snapshot():
    with open(snapshot_path(), "rb") as handle:
        return handle.read()
