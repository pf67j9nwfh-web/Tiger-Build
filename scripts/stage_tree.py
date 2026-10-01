#!/usr/bin/env python3
"""Copy a secret-free source tree for an installer. Usage: stage_tree.py DEST"""
import os
import shutil
import subprocess
import sys

SKIP_DIRS = {".git", "__pycache__", "dist", "docs", ".ssh", "tbtests"}
SKIP_FILES = {
    ".env", "providers.json", "integrations.json", "last-client.json",
    "config.sh", "relay-token", "models-cache.json", ".DS_Store",
}
SKIP_SUFFIX = (".pyc", ".orig", ".pem", ".key")


def ignore(dirpath, names):
    skipped = []
    for name in names:
        if name in SKIP_DIRS or name in SKIP_FILES or name.endswith(SKIP_SUFFIX):
            skipped.append(name)
        elif name.startswith(".env"):
            skipped.append(name)
        elif "settings" in name and name.endswith(".plist"):
            skipped.append(name)
        elif name in ("id_rsa", "id_rsa.pub", "ppc_tiger_rsa", "ppc_tiger_known_hosts"):
            skipped.append(name)
        elif name.endswith(".app"):
            skipped.append(name)
    return skipped


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: stage_tree.py DEST\n")
        return 2
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    dest = sys.argv[1]
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    shutil.copytree(root, dest, ignore=ignore)
    example = os.path.join(root, ".env.example")
    if os.path.isfile(example):
        shutil.copy2(example, os.path.join(dest, ".env.example"))
    scanner = os.path.join(root, "scripts", "scan_secrets.py")
    result = subprocess.call([sys.executable, scanner, dest])
    return result


if __name__ == "__main__":
    sys.exit(main())
