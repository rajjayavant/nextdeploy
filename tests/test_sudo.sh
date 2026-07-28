#!/usr/bin/env bash
# Regression tests for the sudo pre-flight check.
#
# The bug this guards against: using `sudo -v` as the access check. On a
# stock EC2 Ubuntu AMI the 'ubuntu' user has NOPASSWD sudo and no password
# set at all, so `sudo -v` prompts for a password the user cannot possibly
# supply. `sudo -n true` is the correct probe — it never prompts.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PASS=0; FAIL=0
ok_()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail_() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

echo "== the check must not prompt when sudo is passwordless =="

# `sudo -n true` must come before any bare `sudo -v` in preflight.
first_probe="$(grep -nE '^\s*(if )?sudo -(n true|v)' setup.sh | head -n1 || true)"
case "$first_probe" in
  *'sudo -n true'*) ok_   "first sudo probe is 'sudo -n true' (non-prompting)" ;;
  *'sudo -v'*)      fail_ "first sudo probe is 'sudo -v' — this prompts on a passwordless box" ;;
  *)                fail_ "no sudo probe found in setup.sh" ;;
esac

# A passwordless box must never reach `sudo -v`.
if awk '/^  info "Checking sudo access/,/^  # Keep sudo warm/' setup.sh \
   | grep -q 'if sudo -n true'; then
  ok_ "passwordless path is guarded by 'if sudo -n true'"
else
  fail_ "passwordless path is not guarded — sudo -v may run unconditionally"
fi

echo
echo "== the no-password case must be explained before prompting =="

block="$(awk '/^  info "Checking sudo access/,/^  # Keep sudo warm/' setup.sh)"

if printf '%s' "$block" | grep -q 'no password needed'; then
  ok_ "confirms passwordless sudo explicitly"
else
  fail_ "no message for the passwordless case"
fi

# The explanation has to come before `sudo -v`, or the user hits the prompt
# with no idea what to type — the exact complaint that prompted this fix.
hint_line="$(printf '%s' "$block" | grep -n 'never set a password' | cut -d: -f1 | head -n1)"
sudov_line="$(printf '%s' "$block" | grep -n 'sudo -v' | cut -d: -f1 | head -n1)"
if [ -n "$hint_line" ] && [ -n "$sudov_line" ] && [ "$hint_line" -lt "$sudov_line" ]; then
  ok_ "'never set a password' guidance appears BEFORE the sudo -v prompt"
else
  fail_ "guidance missing or appears after the prompt (hint=$hint_line sudov=$sudov_line)"
fi

for phrase in "passwordless" "ubuntu@"; do
  if printf '%s' "$block" | grep -q "$phrase"; then
    ok_ "mentions '$phrase'"
  else
    fail_ "does not mention '$phrase'"
  fi
done

echo
echo "== root check should steer away from 'sudo ./setup.sh' =="

rootblock="$(awk '/if \[ "\$\(id -u\)" -eq 0 \]/,/^  fi/' setup.sh)"
if printf '%s' "$rootblock" | grep -q 'WITHOUT sudo'; then
  ok_ "tells the user to run it without sudo"
else
  fail_ "root message does not say to drop sudo"
fi
if printf '%s' "$rootblock" | grep -q 'calls sudo itself'; then
  ok_ "explains the script escalates on its own"
else
  fail_ "root message does not explain self-escalation"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
