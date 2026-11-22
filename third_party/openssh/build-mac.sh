#!/bin/sh
# Builds OpenSSH's ssh, ssh-keygen, ssh-keyscan, ssh-add, ssh-agent, scp, sftp, sshd, sshd-session and sshd-auth for the old Macs with LibreSSL's libcrypto
# linked in statically (third_party/libressl: RSA, ECDSA and DSA keys as well as ed25519, ML-KEM and curve25519 key exchange, ChaCha20-Poly1305), as universal programs in bin/: ppc + i386 (10.4 and later) and x86_64 (10.5 and
# later) and ppc64 (10.5 and later, for a G5). Run on Snow Leopard with Xcode 3.2 and the 10.4u and 10.5 SDKs, after fetch.sh. bin/ is kept in git.
# With slice names as arguments only those are built and the results are in build/<slice>/.
set -e
cd "$(dirname "$0")"
VERSION=10.6p1
SRC="$PWD/src/openssh-$VERSION"
SSL="$PWD/../libressl"
ONLY="$*"
D=/Developer/SDKs
# The 64-bit programs built with the 10.5 SDK cannot pass a descriptor on 10.6 and later (the server could not give a terminal to a session: "mm_send_fd:
# sendmsg: Invalid argument"): the SDK and those kernels lay a control message out differently. patches/darwin-fdpass.patch chooses the layout by the system it runs on.
grep -q tb_cmsg_packed "$SRC/monitor_fdpass.c" || patch -p1 -d "$SRC" -N -s < "$PWD/patches/darwin-fdpass.patch"
TOOLS="ssh ssh-keygen ssh-keyscan ssh-add ssh-agent scp sftp sshd sshd-session sshd-auth"
slice() {  # name host compiler flags...
  name=$1; host=$2; cc="$3"; shift 3
  [ -z "$ONLY" ] || case " $ONLY " in *" $name "*) ;; *) return 0;; esac
  rm -rf build/$name; mkdir -p build/$name; cd build/$name
  # no PIE on the 10.4 slices (Tiger cannot run it). No sandbox anywhere: the Darwin one loads libsandbox after sshd has chrooted to /var/empty,
  # where it cannot be found (the 64-bit server died with "sandbox_init: dlopen(libsandbox.1.dylib) image not found"); privilege separation and the chroot remain
  CC="$cc" CFLAGS=-O2 CPPFLAGS="-I$SSL/include" LDFLAGS="$* -Wl,-search_paths_first -L$SSL/lib/$name" "$SRC/configure" --host=$host --without-pam --prefix=/usr/local/tbssh $EXTRA > configure.log 2>&1
  make $TOOLS > make.log 2>&1
  for t in $TOOLS; do strip -x $t; done
  cd ../..
  echo "built $name"
}
EXTRA="--without-pie --with-sandbox=no" slice ppc powerpc-apple-darwin8 "gcc-4.0 -arch ppc -isysroot $D/MacOSX10.4u.sdk -mmacosx-version-min=10.4" -arch ppc -isysroot $D/MacOSX10.4u.sdk -mmacosx-version-min=10.4
EXTRA="--without-pie --with-sandbox=no" slice i386 i686-apple-darwin8 "gcc-4.0 -arch i386 -isysroot $D/MacOSX10.4u.sdk -mmacosx-version-min=10.4" -arch i386 -isysroot $D/MacOSX10.4u.sdk -mmacosx-version-min=10.4
EXTRA="--with-sandbox=no" slice x86_64 x86_64-apple-darwin9 "gcc-4.2 -arch x86_64 -isysroot $D/MacOSX10.5.sdk -mmacosx-version-min=10.5" -arch x86_64 -isysroot $D/MacOSX10.5.sdk -mmacosx-version-min=10.5
EXTRA="--without-pie --with-sandbox=no" slice ppc64 powerpc64-apple-darwin9 "gcc-4.2 -arch ppc64 -isysroot $D/MacOSX10.5.sdk -mmacosx-version-min=10.5" -arch ppc64 -isysroot $D/MacOSX10.5.sdk -mmacosx-version-min=10.5
[ -z "$ONLY" ] || exit 0
mkdir -p bin
for t in $TOOLS; do
  lipo -create build/ppc/$t build/i386/$t build/x86_64/$t build/ppc64/$t -output bin/$t
done
ls -la bin
