#!/usr/bin/env bash
# Run every test. These cover the logic that can be verified off-server:
# validation, prompts, the retry engine, and generated config files.
#
# They do NOT cover apt, NodeSource, Certbot, or a live DNS check — those
# need a real Ubuntu host.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "── syntax ──────────────────────────────────────────────"
SYNTAX_FAIL=0
for f in ../setup.sh ../lib/*.sh ./*.sh; do
  if bash -n "$f" 2>/dev/null; then
    printf '  ok    %s\n' "$f"
  else
    printf '  FAIL  %s\n' "$f"; bash -n "$f"; SYNTAX_FAIL=1
  fi
done
[ "$SYNTAX_FAIL" -eq 0 ] || { echo; echo "SYNTAX ERRORS — stopping."; exit 1; }

FAILED=()
for t in test_validate.sh test_ui.sh test_retry.sh test_eco.sh test_redeploy.sh; do
  echo
  echo "── $t ──────────────────────────────────────────"
  bash "$t" || FAILED+=("$t")
done

echo
echo "════════════════════════════════════════════════════════"
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "  All test suites passed."
  exit 0
else
  echo "  FAILED: ${FAILED[*]}"
  exit 1
fi
