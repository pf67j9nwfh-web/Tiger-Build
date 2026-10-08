# OpenSSH 10.6p1

**What it is for:** Tiger Build's own SSH, so the old Macs can talk to current computers and to each other.
- the **client** (`ssh`, `ssh-keygen`, `ssh-keyscan`) is inside the app and used for "Commander on another computer" and other MCP servers over SSH; the installer also puts the whole set (`ssh`, `scp`, `sftp`, `ssh-add`, `ssh-agent`, `ssh-keygen`, `ssh-keyscan`) in `/usr/local/tbssh/bin` for use from a terminal (add that folder to your PATH; `scp` and `sftp` find their `ssh` there);
- the **server** (`sshd`, `sshd-session`, `sshd-auth`) is installed by the installer in `/usr/local/tbssh`, switched off, and started only while Allow Other Computers is on.

The system's own SSH on Tiger, Leopard and Snow Leopard (OpenSSH 4.x to 5.6) cannot negotiate with current servers, which refuse its old algorithms.
This build uses ed25519 keys, ML-KEM/curve25519 key exchange and ChaCha20-Poly1305.

- **Licence:** BSD and ISC (`LICENSE`); also copied into the app (`openssh-LICENSE.txt`) and to `/usr/local/tbssh/LICENSE`.
- **Source:** https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-10.6p1.tar.gz, checked against the SHA-256 in the release announcement by `fetch.sh`.
- **Modifications:** none to the sources. It is built **without OpenSSL** (`--without-openssl`), so only ed25519 host and user keys exist; a computer with only RSA host keys (a stock Remote Login on the old Macs) is reached with the system's ssh instead, which Tiger Build chooses by itself and remembers per host.
- **Built how:** universal programs in `bin/`: ppc + i386 (10.4 and later, no PIE) and x86_64 (10.5 and later); no sandbox in any (see build-mac.sh). No ppc64 slice: a G5 runs the 32-bit one.

## Rebuilding

    ./fetch.sh        # on a current Mac: download, verify
    ./build-mac.sh    # on Snow Leopard with Xcode 3.2 and the 10.4u and 10.5 SDKs: bin/

`bin/` is kept in git, so the app builds without either script. The server's configuration and its launchd job are in `installer/tbssh/`.
