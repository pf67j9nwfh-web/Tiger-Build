#!/usr/bin/env python3
"""Refuse to package a tree that contains a key or a private key."""
import os
import re
import sys

NEEDLES = (
    "BEGIN OPENSSH PRIVATE " + "KEY",
    "BEGIN RSA PRIVATE " + "KEY",
    "BEGIN PRIVATE " + "KEY",
    "sk-" + "ant-",
    "sk-" + "proj-",
    "xa" + "i-",
    "AI" + "za",
)


def scan(root):
    bad = []
    for dirpath, dirnames, files in os.walk(root):
        dirnames[:] = [name for name in dirnames if name not in (".git", "__pycache__", "dist")]
        for name in files:
            path = os.path.join(dirpath, name)
            try:
                data = open(path, "rb").read()
            except IOError:
                continue
            if b"\0" in data[:512]:
                continue
            text = data.decode("utf-8", "ignore")
            for needle in NEEDLES:
                if needle in text:
                    bad.append("%s matches a secret pattern" % os.path.relpath(path, root))
            for line in text.splitlines():
                match = re.match(r"^(?:export\s+)?([A-Za-z0-9_]+)\s*=\s*(.*)$", line.strip())
                if not match or not match.group(1).endswith("API_KEY"):
                    continue
                value = match.group(2).strip().strip('"').strip("'")
                if value and len(value) > 8:
                    bad.append("%s has a filled API key line" % os.path.relpath(path, root))
                    break
    return bad


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    bad = scan(root)
    if bad:
        sys.stderr.write("Refusing to build the installer because it would contain secrets:\n")
        for item in bad:
            sys.stderr.write(item + "\n")
        return 1
    print("secret scan ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
