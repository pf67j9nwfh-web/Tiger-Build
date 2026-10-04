#!/bin/sh
cd "$(dirname "$0")"
gcc -O2 "$@" -Imbedtls-2.28.10/include ecbench.c obj/*.o -o ecbench
