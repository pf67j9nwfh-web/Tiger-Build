# libaom 3.11.0

**What it is for:** decoding AVIF pictures (AV1 frames in a HEIF file), including transparency, rotation, mirroring and cropping, so they can be shown and converted to JPEG. Tiger Build uses only the AV1 decoder.

- **Licence:** BSD-2-Clause plus the Alliance for Open Media patent grant (`LICENSE`, `PATENTS`). Both files are also copied into the app.
- **Source:** https://storage.googleapis.com/aom-releases/libaom-3.11.0.tar.gz, checked against its SHA-256 by `fetch.sh`.
- **Modifications:** none to the sources. `fetch.sh` generates `config/` (the headers for a plain C build: no assembly, no threads, 8 to 12 bits) with cmake, and `files.txt` lists the decoder sources that are compiled.
- **Linked how:** statically, into the app (`lib/libaom32.a`, `libaom64x86.a`, `libaom64ppc.a`).

## Rebuilding

    ./fetch.sh        # on a current Mac with cmake: download, verify, generate config/, keep the decoder sources in src/
    ./build-mac.sh    # on Snow Leopard with Xcode 3.2 and the 10.4u and 10.5 SDKs: writes the three archives in lib/

`include/` and `lib/` are kept in git, so the app builds without running either script.
