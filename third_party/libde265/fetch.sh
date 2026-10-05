#!/bin/sh
# Downloads libde265 1.0.15 (LGPL-3.0, checked against its published SHA-256), keeps the decoder's sources in src/ and
# patches them for the old Macs' C++ compilers (old-compilers.patch: C++98 and tr1 in place of C++11). Run on a current Mac.
set -e
cd "$(dirname "$0")"
VERSION=1.0.15
SHA256=00251986c29d34d3af7117ed05874950c875dd9292d016be29d3b3762666511d
rm -rf src && mkdir src
curl -fsSL -o src/libde265.tar.gz "https://github.com/strukturag/libde265/releases/download/v$VERSION/libde265-$VERSION.tar.gz"
echo "$SHA256  src/libde265.tar.gz" | shasum -a 256 -c -
tar -xzf src/libde265.tar.gz -C src
rm src/libde265.tar.gz
mv "src/libde265-$VERSION" src/libde265
patch -s -p1 -d src/libde265 < old-compilers.patch
rm -rf include && mkdir -p include/libde265 && cp src/libde265/libde265/de265.h src/libde265/libde265/de265-version.h include/libde265/
cp src/libde265/COPYING LICENSE
echo "libde265 $VERSION is in third_party/libde265/src/libde265; its public headers are in third_party/libde265/include"
