#!/usr/bin/env bash
# Drives ui.sh prompts with scripted input. ui.sh reads from /dev/tty, so we
# rebind /dev/tty by running under a pty-less redirect trick: we temporarily
# override the reads by sourcing with a fake tty via process substitution.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PASS=0; FAIL=0
check() { # label expected actual
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL $1: got '$3' want '$2'"; fi
}

# ui.sh now reads plain stdin, so piping input to it just works -- no
# rewriting needed (that indirection is what the stdin fix removed).

lastline() { "$@" | tail -n1; }

run_snippet() { # input, code -> prints result on fd1
  local input="$1" code="$2"
  printf '%s' "$input" | bash -c ". lib/ui.sh; $code" 2>/dev/null
}

echo "== prompt =="
check "plain value"    "hello"     "$(run_snippet $'hello\n'        'prompt v "Q:"; printf "%s" "$v"')"
check "trims spaces"   "hello"     "$(run_snippet $'   hello   \n'  'prompt v "Q:"; printf "%s" "$v"')"
check "uses default"   "3000"      "$(run_snippet $'\n'            'prompt v "Q:" "3000"; printf "%s" "$v"')"
check "override dflt"  "8080"      "$(run_snippet $'8080\n'        'prompt v "Q:" "3000"; printf "%s" "$v"')"
check "empty retries"  "second"    "$(run_snippet $'\nsecond\n'    'prompt v "Q:"; printf "%s" "$v"')"

echo "== confirm =="
check "y"              "yes"       "$(run_snippet $'y\n'    'if confirm "Q?"; then printf yes; else printf no; fi')"
check "yes"            "yes"       "$(run_snippet $'yes\n'  'if confirm "Q?"; then printf yes; else printf no; fi')"
check "n"              "no"        "$(run_snippet $'n\n'    'if confirm "Q?"; then printf yes; else printf no; fi')"
check "N uppercase"    "no"        "$(run_snippet $'N\n'    'if confirm "Q?"; then printf yes; else printf no; fi')"
check "default y"      "yes"       "$(run_snippet $'\n'     'if confirm "Q?" y; then printf yes; else printf no; fi')"
check "default n"      "no"        "$(run_snippet $'\n'     'if confirm "Q?" n; then printf yes; else printf no; fi')"
check "junk retries"   "no"        "$(run_snippet $'wat\nn\n' 'if confirm "Q?"; then printf yes; else printf no; fi')"

echo "== choose =="
check "pick 1"  "alpha"  "$(lastline run_snippet $'1\n'      'choose v "Q?" alpha beta gamma; printf "%s" "$v"')"
check "pick 3"  "gamma"  "$(lastline run_snippet $'3\n'      'choose v "Q?" alpha beta gamma; printf "%s" "$v"')"
check "oob rtry" "beta"  "$(lastline run_snippet $'9\n2\n'   'choose v "Q?" alpha beta gamma; printf "%s" "$v"')"
check "junk rtry" "alpha" "$(lastline run_snippet $'x\n1\n'  'choose v "Q?" alpha beta gamma; printf "%s" "$v"')"

echo "== read_multiline =="
check "env blob"     "A=1|B=2|" "$(run_snippet $'A=1\nB=2\nEOF\n'   'read_multiline v; printf "%s" "$v"' | tr '\n' '|')"
check "stops at EOF" "X=1|"     "$(run_snippet $'X=1\nEOF\nY=2\n'  'read_multiline v; printf "%s" "$v"' | tr '\n' '|')"
check "empty input"  ""         "$(run_snippet $'EOF\n'            'read_multiline v; printf "%s" "$v"' | tr '\n' '|')"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
