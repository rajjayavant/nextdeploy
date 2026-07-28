#!/usr/bin/env bash
# Tests for package-manager detection.
#
# Real-world case that motivated this: a package.json carrying
#     "packageManager": "yarn@pnpm@10.13.1"
# Two managers in one field. Corepack refuses to run, and yarn aborts with
# a message about the global version mismatch. The script previously only
# knew npm and yarn, so it had no way to recover.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

. lib/ui.sh
. lib/validate.sh

PASS=0; FAIL=0
ok_()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail_() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The detection half of reconcile_package_manager, lifted verbatim so the
# test exercises the real parsing rather than a paraphrase of it.
detect_pm() { # <app_dir> -> echoes detected manager
  local APP_DIR="$1" detected="" pm_field="" pm_name=""
  pm_field="$(grep -o '"packageManager"[[:space:]]*:[[:space:]]*"[^"]*"' "$APP_DIR/package.json" 2>/dev/null \
    | sed 's/.*:[[:space:]]*"//; s/"$//' || true)"
  if [ -n "$pm_field" ]; then
    pm_name="${pm_field%%@*}"
    local ats="${pm_field//[^@]/}" valid=0 last_name=""
    if [ "${#ats}" -eq 1 ]; then
      case "$pm_name" in pnpm|yarn|npm|bun) valid=1 ;; esac
    fi
    if [ "$valid" -eq 1 ]; then
      detected="$pm_name"
    else
      last_name="${pm_field%@*}"; last_name="${last_name##*@}"
      case "$last_name" in pnpm|yarn|npm|bun) detected="$last_name" ;; esac
    fi
  fi
  if [ -z "$detected" ]; then
    if   [ -f "$APP_DIR/pnpm-lock.yaml" ];    then detected="pnpm"
    elif [ -f "$APP_DIR/yarn.lock" ];         then detected="yarn"
    elif [ -f "$APP_DIR/package-lock.json" ]; then detected="npm"
    elif [ -f "$APP_DIR/bun.lockb" ];         then detected="bun"
    fi
  fi
  printf '%s' "$detected"
}

mkproj() { # <name> <package.json body> [lockfiles...]
  local d="$WORK/$1"; shift
  mkdir -p "$d"
  printf '%s\n' "$1" > "$d/package.json"; shift
  for lf in "$@"; do touch "$d/$lf"; done
  printf '%s' "$d"
}

t() { # label expected dir
  local got; got="$(detect_pm "$3")"
  if [ "$got" = "$2" ]; then ok_ "$1"; else fail_ "$1: got '$got' want '$2'"; fi
}

echo "== packageManager field wins over lockfiles =="
t "pnpm@10.13.1"  pnpm "$(mkproj a '{"packageManager":"pnpm@10.13.1"}')"
t "yarn@4.1.0"    yarn "$(mkproj b '{"packageManager":"yarn@4.1.0"}')"
t "npm@10.2.0"    npm  "$(mkproj c '{"packageManager":"npm@10.2.0"}')"
t "field beats conflicting lockfile" pnpm \
  "$(mkproj d '{"packageManager":"pnpm@10.13.1"}' yarn.lock)"

echo
echo "== the malformed real-world case =="
# The salvage takes the name adjacent to the version, since that's the one
# the version actually pins: in "yarn@pnpm@10.13.1", 10.13.1 is a pnpm
# version, so pnpm is the intended manager and the leading "yarn@" is the
# stray fragment.
t "yarn@pnpm@10.13.1 reads as pnpm" pnpm \
  "$(mkproj e '{"packageManager":"yarn@pnpm@10.13.1"}')"
t "npm@yarn@1.0.0 reads as yarn" yarn \
  "$(mkproj f '{"packageManager":"npm@yarn@1.0.0"}')"
t "a valid pin is never salvaged" yarn \
  "$(mkproj f2 '{"packageManager":"yarn@4.1.0"}')"
t "garbage falls through to lockfile" yarn \
  "$(mkproj g '{"packageManager":"???"}' yarn.lock)"

echo
echo "== lockfiles when no field is present =="
t "pnpm-lock.yaml"     pnpm "$(mkproj h '{"name":"x"}' pnpm-lock.yaml)"
t "yarn.lock"          yarn "$(mkproj i '{"name":"x"}' yarn.lock)"
t "package-lock.json"  npm  "$(mkproj j '{"name":"x"}' package-lock.json)"
t "bun.lockb"          bun  "$(mkproj k '{"name":"x"}' bun.lockb)"
t "no lockfile at all" ""   "$(mkproj l '{"name":"x"}')"

echo
echo "== lockfile precedence when several exist =="
t "pnpm wins over yarn+npm" pnpm \
  "$(mkproj m '{"name":"x"}' pnpm-lock.yaml yarn.lock package-lock.json)"
t "yarn wins over npm" yarn \
  "$(mkproj n '{"name":"x"}' yarn.lock package-lock.json)"

echo
echo "== formatting tolerance =="
t "spaces around colon" pnpm \
  "$(mkproj o '{ "packageManager" :  "pnpm@10.13.1" }')"
t "field among others"  yarn \
  "$(mkproj p '{"name":"app","packageManager":"yarn@4.1.0","version":"1.0.0"}')"

echo
echo "== every manager has install/build/start wiring =="
for pm in npm yarn pnpm bun; do
  missing=""
  grep -q "^    $pm)" setup.sh || missing="$missing install"
  grep -qE "( |\()$pm (build|run build)" setup.sh || missing="$missing build"
  grep -q "script_bin=\"$pm\"" setup.sh || missing="$missing pm2"
  if [ -z "$missing" ]; then ok_ "$pm wired for install/build/start"
  else fail_ "$pm missing:$missing"; fi
done

echo
echo "== corepack is used when the project pins a version =="
grep -q 'corepack enable'  setup.sh && ok_ "enables corepack" || fail_ "never enables corepack"
grep -q 'corepack prepare' setup.sh && ok_ "activates the pinned version" || fail_ "never activates pinned version"

echo
echo "== PM2 gets an absolute interpreter path =="
if grep -q 'resolved="\$(command -v "\$script_bin"' setup.sh; then
  ok_ "resolves script_bin to an absolute path"
else
  fail_ "PM2 may not find corepack/bun shims at boot"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
