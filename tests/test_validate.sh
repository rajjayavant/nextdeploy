#!/usr/bin/env bash
# Unit tests for lib/validate.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. lib/validate.sh

PASS=0; FAIL=0
t_repo_ok() { # url expected_owner expected_name expected_host
  if parse_repo_url "$1" && [ "$REPO_OWNER" = "$2" ] && [ "$REPO_NAME" = "$3" ] && [ "$REPO_HOST" = "$4" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "  FAIL repo: '$1' -> host=$REPO_HOST owner=$REPO_OWNER name=$REPO_NAME (want $4/$2/$3)"
  fi
}
t_repo_bad() {
  if parse_repo_url "$1"; then FAIL=$((FAIL+1)); echo "  FAIL repo: '$1' should have been rejected (got $REPO_OWNER/$REPO_NAME)"; else PASS=$((PASS+1)); fi
}
t_dom_ok()  { if validate_domain "$1"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL domain: '$1' should be valid ($DOMAIN_ERR)"; fi; }
t_dom_bad() { if validate_domain "$1"; then FAIL=$((FAIL+1)); echo "  FAIL domain: '$1' should be invalid"; else PASS=$((PASS+1)); fi; }
t_port_ok()  { if validate_port "$1"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL port: '$1' should be valid ($PORT_ERR)"; fi; }
t_port_bad() { if validate_port "$1"; then FAIL=$((FAIL+1)); echo "  FAIL port: '$1' should be invalid"; else PASS=$((PASS+1)); fi; }
t_em_ok()  { if validate_email "$1"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL email: '$1' should be valid"; fi; }
t_em_bad() { if validate_email "$1"; then FAIL=$((FAIL+1)); echo "  FAIL email: '$1' should be invalid"; else PASS=$((PASS+1)); fi; }

echo "== repo URLs =="
t_repo_ok "https://github.com/rajjayavant/my-app"      rajjayavant my-app github.com
t_repo_ok "https://github.com/rajjayavant/my-app.git"  rajjayavant my-app github.com
t_repo_ok "https://github.com/rajjayavant/my-app/"     rajjayavant my-app github.com
t_repo_ok "http://github.com/rajjayavant/my-app"       rajjayavant my-app github.com
t_repo_ok "git@github.com:rajjayavant/my-app.git"      rajjayavant my-app github.com
t_repo_ok "git@github.com:rajjayavant/my-app"          rajjayavant my-app github.com
t_repo_ok "ssh://git@github.com/rajjayavant/my-app.git" rajjayavant my-app github.com
t_repo_ok "github.com/rajjayavant/my-app"              rajjayavant my-app github.com
t_repo_ok "rajjayavant/my-app"                         rajjayavant my-app github.com
t_repo_ok "https://gitlab.com/group/proj"              group proj gitlab.com
t_repo_ok "  https://github.com/raj/app  "             raj app github.com
t_repo_ok "https://github.com/raj/my.app"              raj my.app github.com
t_repo_bad "https://github.com/rajjayavant/my-app/tree/main"
t_repo_bad "https://github.com/rajjayavant"
t_repo_bad "not a url at all"
t_repo_bad "https://github.com/"
t_repo_bad ""

echo "== domains =="
t_dom_ok  "wikipedia.org"
t_dom_ok  "app.mycompany.io"
t_dom_ok  "www.example.com"
t_dom_ok  "a.b.c.example.co.uk"
t_dom_ok  "my-app.example.com"
t_dom_ok  "x1.io"
t_dom_bad "https://wikipedia.org"
t_dom_bad "http://wikipedia.org"
t_dom_bad "wikipedia.org/wiki/Home"
t_dom_bad "wikipedia.org:3000"
t_dom_bad "wikipedia.org."
t_dom_bad "localhost"
t_dom_bad "me@example.com"
t_dom_bad "example"
t_dom_bad "-bad.com"
t_dom_bad "bad-.com"
t_dom_bad "example.c0m"
t_dom_bad "ftp://example.com"

echo "== ports =="
t_port_ok 3000; t_port_ok 8080; t_port_ok 1024; t_port_ok 65535
t_port_bad 80; t_port_bad 443; t_port_bad 0; t_port_bad 65536
t_port_bad "abc"; t_port_bad "30 00"; t_port_bad "-1"; t_port_bad ""

echo "== emails =="
t_em_ok "you@example.com"; t_em_ok "a.b+c@sub.example.co.uk"
t_em_bad "notanemail"; t_em_bad "a@b"; t_em_bad "@example.com"; t_em_bad "a b@example.com"; t_em_bad ""

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
