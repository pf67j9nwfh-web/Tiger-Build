#!/bin/sh
# Builds the engine tests with the host compiler and runs them against mockservices and fakecommander.
# Run on a current Mac: sh tests/engine/run-host.sh. Needs third_party/mbedtls/build/libmbedtls-host.a (third_party/mbedtls/build-host.sh)
# and the libwebp and libsmb2 sources (third_party/libwebp/fetch.sh, third_party/libsmb2/fetch.sh).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
cd "$ROOT/tiger-build"
OUT="${TMPDIR:-/tmp}/tb-engine-tests"
export TB_NO_KEYCHAIN=1   # the test programs must not ask for (or read) the real Keychain
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
# libsmb2 (third_party/libsmb2/fetch.sh) for the host, and tbsmbd with it
SMB=../third_party/libsmb2/src
mkdir -p "$OUT/smb"
printf '#define _U_ __attribute__((unused))\n' > "$OUT/smb/tbdefs.h"
for f in $(cd $SMB/lib && ls aes.c aes_reference.c aes128ccm.c alloc.c asn1-ber.c compat.c errors.c hmac.c hmac-md5.c init.c libsmb2.c md4c.c md5.c ntlmssp.c pdu.c sha1.c sha224-256.c sha384-512.c smb2-cmd-*.c smb2-data-*.c smb2-share-enum.c smb3-seal.c smb2-signing.c socket.c spnego-wrapper.c sync.c timestamps.c unicode.c usha.c); do
  clang -O1 -w -std=gnu99 -DHAVE_CONFIG_H -DHAVE_ARC4RANDOM_BUF -include "$OUT/smb/tbdefs.h" -I$SMB/include -I$SMB/include/smb2 -I$SMB/include/apple -I$SMB/lib -c $SMB/lib/$f -o "$OUT/smb/$f.o" &
