# OpenSSH 10.6p1

**What it is for:** Tiger Build's own SSH, so the old Macs can talk to current computers and to each other.
- the **client** (`ssh`, `ssh-keygen`, `ssh-keyscan`) is inside the app and used for "Commander on another computer" and other MCP servers over SSH; the installer also puts the whole set (`ssh`, `scp`, `sftp`, `ssh-add`, `ssh-agent`, `ssh-keygen`, `ssh-keyscan`) in `/usr/local/tbssh/bin` for use from a terminal (add that folder to your PATH; `scp` and `sftp` find their `ssh` there);
- the **server** (`sshd`, `sshd-session`, `sshd-auth`) is installed by the installer in `/usr/local/tbssh`, switched off, and started only while Allow Other Computers is on.

The system's own SSH on Tiger, Leopard and Snow Leopard (OpenSSH 4.x to 5.6) cannot negotiate with current servers, which refuse its old algorithms.
This build has ML-KEM and curve25519 key exchange, ed25519, ECDSA and RSA keys, and ChaCha20-Poly1305, and can still be told to use the old algorithms (see below).

- **Licence:** BSD and ISC (`LICENSE`); also copied into the app (`openssh-LICENSE.txt`) and to `/usr/local/tbssh/LICENSE`.
- **Source:** https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-10.6p1.tar.gz, checked against the SHA-256 in the release announcement by `fetch.sh`.
- **Modifications:** none to the sources. It is built **with LibreSSL** (`third_party/libressl`, libcrypto only, linked statically), so every key type works. Tiger Build uses ed25519 with current hosts and RSA with a stock old Remote Login (Tiger to Snow Leopard), switching the old algorithms back on for that host with `-o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o MACs=+hmac-sha1`; it remembers which, per host, when the host is trusted. From a terminal use the same options for an old host.
- **Built how:** universal programs in `bin/`: ppc + i386 (10.4 and later, no PIE) and x86_64 (10.5 and later); no sandbox in any (see build-mac.sh). No ppc64 slice: a G5 runs the 32-bit one.

## Rebuilding

    ./fetch.sh        # on a current Mac: download, verify (and the same in ../libressl)
    ../libressl/build-mac.sh   # first, on Snow Leopard: the static libcrypto it links
    ./build-mac.sh    # on Snow Leopard with Xcode 3.2 and the 10.4u and 10.5 SDKs: bin/

`bin/` is kept in git, so the app builds without either script. The server's configuration and its launchd job are in `installer/tbssh/`.
