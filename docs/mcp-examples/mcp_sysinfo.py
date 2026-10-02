#!/usr/bin/env python3
"""Example MCP server: read-only facts about the computer the relay runs on."""
import datetime
import hashlib
import os
import platform
import shutil
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_minimal import NUMBER, TEXT, obj, serve


def host_info(args):
    return "\n".join([
        "host: %s" % socket.gethostname(),
        "system: %s %s (%s)" % (platform.system(), platform.release(), platform.machine()),
        "python: %s" % platform.python_version(),
        "cpus: %s" % os.cpu_count(),
    ])


def disk_free(args):
    usage = shutil.disk_usage(args.get("path") or "/")
    return "%.1f GB free of %.1f GB" % (usage.free / 1e9, usage.total / 1e9)


def now(args):
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def sha256(args):
    return hashlib.sha256(str(args["text"]).encode("utf-8")).hexdigest()


def slow(args):
    seconds = min(max(float(args.get("seconds", 5)), 0), 120)
    time.sleep(seconds)
    return "slept %.1f seconds" % seconds


def fail(args):
    raise RuntimeError("this tool always fails, to show how errors look")


serve("example-sysinfo", "1.0", {
    "host_info": ("Name, operating system, Python version and CPU count of the relay computer.", obj({}), host_info),
    "disk_free": ("Free and total disk space for a path on the relay computer.", obj({"path": TEXT}), disk_free),
    "current_time": ("The relay computer's local date and time with its UTC offset.", obj({}), now),
    "sha256": ("SHA-256 of a piece of text, as hex.", obj({"text": TEXT}, ["text"]), sha256),
    "slow_task": ("Wait for a number of seconds (up to 120), then report. For testing Stop and long runs.", obj({"seconds": NUMBER}), slow),
    "always_fails": ("A tool that always returns an error. For testing error handling.", obj({}), fail),
})
