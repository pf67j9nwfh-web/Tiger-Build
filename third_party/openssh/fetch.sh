#!/bin/sh
# Downloads OpenSSH 10.6p1 (portable; BSD and ISC licences, checked against the SHA-256 published in the release announcement,
# https://www.openssh.com/txt/release-10.6) into src/. Run on a current Mac: the old ones cannot download over modern TLS.
set -e
cd "$(dirname "$0")"
VERSION=10.6p1
SHA256=a9dc9565dffe8640f64d863cd29a32bc4a3dbdec0566a7fc44c5d6ee767d5f39
rm -rf src && mkdir src
curl -fsSL -o src/openssh.tar.gz "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-$VERSION.tar.gz"
echo "$SHA256  src/openssh.tar.gz" | shasum -a 256 -c -
COPYFILE_DISABLE=1 tar -xzf src/openssh.tar.gz -C src
rm src/openssh.tar.gz
cp "src/openssh-$VERSION/LICENCE" LICENSE
