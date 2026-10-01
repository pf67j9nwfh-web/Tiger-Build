#!/usr/bin/env python3
"""Write a .deb from a staged tree. Used when dpkg-deb is not installed."""
import os
import sys
import tarfile
import time


def header(name, size):
    line = "%-16s%-12s%-6s%-6s%-8s%-10s`\n" % (
        name, str(int(time.time())), "0", "0", "100644", str(size)
    )
    raw = line.encode("ascii")
    if len(raw) != 60:
        raise RuntimeError("bad ar header for %s" % name)
    return raw


def member(name, data):
    pad = b"\n" if len(data) % 2 else b""
    return header(name, len(data)) + data + pad


def gzip_tar(add):
    import io
    buf = io.BytesIO()
    tar = tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.GNU_FORMAT)
    try:
        add(tar)
    finally:
        tar.close()
    return buf.getvalue()


def add_bytes(tar, name, data, mode):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = mode
    info.mtime = int(time.time())
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    import io
    tar.addfile(info, io.BytesIO(data))


def add_tree(tar, stage):
    for dirpath, dirnames, filenames in os.walk(stage):
        if os.path.abspath(dirpath) == os.path.abspath(stage):
            dirnames[:] = [name for name in dirnames if name != "DEBIAN"]
        rel = os.path.relpath(dirpath, stage)
        if rel != ".":
            info = tarfile.TarInfo("./" + rel.replace(os.sep, "/"))
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            info.mtime = int(os.path.getmtime(dirpath))
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "root"
            tar.addfile(info)
        for name in filenames:
            full = os.path.join(dirpath, name)
            arc = "./" + os.path.relpath(full, stage).replace(os.sep, "/")
            st = os.stat(full)
            info = tarfile.TarInfo(arc)
            info.size = st.st_size
            info.mode = st.st_mode & 0o777
            info.mtime = int(st.st_mtime)
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "root"
            handle = open(full, "rb")
            try:
                tar.addfile(info, handle)
            finally:
                handle.close()


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: pack_deb.py STAGE OUT.deb\n")
        return 2
    stage, out = sys.argv[1], sys.argv[2]
    control = open(os.path.join(stage, "DEBIAN", "control"), "rb").read()
    postinst = open(os.path.join(stage, "DEBIAN", "postinst"), "rb").read()
    if not control.endswith(b"\n"):
        control += b"\n"

    def add_control(tar):
        add_bytes(tar, "./control", control, 0o644)
        add_bytes(tar, "./postinst", postinst, 0o755)

    data = gzip_tar(lambda tar: add_tree(tar, stage))
    ctrl = gzip_tar(add_control)
    blob = b"!<arch>\n" + member("debian-binary", b"2.0\n") + member("control.tar.gz", ctrl) + member("data.tar.gz", data)
    handle = open(out, "wb")
    try:
        handle.write(blob)
    finally:
        handle.close()
    print("Wrote %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
