#!/usr/bin/env python3
"""Keep chat_proxy running until relay.stop exists.

Windows uses this as the process launchd would have supervised. Linux uses
it only when a systemd user session is not available. --login clears a
previous stop, matching a login agent that starts again at the next login.
"""
import os
import sys
import time
import subprocess


def _alive(pid):
    if not pid or pid == os.getpid():
        return False
    from procutil import pid_alive
    return pid_alive(pid)


def _read_pid(path):
    try:
        return int(open(path).read().strip() or "0")
    except (IOError, ValueError):
        return 0


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    sys.path.insert(0, here)
    from paths import support_dir
    support = support_dir()
    if not os.path.isdir(support):
        os.makedirs(support)
    stop = os.path.join(support, "relay.stop")
    host_pid = os.path.join(support, "relay-host.pid")
    log_path = os.path.join(support, "relay.log")
    if "--login" in sys.argv:
        try:
            os.remove(stop)
        except OSError:
            pass
    if os.path.isfile(stop):
        return 0
    old = _read_pid(host_pid)
    if _alive(old):
        return 0
    handle = open(host_pid, "w")
    try:
        handle.write("%d\n" % os.getpid())
    finally:
        handle.close()
    log = open(log_path, "a")
    try:
        os.dup2(log.fileno(), 1)
        os.dup2(log.fileno(), 2)
    except OSError:
        pass
    proxy = os.path.join(here, "chat_proxy.py")
    try:
        while not os.path.isfile(stop):
            proc = subprocess.Popen(
                [sys.executable if sys.platform != "win32" else _console_python(), proxy],
                cwd=root, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0) if sys.platform == 'win32' else 0,
            )
            while proc.poll() is None:
                if os.path.isfile(stop):
                    proc.terminate()
                    try:
                        proc.wait(8)
                    except Exception:
                        proc.kill()
                    return 0
                time.sleep(0.4)
            time.sleep(10)
    finally:
        if _read_pid(host_pid) == os.getpid():
            try:
                os.remove(host_pid)
            except OSError:
                pass
        log.close()
    return 0


def _console_python():
    # pythonw has no console; the child still needs a real interpreter.
    exe = sys.executable
    if exe.lower().endswith("pythonw.exe"):
        sibling = os.path.join(os.path.dirname(exe), "python.exe")
        if os.path.isfile(sibling):
            return sibling
    return exe


if __name__ == "__main__":
    sys.exit(main())
