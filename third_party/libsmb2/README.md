# libsmb2 (commit 57fea04, October 2026)

**What it is for:** speaking SMB 2 and 3 (Windows, NAS, Samba and Mac file sharing). It is the client behind the *SMB file shares* tools (`tiger-build/TBSMB.m`) and the protocol engine of Tiger Build's own file server, `tbsmbd` (`smbd/tbsmbd.c`, installed in `/usr/local/tbssh/bin`). NTLMSSP passwords only (no Kerberos), no DCE/RPC.

- **Licence:** the library (`lib/` and the non-DCE/RPC headers) is **LGPL-2.1 or later** (`LICENSE`, and `COPYING` which lists the separate licences of the other parts; libsmb2 is by Ronnie Sahlberg and others, and a few files in `lib/` carry their own notices, such as the RSA MD4 and MD5 routines and the BSD-licensed SHA code). The DCE/RPC part (`libdcerpc/`, BSD-2-Clause) is not used. The licence is also copied into the installer (`/usr/local/tbssh/libsmb2-LICENSE`).
- **Source:** https://github.com/sahlberg/libsmb2, fetched at that commit by `fetch.sh`.
- **Modifications:** `patches/tbsmbd.patch` (applied by `fetch.sh`): a server handler can return an NT status such as "not found" instead of "not implemented"; a server may hand back query-info replies in wire form; the server can be given an already bound listening socket (launchd); and the NTLM challenge is written in little-endian order, which the PowerPC build needs to act as a server. The patch is under the same licence as the library.
- **Linked how:** statically, into the app (`lib/libsmb2-32.a`, `libsmb2-64x86.a`, `libsmb2-64ppc.a`) and into `bin/tbsmbd`. Because the LGPL asks that you can replace the library: the whole of Tiger Build's source is here, `fetch.sh` and `build-mac.sh` rebuild the library (with or without your own changes), and `make` in `tiger-build/` links the app against whatever is in `lib/`.

## Rebuilding

    ./fetch.sh        # on a current Mac: download the sources into src/ and apply the patch
    ./build-mac.sh    # on Snow Leopard with Xcode 3.2 and the 10.4u and 10.5 SDKs: writes lib/*.a and bin/tbsmbd

`include/`, `lib/` and `bin/` are kept in git, so the app builds without running either script.
