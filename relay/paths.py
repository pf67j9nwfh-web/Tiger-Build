"""Where Tiger Build Relay keeps its files.

Override: TIGERBUILD_RELAY_HOME=/some/folder
Config:   <folder>/config.sh, or TIGERBUILD_RELAY_CONFIG=/path/config.sh

macOS:   ~/Library/Application Support/Tiger Build Relay
Windows: %APPDATA%\\Tiger Build Relay
Linux:   $XDG_DATA_HOME/tiger-build-relay or ~/.local/share/tiger-build-relay

Earlier macOS builds were called Tiger Desk and used
~/Library/Application Support/TigerDesk. setup moves that folder while the
relay is stopped. Until then the old folder is still read.
"""
import os
import sys

APP_NAME = "Tiger Build Relay"
OLD_NAME = "TigerDesk"


def _library():
    return os.path.expanduser("~/Library/Application Support")


def legacy_dir():
    if sys.platform != "darwin":
        return ""
    return os.path.join(_library(), OLD_NAME)


def default_support_dir():
    if sys.platform == "darwin":
        return os.path.join(_library(), APP_NAME)
    if sys.platform == "win32":
        base = os.environ.get("APPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Roaming")
        return os.path.join(base, APP_NAME)
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "tiger-build-relay")


def support_dir():
    override = os.environ.get("TIGERBUILD_RELAY_HOME", "").strip()
    if override:
        folder = override
    else:
        folder = default_support_dir()
        old = legacy_dir()
        if old and not os.path.exists(folder) and os.path.isdir(old):
            return old
    if not os.path.isdir(folder):
        os.makedirs(folder, mode=0o700)
    return folder


def config_sh():
    for name in ("TIGERBUILD_RELAY_CONFIG", "TIGERDESK_CONFIG"):
        value = os.environ.get(name, "").strip()
        if value:
            return value
    return os.path.join(support_dir(), "config.sh")
