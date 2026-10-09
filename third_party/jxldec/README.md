# jxldec (JPEG XL decoder)

**What it is for:** reading `.jxl` pictures (attachments, `convert_file`, Quick Look). One plain-C file, no dependencies, decode only, single-threaded. It is compiled into `tiger-build/TBNet.c`'s object, so every program that has the converter has it.

- **Source:** https://github.com/kjk/jxldec, `dist/jxl.c` and `dist/jxl.h` at commit d71b246 (2026-10-04), checked against their SHA-256 by `fetch.sh`. It is an AI-assisted port of the Rust decoder jxl-oxide, tested by its author against libjxl on more than 1,200 files.
- **Licence: MIT.** Its author said it is in the spirit of his other decoder, [djvudec](https://github.com/kjk/djvudec) (MIT), so it is treated as MIT, and `LICENSE` here is the standard MIT text in his name. If the repository later states something else, follow that.
- **Changes** (`patches/old-macs.patch`): on PowerPC the decoder's byte swap was not used because gcc 4.0 and 4.2 do not define `__BYTE_ORDER__`, so every file failed on a G4; the same patch reads the coefficient order as two 16-bit numbers (it read one 32-bit number, which swaps the halves on PowerPC); and the x86 `cpuid.h` include is skipped when SIMD is switched off. `TBNet.c` switches the AVX2/SSE2 code off (`JXL_NO_AVX2`, `JXL_DCT_FORCE_SCALAR`, `JXL_EPF_FORCE_SCALAR`), as these compilers have no `immintrin.h`.
- **Tried:** every file below decodes on a G4 (Tiger), a Leopard Mac and a Snow Leopard Mac, identical on all three and within one step of libjxl (`djxl`): lossless, lossy (VarDCT and Modular), 16-bit grey, alpha, animation with alpha, splines, 1536x1024. About 14,000 damaged files were fed to a sanitizer build without a memory error. A G4 takes about 5 seconds for 1536x1024.
- **Limits in Tiger Build:** at most 16384 pixels either way and 40 million in all; a long animation is judged by its first frames; the picture is turned into a JPEG, so transparency becomes white. JPEG XL files that were made by recompressing a JPEG are decoded to pixels, not turned back into the JPEG.

## Rebuilding

    ./fetch.sh        # on a current Mac: download, verify, patch
