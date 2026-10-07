# libde265 1.0.15

**What it is for:** decoding HEIC pictures (HEVC), such as photos from an iPhone, so they can be shown and converted to JPEG.

- **Licence:** LGPL-3.0 for the library (`LICENSE`); the upstream sample programs (MIT) are not used. The licence text is also copied into the app.
- **Source:** https://github.com/strukturag/libde265/releases/download/v1.0.15/libde265-1.0.15.tar.gz, checked against its SHA-256 by `fetch.sh`.
- **Modifications:** `old-compilers.patch` changes the code to C++98 and tr1 so gcc 4.0 and 4.2 (Xcode 2.5 and 3.2) can build it. Nothing else.
- **Linked how:** as a separate dynamic library, `Contents/Frameworks/libde265.dylib` inside the app, loaded with `dlopen` only when a HEIC picture is converted (`tiger-build/TBHEIC.m`). Because it is a separate file, anyone can replace it with their own build, which is what the LGPL asks for. The path can be overridden with the `TBDE265Path` default.

## Rebuilding

    ./fetch.sh        # on a current Mac: download, verify, apply old-compilers.patch
    ./build-mac.sh    # on Snow Leopard with Xcode 3.2 and the 10.4u and 10.5 SDKs: lib/libde265-32.dylib (ppc + i386), -64x86, -64ppc

`include/` and `lib/` are kept in git, so the app builds without running either script.
