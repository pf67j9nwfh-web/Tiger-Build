#!/bin/sh
# Downloads mbedTLS 3.6.7 (checked against its published SHA-256), unpacks it to src/ and applies old-macs.patch.
# Run on a current Mac: the old ones cannot download from GitHub.
set -e
cd "$(dirname "$0")"
VERSION=3.6.7
SHA256=a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6
rm -rf src && mkdir src
curl -fsSL -o src/mbedtls.tar.bz2 "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$VERSION/mbedtls-$VERSION.tar.bz2"
echo "$SHA256  src/mbedtls.tar.bz2" | shasum -a 256 -c -
tar -xjf src/mbedtls.tar.bz2 -C src
rm src/mbedtls.tar.bz2
mv "src/mbedtls-$VERSION" src/mbedtls
(cd src/mbedtls && patch -p1 < ../../old-macs.patch)
rm -rf include && mkdir include && cp -R src/mbedtls/include/mbedtls src/mbedtls/include/psa include/
echo "mbedTLS $VERSION is in third_party/mbedtls/src/mbedtls; its headers are in third_party/mbedtls/include"
