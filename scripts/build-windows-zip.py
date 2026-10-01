#!/usr/bin/env python3
"""Build the Windows zip and Install-TigerBuildRelay.cmd. No API keys."""
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, "dist")
CMD = """@echo off\r
set DEST=%LOCALAPPDATA%\\Tiger Build Relay\\package\r
mkdir "%DEST%" 2>nul\r
tar -xf "%~dp0tiger-build-relay-payload.zip" -C "%DEST%"\r
if errorlevel 1 (\r
  echo Unpack failed.\r
  exit /b 1\r
)\r
echo Unpacked to %DEST%\r
echo Next, as your user: python "%DEST%\\scripts\\setup.py"\r
echo That adds Tiger Build Relay to the Start menu.\r
"""


def main():
    if not os.path.isdir(DIST):
        os.makedirs(DIST)
    stage = tempfile.mkdtemp(prefix="tiger-build-stage-")
    try:
        result = subprocess.call([sys.executable, os.path.join(ROOT, "scripts", "stage_tree.py"), stage])
        if result != 0:
            return result
        payload = os.path.join(DIST, "tiger-build-relay-payload.zip")
        if os.path.isfile(payload):
            os.remove(payload)
        zf = zipfile.ZipFile(payload, "w", zipfile.ZIP_DEFLATED)
        try:
            for dirpath, dirnames, filenames in os.walk(stage):
                dirnames[:] = [name for name in dirnames if name != "__pycache__"]
                for name in filenames:
                    full = os.path.join(dirpath, name)
                    arc = os.path.relpath(full, stage).replace(os.sep, "/")
                    zf.write(full, arc)
        finally:
            zf.close()
        cmd_path = os.path.join(DIST, "Install-TigerBuildRelay.cmd")
        handle = open(cmd_path, "wb")
        try:
            handle.write(CMD.encode("ascii"))
        finally:
            handle.close()
        setup = os.path.join(ROOT, "installer", "windows", "setup.ps1")
        if os.path.isfile(setup):
            shutil.copy2(setup, os.path.join(DIST, "setup.ps1"))
        print("Wrote %s" % payload)
        print("Wrote %s" % cmd_path)
    finally:
        shutil.rmtree(stage)
    return 0


if __name__ == "__main__":
    sys.exit(main())
