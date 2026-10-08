#!/bin/sh
# Joins bin/sshfs-ppc, -i386 and -x86_64 (each built on a Mac of that kind by build-native.sh) into the universal bin/sshfs.
set -e
cd "$(dirname "$0")"
lipo -create bin/sshfs-ppc bin/sshfs-i386 bin/sshfs-x86_64 -output bin/sshfs
lipo -info bin/sshfs
