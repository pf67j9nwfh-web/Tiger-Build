# libwebp 1.5.0

**What it is for:** reading WebP pictures (including animated ones, up to four frames) so they can be shown and converted to JPEG. Tiger Build uses only the decoder and the demuxer.

- **Licence:** BSD-3-Clause (`LICENSE`). The licence text is also copied into the app (`Contents/Resources`).
- **Source:** https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.5.0.tar.gz, checked against its SHA-256 by `fetch.sh`.
- **Modifications:** none. The upstream sources are used as published.
- **Linked how:** statically, into the app (`lib/libwebp32.a`, `libwebp64x86.a`, `libwebp64ppc.a`).

## Rebuilding

    ./fetch.sh        # on a current Mac: download, verify, keep only the decoder and demuxer sources in src/
    ./build-mac.sh    # on Snow Leopard with Xcode 3.2 and the 10.4u and 10.5 SDKs: writes the three archives in lib/

`include/` and `lib/` are kept in git, so the app builds without running either script.
