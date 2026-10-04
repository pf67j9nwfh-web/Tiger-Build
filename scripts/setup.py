#!/usr/bin/env python3
"""Install Tiger Build Relay for the current user and start it.

macOS, Windows, and Linux. scripts/setup.sh calls this on Unix.
The relay is copied to the settings folder's app/ directory and runs from
there, so a later edit of a checkout does not change the running copy until
setup is run again.
"""
import os
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _python_on_windows():
    local = os.environ.get("LOCALAPPDATA", "")
    base = os.path.join(local, "Programs", "Python")
    found = []
    if os.path.isdir(base):
        for dirpath, dirnames, files in os.walk(base):
            if "python.exe" in files and "WindowsApps" not in dirpath:
                found.append(os.path.join(dirpath, "python.exe"))
    found.sort()
    return found[-1] if found else ""


def ensure_real_python():
    if sys.platform != "win32":
        return
    if "WindowsApps" not in sys.executable and os.path.isfile(sys.executable):
        return
    found = _python_on_windows()
    if not found:
        sys.stderr.write("Python 3 is required. Install it from python.org.\n")
        sys.exit(1)
    os.execv(found, [found] + sys.argv)


def _ignore(dirpath, names):
    skip = []
    for name in names:
        if name in ("__pycache__", ".git") or name.endswith((".pyc", ".orig")):
            skip.append(name)
    return skip


def migrate_mac(support):
    if sys.platform != "darwin" or os.environ.get("TIGERBUILD_RELAY_HOME"):
        return support
    library = os.path.expanduser("~/Library/Application Support")
    old = os.path.join(library, "TigerDesk")
    new = os.path.join(library, "Tiger Build Relay")
    if os.path.isdir(old) and not os.path.exists(new):
        old_control = os.path.join(old, "app", "relay", "control.py")
        if os.path.isfile(old_control):
            stop_installed(old_control)
        subprocess.call(["launchctl", "bootout", "gui/%d/local.tigerbuild.relay" % os.getuid()])
        print("Moving %s to %s" % (old, new))
        shutil.move(old, new)
        support = new
    subprocess.call(["launchctl", "bootout", "gui/%d/local.jr.tigerdesk.relay" % os.getuid()])
    stale = os.path.expanduser("~/Library/LaunchAgents/local.jr.tigerdesk.relay.plist")
    if os.path.isfile(stale):
        os.remove(stale)
    return support


