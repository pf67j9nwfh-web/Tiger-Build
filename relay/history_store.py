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


def _save_snapshot(payload):
    if not payload or len(payload) > 16 * 1024 * 1024:
        raise ValueError("History must be between 1 byte and 16 MB.")
    try:
        root = plistlib.loads(payload)
    except Exception:
        raise ValueError("Not a valid history property list.")
    if not isinstance(root, dict) or not isinstance(root.get("chats"), list):
        raise ValueError("History must contain a chats list.")
    if any(not isinstance(c, dict) or not isinstance(c.get("messages"), list) for c in root["chats"]):
        raise ValueError("Malformed chat history.")
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
