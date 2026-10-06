#!/bin/sh
# Builds libaom's AV1 decoder as static libraries for the old Macs; run on Snow Leopard with Xcode 3.2 and the 10.4u and 10.5 SDKs,
# after fetch.sh. Plain C, no threads: AVIF pictures are single frames, and the Macs that need this are slow either way.
# Writes lib/libaom32.a (ppc + i386), lib/libaom64x86.a and lib/libaom64ppc.a. Those, config/ and include/ are kept in git.
set -e
cd "$(dirname "$0")"
L=src/libaom
D=/Developer/SDKs
slice() {  # name compiler flags...
  name=$1; cc=$2; shift 2
  rm -rf build/obj_$name; mkdir -p build/obj_$name
  for f in `cat files.txt` config/aom_config.c; do
    case $f in config/*) src=$f ;; *) src=$L/$f ;; esac
    $cc -O2 "$@" -std=gnu99 -fno-common -DNDEBUG -I$L -I. -c $src -o build/obj_$name/`echo $f | tr / _`.o
  done
  mkdir -p lib
  rm -f lib/libaom$name.a
  libtool -static -o lib/libaom$name.a build/obj_$name/*.o 2>/dev/null
  echo "built lib/libaom$name.a"
}
slice 32 gcc-4.0 -arch ppc -arch i386 -mmacosx-version-min=10.4 -isysroot $D/MacOSX10.4u.sdk
slice 64x86 gcc-4.2 -arch x86_64 -mmacosx-version-min=10.5 -isysroot $D/MacOSX10.5.sdk
slice 64ppc gcc-4.0 -arch ppc64 -mmacosx-version-min=10.5 -isysroot $D/MacOSX10.5.sdk
