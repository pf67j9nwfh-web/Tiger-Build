#!/bin/sh
# Downloads the sources of sshfs 2.2 and what it is built with, checked against their SHA-256, into src/. Run on a current Mac.
#  - sshfs-fuse 2.2 (GPL-2.0): from the Wayback Machine's copy of the SourceForge release (the original link is gone)
#  - the MacFUSE project's patch for it (patches/sshfs-2.2-macosx.patch, kept in this repository): Darwin semaphores, volume name, -F
#  - glib 2.16.6 (LGPL-2.1) and pkg-config 0.23 (GPL-2.0), built only to link sshfs statically
set -e
cd "$(dirname "$0")"
rm -rf src && mkdir src
get() {  # url sha256 file
  curl -fsSL -o "src/$3" "$1"
  echo "$2  src/$3" | shasum -a 256 -c -
}
get "https://web.archive.org/web/2012id_/http://downloads.sourceforge.net/project/fuse/sshfs-fuse/2.2/sshfs-fuse-2.2.tar.gz" 206ebcbc4cb9f5039bfcc7059678a0f61120605a5cdcbffa3ae5716c113e5423 sshfs-fuse-2.2.tar.gz
get "https://download.gnome.org/sources/glib/2.16/glib-2.16.6.tar.bz2" c3d8f831b8d127905f8e7f066ff5398668fa26f6a180945b32a5641c03c42925 glib-2.16.6.tar.bz2
get "https://pkgconfig.freedesktop.org/releases/pkg-config-0.23.tar.gz" 08a0e072d6a05419a58124db864f0685e6ac96e71b2875bf15ac12714e983b53 pkg-config-0.23.tar.gz
echo "e49009e14fd817a9c6f66ebace0b5d68110a5c53c37cb7f18f79bb26d80d49c5  patches/sshfs-2.2-macosx.patch" | shasum -a 256 -c -
