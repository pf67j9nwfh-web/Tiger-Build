#!/bin/sh
# usage: build.sh [extra gcc flags]  -- builds tlstest and benchmark next to the mbedtls tree
cd "$(dirname "$0")"
M=mbedtls-2.28.10
mkdir -p obj
start=`date +%s`
for f in $M/library/*.c; do
  o=obj/`basename $f .c`.o
  [ -f $o ] || gcc -O2 "$@" -I$M/include -c $f -o $o || exit 1
done
gcc -O2 "$@" -I$M/include tlstest.c obj/*.o -o tlstest || exit 1
gcc -O2 "$@" -I$M/include $M/programs/test/benchmark.c obj/*.o -o benchmark || exit 1
echo "built in $((`date +%s` - start)) s"
