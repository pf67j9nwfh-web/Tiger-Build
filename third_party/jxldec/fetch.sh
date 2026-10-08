#!/bin/sh
# Downloads jxl.c and jxl.h of kjk/jxldec at the pinned commit, checks them, and applies patches/old-macs.patch. Run on a current Mac.
# jxl.c and jxl.h in this folder are the result and are kept in git.
set -e
cd "$(dirname "$0")"
C=d71b246bfe099adff25eea5b6c6b9526f5f25282
curl -fsSL -o jxl.c "https://raw.githubusercontent.com/kjk/jxldec/$C/dist/jxl.c"
curl -fsSL -o jxl.h "https://raw.githubusercontent.com/kjk/jxldec/$C/dist/jxl.h"
echo "4c2769a462c99596963a9d580950a172ec6a9504c65a131d73ffa26525b5246f  jxl.c" | shasum -a 256 -c -
echo "bb74558566b9b06f8147ab9e09e4dc2e4783a7545f96dbda99dbf8b5a705707e  jxl.h" | shasum -a 256 -c -
patch -p1 < patches/old-macs.patch
