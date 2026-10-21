#!/bin/sh
# Builds libsmb2 (NTLMSSP only, no Kerberos, no DCE/RPC) as static libraries for the old Macs: lib/libsmb2-32.a (ppc + i386, 10.4 SDK, gcc 4.0) and
# lib/libsmb2-64x86.a (x86_64) and lib/libsmb2-64ppc.a (ppc64, both 10.5 SDK). Run on Snow Leopard with Xcode 3.2 after fetch.sh. lib/ and include/ are kept in git.
set -e
cd "$(dirname "$0")"
D=/Developer/SDKs
SRC="$PWD/src"
FILES="aes.c aes_reference.c aes128ccm.c alloc.c asn1-ber.c compat.c errors.c hmac.c hmac-md5.c init.c libsmb2.c md4c.c md5.c ntlmssp.c pdu.c sha1.c sha224-256.c sha384-512.c
 smb2-cmd-cancel.c smb2-cmd-close.c smb2-cmd-create.c smb2-cmd-echo.c smb2-cmd-error.c smb2-cmd-flush.c smb2-cmd-ioctl.c smb2-cmd-lock.c smb2-cmd-logoff.c smb2-cmd-negotiate.c
 smb2-cmd-notify-change.c smb2-cmd-oplock-break.c smb2-cmd-query-directory.c smb2-cmd-query-info.c smb2-cmd-read.c smb2-cmd-session-setup.c smb2-cmd-set-info.c
 smb2-cmd-tree-connect.c smb2-cmd-tree-disconnect.c smb2-cmd-write.c smb2-data-file-info.c smb2-data-filesystem-info.c smb2-data-security-descriptor.c smb2-data-reparse-point.c
 smb2-share-enum.c smb3-seal.c smb2-signing.c socket.c spnego-wrapper.c sync.c timestamps.c unicode.c usha.c"
rm -rf build && mkdir -p build
printf '#define _U_ __attribute__((unused))\n' > build/tbdefs.h
DEFS="-DHAVE_CONFIG_H -DHAVE_DEV_URANDOM -include $PWD/build/tbdefs.h"
INC="-I$SRC/include -I$SRC/include/smb2 -I$SRC/include/apple -I$SRC/lib"
mkdir -p lib include build
mkdir -p build/32 build/64 build/p64
for f in $FILES; do
  gcc-4.0 -arch ppc -arch i386 -isysroot $D/MacOSX10.4u.sdk -mmacosx-version-min=10.4 -O2 -std=gnu99 -w $DEFS $INC -c $SRC/lib/$f -o build/32/$f.o
  gcc-4.2 -arch x86_64 -isysroot $D/MacOSX10.5.sdk -mmacosx-version-min=10.5 -O2 -std=gnu99 -w $DEFS $INC -c $SRC/lib/$f -o build/64/$f.o
  gcc-4.2 -arch ppc64 -isysroot $D/MacOSX10.5.sdk -mmacosx-version-min=10.5 -O2 -std=gnu99 -w $DEFS $INC -c $SRC/lib/$f -o build/p64/$f.o
done
# the server (../../smbd/tbsmbd.c) with them: bin/tbsmbd, ppc + i386 + x86_64
mkdir -p bin
gcc-4.0 -arch ppc -arch i386 -isysroot $D/MacOSX10.4u.sdk -mmacosx-version-min=10.4 -O2 -std=gnu99 -Wall $INC -c ../../smbd/tbsmbd.c -o build/32/tbsmbd.main
gcc-4.2 -arch x86_64 -isysroot $D/MacOSX10.5.sdk -mmacosx-version-min=10.5 -O2 -std=gnu99 -Wall $INC -c ../../smbd/tbsmbd.c -o build/64/tbsmbd.main
gcc-4.0 -arch ppc -arch i386 -isysroot $D/MacOSX10.4u.sdk -mmacosx-version-min=10.4 -o build/tbsmbd32 build/32/tbsmbd.main build/32/*.c.o
gcc-4.2 -arch x86_64 -isysroot $D/MacOSX10.5.sdk -mmacosx-version-min=10.5 -o build/tbsmbd64 build/64/tbsmbd.main build/64/*.c.o
lipo -create build/tbsmbd32 build/tbsmbd64 -output bin/tbsmbd
strip -x bin/tbsmbd
rm -f lib/libsmb2-32.a lib/libsmb2-64x86.a lib/libsmb2-64ppc.a
libtool -static -o lib/libsmb2-32.a build/32/*.o
libtool -static -o lib/libsmb2-64x86.a build/64/*.o
libtool -static -o lib/libsmb2-64ppc.a build/p64/*.o
rm -rf include/smb2 && mkdir -p include/smb2 && cp $SRC/include/smb2/*.h include/smb2/
mkdir -p include/apple && cp $SRC/include/apple/config.h include/apple/
cp $SRC/include/libsmb2-private.h $SRC/include/portable-endian.h $SRC/include/slist.h $SRC/include/asprintf.h include/ 2>/dev/null || true
rm -rf build
ls -la lib
