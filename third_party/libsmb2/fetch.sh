#!/bin/sh
# Downloads libsmb2 (SMB 2 and 3 client and server library, LGPL-2.1, https://github.com/sahlberg/libsmb2) at the commit Tiger Build was built and tested with, into src/.
# Run on a current Mac: the old ones cannot download over modern TLS.
set -e
cd "$(dirname "$0")"
COMMIT=57fea04
rm -rf src && git clone -q https://github.com/sahlberg/libsmb2.git src
git -C src checkout -q $COMMIT
rm -rf src/.git
patch -p1 -d src -s < patches/tbsmbd.patch   # status codes, raw query-info, inherited listening socket (see the patch)
cp src/LICENCE-LGPL-2.1.txt LICENSE
cp src/COPYING COPYING