def ssh_version():
    """(major, minor) of the OpenSSH client on PATH, or None if unknown."""
    try:
        result = subprocess.run(["ssh", "-V"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None
    import re
    text = (result.stderr or b"").decode("utf-8", "replace") + (result.stdout or b"").decode("utf-8", "replace")
    match = re.search(r"OpenSSH_(?:for_Windows_)?(\d+)\.(\d+)", text)
    return (int(match.group(1)), int(match.group(2))) if match else None


def warn_old_ssh():
    version = ssh_version()
    if version is None:
        print("Warning: no OpenSSH client was found. The relay needs OpenSSH 9.1 or later to reach the Tiger Mac.")
    elif version < (9, 1):
        print("Warning: OpenSSH %d.%d is too old. The relay needs 9.1 or later to reach the Tiger Mac." % version)
        print("See Relay system requirements in README.md.")


def stop_installed(control):
    result = subprocess.run([sys.executable, control, "stop"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90)
    if result.returncode:
        raise RuntimeError("The installed relay could not be stopped; upgrade aborted. See relay.log.")


def copy_app(support):
    target = os.path.join(support, "app")
    if os.path.realpath(ROOT) == os.path.realpath(target):
        raise RuntimeError("Run setup from the package folder, not the running app folder.")
    app = tempfile.mkdtemp(prefix="app-new-", dir=support)
    backup = None
    try:
        for name in ("relay", "ppc-commander", "mcp-examples"):
            if os.path.isdir(os.path.join(ROOT, name)):
                shutil.copytree(os.path.join(ROOT, name), os.path.join(app, name), ignore=_ignore)
        for extra in ("config.example.sh", ".env.example", "RELEASE.txt", "README.md", "LICENSE"):
            src = os.path.join(ROOT, extra)
            if os.path.isfile(src):
                shutil.copy2(src, os.path.join(app, extra))
        scripts = os.path.join(app, "scripts")
        os.makedirs(scripts)
        for name in ("setup.py", "setup.sh", "scan_secrets.py"):
            src = os.path.join(ROOT, "scripts", name)
            if os.path.isfile(src):
                shutil.copy2(src, os.path.join(scripts, name))
        env_src = os.path.join(ROOT, ".env")
        env_dst = os.path.join(app, ".env")
        if not os.path.isfile(env_src):
            env_src = os.path.join(target, ".env")
        if os.path.isfile(env_src) and not os.path.isfile(env_dst):
            shutil.copy2(env_src, env_dst)
            os.chmod(env_dst, stat.S_IRUSR | stat.S_IWUSR)
        chat = os.path.join(app, "relay", "chat_proxy.py")
        if os.path.isfile(chat):
            os.chmod(chat, 0o755)
        bin_dir = os.path.join(app, "ppc-commander", "bin")
        if os.path.isdir(bin_dir):
            for name in os.listdir(bin_dir):
                path = os.path.join(bin_dir, name)
                if os.path.isfile(path):
                    os.chmod(path, 0o755)
        if os.path.isdir(target):
            backup = tempfile.mkdtemp(prefix="app-old-", dir=support)
            os.rmdir(backup)
            os.rename(target, backup)
        try:
            os.rename(app, target)
        except OSError:
            if backup:
                os.rename(backup, target)
                backup = None
            raise
        if backup:
            shutil.rmtree(backup)
        return target
    finally:
        if os.path.isdir(app):
            shutil.rmtree(app)


def configured(support):
    if sys.platform == "darwin":
        agent = os.path.expanduser("~/Library/LaunchAgents/local.tigerbuild.relay.plist")
        return os.path.isfile(agent) or os.path.isfile(os.path.join(support, "service.plist"))
    if sys.platform == "win32":
        result = subprocess.run(
            ["schtasks", "/Query", "/TN", "Tiger Build Relay"],
            capture_output=True,
        )
        startup = os.path.join(
            os.environ.get("APPDATA", ""),
            "Microsoft", "Windows", "Start Menu", "Programs", "Startup",
        )
        return result.returncode == 0 or any(
            os.path.isfile(os.path.join(startup, "Tiger Build Relay" + ext)) for ext in (".lnk", ".cmd")
        )
    unit = os.path.expanduser("~/.config/systemd/user/local.tigerbuild.relay.service")
    return os.path.isfile(unit)


def allow_windows_firewall(port):
    if sys.platform != "win32":
        return
    script = (
        "try { New-NetFirewallRule -DisplayName 'Tiger Build Relay' -Direction Inbound "
        "-Action Allow -Protocol TCP -LocalPort %d -ErrorAction Stop | Out-Null; "
        "Write-Output 'firewall rule added' } catch { Write-Output 'firewall rule skipped' }"
        % int(port)
    )
    subprocess.call(["powershell", "-NoProfile", "-Command", script])


def build_gui():
    if sys.platform != "darwin" or os.environ.get("NO_GUI_BUILD") == "1":
        return
    if os.path.isdir("/Applications/Tiger Build Relay.app"):
        return
    if not shutil.which("swiftc"):
        print("Swift is not installed, so the Tiger Build Relay app was not built.")
        print("Install the command line tools with: xcode-select --install")
        return
    script = os.path.join(ROOT, "scripts", "build-relay-gui.sh")
    subprocess.check_call(["bash", script])
    subprocess.call(["osascript", "-e", 'tell application "Tiger Desk" to quit'])
    old = os.path.expanduser("~/Applications/Tiger Desk.app")
    if os.path.isdir(old):
        shutil.rmtree(old)


def run_control(control, args, payload=None):
    proc = subprocess.Popen(
        [sys.executable, control] + args,
        stdin=subprocess.PIPE if payload is not None else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    out, err = proc.communicate(payload)
    if proc.returncode:
        text = (err or out or b"").decode("utf-8", "replace").strip()
        raise RuntimeError(text or ("control.py %s failed" % " ".join(args)))
    return out


def _icon_source():
    candidates = (
        os.path.join(ROOT, "assets", "icon-128.png"),
        "/opt/tiger-build-relay/assets/icon-128.png",
        "/usr/local/tiger-build-relay/assets/icon-128.png",
    )
    for path in candidates:
        if os.path.isfile(path):
            return path
    return ""


def write_windows_shortcut(gui):
    menu = os.path.join(os.environ.get("APPDATA", ""), "Microsoft", "Windows", "Start Menu", "Programs")
    if not menu or not os.path.isdir(menu):
        return ""
    link = os.path.join(menu, "Tiger Build Relay.lnk")
    pythonw = os.path.join(os.path.dirname(sys.executable), "pythonw.exe")
    target = pythonw if os.path.isfile(pythonw) else sys.executable
    script = (
        "$s = (New-Object -ComObject WScript.Shell).CreateShortcut($env:TB_LINK)\n"
        "$s.TargetPath = $env:TB_TARGET\n"
        "$s.Arguments = $env:TB_ARGS\n"
        "$s.WorkingDirectory = $env:TB_WORK\n"
        "$s.Description = 'Start, stop, and configure Tiger Build Relay'\n"
        "$s.Save()\n"
    )
    env = os.environ.copy()
    env["TB_LINK"] = link
    env["TB_TARGET"] = target
    env["TB_ARGS"] = '"' + gui + '"'
    env["TB_WORK"] = os.path.dirname(gui)
    subprocess.run(["powershell", "-NoProfile", "-Command", script], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return link if os.path.isfile(link) else ""


def write_linux_desktop(gui):
    packaged = "/usr/share/applications/tiger-build-relay.desktop"
    if os.path.isfile(packaged):
        return packaged
    apps = os.path.expanduser("~/.local/share/applications")
    os.makedirs(apps, mode=0o755, exist_ok=True)
    icon_name = "tiger-build-relay"
    src = _icon_source()
    if src:
        icon_dir = os.path.expanduser("~/.local/share/icons/hicolor/128x128/apps")
        os.makedirs(icon_dir, mode=0o755, exist_ok=True)
        shutil.copy2(src, os.path.join(icon_dir, icon_name + ".png"))
    desktop = os.path.join(apps, "tiger-build-relay.desktop")
    lines = [
        "[Desktop Entry]",
        "Version=1.5",
        "Type=Application",
        "Name=Tiger Build Relay",
        "GenericName=Relay settings",
        "Comment=Start, stop, and configure Tiger Build Relay",
        "Exec=%s \"%s\"" % (sys.executable, gui),
        "Icon=%s" % icon_name,
        "Terminal=false",
        "Categories=Network;Settings;",
        "StartupNotify=true",
        "",
    ]
    handle = open(desktop, "w")
    try:
        handle.write("\n".join(lines))
    finally:
        handle.close()
    os.chmod(desktop, 0o644)
    return desktop


def install_launcher(app):
    if sys.platform == "darwin":
        system = "/Applications/Tiger Build Relay.app"
        user = os.path.expanduser("~/Applications/Tiger Build Relay.app")
        if os.path.isdir(system):
            if os.path.isdir(user) and os.path.abspath(user) != os.path.abspath(system):
                shutil.rmtree(user)
            return system
        return user if os.path.isdir(user) else ""
    gui = os.path.join(app, "relay", "settings_gui.py")
    if not os.path.isfile(gui):
        return ""
    if sys.platform == "win32":
        return write_windows_shortcut(gui)
    if sys.platform.startswith("linux"):
        return write_linux_desktop(gui)
    return ""


def connect_tiger_mac(shell):
    """Make the relay's SSH key and, from a terminal, install it on the Tiger
    Mac. Without a Tiger Mac in config.sh (or without a terminal) nothing is
    asked: Tiger Build on that Mac sets this up itself (Configuration,
    Connect Commander over SSH), with no password."""
    import connection
    shell = load_shell_config_again()
    try:
        connection.ensure_key(shell)
    except Exception as exc:
        print("Could not make the SSH key (%s). Tiger Build can still connect for you." % exc)
        return
    if not shell.get("TIGER_HOST") or not shell.get("TIGER_USER"):
        print("")
        print("No Tiger Mac is set yet. Open Tiger Build on it and choose Configuration, Connect Commander over SSH,")
        print("or set the address and user in the Tiger Build Relay app.")
        return
    try:
        connection.remember_host_key(shell)
    except RuntimeError as exc:
        print("")
        print("Commander: %s" % exc)
        return
    result = connection.test(shell)
    if result["ok"]:
        print("Commander: %s" % result["message"])
        return
    print("")
    print("Commander: %s" % result["message"])
    if result["code"] in ("auth", "key_missing") and sys.stdin.isatty():
        answer = input("Install the relay's key on %s@%s now? You will be asked for that account's password. [y/N] "
                       % (shell["TIGER_USER"], shell["TIGER_HOST"]))
        if answer.strip().lower().startswith("y"):
            if connection.install_key_interactive(shell):
                print("Commander: %s" % connection.test(shell)["message"])
            else:
                print("The key was not installed. Tiger Build can do it without a password: Configuration, Connect Commander over SSH.")


def load_shell_config_again():
    from mcp_bridge import load_shell_config
    return load_shell_config()


def main():
    ensure_real_python()
    sys.path.insert(0, os.path.join(ROOT, "relay"))
    from paths import default_support_dir
    support = os.environ.get("TIGERBUILD_RELAY_HOME", "").strip() or default_support_dir()
    support = migrate_mac(support)
    if not os.path.isdir(support):
        os.makedirs(support, mode=0o700)
    if sys.platform != "win32":
        os.chmod(support, 0o700)
    os.environ["TIGERBUILD_RELAY_HOME"] = support
    config = os.path.join(support, "config.sh")
    if not os.path.isfile(config):
        shutil.copy2(os.path.join(ROOT, "config.example.sh"), config)
        try:
            os.chmod(config, 0o600)
        except OSError:
            pass
        print("Wrote %s" % config)
    from mcp_bridge import load_shell_config
    shell = load_shell_config()
    warn_old_ssh()
    # Stop the copy that is running before replacing its files. Windows
    # cannot delete a program that is still open.
    old_control = os.path.join(support, "app", "relay", "control.py")
    if os.path.isfile(old_control):
        stop_installed(old_control)
    app = copy_app(support)
    import integrations
    if integrations.install_examples(os.path.join(app, "mcp-examples"), sys.executable):
        print("Added the example MCP servers (calculator, notebook, system info, weather). Switch them off in the relay settings.")
    control = os.path.join(app, "relay", "control.py")
    # First install turns autostart on. Later runs keep the user's choice.
    if not configured(support):
        run_control(control, ["autostart"], b'{"enabled":true}')
    run_control(control, ["stop"])
    run_control(control, ["start"])
    allow_windows_firewall(shell.get("LISTEN_PORT") or "8765")
    build_gui()
    launcher = install_launcher(app)
    proxy = os.path.join(app, "relay", "chat_proxy.py")
    address = subprocess.check_output(
        [sys.executable, proxy, "--print-address"], env=os.environ
    ).decode().strip()
    print("")
    print("Tiger Build Relay is running.")
    print("  Settings folder: %s" % support)
    print("  Log:             %s" % os.path.join(support, "relay.log"))
    print("  Address:         %s   Port: %s" % (address, shell.get("LISTEN_PORT") or "8765"))
    if os.environ.get("TIGERBUILD_SETUP_QUIET") == "1":
        print("  Token:           saved in the settings folder (not printed)")
    else:
        token = subprocess.check_output(
            [sys.executable, proxy, "--print-token"], env=os.environ
        ).decode().strip()
        print("  Token:           %s" % token)
    print("Enter the address, port and token in Tiger Build > Preferences.")
    connect_tiger_mac(shell)
    if launcher:
        print("  Open:            %s" % launcher)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        sys.stderr.write(str(exc) + "\n")
        sys.exit(1)
