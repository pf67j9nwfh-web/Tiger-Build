#!/bin/sh
# Builds libwebp's decoder as static libraries for the old Macs; run on Snow Leopard with Xcode 3.2 and the 10.4u and 10.5 SDKs,
# after fetch.sh. Writes lib/libwebp32.a (ppc + i386), lib/libwebp64x86.a and lib/libwebp64ppc.a. Those and include/ are kept in git.
set -e
cd "$(dirname "$0")"
W=src/libwebp
D=/Developer/SDKs
FILES="$W/src/dec/*.c $W/src/dsp/*.c $W/src/utils/*.c"
# An empty config.h: with HAVE_CONFIG_H set the library uses its plain C code everywhere, which is what the old Macs need.
mkdir -p build/cfg/src/webp && : > build/cfg/src/webp/config.h
slice() {  # name compiler flags...
  name=$1; cc=$2; shift 2
  rm -rf build/obj_$name; mkdir -p build/obj_$name
  for f in $FILES; do
    case `basename $f` in
      *_sse2.c|*_sse41.c|*_neon.c|*_mips*.c|*_msa.c|*_avx2.c|*enc*|ssim.c|cost.c|quant_levels_utils.c|bit_writer_utils.c) continue ;;
    esac
    $cc -O2 "$@" -std=gnu99 -fno-common -DHAVE_CONFIG_H -Ibuild/cfg -I$W -I$W/src -c $f -o build/obj_$name/`basename $f .c`.o
  done
  mkdir -p lib
  libtool -static -o lib/libwebp$name.a build/obj_$name/*.o 2>/dev/null
  echo "built lib/libwebp$name.a"
}
slice 32 gcc-4.0 -arch ppc -arch i386 -mmacosx-version-min=10.4 -isysroot $D/MacOSX10.4u.sdk
slice 64x86 gcc-4.2 -arch x86_64 -mmacosx-version-min=10.5 -isysroot $D/MacOSX10.5.sdk
slice 64ppc gcc-4.0 -arch ppc64 -mmacosx-version-min=10.5 -isysroot $D/MacOSX10.5.sdk
