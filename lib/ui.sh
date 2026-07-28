# shellcheck shell=bash
# ui.sh — colours, logging, prompts, and the retry engine.

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

STEP_NUM=0
STEP_TOTAL=12

log()      { printf '%s\n' "$*"; }
info()     { printf '%s\n' "${C_BLUE}·${C_RESET} $*"; }
ok()       { printf '%s\n' "${C_GREEN}✓${C_RESET} $*"; }
warn()     { printf '%s\n' "${C_YELLOW}!${C_RESET} $*" >&2; }
err()      { printf '%s\n' "${C_RED}✗${C_RESET} $*" >&2; }
dim()      { printf '%s\n' "${C_DIM}$*${C_RESET}"; }
blank()    { printf '\n'; }

# A boxed hint. Use for anything the user could plausibly get wrong.
hint() {
  printf '%s\n' "${C_DIM}  ┌─${C_RESET}"
  while IFS= read -r line; do
    printf '%s\n' "${C_DIM}  │${C_RESET} $line"
  done <<< "$1"
  printf '%s\n' "${C_DIM}  └─${C_RESET}"
}

step() {
  STEP_NUM=$((STEP_NUM + 1))
  blank
  printf '%s\n' "${C_BOLD}${C_CYAN}[${STEP_NUM}/${STEP_TOTAL}] $*${C_RESET}"
  printf '%s\n' "${C_DIM}$(printf '─%.0s' $(seq 1 60))${C_RESET}"
}

fatal() {
  blank
  err "$*"
  blank
  dim "Nothing was left half-applied that a re-run won't fix."
  dim "Re-run this script to pick up from here: sudo -v && ./setup.sh"
  exit 1
}

# ── Prompts ────────────────────────────────────────────────────────────────
# These read from stdin. setup.sh points stdin at /dev/tty on startup, so
# this works whether the script is run from a file or piped from curl —
# and, critically, it leaves the terminal free for sudo to prompt on.
#
# Prompt text goes to stderr so it stays visible even if a caller captures
# stdout, and never contaminates a captured value.

prompt() {
  # prompt <varname> <question> [default]
  local __var="$1" __q="$2" __def="${3:-}" __ans=""
  while true; do
    if [ -n "$__def" ]; then
      printf '%s' "${C_BOLD}?${C_RESET} $__q ${C_DIM}[$__def]${C_RESET} " >&2
    else
      printf '%s' "${C_BOLD}?${C_RESET} $__q " >&2
    fi
    IFS= read -r __ans || fatal "Input closed unexpectedly."
    __ans="${__ans#"${__ans%%[![:space:]]*}"}"
    __ans="${__ans%"${__ans##*[![:space:]]}"}"
    [ -z "$__ans" ] && __ans="$__def"
    if [ -z "$__ans" ]; then
      err "This can't be empty. Please enter a value."
      continue
    fi
    printf -v "$__var" '%s' "$__ans"
    return 0
  done
}

confirm() {
  # confirm <question> [default y|n] -> returns 0 for yes
  local __q="$1" __def="${2:-y}" __ans="" __opts
  if [ "$__def" = "y" ]; then __opts="Y/n"; else __opts="y/N"; fi
  while true; do
    printf '%s' "${C_BOLD}?${C_RESET} $__q ${C_DIM}[$__opts]${C_RESET} " >&2
    IFS= read -r __ans || fatal "Input closed unexpectedly."
    __ans="$(printf '%s' "$__ans" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    [ -z "$__ans" ] && __ans="$__def"
    case "$__ans" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) err "Please answer y or n." ;;
    esac
  done
}

pause() {
  printf '%s' "${C_BOLD}↵${C_RESET} ${1:-Press Enter to continue} " >&2
  IFS= read -r _ || true
  blank
}

choose() {
  # choose <varname> <question> <opt1> <opt2> ...
  local __var="$1" __q="$2"; shift 2
  local __opts=("$@") __i __ans
  blank
  printf '%s\n' "${C_BOLD}?${C_RESET} $__q" >&2
  for __i in "${!__opts[@]}"; do
    printf '%s\n' "    ${C_BOLD}$((__i + 1)))${C_RESET} ${__opts[$__i]}" >&2
  done
  while true; do
    printf '%s' "  Enter a number ${C_DIM}[1-${#__opts[@]}]${C_RESET} " >&2
    IFS= read -r __ans || fatal "Input closed unexpectedly."
    __ans="$(printf '%s' "$__ans" | tr -d '[:space:]')"
    if [[ "$__ans" =~ ^[0-9]+$ ]] && [ "$__ans" -ge 1 ] && [ "$__ans" -le "${#__opts[@]}" ]; then
      printf -v "$__var" '%s' "${__opts[$((__ans - 1))]}"
      blank
      return 0
    fi
    err "Enter a number between 1 and ${#__opts[@]}."
  done
}

# Read a multi-line blob terminated by a lone EOF line. Used for .env paste.
read_multiline() {
  # read_multiline <varname>
  local __var="$1" __line="" __buf=""
  while IFS= read -r __line; do
    [ "$__line" = "EOF" ] && break
    __buf+="$__line"$'\n'
  done
  printf -v "$__var" '%s' "$__buf"
}

# ── Retry engine ───────────────────────────────────────────────────────────
# retry_step <description> <function-name>
#
# Calls the function. On non-zero exit the user is offered retry / skip /
# abort. This is what makes every stage of the installer resumable: each
# step function is written to be safe to run again from scratch.
retry_step() {
  local desc="$1" fn="$2" attempt=1
  while true; do
    if "$fn"; then
      return 0
    fi
    local rc=$?
    blank
    err "Step failed: $desc"
    [ "$attempt" -gt 1 ] && dim "  (attempt $attempt)"
    blank
    local action
    choose action "What would you like to do?" \
      "Retry this step" \
      "Open a shell to investigate, then retry" \
      "Skip this step (only if you know it's already done)" \
      "Abort setup"
    case "$action" in
      "Retry this step")
        attempt=$((attempt + 1)); continue ;;
      "Open a shell to investigate, then retry")
        blank
        dim "Dropping to a shell. Type 'exit' when you're ready to retry."
        blank
        "${SHELL:-/bin/bash}" || true
        attempt=$((attempt + 1)); continue ;;
      "Skip this step (only if you know it's already done)")
        warn "Skipping: $desc"
        warn "Later steps may fail as a result."
        return 0 ;;
      "Abort setup")
        fatal "Aborted at: $desc (exit code $rc)" ;;
    esac
  done
}

# Run a command, showing output only if it fails. Keeps the log readable
# while preserving the diagnostics that matter when something breaks.
run_quiet() {
  local logf; logf="$(mktemp)"
  if "$@" > "$logf" 2>&1; then
    rm -f "$logf"; return 0
  fi
  local rc=$?
  blank
  err "Command failed: $*"
  dim "─── last 30 lines of output ───"
  tail -n 30 "$logf" >&2
  dim "───────────────────────────────"
  rm -f "$logf"
  return $rc
}
