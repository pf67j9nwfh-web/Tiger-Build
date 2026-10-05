#!/bin/sh
# Builds libde265's decoder as a dynamic library for the old Macs; run on Snow Leopard with Xcode 3.2 and the 10.4u and 10.5 SDKs,
# after fetch.sh. Writes lib/libde265-32.dylib (ppc + i386, 10.4 and later), lib/libde265-64x86.dylib and lib/libde265-64ppc.dylib.
# It is a separate library, loaded when a HEIC picture is converted, so the LGPL's terms are met by letting it be replaced.
set -e
cd "$(dirname "$0")"
L=src/libde265/libde265
D=/Developer/SDKs
FILES="alloc_pool bitstream cabac contextmodel de265 deblock decctx dpb fallback-dct fallback-motion fallback image intrapred md5 motion nal-parser nal pps refpic sao scan sei slice sps threads transform util vps vui"
slice() {  # name compiler flags...
  name=$1; cc=$2; shift 2
  rm -rf build/obj_$name; mkdir -p build/obj_$name
  for f in $FILES; do
    $cc -O2 "$@" -fno-common -Doverride= '-Dmemalign(a,s)=malloc(s)' -I$L -I$L/.. -c $L/$f.cc -o build/obj_$name/$f.o
  done
  mkdir -p lib
  $cc -dynamiclib "$@" -install_name @executable_path/../Frameworks/libde265.dylib -o lib/libde265-$name.dylib build/obj_$name/*.o -lstdc++
  echo "built lib/libde265-$name.dylib"
}
slice 32 g++-4.0 -arch ppc -arch i386 -mmacosx-version-min=10.4 -isysroot $D/MacOSX10.4u.sdk
slice 64x86 g++-4.2 -arch x86_64 -mmacosx-version-min=10.5 -isysroot $D/MacOSX10.5.sdk
slice 64ppc g++-4.0 -arch ppc64 -mmacosx-version-min=10.5 -isysroot $D/MacOSX10.5.sdk
