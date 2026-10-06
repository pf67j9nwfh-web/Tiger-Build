#!/bin/sh
# Downloads libwebp 1.5.0 (BSD-3-Clause, checked against its published SHA-256) and keeps the decoder's and demuxer's sources in src/.
# Run on a current Mac: the old ones cannot download over modern TLS.
set -e
cd "$(dirname "$0")"
VERSION=1.5.0
SHA256=7d6fab70cf844bf6769077bd5d7a74893f8ffd4dfb42861745750c63c2a5c92c
rm -rf src && mkdir src
curl -fsSL -o src/libwebp.tar.gz "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$VERSION.tar.gz"
echo "$SHA256  src/libwebp.tar.gz" | shasum -a 256 -c -
tar -xzf src/libwebp.tar.gz -C src
rm src/libwebp.tar.gz
mv "src/libwebp-$VERSION" src/libwebp
rm -rf include && mkdir -p include/webp && cp src/libwebp/src/webp/decode.h src/libwebp/src/webp/types.h src/libwebp/src/webp/format_constants.h src/libwebp/src/webp/demux.h src/libwebp/src/webp/mux_types.h include/webp/
cp src/libwebp/COPYING LICENSE
echo "libwebp $VERSION is in third_party/libwebp/src/libwebp; the decoder's headers are in third_party/libwebp/include"
