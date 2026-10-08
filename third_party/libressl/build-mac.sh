#!/bin/sh
# Builds LibreSSL's libcrypto as static libraries for the old Macs; run on Snow Leopard with Xcode 3.2 and the 10.4u and 10.5 SDKs, after
# fetch.sh. Writes lib/<slice>/libcrypto.a for ppc, i386 and x86_64 and include/ (the headers). Assembly is off (Xcode 3.2's assembler cannot
# read it). Those and include/ are kept in git.
set -e
cd "$(dirname "$0")"
VERSION=4.3.3
SRC="$PWD/src/libressl-$VERSION"
D=/Developer/SDKs
slice() {  # name host compiler flags...
  name=$1; host=$2; cc="$3"; shift 3
  rm -rf build/$name; mkdir -p build/$name lib/$name; cd build/$name
  CC="$cc" CFLAGS=-O2 LDFLAGS="$*" "$SRC/configure" --host=$host --disable-shared --disable-tests --disable-asm --prefix="$PWD/root" > configure.log 2>&1
  make -C crypto > make.log 2>&1
  cp crypto/.libs/libcrypto.a ../../lib/$name/libcrypto.a
  strip -S ../../lib/$name/libcrypto.a
  ranlib ../../lib/$name/libcrypto.a   # strip leaves the archive without a usable symbol table
  cd ../..
  echo "built $name"
}
slice ppc powerpc-apple-darwin8 "gcc-4.0 -arch ppc -isysroot $D/MacOSX10.4u.sdk -mmacosx-version-min=10.4" -arch ppc -isysroot $D/MacOSX10.4u.sdk -mmacosx-version-min=10.4
slice i386 i686-apple-darwin8 "gcc-4.0 -arch i386 -isysroot $D/MacOSX10.4u.sdk -mmacosx-version-min=10.4" -arch i386 -isysroot $D/MacOSX10.4u.sdk -mmacosx-version-min=10.4
slice x86_64 x86_64-apple-darwin9 "gcc-4.2 -arch x86_64 -isysroot $D/MacOSX10.5.sdk -mmacosx-version-min=10.5" -arch x86_64 -isysroot $D/MacOSX10.5.sdk -mmacosx-version-min=10.5
rm -rf include && mkdir include && cp -R "$SRC/include/openssl" include/openssl
ls -la lib/*/libcrypto.a
