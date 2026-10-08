# LibreSSL 4.3.3

**What it is for:** libcrypto only, linked statically into the bundled OpenSSH (`third_party/openssh`) so it can use RSA, ECDSA and DSA keys and the old key-exchange algorithms as well as ed25519. Nothing else in Tiger Build uses it (TLS is mbedTLS).

- **Licence:** ISC for LibreSSL's own code, with the original OpenSSL and SSLeay licences for the code derived from them (`LICENSE`); also in the OpenSSH package's licence folder.
- **Source:** https://cdn.openbsd.org/pub/OpenBSD/LibreSSL/libressl-4.3.3.tar.gz, checked against its SHA-256 by `fetch.sh`.
- **Modifications:** none. Assembly is switched off (`--disable-asm`: Xcode 3.2's assembler cannot read it) and only `crypto/` is built.
- **Linked how:** statically, as `lib/ppc`, `lib/i386` and `lib/x86_64` (`libcrypto.a`, stripped and re-indexed with `ranlib`), with the headers in `include/`.

## Rebuilding

    ./fetch.sh        # on a current Mac: download, verify
    ./build-mac.sh    # on Snow Leopard with Xcode 3.2 and the 10.4u and 10.5 SDKs: lib/ and include/

`include/` and `lib/` are kept in git. OpenSSH's build passes `-Wl,-search_paths_first` so the linker takes these archives and not the system's older libcrypto.dylib.
