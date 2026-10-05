#!/bin/sh
# Builds the engine tests with the host compiler and runs them against mockservices and fakecommander.
# Run on a current Mac: sh tests/engine/run-host.sh. Needs third_party/mbedtls/build/libmbedtls-host.a (third_party/mbedtls/build-host.sh)
# and the libwebp sources (third_party/libwebp/fetch.sh).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
cd "$ROOT/tiger-build"
OUT="${TMPDIR:-/tmp}/tb-engine-tests"
rm -rf "$OUT"; mkdir -p "$OUT/webp" "$OUT/cfg/src/webp"
: > "$OUT/cfg/src/webp/config.h"
TLS=../third_party/mbedtls
WEBP=../third_party/libwebp/src/libwebp
TLSFLAGS="-std=gnu99 -I$TLS/include -DMBEDTLS_USER_CONFIG_FILE=\"$(cd $TLS && pwd)/tb_config.h\""
for f in $WEBP/src/dec/*.c $WEBP/src/dsp/*.c $WEBP/src/utils/*.c $WEBP/src/demux/*.c; do
  case $(basename $f) in *_sse2.c|*_sse41.c|*_neon.c|*_mips*.c|*_msa.c|*enc*|ssim.c|cost.c|quant_levels_utils.c|bit_writer_utils.c) continue;; esac
  clang -O1 -w -DHAVE_CONFIG_H -I"$OUT/cfg" -I$WEBP -I$WEBP/src -c $f -o "$OUT/webp/$(basename $f .c).o"
done
AOM=../third_party/libaom
mkdir -p "$OUT/aom"
for f in $(cat $AOM/files.txt) config/aom_config.c; do
  case $f in config/*) src=$AOM/$f;; *) src=$AOM/src/libaom/$f;; esac
  clang -O1 -w -std=c99 -DNDEBUG -I$AOM/src/libaom -I$AOM -c $src -o "$OUT/aom/$(echo $f | tr / _).o"
done
COMMON="TBEngine.m TBHTTP.m TBNet.c TBJSON.m TBSupport.m TBMarkup.m TBEmoji.m TBMachine.m TBRun.m TBMCP.m"
COMMON_NO_MCP="TBEngine.m TBHTTP.m TBNet.c TBJSON.m TBSupport.m TBMarkup.m TBEmoji.m TBMachine.m TBRun.m"
LIBS="-framework Foundation -framework Security -framework AppKit -framework ApplicationServices $TLS/build/libmbedtls-host.a -lz"
build() { name=$1; shift; clang -w -fobjc-exceptions $TLSFLAGS -I. -I../third_party/libwebp/include -I../third_party/libaom/include -o "$OUT/$name" "$@" $LIBS; }
build speech ../tests/engine/speechtest.m TBSpeech.m $COMMON
build outputs ../tests/engine/outputstest.m TBOutputs.m TBExtract.m TBOffice.m TBHEIC.m $COMMON "$OUT"/webp/*.o "$OUT"/aom/*.o
build extras ../tests/engine/extrastest.m TBBuiltin.m TBSSH.m TBExtras.m TBOutputs.m TBMedia.m TBIntegrations.m TBExtract.m TBOffice.m TBHEIC.m $COMMON "$OUT"/webp/*.o "$OUT"/aom/*.o
build prov ../tests/engine/provtest.m TBProviders.m $COMMON
build session ../tests/engine/sessiontest.m TBSession.m TBSessionGrok.m TBProviders.m TBPricing.m TBLocal.m TBExtras.m TBBuiltin.m TBMedia.m TBOutputs.m TBExtract.m TBOffice.m TBHEIC.m TBIntegrations.m TBSSH.m $COMMON "$OUT"/webp/*.o "$OUT"/aom/*.o
build mock ../tests/engine/mockservices.m TBJSON.m
clang -w -fobjc-exceptions -I. -framework Foundation -o "$OUT/fakecommander" ../tests/engine/fakecommander.m TBJSON.m
make -s -C ../commander host TB="$PWD" >/dev/null && cp ../commander/ppc-commander-host "$OUT/ppc-commander"
build commander ../tests/engine/commandertest.m TBMCP.m $COMMON_NO_MCP
build commanderfull ../tests/engine/commanderfull.m TBMCP.m $COMMON_NO_MCP
PORT=8795
"$OUT/mock" $PORT > /dev/null 2>&1 &
MOCK=$!
trap 'kill $MOCK 2>/dev/null' EXIT
sleep 1
mkdir -p "$OUT/files"
status=0
for t in speech outputs; do "$OUT/$t" $( [ $t = speech ] && echo $PORT || echo "$OUT/files" ) || status=1; done
"$OUT/extras" $PORT || status=1
"$OUT/prov" $PORT || status=1
"$OUT/commander" "$OUT/ppc-commander" || status=1
"$OUT/commanderfull" "$OUT/ppc-commander" || status=1
"$OUT/session" $PORT 127.0.0.1 "$OUT/fakecommander" || status=1
[ $status = 0 ] && echo "all engine tests passed" || echo "SOME ENGINE TESTS FAILED"
exit $status
