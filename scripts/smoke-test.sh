#!/bin/bash
# On-device smoke test for one old Mac. The Mac must already have the checkout's tiger-build/ copied to ~/TigerBuild-dev (the dev loop does that).
#   SMOKE_SSH="ssh user@host" scripts/smoke-test.sh          (SMOKE_SSH is the command that runs a shell command on that Mac, stdin passed through)
# Checks: the unit tests pass; the converter turns each fixture into the right thing; the app starts, stays up and leaves no crash report;
# the uninstaller (dry run) lists what it would remove. Exit status 0 when everything passed.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
: "${SMOKE_SSH:?set SMOKE_SSH to the command that runs a command on the Mac}"
fail=0
r() { $SMOKE_SSH "$@"; }
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }

echo "== $(r 'sw_vers -productVersion; uname -m' | tr '\n' ' ')"
r 'cd ~/TigerBuild-dev && make test 2>&1 | tail -1' | grep -q "all passed" && ok "unit tests" || bad "unit tests"

COPYFILE_DISABLE=1 tar --no-xattrs -C "$HERE/tests/engine" -cf - fixtures | r 'rm -rf ~/tb-fixtures && mkdir ~/tb-fixtures && cd ~/tb-fixtures && tar -xf - 2>/dev/null'
r 'cd ~/TigerBuild-dev && make convert 2>&1 | grep -ci " error"' | grep -q '^0$' && ok "converter builds" || bad "converter builds"
conv() { r "cd ~/TigerBuild-dev && TB_AUDIO_DECODE_ONLY=1 ./convert32 ~/tb-fixtures/fixtures/$1 /tmp/tb-smoke.jpg 2>&1 | head -12"; }
check() { conv "$1" | grep -q "$2" && ok "converts $1" || bad "converts $1 (wanted '$2')"; }
check book.epub "The Test Book"
check stuff.zip "3 files, 2.9 MB"
check tiny.jxl "Converted from JPEG XL"
check tiny-lossy.jxl "Converted from JPEG XL"
check tiny.bmp "Converted from BMP"
check tiny.tif "Converted from TIF"
check speech.wav "decoded"
r 'rm -rf ~/tb-fixtures /tmp/tb-smoke.jpg'

before=$(r 'ls ~/Library/Logs/CrashReporter ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -ci "^TigerBuild"')
r 'killall TigerBuild 2>/dev/null; sleep 1; cd ~/TigerBuild-dev && (./TigerBuild.app/Contents/MacOS/TigerBuild > /dev/null 2>&1 &); sleep 20; ps ax | grep -c "[T]igerBuild.app/Contents/MacOS"' | grep -q '^1$' && ok "app starts and stays up" || bad "app starts and stays up (a Keychain prompt waiting for an answer counts as up)"
after=$(r 'ls ~/Library/Logs/CrashReporter ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -ci "^TigerBuild"')
[ "$before" = "$after" ] && ok "no new crash report" || bad "no new crash report"
r 'killall TigerBuild 2>/dev/null; true'

cat "$HERE/installer/tbssh/tiger-build-uninstall" | r 'cat > /tmp/tbu-smoke.sh; TB_UNINSTALL_DRYRUN=1 sh /tmp/tbu-smoke.sh 2>&1; rm -f /tmp/tbu-smoke.sh' > /tmp/tbu-smoke.out
grep -q "rm -rf /usr/local/tbssh" /tmp/tbu-smoke.out && grep -q "Applications/Tiger Build.app" /tmp/tbu-smoke.out && grep -q "^done" /tmp/tbu-smoke.out && ok "uninstaller dry run" || bad "uninstaller dry run"
rm -f /tmp/tbu-smoke.out
[ $fail = 0 ] && echo "smoke test passed" || echo "SMOKE TEST FAILED"
exit $fail
