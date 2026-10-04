#!/bin/sh
# mbedTLS for the Mac you are developing on, for the tests that run there (build/libmbedtls-host.a). Run fetch.sh first.
set -e
cd "$(dirname "$0")"
M=src/mbedtls
rm -rf build/obj_host && mkdir -p build/obj_host
for f in $M/library/*.c; do
  cc -O2 -w -std=gnu99 -DMBEDTLS_USER_CONFIG_FILE=\"`pwd`/tb_config.h\" -I$M/include -I$M/library -c $f -o build/obj_host/`basename $f .c`.o
done
libtool -static -o build/libmbedtls-host.a build/obj_host/*.o 2>/dev/null
echo "built build/libmbedtls-host.a"
