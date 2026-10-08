#!/bin/sh
# Downloads LibreSSL 4.3.3 (ISC and OpenSSL/SSLeay licences, checked against the SHA-256 published with the release) into src/. Run on a current Mac.
# Only libcrypto is used, linked statically into the bundled OpenSSH (RSA, ECDSA and the other key types OpenSSH needs besides ed25519).
set -e
cd "$(dirname "$0")"
VERSION=4.3.3
SHA256=ff97c432457f349e6ba3d416ab903bc7468f1436f0f32efe5fff808de292c7b8
rm -rf src && mkdir src
curl -fsSL -o src/libressl.tar.gz "https://cdn.openbsd.org/pub/OpenBSD/LibreSSL/libressl-$VERSION.tar.gz"
echo "$SHA256  src/libressl.tar.gz" | shasum -a 256 -c -
COPYFILE_DISABLE=1 tar -xzf src/libressl.tar.gz -C src
rm src/libressl.tar.gz
cp "src/libressl-$VERSION/COPYING" LICENSE
