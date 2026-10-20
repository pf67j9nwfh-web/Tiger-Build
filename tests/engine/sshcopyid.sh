#!/bin/sh
# tbssh-commander: ssh-copy-id support. Runs the wrapper with a made-up home and the commands ssh-copy-id sends.
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$HERE/../../installer/tbssh/tbssh-commander"
H="${TMPDIR:-/tmp}/tb-copyid-home"; rm -rf "$H"; mkdir -p "$H"
L="$H/Library/Application Support/Tiger Build/ssh/authorized_keys"
fail=0
check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
K1='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOneKeyOneKeyOneKeyOneKeyOneKeyOneKeyOneKey1 me@modern'
K2='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQTwoKeyTwoKeyTwoKeyTwoKeyTwoKeyTwoKey2 me@other'
printf '%s\nnot a key\n%s\n' "$K1" "$K2" | HOME="$H" SSH_ORIGINAL_COMMAND="exec sh -c 'cd ; umask 077 ; mkdir -p .ssh && cat >> .ssh/authorized_keys || exit 1'" "$W"
[ "$(wc -l < "$L" | tr -d ' ')" = 2 ] && grep -qF "OneKeyOne" "$L" && grep -qF "TwoKeyTwo" "$L" && ! grep -q "not a key" "$L" && check "ssh-copy-id: two keys added, the junk line left out" ok || check "ssh-copy-id: two keys added, the junk line left out" bad
printf '%s\n' "$K1" | HOME="$H" SSH_ORIGINAL_COMMAND="exec sh -c 'cat >> .ssh/authorized_keys'" "$W"
[ "$(wc -l < "$L" | tr -d ' ')" = 2 ] && check "ssh-copy-id: a key already there is not added twice" ok || check "ssh-copy-id: a key already there is not added twice" bad
[ "$(stat -f %Lp "$L" 2>/dev/null || stat -c %a "$L")" = 600 ] && check "ssh-copy-id: the list is private to the account" ok || check "ssh-copy-id: the list is private to the account" bad
HOME="$H" SSH_ORIGINAL_COMMAND="exit" "$W" </dev/null && check "ssh-copy-id: its test login succeeds without starting anything" ok || check "ssh-copy-id: its test login succeeds without starting anything" bad
HOME="$H" SSH_ORIGINAL_COMMAND="commander" "$W" </dev/null 2>/dev/null; [ $? = 1 ] && check "anything else still wants Commander (not installed here)" ok || check "anything else still wants Commander (not installed here)" bad
rm -rf "$H"
exit $fail
