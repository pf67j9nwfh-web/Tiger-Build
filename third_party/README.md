# Third-party components

| Folder | What | Licence | Used for |
| --- | --- | --- | --- |
| `mbedtls/` | mbedTLS 3.6.7 | Apache-2.0 | TLS 1.2 and 1.3 for every HTTPS connection |
| `libwebp/` | libwebp 1.5.0 (decoder) | BSD-3-Clause | WebP pictures |
| `libde265/` | libde265 1.0.15 | LGPL-3.0 (separate dylib) | HEIC pictures |
| `libaom/` | libaom 3.11.0 (AV1 decoder) | BSD-2-Clause + patent grant | AVIF pictures |
| `jxldec/` | jxldec (JPEG XL decoder, plain C) with changes for the old Macs | no licence published, see its README | JPEG XL pictures |
| `openssh/` | OpenSSH 10.6p1 | BSD, ISC | the bundled ssh client and Tiger Build's SSH server |
| `sshfs/` | sshfs 2.2 with MacFUSE's patch, glib 2.16.6 static | GPL-2.0, LGPL-2.1 | Mounting another computer's folder over the bundled ssh (needs MacFUSE) |
| `libressl/` | LibreSSL 4.3.3 (libcrypto, static) | ISC, OpenSSL/SSLeay | RSA, ECDSA and the old algorithms in OpenSSH |

Each folder has its own `README.md` (what it is for, where the source comes from, what was changed, how it is linked and rebuilt), its licence text,
and `fetch.sh` / `build-mac.sh` to download, verify (SHA-256) and rebuild it. The built libraries and headers are kept in git.

Two data files that ship with the app are not code and live beside it in `tiger-build/`: see `tiger-build/THIRD-PARTY.md`.
