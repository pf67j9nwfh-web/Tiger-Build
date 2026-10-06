#!/bin/sh
cd "$(dirname "$0")"
gcc -O2 "$@" -Imbedtls-2.28.10/include tlstest.c obj/*.o -o tlstest