done
wait
clang -O1 -w -std=gnu99 -I$SMB/include -I$SMB/include/smb2 -I$SMB/include/apple -o "$OUT/tbsmbd" ../smbd/tbsmbd.c "$OUT"/smb/*.o
COMMON="TBEngine.m TBHTTP.m TBNet.c TBJSON.m TBSupport.m TBMarkup.m TBEmoji.m TBMachine.m TBRun.m TBMCP.m TBOAuth.m"
COMMON_NO_MCP="TBEngine.m TBHTTP.m TBNet.c TBJSON.m TBSupport.m TBMarkup.m TBEmoji.m TBMachine.m TBRun.m"
LIBS="-framework Foundation -framework Security -framework AppKit -framework ApplicationServices -framework AudioToolbox -framework QTKit $TLS/build/libmbedtls-host.a -lz"
build() { name=$1; shift; clang -w -fobjc-exceptions $TLSFLAGS -I. -I../cli -I../third_party/libsmb2/include -I../third_party/libsmb2/include/smb2 -I../third_party/libwebp/include -I../third_party/libaom/include -o "$OUT/$name" "$@" $LIBS; }
build speech ../tests/engine/speechtest.m TBSpeech.m $COMMON
build outputs ../tests/engine/outputstest.m TBOutputs.m TBExtract.m TBOffice.m TBHEIC.m $COMMON "$OUT"/webp/*.o "$OUT"/aom/*.o
build extras ../tests/engine/extrastest.m TBSMB.m "$OUT"/smb/*.o TBBuiltin.m TBBackground.m TBSSH.m TBLocalTools.m TBExtras.m TBSkills.m TBOutputs.m TBMedia.m TBWebTools.m TBIntegrations.m TBExtract.m TBOffice.m TBHEIC.m $COMMON "$OUT"/webp/*.o "$OUT"/aom/*.o
build prov ../tests/engine/provtest.m TBProviders.m $COMMON
build session ../tests/engine/sessiontest.m TBSMB.m "$OUT"/smb/*.o TBSession.m TBSessionGrok.m TBSessionSub.m TBModelProfiles.m TBModelUpdate.m TBProviders.m TBPricing.m TBLocal.m TBLocalTools.m TBExtras.m TBSkills.m TBBuiltin.m TBBackground.m TBMedia.m TBWebTools.m TBOutputs.m TBExtract.m TBOffice.m TBHEIC.m TBIntegrations.m TBSSH.m $COMMON "$OUT"/webp/*.o "$OUT"/aom/*.o
build formats ../tests/engine/formatstest.m TBExtract.m TBOffice.m TBHEIC.m TBSpeech.m $COMMON "$OUT"/webp/*.o "$OUT"/aom/*.o
build localtools ../tests/engine/localtoolstest.m TBLocalTools.m TBSkills.m TBModelProfiles.m TBProviders.m TBExtract.m TBOffice.m TBHEIC.m TBSpeech.m $COMMON "$OUT"/webp/*.o "$OUT"/aom/*.o
build chatexport ../tests/engine/chatexporttest.m TBChatExport.m $COMMON
build mcptransport ../tests/engine/mcptransporttest.m TBMCP.m TBOAuth.m $COMMON_NO_MCP
build smbtest ../tests/engine/smbtest.m TBSMB.m "$OUT"/smb/*.o $COMMON
build store ../tests/engine/storetest.m $COMMON
build tb ../cli/main.m ../cli/TBCLICore.m ../cli/TBTerm.m ../cli/TBMarkdown.m ../cli/TBCLIApp.m ../cli/TBCLICommands.m ../cli/TBCLIExtras.m TBSMB.m "$OUT"/smb/*.o TBSession.m TBSessionGrok.m TBSessionSub.m TBModelProfiles.m TBModelUpdate.m TBProviders.m TBPricing.m TBLocal.m TBLocalTools.m TBExtras.m TBSkills.m TBBuiltin.m TBBackground.m TBMedia.m TBWebTools.m TBOutputs.m TBExtract.m TBOffice.m TBHEIC.m TBIntegrations.m TBSSH.m TBService.m TBSpeech.m TBChatExport.m $COMMON "$OUT"/webp/*.o "$OUT"/aom/*.o
build mock ../tests/engine/mockservices.m TBJSON.m
clang -w -fobjc-exceptions -I. -framework Foundation -o "$OUT/fakecommander" ../tests/engine/fakecommander.m TBJSON.m
make -s -C ../commander host TB="$PWD" >/dev/null && cp ../commander/ppc-commander-host "$OUT/ppc-commander"
build commander ../tests/engine/commandertest.m TBMCP.m TBOAuth.m $COMMON_NO_MCP
build commanderfull ../tests/engine/commanderfull.m TBMCP.m TBOAuth.m $COMMON_NO_MCP
PORT=8795
"$OUT/mock" $PORT > /dev/null 2>&1 &
MOCK=$!
trap 'kill $MOCK 2>/dev/null' EXIT
sleep 1
mkdir -p "$OUT/files"
status=0
for t in speech outputs; do "$OUT/$t" $( [ $t = speech ] && echo $PORT || echo "$OUT/files" ) || status=1; done
# the SMB tools against tbsmbd, which serves a folder to tbuser
mkdir -p "$OUT/share"; printf 'tbuser:s3cret-pass\n' > "$OUT/smbusers"; chmod 600 "$OUT/smbusers"
"$OUT/tbsmbd" --root "$OUT/share" --share Share --users "$OUT/smbusers" --port 8446 > "$OUT/tbsmbd.log" 2>&1 &
SMBD=$!
trap 'kill $MOCK $SMBD 2>/dev/null' EXIT
sleep 1
"$OUT/smbtest" 8446 "$OUT/share" || status=1
rm -rf "$OUT/storedir"; "$OUT/store" "$OUT/storedir" || status=1
"$OUT/extras" $PORT || status=1
"$OUT/mcptransport" $PORT || status=1
"$OUT/formats" ../tests/engine/fixtures || status=1
"$OUT/localtools" || status=1
"$OUT/chatexport" || status=1
"$OUT/prov" $PORT || status=1
"$OUT/commander" "$OUT/ppc-commander" || status=1
sh ../tests/engine/sshcopyid.sh 2>&1 || status=1
"$OUT/commanderfull" "$OUT/ppc-commander" || status=1
"$OUT/session" $PORT 127.0.0.1 "$OUT/fakecommander" || status=1
[ $status = 0 ] && echo "all engine tests passed" || echo "SOME ENGINE TESTS FAILED"
exit $status
