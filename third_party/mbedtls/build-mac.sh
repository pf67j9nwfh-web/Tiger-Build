#!/bin/sh
# Builds mbedTLS as static libraries for the old Macs; run on Snow Leopard with Xcode 3.2 and the 10.4u and 10.5 SDKs,
# after fetch.sh. Writes build/libmbedtls32.a (ppc + i386, 10.4 and later), build/libmbedtls64x86.a (x86_64, 10.5 and later)
# and build/libmbedtls64ppc.a (ppc64, 10.5 and later), the same three slices the app is built from.
set -e
cd "$(dirname "$0")"
M=src/mbedtls
HERE=`pwd`
D=/Developer/SDKs
slice() {  # name compiler flags...
  name=$1; cc=$2; shift 2
  rm -rf build/obj_$name; mkdir -p build/obj_$name
  for f in $M/library/*.c; do
    $cc -O2 "$@" -std=gnu99 -D_DARWIN_C_SOURCE -DMBEDTLS_USER_CONFIG_FILE=\"$HERE/tb_config.h\" -I$M/include -I$M/library -c $f -o build/obj_$name/`basename $f .c`.o
  done
  libtool -static -o build/libmbedtls$name.a build/obj_$name/*.o
  echo "built build/libmbedtls$name.a"
}
slice 32 gcc-4.0 -arch ppc -arch i386 -mmacosx-version-min=10.4 -isysroot $D/MacOSX10.4u.sdk
slice 64x86 gcc-4.2 -arch x86_64 -mmacosx-version-min=10.5 -isysroot $D/MacOSX10.5.sdk
slice 64ppc gcc-4.0 -arch ppc64 -mmacosx-version-min=10.5 -isysroot $D/MacOSX10.5.sdk
