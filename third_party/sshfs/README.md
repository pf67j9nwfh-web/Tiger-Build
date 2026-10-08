# sshfs 2.2

**What it is for:** mounting a folder of another computer as a volume over SSH (`sshfs host:/path ~/mnt`), through the bundled OpenSSH client. It installs as `/usr/local/tbssh/bin/sshfs`. Tiger Build itself does not call it; it is for the user and for agents that run commands. It needs [MacFUSE](https://code.google.com/archive/p/macfuse/) (or a compatible build) on the Mac: the program loads `/usr/local/lib/libfuse.2.dylib`.

- **Licence:** GPL-2.0 (`LICENSE`). glib is LGPL-2.1 and is linked statically; its source is in `src/` after `fetch.sh`.
- **Source:** sshfs-fuse 2.2 from the SourceForge release (the Wayback Machine's copy, the link is gone), glib 2.16.6 from download.gnome.org, pkg-config 0.23 from freedesktop.org; all checked against SHA-256 by `fetch.sh`.
- **Modifications:** MacFUSE's patch for sshfs 2.2 (`patches/sshfs-2.2-macosx.patch`: Darwin semaphores, volume name, `-F`), built with `-D__FreeBSD__=10 -DDARWIN_SEMAPHORE_COMPAT`. glib's configure is patched to skip the gettext check.
- **Linked how:** glib statically; libfuse dynamically from `/usr/local/lib`. One universal program (ppc, i386, x86_64), joined with `lipo`.

## Using it

    sshfs -o ssh_command=/usr/local/tbssh/bin/ssh user@host:/path ~/mnt

sshfs 2.2 does not pass on ssh options it does not know, so for an old host put the algorithms in `~/.ssh/config` instead:

    Host oldhost
      KexAlgorithms +diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1
      HostKeyAlgorithms +ssh-rsa
      PubkeyAcceptedAlgorithms +ssh-rsa
      MACs +hmac-sha1

Unmount with `umount ~/mnt`.

## Rebuilding

    ./fetch.sh                    # on a current Mac: download, verify
    ./build-native.sh SLICE       # on a Mac of that kind (ppc, i386 or x86_64), with MacFUSE's SDK in ~/fuse-sdk: bin/sshfs-SLICE
    ./join.sh                     # bin/sshfs

The ppc slice was linked on Snow Leopard (`gcc-4.2 -arch ppc -isysroot` the 10.5 SDK) from objects and glib built on Tiger, because Tiger's linker would not take MacFUSE's libfuse; it has not been run on a PowerPC Mac.

`bin/sshfs` is kept in git.
