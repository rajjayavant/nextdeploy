#!/usr/bin/env bash
# Regression tests for terminal/stdin handling.
#
# The bug: run as `bash <(curl ...)`, stdin is the script text rather than
# the keyboard. `read` then consumes script bytes instead of typed input
# (so pressing Enter appears to do nothing), and sudo finds no free
# terminal to prompt on (so it asks for a password that can't be typed).
#
# The fix: setup.sh reattaches stdin to /dev/tty once at startup, and the
# prompt helpers read plain stdin rather than grabbing /dev/tty themselves.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PASS=0; FAIL=0
ok_()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail_() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

echo "== setup.sh reattaches stdin before doing anything =="

if grep -q 'exec < /dev/tty' setup.sh; then
  ok_ "reattaches stdin to /dev/tty"
else
  fail_ "missing 'exec < /dev/tty' — prompts will eat the script when curl-piped"
fi

# The reattach must happen before the first prompt, or it's pointless.
exec_line="$(grep -n 'exec < /dev/tty' setup.sh | head -n1 | cut -d: -f1)"
load_line="$(grep -n '^_load_lib ui.sh' setup.sh | head -n1 | cut -d: -f1)"
if [ -n "$exec_line" ] && [ -n "$load_line" ] && [ "$exec_line" -lt "$load_line" ]; then
  ok_ "reattach happens before the UI library loads"
else
  fail_ "reattach is too late (exec=$exec_line load=$load_line)"
fi

if grep -q 'HAVE_TTY' setup.sh; then
  ok_ "tracks whether a terminal exists at all"
else
  fail_ "no HAVE_TTY guard — would block forever with no terminal"
fi

echo
echo "== prompts must not grab /dev/tty themselves =="

# Any read from /dev/tty competes with sudo for the terminal.
if grep -qE 'read -r [^<]*< */dev/tty' lib/ui.sh; then
  fail_ "a prompt still reads directly from /dev/tty"
else
  ok_ "no prompt reads directly from /dev/tty"
fi

if grep -qE '> */dev/tty' lib/ui.sh; then
  fail_ "a prompt still writes directly to /dev/tty"
else
  ok_ "no prompt writes directly to /dev/tty"
fi

echo
echo "== prompts still work with piped stdin =="

# This is the real behavioural check: with stdin piped (no tty at all),
# the helpers must read the piped bytes rather than hang or misread.
t_prompt() { # label input code expected
  local got
  got="$(printf '%s' "$2" | bash -c ". lib/ui.sh; $3" 2>/dev/null | tail -n1)"
  if [ "$got" = "$4" ]; then ok_ "$1"; else fail_ "$1: got '$got' want '$4'"; fi
}

t_prompt "prompt reads piped value"   $'hello\n'  'prompt v "Q:"; printf "%s" "$v"'          "hello"
t_prompt "Enter alone takes default"  $'\n'       'prompt v "Q:" "3000"; printf "%s" "$v"'   "3000"
t_prompt "confirm: Enter = default y" $'\n'       'confirm "Q?" y && printf yes || printf no' "yes"
t_prompt "confirm: Enter = default n" $'\n'       'confirm "Q?" n && printf yes || printf no' "no"
t_prompt "choose reads a number"      $'2\n'      'choose v "Q?" a b c; printf "%s" "$v"'    "b"

echo
echo "== prompt text goes to stderr, not stdout =="

# Prompt text on stdout would corrupt any captured value.
out="$(printf 'x\n' | bash -c '. lib/ui.sh; prompt v "QUESTION:" >/dev/null 2>/dev/null; printf "%s" "$v"' 2>/dev/null)"
if [ "$out" = "x" ]; then
  ok_ "captured value is clean"
else
  fail_ "captured value polluted by prompt text: '$out'"
fi

stderr_out="$(printf 'x\n' | bash -c '. lib/ui.sh; prompt v "QUESTION:"' 2>&1 >/dev/null)"
case "$stderr_out" in
  *QUESTION:*) ok_ "prompt text appears on stderr" ;;
  *)           fail_ "prompt text not on stderr" ;;
esac

echo
echo "== sudo gets a self-explanatory prompt =="

if grep -q 'sudo -p' setup.sh; then
  ok_ "uses a custom sudo prompt"
else
  fail_ "bare sudo prompt gives no context"
fi
if grep -q 'Nothing is' setup.sh && grep -q 'echoed as you type' setup.sh; then
  ok_ "explains that typing is invisible"
else
  fail_ "does not explain the hidden-typing behaviour"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
