#!/usr/bin/env bash
# Verify write_redeploy_script emits a valid, correct script for each combo.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. lib/ui.sh
. lib/validate.sh

NEXTDEPLOY_VERSION=0.1.0
APP_DIR=/home/ubuntu/myapp
APP_NAME=myapp
DEPLOY_KEY=/home/ubuntu/.ssh/nextdeploy_ed25519

# Pull just the function out of setup.sh so we test the real code.
eval "$(awk '/^write_redeploy_script\(\) \{/,/^\}/' setup.sh)"

FAIL=0
for pm in npm yarn pnpm bun; do
  for priv in no yes; do
    PKG_MANAGER=$pm
    REPO_IS_PRIVATE=$priv
    REDEPLOY_PATH="/tmp/redeploy_${pm}_${priv}.sh"
    write_redeploy_script > /dev/null

    if ! bash -n "$REDEPLOY_PATH" 2>/dev/null; then
      echo "  FAIL $pm/$priv: syntax error"; FAIL=$((FAIL+1)); continue
    fi
    [ -x "$REDEPLOY_PATH" ] || { echo "  FAIL $pm/$priv: not executable"; FAIL=$((FAIL+1)); }

    # Correct install and build commands for this package manager?
    case "$pm" in
      yarn) want_build='yarn build';    want_install='yarn install --frozen-lockfile' ;;
      pnpm) want_build='pnpm build';    want_install='pnpm install --frozen-lockfile' ;;
      bun)  want_build='bun run build'; want_install='bun install' ;;
      *)    want_build='npm run build'; want_install='npm ci' ;;
    esac
    grep -qF "$want_build"   "$REDEPLOY_PATH" || { echo "  FAIL $pm/$priv: missing '$want_build'"; FAIL=$((FAIL+1)); }
    grep -qF "$want_install" "$REDEPLOY_PATH" || { echo "  FAIL $pm/$priv: missing '$want_install'"; FAIL=$((FAIL+1)); }

    # The fallback must be a real command, not a mangled one like
    # "bun install install" produced by naive string surgery.
    if grep -qE '\|\| (npm|yarn|pnpm|bun) install install' "$REDEPLOY_PATH"; then
      echo "  FAIL $pm/$priv: malformed fallback install"; FAIL=$((FAIL+1))
    fi

    # Deploy key present only for private repos?
    if [ "$priv" = yes ]; then
      grep -q 'GIT_SSH_COMMAND' "$REDEPLOY_PATH"  || { echo "  FAIL $pm/$priv: private repo missing GIT_SSH_COMMAND"; FAIL=$((FAIL+1)); }
    else
      grep -q 'GIT_SSH_COMMAND' "$REDEPLOY_PATH"  && { echo "  FAIL $pm/$priv: public repo should not set GIT_SSH_COMMAND"; FAIL=$((FAIL+1)); }
    fi

    grep -q "pm2 restart \"myapp\" --update-env" "$REDEPLOY_PATH" || { echo "  FAIL $pm/$priv: bad pm2 restart"; FAIL=$((FAIL+1)); }
    echo "  ok  $pm / private=$priv"
  done
done

echo
echo "--- sample (yarn, private) ---"
cat /tmp/redeploy_yarn_yes.sh
echo "------------------------------"
[ "$FAIL" -eq 0 ] && echo "all redeploy variants valid" || echo "FAILURES: $FAIL"
[ "$FAIL" -eq 0 ]
