#!/bin/sh
# Builds OpenSSH's ssh, ssh-keygen, ssh-keyscan, sshd, sshd-session and sshd-auth for the old Macs, without OpenSSL (ed25519 keys,
# ML-KEM and curve25519 key exchange, ChaCha20-Poly1305), as universal programs in bin/: ppc + i386 (10.4 and later) and x86_64 (10.5 and
# later). Run on Snow Leopard with Xcode 3.2 and the 10.4u and 10.5 SDKs, after fetch.sh. bin/ is kept in git. There is no ppc64 slice:
# a G5 runs the 32-bit one.
set -e
cd "$(dirname "$0")"
VERSION=10.6p1
SRC="$PWD/src/openssh-$VERSION"
D=/Developer/SDKs
TOOLS="ssh ssh-keygen ssh-keyscan ssh-add ssh-agent scp sftp sshd sshd-session sshd-auth"
slice() {  # name host compiler flags...
  name=$1; host=$2; cc="$3"; shift 3
  rm -rf build/$name; mkdir -p build/$name; cd build/$name
  # no PIE on the 10.4 slices (Tiger cannot run it). No sandbox anywhere: the Darwin one loads libsandbox after sshd has chrooted to /var/empty,
  # where it cannot be found (the 64-bit server died with "sandbox_init: dlopen(libsandbox.1.dylib) image not found"); privilege separation and the chroot remain
  CC="$cc" CFLAGS=-O2 LDFLAGS="$*" "$SRC/configure" --host=$host --without-openssl --without-pam --prefix=/usr/local/tbssh $EXTRA > configure.log 2>&1
  make $TOOLS > make.log 2>&1
  for t in $TOOLS; do strip -x $t; done
  cd ../..
  echo "built $name"
}
EXTRA="--without-pie --with-sandbox=no" slice ppc powerpc-apple-darwin8 "gcc-4.0 -arch ppc -isysroot $D/MacOSX10.4u.sdk -mmacosx-version-min=10.4" -arch ppc -isysroot $D/MacOSX10.4u.sdk -mmacosx-version-min=10.4
EXTRA="--without-pie --with-sandbox=no" slice i386 i686-apple-darwin8 "gcc-4.0 -arch i386 -isysroot $D/MacOSX10.4u.sdk -mmacosx-version-min=10.4" -arch i386 -isysroot $D/MacOSX10.4u.sdk -mmacosx-version-min=10.4
EXTRA="--with-sandbox=no" slice x86_64 x86_64-apple-darwin9 "gcc-4.2 -arch x86_64 -isysroot $D/MacOSX10.5.sdk -mmacosx-version-min=10.5" -arch x86_64 -isysroot $D/MacOSX10.5.sdk -mmacosx-version-min=10.5
mkdir -p bin
for t in $TOOLS; do
  lipo -create build/ppc/$t build/i386/$t build/x86_64/$t -output bin/$t
done
ls -la bin
