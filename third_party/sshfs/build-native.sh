#!/bin/sh
# usage: build-native.sh SLICE [FUSE_DIR]
# Builds sshfs 2.2 (with the MacFUSE patch, glib linked in statically) for the Mac it runs on, into bin/sshfs-SLICE (SLICE: ppc, i386 or x86_64: the
# architecture of that Mac). FUSE_DIR holds MacFUSE's include/fuse and lib/libfuse.2.dylib (default /usr/local, where MacFUSE's installer puts them);
# sshfs finds libfuse there when it runs. Run fetch.sh first, on another Mac. The three slices are joined into one program with lipo (join.sh).
set -e
cd "$(dirname "$0")"
SLICE=${1:?slice}
FUSE=${2:-/usr/local}
ROOT="$PWD"
W="$ROOT/build/$SLICE"
rm -rf "$W" && mkdir -p "$W" "$ROOT/bin"
cd "$W"
tar xzf "$ROOT/src/pkg-config-0.23.tar.gz" && tar xjf "$ROOT/src/glib-2.16.6.tar.bz2" && tar xzf "$ROOT/src/sshfs-fuse-2.2.tar.gz"
export PATH="$W/root/bin:$PATH"
( cd pkg-config-0.23 && ./configure --prefix="$W/root" --with-internal-glib > ../pkgconfig.log 2>&1 && make >> ../pkgconfig.log 2>&1 && make install >> ../pkgconfig.log 2>&1 )
# glib wants gettext in the C library even with NLS off, and nothing here uses it
# (Snow Leopard's iconv.h is GNU libiconv's, which glib only accepts when told)
( cd glib-2.16.6 && sed -i '' 's/^if test "$gt_cv_have_gettext" != "yes" ; then/if false ; then/' configure \
  && for iconv in "-g -O2" "-g -O2 -DUSE_LIBICONV_GNU"; do
       ( make distclean > /dev/null 2>&1; CFLAGS="$iconv" LIBS="-liconv" ./configure --prefix="$W/root" --disable-shared --enable-static --disable-nls --disable-gtk-doc --disable-man > ../glib.log 2>&1 \
         && make >> ../glib.log 2>&1 && make install >> ../glib.log 2>&1 ) && break
     done )
export PKG_CONFIG_PATH="$W/root/lib/pkgconfig"
( cd sshfs-fuse-2.2 && patch -p1 < "$ROOT/patches/sshfs-2.2-macosx.patch" > ../patch.log \
  && SSHFS_CFLAGS="-I$FUSE/include/fuse -D_FILE_OFFSET_BITS=64 -D_REENTRANT $(pkg-config --cflags glib-2.0 gthread-2.0)" \
     SSHFS_LIBS="-L$FUSE/lib -lfuse $(pkg-config --libs glib-2.0 gthread-2.0)" \
     CFLAGS="-O2 -D__FreeBSD__=10 -DDARWIN_SEMAPHORE_COMPAT" ./configure --prefix="$W/root" > ../sshfs.log 2>&1 \
  && make LDFLAGS="-framework Carbon -liconv -mmacosx-version-min=10.5" >> ../sshfs.log 2>&1 )
cp sshfs-fuse-2.2/sshfs "$ROOT/bin/sshfs-$SLICE"
strip -x "$ROOT/bin/sshfs-$SLICE"
file "$ROOT/bin/sshfs-$SLICE"
