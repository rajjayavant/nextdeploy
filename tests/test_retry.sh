#!/usr/bin/env bash
# Tests for the retry engine — the thing that makes every step recoverable.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# ui.sh reads from /dev/tty so it works under `curl | bash`. For testing we
# rewrite those redirections so we can drive it with piped input.
sed -e 's|< /dev/tty||g' -e 's|> /dev/tty|>\&2|g' lib/ui.sh > /tmp/ui_notty_retry.sh
. /tmp/ui_notty_retry.sh

PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL $1: got '$3' want '$2'"; fi; }

# The step function runs inside a command substitution (a subshell), so a
# plain shell variable can't carry the count back out. Use a temp file.
COUNTER=/tmp/nextdeploy_test_attempts
bump() { echo x >> "$COUNTER"; }
count() { wc -l < "$COUNTER" 2>/dev/null | tr -d ' '; }

echo "== retry until success =="
: > "$COUNTER"
flaky() { bump; [ "$(count)" -ge 3 ] && return 0; return 1; }
rc=$(printf '1\n1\n' | { retry_step "flaky" flaky >/dev/null 2>&1; echo $?; })
check "retries then succeeds (rc)"       "0" "$rc"
check "took 3 attempts"                  "3" "$(count)"

echo "== first-try success runs once =="
: > "$COUNTER"
good() { bump; return 0; }
rc=$(printf '' | { retry_step "good" good >/dev/null 2>&1; echo $?; })
check "success rc"                       "0" "$rc"
check "no retry menu shown"              "1" "$(count)"

echo "== skip path =="
always_fail() { return 1; }
rc=$(printf '3\n' | { retry_step "doomed" always_fail >/dev/null 2>&1; echo $?; })
check "skip returns 0 and continues"     "0" "$rc"

echo "== abort path =="
out=$(printf '4\n' | ( retry_step "doomed" always_fail >/dev/null 2>&1; echo "REACHED" ) 2>/dev/null; echo "rc=$?")
check "abort does not continue"          "rc=1" "$out"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
