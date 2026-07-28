#!/usr/bin/env bash
#
# nextdeploy — take a fresh Ubuntu EC2 box to a live, HTTPS Next.js app.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/rajjayavant/nextdeploy/main/setup.sh)
#
# Every step is retryable and safe to run twice. If something breaks, fix it
# and pick "Retry" — you should never have to start over.

set -uo pipefail

# ── Reclaim the terminal ───────────────────────────────────────────────────
# When this script is run as `bash <(curl ...)` or `curl ... | bash`, stdin
# is the script text, not the keyboard. That breaks two things at once:
# `read` gets script bytes instead of typed input, and `sudo` finds no
# terminal to ask for a password on.
#
# Reattaching stdin to the controlling terminal once, here, fixes both --
# and lets every `read` below just use stdin normally.
if [ ! -t 0 ] && [ -r /dev/tty ]; then
  exec < /dev/tty
fi

# True only if we genuinely have a terminal to talk to. When we don't
# (cron, CI, a pipe with no tty) we must not block on a prompt.
if [ -t 0 ]; then HAVE_TTY=1; else HAVE_TTY=0; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEXTDEPLOY_VERSION="0.1.0"
NEXTDEPLOY_RAW_BASE="${NEXTDEPLOY_RAW_BASE:-https://raw.githubusercontent.com/rajjayavant/nextdeploy/main}"

# Source libs locally, or fetch them when we've been piped in from curl.
_load_lib() {
  local name="$1"
  if [ -r "$SCRIPT_DIR/lib/$name" ]; then
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/lib/$name"
  else
    # No local lib/ — we were piped in from curl, so fetch it. Say so out
    # loud: if someone edited lib/ locally and ran the script through
    # process substitution, SCRIPT_DIR is /dev/fd and their edits are
    # silently ignored in favour of whatever is on the remote branch.
    echo "· Fetching lib/$name from $NEXTDEPLOY_RAW_BASE" >&2
    local tmp; tmp="$(mktemp)"
    if curl -fsSL "$NEXTDEPLOY_RAW_BASE/lib/$name" -o "$tmp" 2>/dev/null; then
      # shellcheck source=/dev/null
      . "$tmp"; rm -f "$tmp"
    else
      rm -f "$tmp"
      echo "Could not load lib/$name." >&2
      echo "  Looked in: $SCRIPT_DIR/lib/$name" >&2
      echo "  And at:    $NEXTDEPLOY_RAW_BASE/lib/$name" >&2
      echo "" >&2
      echo "If you cloned the repo, run ./setup.sh from inside it." >&2
      exit 1
    fi
  fi
}
_load_lib ui.sh
_load_lib validate.sh

# ── State ──────────────────────────────────────────────────────────────────
PKG_MANAGER=""       # npm | yarn
REPO_URL=""          # the clone URL we actually use
REPO_HOST=""; REPO_OWNER=""; REPO_NAME=""
REPO_IS_PRIVATE=""   # yes | no
APP_DIR=""
APP_NAME=""
APP_PORT="3000"
DOMAIN=""
WANT_WWW="no"
LE_EMAIL=""
PUBLIC_IP=""
DEPLOY_KEY="$HOME/.ssh/nextdeploy_ed25519"
SETUP_TLS="no"
REDEPLOY_PATH="$HOME/redeploy.sh"

STATE_DIR="$HOME/.nextdeploy"
STATE_FILE="$STATE_DIR/state.env"

save_state() {
  mkdir -p "$STATE_DIR"
  cat > "$STATE_FILE" <<EOF
# Written by nextdeploy v$NEXTDEPLOY_VERSION. Safe to delete.
PKG_MANAGER="$PKG_MANAGER"
REPO_URL="$REPO_URL"
REPO_OWNER="$REPO_OWNER"
REPO_NAME="$REPO_NAME"
REPO_IS_PRIVATE="$REPO_IS_PRIVATE"
APP_DIR="$APP_DIR"
APP_NAME="$APP_NAME"
APP_PORT="$APP_PORT"
DOMAIN="$DOMAIN"
WANT_WWW="$WANT_WWW"
EOF
  chmod 600 "$STATE_FILE" 2>/dev/null || true
}

load_state() {
  [ -r "$STATE_FILE" ] || return 1
  # shellcheck source=/dev/null
  . "$STATE_FILE"
  return 0
}

# ── Banner ─────────────────────────────────────────────────────────────────
banner() {
  blank
  printf '%s\n' "${C_BOLD}${C_CYAN}  nextdeploy${C_RESET} ${C_DIM}v$NEXTDEPLOY_VERSION${C_RESET}"
  dim "  Fresh Ubuntu box → live Next.js app over HTTPS."
  blank
  dim "  Every step can be retried. If one fails you'll get a menu, not a"
  dim "  stack trace. Nothing here is destructive to an existing deploy."
  blank
}

# ═══════════════════════════════════════════════════════════════════════════
# Step 0 — pre-flight
# ═══════════════════════════════════════════════════════════════════════════
preflight() {
  step "Checking this machine"

  if [ "$(id -u)" -eq 0 ]; then
    err "Don't run this as root."
    blank
    hint "Running as root makes PM2 and your app files root-owned, which
causes permission problems later and is a security risk.

Run it WITHOUT sudo — as your normal user:

    ./setup.sh

The script calls sudo itself for the few steps that need it. On a
stock Ubuntu EC2 image the 'ubuntu' user can do that without ever
being asked for a password, so there's nothing you need to set up.

If you aren't logged in as 'ubuntu', log in as that user first:

    ssh ubuntu@your-server-ip"
    return 1
  fi

  if ! is_ubuntu; then
    warn "This doesn't look like Ubuntu."
    local pretty="unknown"
    [ -r /etc/os-release ] && pretty="$( . /etc/os-release; echo "${PRETTY_NAME:-unknown}" )"
    dim "  Detected: $pretty"
    blank
    dim "nextdeploy is written and tested for Ubuntu (20.04 and newer)."
    dim "It may still work on Debian. Anything else will likely fail."
    blank
    confirm "Continue anyway?" "n" || return 1
  else
    ok "Ubuntu $(ubuntu_version)"
  fi

  if ! has_cmd sudo; then
    err "'sudo' isn't installed, and this script needs it to install packages."
    return 1
  fi

  # Check for passwordless sudo FIRST. On a stock EC2 Ubuntu AMI the
  # 'ubuntu' user has NOPASSWD sudo and has no password set at all, so
  # prompting would be both unnecessary and unanswerable. `sudo -n` never
  # prompts — it just fails if a password would be required.
  info "Checking sudo access…"
  if sudo -n true 2>/dev/null; then
    ok "sudo access confirmed (no password needed)"
  else
    blank
    warn "sudo wants a password for '$USER'."
    hint "On a stock EC2 Ubuntu image, logged in as 'ubuntu', you would
normally NOT see this — that account sudoes without a password.

Seeing it usually means one of:

  • You're logged in as a user you created yourself. Use that
    user's password.

  • You're on a customised or non-AWS image without the
    cloud-init NOPASSWD rule.

If you don't know a password, press Ctrl-C and log back in as
'ubuntu', which doesn't need one:

    ssh ubuntu@YOUR_SERVER_IP

Otherwise type your password at the prompt below. Nothing is
echoed as you type — no dots, no stars. That's normal; just
type it and press Enter."
    blank

    if [ "$HAVE_TTY" -eq 0 ]; then
      err "No terminal available to ask for a password."
      hint "This script is running without a terminal attached, so sudo
has no way to prompt you.

If you ran it through a pipe, use process substitution instead
so the terminal stays connected:

    bash <(curl -fsSL $NEXTDEPLOY_RAW_BASE/setup.sh)"
      return 1
    fi

    # -v refreshes the credential; the custom prompt makes it obvious
    # which program is asking and for whose password.
    if ! sudo -p "[sudo] password for %u (typing is hidden): " -v; then
      blank
      err "Could not get sudo access."
      hint "Nothing has been changed on this server.

If you don't have a sudo password, log in as the 'ubuntu' user —
on a stock EC2 Ubuntu image it can sudo without one.

If you created this user yourself and it isn't in the sudo group,
add it from a root shell:

    usermod -aG sudo YOUR_USERNAME

then log out, log back in, and re-run this script."
      return 1
    fi
    ok "sudo access confirmed"
  fi

  # Keep sudo warm for the whole run so a long apt or build doesn't stall
  # on a re-prompt halfway through. Harmless when sudo is passwordless.
  ( while true; do sudo -n true 2>/dev/null; sleep 50; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

  local disk; disk="$(free_disk_mb)"
  if [ "$disk" -lt 3000 ] 2>/dev/null; then
    warn "Only ${disk}MB free on /. A Next.js build usually needs 2–3GB free."
    confirm "Continue anyway?" "n" || return 1
  else
    ok "Disk: ${disk}MB free"
  fi

  local ram; ram="$(total_ram_mb)"
  ok "Memory: ${ram}MB"
  if [ "$ram" -lt 2000 ] 2>/dev/null && ! has_swap; then
    blank
    warn "This machine has under 2GB of RAM and no swap file."
    hint "'next build' is memory-hungry and is very likely to be killed by
the kernel partway through on a 1GB instance (t2.micro, t3.micro).

Adding a 2GB swap file avoids this. It costs 2GB of disk and is
a completely standard thing to do on small instances."
    blank
    if confirm "Add a 2GB swap file?" "y"; then
      if run_quiet sudo fallocate -l 2G /swapfile \
        && run_quiet sudo chmod 600 /swapfile \
        && run_quiet sudo mkswap /swapfile \
        && run_quiet sudo swapon /swapfile; then
        grep -q '^/swapfile' /etc/fstab 2>/dev/null \
          || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
        ok "2GB swap enabled (persists across reboots)"
      else
        warn "Could not create swap. Continuing — the build may fail on low memory."
      fi
    fi
  fi

  info "Detecting this server's public IP address…"
  PUBLIC_IP="$(detect_public_ip)"
  if [ -n "$PUBLIC_IP" ]; then
    ok "Public IP: ${C_BOLD}$PUBLIC_IP${C_RESET}"
  else
    warn "Couldn't determine the public IP automatically."
    dim "  Not fatal — you'll be asked for it later if we set up a domain."
  fi

  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Step 1 — apt update
# ═══════════════════════════════════════════════════════════════════════════
update_system() {
  step "Updating package lists"

  # Unattended-upgrades holds the dpkg lock on a fresh boot and is the single
  # most common cause of a confusing "could not get lock" failure here.
  if sudo fuser /var/lib/dpkg/lock-frontend > /dev/null 2>&1; then
    info "Another process is installing packages (Ubuntu's automatic updates)."
    dim "  Waiting up to 3 minutes for it to finish…"
    local waited=0
    while sudo fuser /var/lib/dpkg/lock-frontend > /dev/null 2>&1 && [ "$waited" -lt 180 ]; do
      sleep 5; waited=$((waited + 5))
      [ $((waited % 30)) -eq 0 ] && dim "  …still waiting (${waited}s)"
    done
    if sudo fuser /var/lib/dpkg/lock-frontend > /dev/null 2>&1; then
      err "The package lock is still held after 3 minutes."
      hint "Ubuntu's unattended-upgrades service is still running. Wait a
minute and retry — it usually finishes within a few minutes of
first boot. To watch it:

    ps aux | grep -i apt"
      return 1
    fi
    ok "Lock released"
  fi

  info "Running apt-get update…"
  run_quiet sudo apt-get update -y || {
    hint "apt couldn't refresh its package lists. Usual causes:
  • No outbound internet — check the instance has a public IP
    and its security group allows outbound traffic.
  • DNS not resolving — try: ping -c1 archive.ubuntu.com"
    return 1
  }
  ok "Package lists updated"

  info "Installing base tools (curl, git, ca-certificates)…"
  run_quiet sudo apt-get install -y curl git ca-certificates gnupg ufw dnsutils || return 1
  ok "Base tools ready"

  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Step 2 — Node.js
# ═══════════════════════════════════════════════════════════════════════════
NODE_MAJOR_REQUIRED=18
install_node() {
  step "Installing Node.js"

  if has_cmd node; then
    local cur major
    cur="$(node --version 2>/dev/null | sed 's/^v//')"
    major="${cur%%.*}"
    if [ "${major:-0}" -ge "$NODE_MAJOR_REQUIRED" ] 2>/dev/null; then
      ok "Node.js v$cur already installed"
      has_cmd npm && ok "npm v$(npm --version 2>/dev/null)"
      return 0
    fi
    warn "Node.js v$cur is installed but Next.js needs v$NODE_MAJOR_REQUIRED or newer."
    info "Upgrading to Node.js 20 LTS…"
  else
    info "Node.js isn't installed. Installing Node.js 20 LTS…"
    dim "  (Ubuntu's own 'nodejs' package is too old for current Next.js,"
    dim "   so we use the official NodeSource repository instead.)"
  fi

  local keyring=/usr/share/keyrings/nodesource.gpg
  sudo rm -f "$keyring"
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | sudo gpg --dearmor -o "$keyring" 2>/dev/null || {
      err "Couldn't fetch the NodeSource signing key."
      hint "This is almost always a network problem. Check the server can
reach the internet:

    curl -I https://deb.nodesource.com"
      return 1
    }
  echo "deb [signed-by=$keyring] https://deb.nodesource.com/node_20.x nodistro main" \
    | sudo tee /etc/apt/sources.list.d/nodesource.list > /dev/null

  run_quiet sudo apt-get update -y || return 1
  run_quiet sudo apt-get install -y nodejs || {
    hint "Installing nodejs failed. If the output above mentions a conflict
with an existing 'nodejs' or 'libnode-dev' package, remove the old
one and retry:

    sudo apt-get remove -y nodejs libnode-dev npm
    sudo apt-get autoremove -y"
    return 1
  }

  has_cmd node || { err "Node still isn't on PATH after installing."; return 1; }
  ok "Node.js $(node --version) installed"
  ok "npm v$(npm --version 2>/dev/null)"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Step 3 — package manager choice
# ═══════════════════════════════════════════════════════════════════════════
choose_package_manager() {
  step "Choosing a package manager"

  dim "This installs your app's dependencies."
  blank
  dim "If you're not sure, just pick npm. After we clone your repo we"
  dim "read its lockfile and package.json, and if the project actually"
  dim "expects something else we'll say so and offer to switch."
  blank

  local pick
  choose pick "Which package manager does your project use?" \
    "npm  (comes with Node — safe default)" \
    "yarn" \
    "pnpm" \
    "bun"

  case "$pick" in
    npm*)  PKG_MANAGER="npm"  ;;
    yarn*) PKG_MANAGER="yarn" ;;
    pnpm*) PKG_MANAGER="pnpm" ;;
    bun*)  PKG_MANAGER="bun"  ;;
  esac

  # Only npm is guaranteed present right now; the rest are installed after
  # the clone, where package.json can tell us which version to pin.
  if [ "$PKG_MANAGER" = "npm" ]; then
    ok "Using npm v$(npm --version 2>/dev/null)"
  else
    ok "Will use $PKG_MANAGER (installed after we've seen your repo)"
  fi

  save_state
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Step 4 — repository URL + visibility
# ═══════════════════════════════════════════════════════════════════════════
ask_repo() {
  step "Your repository"

  hint "Paste the URL of the GitHub repo you want to deploy.

Any of these work:
    https://github.com/rajjayavant/my-app
    git@github.com:rajjayavant/my-app.git
    rajjayavant/my-app

Don't paste a link to a branch or file — just the repo itself."
  blank

  while true; do
    local raw
    prompt raw "Repository URL:"
    if parse_repo_url "$raw"; then
      break
    fi
    err "That doesn't look like a repository URL."
    dim "  Expected something like: https://github.com/owner/repo"
    dim "  You entered:             $raw"
    blank
  done

  ok "Repository: ${C_BOLD}$REPO_OWNER/$REPO_NAME${C_RESET} on $REPO_HOST"

  info "Checking whether this repository is public…"
  local https_url="https://$REPO_HOST/$REPO_OWNER/$REPO_NAME.git"
  local code
  code="$(curl -o /dev/null -sS -w '%{http_code}' --max-time 15 \
    "https://$REPO_HOST/$REPO_OWNER/$REPO_NAME/info/refs?service=git-upload-pack" 2>/dev/null || echo "000")"

  case "$code" in
    200)
      REPO_IS_PRIVATE="no"
      REPO_URL="$https_url"
      ok "Repository is ${C_GREEN}public${C_RESET} — no credentials needed"
      ;;
    401|403|404)
      REPO_IS_PRIVATE="yes"
      REPO_URL="git@$REPO_HOST:$REPO_OWNER/$REPO_NAME.git"
      ok "Repository is ${C_YELLOW}private${C_RESET} (or doesn't exist)"
      dim "  We'll set up an SSH deploy key so this server can read it."
      ;;
    000)
      err "Couldn't reach $REPO_HOST to check the repository."
      hint "This is a network problem, not a problem with your URL.
Check the server has outbound internet:

    curl -I https://github.com"
      return 1
      ;;
    *)
      warn "Unexpected response from $REPO_HOST (HTTP $code)."
      if confirm "Treat this repository as private and set up an SSH key?" "y"; then
        REPO_IS_PRIVATE="yes"
        REPO_URL="git@$REPO_HOST:$REPO_OWNER/$REPO_NAME.git"
      else
        REPO_IS_PRIVATE="no"
        REPO_URL="$https_url"
      fi
      ;;
  esac

  APP_NAME="$REPO_NAME"
  APP_DIR="$HOME/$REPO_NAME"
  save_state
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Step 5 — deploy key for private repos
# ═══════════════════════════════════════════════════════════════════════════
setup_deploy_key() {
  if [ "$REPO_IS_PRIVATE" != "yes" ]; then
    # Public repo — no key needed. Shrink the total so the step counter
    # doesn't advertise a step the user will never see.
    STEP_TOTAL=$((STEP_TOTAL - 1))
    return 0
  fi

  step "Giving this server access to your private repo"

  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

  if [ -f "$DEPLOY_KEY" ] && [ -f "$DEPLOY_KEY.pub" ]; then
    info "An SSH key from a previous run already exists."
    if confirm "Reuse it? (choose No to generate a fresh one)" "y"; then
      : # keep it
    else
      rm -f "$DEPLOY_KEY" "$DEPLOY_KEY.pub"
    fi
  fi

  if [ ! -f "$DEPLOY_KEY" ]; then
    info "Generating a new SSH key for this server…"
    run_quiet ssh-keygen -t ed25519 -N "" -C "nextdeploy@$(hostname)" -f "$DEPLOY_KEY" || {
      err "Could not generate an SSH key."
      return 1
    }
    chmod 600 "$DEPLOY_KEY"; chmod 644 "$DEPLOY_KEY.pub"
    ok "SSH key generated"
  fi

  # Pin the host key so the first clone doesn't hang on a yes/no prompt.
  local kh="$HOME/.ssh/known_hosts"
  touch "$kh"; chmod 600 "$kh"
  if ! ssh-keygen -F "$REPO_HOST" -f "$kh" > /dev/null 2>&1; then
    ssh-keyscan -H "$REPO_HOST" >> "$kh" 2>/dev/null || true
  fi

  local pubkey; pubkey="$(cat "$DEPLOY_KEY.pub")"

  blank
  printf '%s\n' "${C_BOLD}Copy the key below — all of it, one line:${C_RESET}"
  blank
  printf '%s\n' "${C_DIM}────────────────── copy from here ──────────────────${C_RESET}"
  printf '%s\n' "${C_GREEN}$pubkey${C_RESET}"
  printf '%s\n' "${C_DIM}─────────────────── to here ────────────────────────${C_RESET}"
  blank

  hint "Now add it to your repository as a deploy key:

  1. Open this page in your browser:

       https://$REPO_HOST/$REPO_OWNER/$REPO_NAME/settings/keys/new

  2. Title:  anything you like, e.g. 'ec2-production'
  3. Key:    paste the green text above
  4. Leave 'Allow write access' UNCHECKED — this server only
     needs to read your code.
  5. Click 'Add key'.

If the link 404s, you're either not logged in or you don't have
admin rights on that repository."
  blank

  while true; do
    pause "Press Enter once you've added the key…"

    info "Testing the connection to $REPO_HOST…"
    local out rc
    out="$(GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10" \
      git ls-remote "$REPO_URL" HEAD 2>&1)"
    rc=$?

    if [ $rc -eq 0 ]; then
      ok "Connection works — this server can now read your repository"
      break
    fi

    blank
    err "Couldn't read the repository yet."
    blank
    if printf '%s' "$out" | grep -qi 'permission denied\|publickey'; then
      dim "  GitHub rejected the key. Most likely the paste was incomplete —"
      dim "  it must start with 'ssh-ed25519' and be on a single line."
    elif printf '%s' "$out" | grep -qi 'repository not found\|does not exist'; then
      dim "  The key was accepted, but it isn't attached to $REPO_OWNER/$REPO_NAME."
      dim "  Check you added it to the right repository."
    elif printf '%s' "$out" | grep -qi 'could not resolve\|timed out\|network'; then
      dim "  Network problem reaching $REPO_HOST — not a key problem."
    else
      dim "  Git said:"
      printf '%s\n' "$out" | head -n 5 | sed 's/^/    /' >&2
    fi
    blank
    confirm "Try again?" "y" || return 1
  done

  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Step 6 — clone
# ═══════════════════════════════════════════════════════════════════════════
GIT_SSH_CMD_FOR_REPO() {
  if [ "$REPO_IS_PRIVATE" = "yes" ]; then
    printf '%s' "ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  else
    printf '%s' "ssh"
  fi
}

clone_repo() {
  step "Cloning your repository"

  if [ -d "$APP_DIR/.git" ]; then
    info "$APP_DIR already contains a git repository."
    local existing
    existing="$(git -C "$APP_DIR" remote get-url origin 2>/dev/null || echo "unknown")"
    dim "  Existing remote: $existing"
    blank
    local pick
    choose pick "What should we do?" \
      "Pull the latest changes into it" \
      "Delete it and clone fresh" \
      "Leave it exactly as-is"
    case "$pick" in
      "Pull the latest changes into it")
        info "Pulling…"
        GIT_SSH_COMMAND="$(GIT_SSH_CMD_FOR_REPO)" run_quiet git -C "$APP_DIR" pull --ff-only || {
          hint "The pull failed. If you've made local edits on the server they
may conflict. Easiest fix is to choose 'Delete it and clone fresh'
on the retry — but only if you have no uncommitted work there."
          return 1
        }
        ok "Updated to latest"
        ;;
      "Delete it and clone fresh")
        blank
        warn "This will permanently delete $APP_DIR and everything in it."
        confirm "Are you sure?" "n" || return 1
        rm -rf "$APP_DIR" || { err "Couldn't remove $APP_DIR"; return 1; }
        info "Cloning fresh…"
        GIT_SSH_COMMAND="$(GIT_SSH_CMD_FOR_REPO)" run_quiet git clone "$REPO_URL" "$APP_DIR" || return 1
        ok "Cloned into $APP_DIR"
        ;;
      *)
        ok "Leaving $APP_DIR untouched"
        ;;
    esac
  else
    if [ -e "$APP_DIR" ]; then
      err "$APP_DIR exists but isn't a git repository."
      hint "Something else is at that path. Move or remove it, then retry:

    ls -la $APP_DIR"
      return 1
    fi
    info "Cloning into $APP_DIR …"
    GIT_SSH_COMMAND="$(GIT_SSH_CMD_FOR_REPO)" run_quiet git clone "$REPO_URL" "$APP_DIR" || {
      hint "The clone failed. Check the output above — if it mentions
authentication, the deploy key step may need redoing."
      return 1
    }
    ok "Cloned into $APP_DIR"
  fi

  # Sanity-check that this is actually a Next.js project, since everything
  # downstream (build command, port, PM2 start) assumes it is.
  if [ ! -f "$APP_DIR/package.json" ]; then
    err "There's no package.json in $APP_DIR."
    hint "This doesn't look like a Node.js project. Check you cloned the
right repository — and that your app isn't in a subdirectory."
    return 1
  fi

  if grep -q '"next"' "$APP_DIR/package.json" 2>/dev/null; then
    ok "Next.js project detected"
  else
    warn "Couldn't find 'next' in package.json — this may not be a Next.js app."
    confirm "Continue anyway?" "n" || return 1
  fi

  reconcile_package_manager

  save_state
  return 0
}

# Now that the repo is on disk it can tell us what it actually wants, which
# beats the guess made before cloning. Lockfiles and `packageManager` are
# authoritative; the earlier prompt was only ever a hint.
reconcile_package_manager() {
  local detected="" reason="" pm_field=""

  # `packageManager` is the strongest signal — it's what Corepack enforces.
  pm_field="$(grep -o '"packageManager"[[:space:]]*:[[:space:]]*"[^"]*"' "$APP_DIR/package.json" 2>/dev/null \
    | sed 's/.*:[[:space:]]*"//; s/"$//' || true)"

  if [ -n "$pm_field" ]; then
    # The valid form is exactly one name, one @, then a version. Decide
    # validity before matching a prefix: "yarn@pnpm@10.13.1" starts with
    # "yarn@" and would otherwise be read as a legitimate yarn pin, which
    # is precisely how a typo becomes a baffling mid-install failure.
    local pm_name="${pm_field%%@*}"
    local ats="${pm_field//[^@]/}"
    local valid=0
    if [ "${#ats}" -eq 1 ]; then
      case "$pm_name" in
        pnpm|yarn|npm|bun) valid=1 ;;
      esac
    fi

    if [ "$valid" -eq 1 ]; then
      detected="$pm_name"
      reason="package.json declares \"packageManager\": \"$pm_field\""
    else
      blank
      warn "package.json has a malformed \"packageManager\" field:"
      blank
      printf '%s\n' "      ${C_RED}\"packageManager\": \"$pm_field\"${C_RESET}"
      blank
      hint "That value isn't valid. The format is one name, one @, and a
version:

    \"packageManager\": \"pnpm@10.13.1\"
    \"packageManager\": \"yarn@4.1.0\"

A value like \"yarn@pnpm@10.13.1\" names two package managers at
once. Corepack refuses to run when it sees that, and yarn stops
with a message about a version mismatch.

Worth fixing in your repository — it breaks any deploy that uses
Corepack, not just this script. For now we'll work out the right
manager from the rest of the project."
      blank

      # Salvage the name nearest the version — in "yarn@pnpm@10.13.1"
      # that's pnpm, since the trailing 10.13.1 is the version it pins.
      local last_name="${pm_field%@*}"   # drop the version
      last_name="${last_name##*@}"       # keep the final name
      case "$last_name" in
        pnpm|yarn|npm|bun)
          detected="$last_name"
          reason="read '$last_name' out of the malformed field"
          ;;
      esac
    fi
  fi

  # Lockfiles are the next-best evidence.
  if [ -z "$detected" ]; then
    if   [ -f "$APP_DIR/pnpm-lock.yaml" ];    then detected="pnpm"; reason="found pnpm-lock.yaml"
    elif [ -f "$APP_DIR/yarn.lock" ];         then detected="yarn"; reason="found yarn.lock"
    elif [ -f "$APP_DIR/package-lock.json" ]; then detected="npm";  reason="found package-lock.json"
    elif [ -f "$APP_DIR/bun.lockb" ];         then detected="bun";  reason="found bun.lockb"
    fi
  fi

  [ -z "$detected" ] && { dim "  (no lockfile — sticking with $PKG_MANAGER)"; return 0; }

  if [ "$detected" = "$PKG_MANAGER" ]; then
    ok "Confirmed $PKG_MANAGER — $reason"
    return 0
  fi

  blank
  warn "This project uses ${C_BOLD}$detected${C_RESET}, but you chose ${C_BOLD}$PKG_MANAGER${C_RESET}."
  dim "  ($reason)"
  blank
  dim "Using the package manager the project expects installs exactly the"
  dim "versions it was tested with. A different one ignores the lockfile"
  dim "and resolves fresh, which occasionally pulls in a breaking update."
  blank

  local pick
  choose pick "Which should we use?" \
    "$detected — what this project expects (recommended)" \
    "$PKG_MANAGER — what you picked earlier"

  case "$pick" in
    "$detected"*) PKG_MANAGER="$detected" ;;
    *)            ok "Staying with $PKG_MANAGER"; return 0 ;;
  esac

  ensure_package_manager "$PKG_MANAGER" || return 1
  return 0
}

# Make sure the chosen package manager is actually runnable, installing or
# enabling it as needed. Returns non-zero only if it can't be provided.
ensure_package_manager() {
  local pm="$1"

  case "$pm" in
    npm)
      has_cmd npm || { err "npm is missing — the Node.js step should have provided it."; return 1; }
      ok "Using npm v$(npm --version 2>/dev/null)"
      ;;

    yarn|pnpm)
      # Corepack ships with Node 16.9+ and is the supported way to get the
      # exact version a project pins. Prefer it over a global install.
      if [ -n "$(grep -o '"packageManager"[[:space:]]*:[[:space:]]*"[^"]*"' "$APP_DIR/package.json" 2>/dev/null)" ] \
         && has_cmd corepack; then
        info "Enabling Corepack to match the version your project pins…"
        if run_quiet sudo corepack enable; then
          ok "Corepack enabled"
          # `corepack prepare` reads the pinned version from package.json.
          ( cd "$APP_DIR" && run_quiet corepack prepare --activate ) \
            && ok "Activated the version pinned in package.json" \
            || dim "  (couldn't pre-activate; $pm will fetch it on first use)"
          return 0
        fi
        dim "  (Corepack wouldn't enable — falling back to a global install)"
      fi

      if has_cmd "$pm"; then
        ok "$pm v$("$pm" --version 2>/dev/null) already installed"
        return 0
      fi

      info "Installing $pm…"
      run_quiet sudo npm install -g "$pm" || {
        hint "Installing $pm globally failed.

npm can install almost any project, including one with a
$pm lockfile — it just ignores the locked versions. Retry
this step and choose npm if you'd rather move on."
        return 1
      }
      ok "$pm v$("$pm" --version 2>/dev/null) installed"
      ;;

    bun)
      if has_cmd bun; then
        ok "bun v$(bun --version 2>/dev/null) already installed"
        return 0
      fi
      info "Installing bun…"
      if curl -fsSL https://bun.sh/install | bash > /dev/null 2>&1; then
        export BUN_INSTALL="$HOME/.bun"
        export PATH="$BUN_INSTALL/bin:$PATH"
        has_cmd bun && ok "bun v$(bun --version 2>/dev/null) installed" || {
          err "bun installed but isn't on PATH."; return 1; }
      else
        err "Couldn't install bun."
        return 1
      fi
      ;;
  esac
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Step 7 — .env  (must happen BEFORE the build)
# ═══════════════════════════════════════════════════════════════════════════
setup_env_file() {
  step "Environment variables"

  hint "If your app needs environment variables — database URLs, API keys,
NEXTAUTH_SECRET and so on — add them now.

This has to happen before we build, because Next.js bakes any
NEXT_PUBLIC_* variables into the build output. Adding them later
means rebuilding."
  blank

  if [ -f "$APP_DIR/.env" ]; then
    info "There's already a .env file at $APP_DIR/.env"
    dim "  It has $(wc -l < "$APP_DIR/.env" 2>/dev/null | tr -d ' ') line(s)."
    blank
    local pick
    choose pick "What would you like to do?" \
      "Keep it as it is" \
      "Replace it with something I paste now" \
      "Add more variables to the end of it"
    case "$pick" in
      "Keep it as it is") ok "Keeping the existing .env"; return 0 ;;
      "Replace it with something I paste now") : ;;
      "Add more variables to the end of it") : ;;
    esac
    [ "$pick" = "Replace it with something I paste now" ] && rm -f "$APP_DIR/.env"
  else
    if ! confirm "Does your app need a .env file?" "y"; then
      ok "Skipping — no environment variables"
      return 0
    fi
  fi

  blank
  hint "Paste the full contents of your .env file below.

One KEY=value per line, for example:

    DATABASE_URL=postgres://user:pass@host:5432/mydb
    NEXTAUTH_SECRET=some-long-random-string
    NEXT_PUBLIC_API_URL=https://api.example.com

When you're done, type EOF on a line by itself and press Enter."
  blank
  printf '%s\n' "${C_DIM}─── paste below ───${C_RESET}"

  local content=""
  read_multiline content

  if [ -z "${content//[[:space:]]/}" ]; then
    warn "Nothing was pasted."
    confirm "Continue without environment variables?" "y" && { ok "Skipping"; return 0; }
    return 1
  fi

  printf '%s' "$content" >> "$APP_DIR/.env"
  chmod 600 "$APP_DIR/.env"

  local count
  count="$(grep -cE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$APP_DIR/.env" 2>/dev/null || echo 0)"
  blank
  ok "Wrote $count variable(s) to $APP_DIR/.env ${C_DIM}(readable only by you)${C_RESET}"

  if [ "$count" -eq 0 ]; then
    warn "None of those lines look like KEY=value pairs."
    dim "  Check the file: cat $APP_DIR/.env"
    confirm "Continue anyway?" "n" || return 1
  fi

  # If PORT is set in .env, honour it — it beats whatever we'd guess.
  local envport
  envport="$(grep -E '^[[:space:]]*PORT=' "$APP_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2 | tr -d '"'"'"' ' || true)"
  if [ -n "$envport" ] && validate_port "$envport"; then
    APP_PORT="$envport"
    info "Found PORT=$APP_PORT in your .env — the app will use that port."
  fi

  # .env must never be committed back to the repo.
  if [ -f "$APP_DIR/.gitignore" ] && ! grep -qE '^\.env$' "$APP_DIR/.gitignore" 2>/dev/null; then
    echo ".env" >> "$APP_DIR/.gitignore"
    dim "  (added .env to .gitignore)"
  fi

  save_state
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Step 8 — install deps + build
# ═══════════════════════════════════════════════════════════════════════════
install_and_build() {
  step "Installing dependencies and building"

  cd "$APP_DIR" || { err "Couldn't enter $APP_DIR"; return 1; }

  # The manager may have been switched after the clone revealed what the
  # project actually uses, so make sure it's runnable before we lean on it.
  ensure_package_manager "$PKG_MANAGER" || return 1

  info "Installing dependencies with $PKG_MANAGER — this can take a few minutes…"

  # Prefer the strict, lockfile-respecting form, then fall back to a plain
  # install. A lockfile that's out of sync with package.json fails the
  # strict form, and that shouldn't be fatal on a first deploy.
  local install_ok=1
  case "$PKG_MANAGER" in
    yarn)
      if [ -f yarn.lock ]; then yarn install --frozen-lockfile || yarn install || install_ok=0
      else yarn install || install_ok=0; fi ;;
    pnpm)
      if [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile || pnpm install || install_ok=0
      else pnpm install || install_ok=0; fi ;;
    bun)
      bun install || install_ok=0 ;;
    *)
      if [ -f package-lock.json ]; then npm ci || npm install || install_ok=0
      else npm install || install_ok=0; fi ;;
  esac

  if [ "$install_ok" -eq 0 ]; then
    hint "Dependency installation failed. Common causes:

  • A \"packageManager\" field that doesn't match the tool being
    used. If the error above mentions Corepack, that's this —
    the field in package.json is the authority, and it may be
    wrong or malformed.

  • Out of memory — check with: free -h

  • A private npm package the server can't authenticate to

  • A postinstall script needing a tool we haven't installed

The full error is above."
    return 1
  fi
  ok "Dependencies installed"

  if ! grep -q '"build"' package.json 2>/dev/null; then
    warn "No 'build' script in package.json — skipping the build step."
  else
    blank
    info "Building the app — this is the slowest part, often 1–3 minutes…"
    local build_ok=1
    case "$PKG_MANAGER" in
      yarn) yarn build        || build_ok=0 ;;
      pnpm) pnpm build        || build_ok=0 ;;
      bun)  bun run build     || build_ok=0 ;;
      *)    npm run build     || build_ok=0 ;;
    esac

    if [ "$build_ok" -eq 0 ]; then
      blank
      hint "The build failed. Read the error above — it's from your app, not
from this script, so it's usually a real code or config issue.

Two things that specifically bite on small EC2 instances:
  • Killed / 'JavaScript heap out of memory' → not enough RAM.
    Re-run this script and accept the swap file offer.
  • A missing environment variable that's needed at build time →
    retry, and this script will let you re-do the .env step.

Once you've pushed a fix, choose 'Retry' and it will pull and
rebuild."
      return 1
    fi
    ok "Build succeeded"
  fi

  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Step 9 — PM2
# ═══════════════════════════════════════════════════════════════════════════
setup_pm2() {
  step "Running the app with PM2"

  if ! has_cmd pm2; then
    info "Installing PM2 (keeps your app running and restarts it on crash/reboot)…"
    run_quiet sudo npm install -g pm2 || {
      hint "Couldn't install PM2 globally. If the error mentions EACCES,
npm's global directory has wrong permissions:

    sudo chown -R \$(whoami) /usr/lib/node_modules"
      return 1
    }
    ok "PM2 installed"
  else
    ok "PM2 v$(pm2 --version 2>/dev/null) already installed"
  fi

  blank
  dim "Your app needs a port to listen on. Nginx will sit in front of it and"
  dim "forward public traffic there, so this port stays private to the server."
  blank
  while true; do
    local p
    prompt p "Which port should the app run on?" "$APP_PORT"
    if validate_port "$p"; then
      # Refuse a port that's already taken by something else.
      if has_cmd ss && ss -ltn "sport = :$p" 2>/dev/null | grep -q LISTEN; then
        if pm2 describe "$APP_NAME" > /dev/null 2>&1; then
          APP_PORT="$p"; break   # it's our own app from a previous run
        fi
        err "Port $p is already in use by another process."
        dim "  See what's using it:  sudo ss -ltnp | grep :$p"
        blank
        continue
      fi
      APP_PORT="$p"; break
    fi
    err "$PORT_ERR"
  done
  ok "Using port $APP_PORT"

  cd "$APP_DIR" || return 1

  # Idempotent: replace any process from an earlier run rather than stacking.
  if pm2 describe "$APP_NAME" > /dev/null 2>&1; then
    info "Restarting the existing '$APP_NAME' process…"
    run_quiet pm2 delete "$APP_NAME" || true
  fi

  # Use an ecosystem file rather than a bare `pm2 start`. Three reasons:
  # a bare `pm2 start "npm start"` makes PM2 look for a *file* called
  # "npm start"; PORT= in front of pm2 sets it for the CLI, not for the
  # app the daemon spawns; and a config file is what survives `pm2 save`
  # and a reboot intact.
  local script_bin script_args
  if grep -q '"start"' package.json 2>/dev/null; then
    case "$PKG_MANAGER" in
      yarn) script_bin="yarn"; script_args="'start'" ;;
      pnpm) script_bin="pnpm"; script_args="'start'" ;;
      bun)  script_bin="bun";  script_args="'run', 'start'" ;;
      *)    script_bin="npm";  script_args="'run', 'start'" ;;
    esac
  else
    script_bin="npx"; script_args="'next', 'start'"
  fi

  # PM2 needs an absolute path: Corepack shims and a bun install under
  # ~/.bun aren't on the PATH the PM2 daemon inherits at boot.
  local resolved; resolved="$(command -v "$script_bin" 2>/dev/null || true)"
  [ -n "$resolved" ] && script_bin="$resolved"

  local eco="$APP_DIR/ecosystem.config.js"
  info "Writing $eco …"
  cat > "$eco" <<ECOCONF
// Generated by nextdeploy v$NEXTDEPLOY_VERSION
// Regenerated on each run — edit with that in mind.
module.exports = {
  apps: [{
    name: '$APP_NAME',
    cwd: '$APP_DIR',
    script: '$script_bin',
    args: [$script_args],
    interpreter: 'none',
    env: {
      NODE_ENV: 'production',
      PORT: '$APP_PORT',
    },
    autorestart: true,
    max_restarts: 10,
    // A crash loop should back off rather than hammer the box.
    restart_delay: 2000,
    max_memory_restart: '512M',
  }],
};
ECOCONF

  # Don't commit our generated file back to the user's repo.
  if [ -f "$APP_DIR/.gitignore" ] && ! grep -qE '^ecosystem\.config\.js$' "$APP_DIR/.gitignore" 2>/dev/null; then
    echo "ecosystem.config.js" >> "$APP_DIR/.gitignore"
  fi

  info "Starting '$APP_NAME' on port $APP_PORT …"
  if ! run_quiet pm2 start "$eco"; then
    err "PM2 couldn't start the app."
    dim "  Logs:  pm2 logs $APP_NAME --lines 50"
    return 1
  fi

  # PM2 reports "online" immediately; a crash-looping app needs a moment
  # to reveal itself, so verify by actually talking to the port.
  info "Waiting for the app to respond…"
  local waited=0 up=0
  while [ "$waited" -lt 45 ]; do
    if curl -fsS --max-time 3 -o /dev/null "http://127.0.0.1:$APP_PORT" 2>/dev/null; then
      up=1; break
    fi
    if ! pm2 describe "$APP_NAME" 2>/dev/null | grep -q 'online'; then
      break
    fi
    sleep 3; waited=$((waited + 3))
    [ $((waited % 15)) -eq 0 ] && dim "  …still starting (${waited}s)"
  done

  if [ "$up" -ne 1 ]; then
    blank
    err "The app isn't responding on port $APP_PORT."
    blank
    dim "─── recent app logs ───"
    pm2 logs "$APP_NAME" --lines 25 --nostream 2>/dev/null | tail -n 25 >&2 || true
    dim "───────────────────────"
    hint "Most common causes:
  • The app crashed on startup — a missing env var is the usual
    culprit. The logs above will normally say which one.
  • The app is hard-coded to a different port. Check your
    package.json start script for an explicit -p flag.
  • It's just slow to boot. Retry and it may pass on the second go."
    return 1
  fi

  ok "App is live on http://127.0.0.1:$APP_PORT"

  write_redeploy_script

  info "Configuring PM2 to start automatically on reboot…"
  run_quiet pm2 save || warn "Couldn't save the PM2 process list."
  local startup_cmd
  startup_cmd="$(pm2 startup systemd -u "$USER" --hp "$HOME" 2>/dev/null | grep -E '^sudo ' | tail -n1 || true)"
  if [ -n "$startup_cmd" ]; then
    eval "$startup_cmd" > /dev/null 2>&1 && ok "Auto-start on reboot enabled" \
      || warn "Couldn't enable auto-start. Run manually: $startup_cmd"
  else
    ok "Auto-start already configured"
  fi

  save_state
  return 0
}

# Write a redeploy helper. Printing a one-liner in the summary isn't enough:
# a private repo needs the deploy key in GIT_SSH_COMMAND, and the build
# command differs between npm and yarn. Baking both into a script means the
# user has one thing to remember and it's correct for their setup.
write_redeploy_script() {
  local build_cmd install_cmd fallback_install git_env=""
  case "$PKG_MANAGER" in
    yarn) install_cmd="yarn install --frozen-lockfile"; fallback_install="yarn install"
          build_cmd="yarn build" ;;
    pnpm) install_cmd="pnpm install --frozen-lockfile"; fallback_install="pnpm install"
          build_cmd="pnpm build" ;;
    bun)  install_cmd="bun install";                    fallback_install="bun install"
          build_cmd="bun run build" ;;
    *)    install_cmd="npm ci";                         fallback_install="npm install"
          build_cmd="npm run build" ;;
  esac
  if [ "$REPO_IS_PRIVATE" = "yes" ]; then
    git_env="export GIT_SSH_COMMAND=\"ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes\""
  fi

  cat > "$REDEPLOY_PATH" <<REDEPLOY
#!/usr/bin/env bash
# Generated by nextdeploy v$NEXTDEPLOY_VERSION — pull, build, restart.
set -euo pipefail

cd "$APP_DIR"
$git_env

echo "→ Pulling latest code…"
git pull --ff-only

echo "→ Installing dependencies…"
# Fall back to a plain install when the lockfile is out of sync with
# package.json — that shouldn't stop a deploy.
$install_cmd || $fallback_install

echo "→ Building…"
$build_cmd

echo "→ Restarting…"
pm2 restart "$APP_NAME" --update-env

echo
echo "✓ Deployed. Logs: pm2 logs $APP_NAME"
REDEPLOY

  chmod +x "$REDEPLOY_PATH"
  ok "Redeploy script written to $REDEPLOY_PATH"
}

# ═══════════════════════════════════════════════════════════════════════════
# Step 10 — Nginx
# ═══════════════════════════════════════════════════════════════════════════
setup_nginx() {
  step "Setting up Nginx"

  if ! has_cmd nginx; then
    info "Installing Nginx…"
    run_quiet sudo apt-get install -y nginx || return 1
    ok "Nginx installed"
  else
    ok "Nginx already installed"
  fi

  blank
  dim "Nginx will listen on port 80 and forward requests to your app on"
  dim "port $APP_PORT. That's what makes the site reachable without a"
  dim ":$APP_PORT in the URL."
  blank

  if confirm "Do you have a domain name to point at this server?" "y"; then
    hint "Enter just the domain, nothing else.

    ✓  wikipedia.org
    ✓  app.mycompany.io

    ✗  https://wikipedia.org      ← no protocol
    ✗  wikipedia.org/wiki/Home    ← no path
    ✗  wikipedia.org:3000         ← no port"
    blank
    while true; do
      local d
      prompt d "Your domain:"
      d="$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')"
      if validate_domain "$d"; then DOMAIN="$d"; break; fi
      err "$DOMAIN_ERR"
      dim "  You entered: $d"
      blank
    done
    ok "Domain: $DOMAIN"

    if [[ "$DOMAIN" != www.* ]] && [ "$(grep -o '\.' <<< "$DOMAIN" | wc -l)" -eq 1 ]; then
      confirm "Also serve www.$DOMAIN?" "y" && WANT_WWW="yes"
    fi
  else
    DOMAIN=""
    dim "  No problem — Nginx will serve on the server's IP address."
    dim "  You can re-run this script later to add a domain and HTTPS."
  fi

  local server_names="_"
  if [ -n "$DOMAIN" ]; then
    server_names="$DOMAIN"
    [ "$WANT_WWW" = "yes" ] && server_names="$DOMAIN www.$DOMAIN"
  fi

  local conf="/etc/nginx/sites-available/$APP_NAME"
  info "Writing $conf …"

  sudo tee "$conf" > /dev/null <<NGINXCONF
# Generated by nextdeploy v$NEXTDEPLOY_VERSION
# Safe to edit — re-running nextdeploy will overwrite it.

server {
    listen 80;
    listen [::]:80;

    server_name $server_names;

    # Let Next.js handle its own compression and caching headers.
    location / {
        proxy_pass         http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;

        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        'upgrade';
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;

        proxy_read_timeout 300s;
    }

    # Next.js build assets are content-hashed, so they can be cached hard.
    location /_next/static/ {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_cache_bypass \$http_upgrade;
        add_header Cache-Control "public, max-age=31536000, immutable";
    }

    client_max_body_size 25M;
}
NGINXCONF

  sudo ln -sfn "$conf" "/etc/nginx/sites-enabled/$APP_NAME"

  # The default site also claims port 80 and will shadow ours.
  if [ -e /etc/nginx/sites-enabled/default ]; then
    info "Removing Nginx's default placeholder site…"
    sudo rm -f /etc/nginx/sites-enabled/default
  fi

  info "Checking the Nginx configuration…"
  if ! sudo nginx -t > /dev/null 2>&1; then
    err "Nginx rejected the configuration."
    sudo nginx -t 2>&1 | sed 's/^/    /' >&2
    return 1
  fi
  ok "Configuration is valid"

  run_quiet sudo systemctl reload nginx || run_quiet sudo systemctl restart nginx || {
    err "Nginx wouldn't reload."
    dim "  Details:  sudo systemctl status nginx"
    return 1
  }
  run_quiet sudo systemctl enable nginx || true
  ok "Nginx is running"

  # Firewall — a closed port 80 also breaks certbot later.
  if has_cmd ufw; then
    if sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
      run_quiet sudo ufw allow 'Nginx Full' || true
      ok "Firewall updated to allow HTTP and HTTPS"
    else
      dim "  (ufw firewall is inactive — nothing to open locally)"
    fi
  fi

  info "Testing through Nginx…"
  if curl -fsS --max-time 10 -o /dev/null -H "Host: ${DOMAIN:-localhost}" "http://127.0.0.1" 2>/dev/null; then
    ok "Nginx is correctly proxying to your app"
  else
    warn "Couldn't verify the proxy locally. It may still be fine."
  fi

  blank
  if [ -n "$PUBLIC_IP" ]; then
    ok "Your app should now be reachable at ${C_BOLD}http://$PUBLIC_IP${C_RESET}"
    blank
    hint "If that URL doesn't load, it's almost certainly your EC2 security
group rather than the server.

In the AWS console: EC2 → Instances → your instance → Security →
click the security group → Edit inbound rules → Add rule:

    Type: HTTP   Port: 80    Source: Anywhere-IPv4  (0.0.0.0/0)
    Type: HTTPS  Port: 443   Source: Anywhere-IPv4  (0.0.0.0/0)

This script can't change that for you — it lives in AWS, not on
this machine."
  fi

  save_state
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Step 11 — DNS + HTTPS via certbot
# ═══════════════════════════════════════════════════════════════════════════
setup_tls() {
  step "HTTPS with a free Let's Encrypt certificate"

  if [ -z "$DOMAIN" ]; then
    info "No domain was configured, so there's nothing to secure."
    dim "  Let's Encrypt only issues certificates for domain names, not IPs."
    dim "  Re-run this script once you have a domain pointed here."
    return 0
  fi

  if [ -z "$PUBLIC_IP" ]; then
    warn "We couldn't detect this server's public IP automatically."
    hint "Find it in the AWS console: EC2 → Instances → your instance →
'Public IPv4 address'. It looks like 13.234.56.78"
    blank
    while true; do
      local ip
      prompt ip "This server's public IPv4 address:"
      if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then PUBLIC_IP="$ip"; break; fi
      err "That isn't a valid IPv4 address. Expected four numbers with dots, like 13.234.56.78"
    done
  fi

  blank
  printf '%s\n' "${C_BOLD}Point your domain at this server${C_RESET}"
  blank
  dim "Go to wherever you bought $DOMAIN (GoDaddy, Namecheap, Cloudflare,"
  dim "Route 53 …), open its DNS settings, and add these records:"
  blank
  printf '%s\n' "${C_DIM}  ┌──────┬──────────────┬─────────────────────┐${C_RESET}"
  printf '%s\n' "${C_DIM}  │${C_RESET} Type ${C_DIM}│${C_RESET} Name         ${C_DIM}│${C_RESET} Value               ${C_DIM}│${C_RESET}"
  printf '%s\n' "${C_DIM}  ├──────┼──────────────┼─────────────────────┤${C_RESET}"
  printf '%s\n' "${C_DIM}  │${C_RESET} ${C_GREEN}A${C_RESET}    ${C_DIM}│${C_RESET} ${C_BOLD}@${C_RESET}            ${C_DIM}│${C_RESET} ${C_BOLD}$PUBLIC_IP${C_RESET}"
  [ "$WANT_WWW" = "yes" ] && \
  printf '%s\n' "${C_DIM}  │${C_RESET} ${C_GREEN}A${C_RESET}    ${C_DIM}│${C_RESET} ${C_BOLD}www${C_RESET}          ${C_DIM}│${C_RESET} ${C_BOLD}$PUBLIC_IP${C_RESET}"
  printf '%s\n' "${C_DIM}  └──────┴──────────────┴─────────────────────┘${C_RESET}"
  blank
  hint "Notes:
  • '@' means the domain itself ($DOMAIN). Some registrars want
    the name left blank instead — same thing.
  • Set TTL to the lowest available (300 / 5 minutes) so changes
    take effect quickly.
  • If you're on Cloudflare, set the record to ${C_BOLD}DNS only${C_RESET} (grey
    cloud) for now. Orange-cloud proxying will make the
    certificate check fail.
  • Delete any existing A or AAAA record for the same name first,
    or they'll conflict."
  blank

  local names=("$DOMAIN")
  [ "$WANT_WWW" = "yes" ] && names+=("www.$DOMAIN")

  while true; do
    pause "Press Enter once you've added the DNS records…"

    info "Checking DNS… (changes can take a few minutes to spread)"
    blank
    local all_good=1
    for n in "${names[@]}"; do
      local got; got="$(resolve_a "$n" | tr '\n' ' ' | sed 's/ *$//')"
      if [ -z "$got" ]; then
        printf '%s\n' "  ${C_RED}✗${C_RESET} $n → ${C_DIM}no A record found yet${C_RESET}"
        all_good=0
      elif printf '%s' " $got " | grep -q " $PUBLIC_IP "; then
        printf '%s\n' "  ${C_GREEN}✓${C_RESET} $n → $got"
      else
        printf '%s\n' "  ${C_RED}✗${C_RESET} $n → $got ${C_DIM}(expected $PUBLIC_IP)${C_RESET}"
        all_good=0
      fi
    done
    blank

    if [ "$all_good" -eq 1 ]; then
      ok "DNS is pointing at this server"
      break
    fi

    err "DNS isn't ready yet."
    hint "If you've only just added the records, this is normal — give it
2–5 minutes and check again.

If it's been longer, check:
  • The record type is ${C_BOLD}A${C_RESET} (not CNAME, not AAAA)
  • The value is exactly ${C_BOLD}$PUBLIC_IP${C_RESET}
  • You edited DNS at the registrar that actually controls the
    domain's nameservers
  • Cloudflare proxying is OFF (grey cloud, not orange)"
    blank
    local pick
    choose pick "What now?" \
      "Check again" \
      "Skip HTTPS for now (the site still works over http://)" \
      "Abort"
    case "$pick" in
      "Check again") continue ;;
      "Skip HTTPS for now (the site still works over http://)")
        warn "Skipping HTTPS. Re-run this script any time to set it up."
        return 0 ;;
      "Abort") return 1 ;;
    esac
  done

  # Certbot needs to reach port 80 from the outside for HTTP-01.
  info "Checking that port 80 is reachable from the internet…"
  local ext
  ext="$(curl -fsS --max-time 12 -o /dev/null -w '%{http_code}' "http://$DOMAIN" 2>/dev/null || echo "000")"
  if [ "$ext" = "000" ]; then
    warn "Couldn't reach http://$DOMAIN from this server."
    hint "Let's Encrypt has to reach your site on port 80 to verify you own
the domain. If it can't, certificate issuance will fail.

The usual cause is the EC2 security group not allowing inbound
HTTP. In the AWS console:

  EC2 → Instances → your instance → Security → the security
  group → Edit inbound rules → Add rule → Type: HTTP,
  Source: Anywhere-IPv4

Add HTTPS (443) at the same time — you'll need it in a moment."
    blank
    confirm "Continue and try anyway?" "y" || return 1
  else
    ok "Port 80 is reachable (HTTP $ext)"
  fi

  if ! has_cmd certbot; then
    info "Installing Certbot…"
    run_quiet sudo apt-get install -y certbot python3-certbot-nginx || {
      hint "Couldn't install Certbot from apt. Try refreshing package lists
and retrying:

    sudo apt-get update"
      return 1
    }
    ok "Certbot installed"
  else
    ok "Certbot already installed"
  fi

  blank
  dim "Let's Encrypt needs an email address. It's used only to warn you if"
  dim "a certificate is about to expire without renewing. It isn't public."
  blank
  while true; do
    local em
    prompt em "Email address:"
    if validate_email "$em"; then LE_EMAIL="$em"; break; fi
    err "That doesn't look like an email address."
    dim "  Expected something like: you@example.com"
  done

  local domain_args=()
  for n in "${names[@]}"; do domain_args+=(-d "$n"); done

  blank
  info "Requesting a certificate for: ${names[*]}"
  dim "  Certbot will also update your Nginx config to serve HTTPS and"
  dim "  redirect http:// to https:// automatically."
  blank

  if sudo certbot --nginx "${domain_args[@]}" \
      --non-interactive --agree-tos -m "$LE_EMAIL" --redirect; then
    ok "Certificate issued and Nginx updated"
    SETUP_TLS="yes"
  else
    blank
    err "Certbot couldn't get a certificate."
    hint "The output above has the specific reason. The frequent ones:

  • 'Timeout during connect' → port 80 is blocked. Fix the EC2
    security group (inbound HTTP from 0.0.0.0/0) and retry.
  • 'DNS problem: NXDOMAIN' → the A record hasn't propagated
    yet. Wait a few minutes and retry.
  • 'too many certificates already issued' → Let's Encrypt rate
    limit, 5 per domain per week. You'll have to wait, or use a
    subdomain instead.
  • Cloudflare orange cloud is on → switch the record to DNS
    only and retry.

Your site is still up over http:// while you sort this out."
    return 1
  fi

  info "Checking automatic renewal…"
  if sudo certbot renew --dry-run > /dev/null 2>&1; then
    ok "Auto-renewal is working — certificates renew themselves every 60 days"
  else
    warn "The renewal dry-run failed. Your certificate is valid for 90 days,"
    warn "but check renewal later with:  sudo certbot renew --dry-run"
  fi

  if has_cmd ufw && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
    run_quiet sudo ufw allow 'Nginx Full' || true
  fi

  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════
summary() {
  blank; blank
  printf '%s\n' "${C_BOLD}${C_GREEN}  ✓ Setup complete${C_RESET}"
  printf '%s\n' "${C_DIM}$(printf '─%.0s' $(seq 1 60))${C_RESET}"
  blank

  local url
  if [ -n "$DOMAIN" ] && [ "$SETUP_TLS" = "yes" ]; then url="https://$DOMAIN"
  elif [ -n "$DOMAIN" ];                                then url="http://$DOMAIN"
  elif [ -n "$PUBLIC_IP" ];                             then url="http://$PUBLIC_IP"
  else                                                       url="http://<your-server-ip>"; fi

  printf '%s\n' "  Your app is live at   ${C_BOLD}${C_CYAN}$url${C_RESET}"
  blank
  printf '%s\n' "  ${C_DIM}App directory${C_RESET}     $APP_DIR"
  printf '%s\n' "  ${C_DIM}Process name${C_RESET}      $APP_NAME"
  printf '%s\n' "  ${C_DIM}Internal port${C_RESET}     $APP_PORT"
  printf '%s\n' "  ${C_DIM}Package manager${C_RESET}   $PKG_MANAGER"
  [ "$SETUP_TLS" = "yes" ] && printf '%s\n' "  ${C_DIM}HTTPS${C_RESET}             Let's Encrypt, auto-renewing"
  blank
  printf '%s\n' "${C_BOLD}  Day-to-day commands${C_RESET}"
  blank
  printf '%s\n' "  ${C_DIM}# see logs${C_RESET}"
  printf '%s\n' "  pm2 logs $APP_NAME"
  blank
  printf '%s\n' "  ${C_DIM}# restart after a config change${C_RESET}"
  printf '%s\n' "  pm2 restart $APP_NAME"
  blank
  printf '%s\n' "  ${C_DIM}# deploy new code (pull, install, build, restart)${C_RESET}"
  printf '%s\n' "  $REDEPLOY_PATH"
  blank
  printf '%s\n' "  ${C_DIM}# check status${C_RESET}"
  printf '%s\n' "  pm2 status"
  blank

  if [ -z "$DOMAIN" ]; then
    dim "  Want a domain and HTTPS? Point one at this server, then re-run"
    dim "  this script — it'll skip everything that's already done."
    blank
  elif [ "$SETUP_TLS" != "yes" ]; then
    dim "  HTTPS wasn't set up. Re-run this script once DNS is pointing here."
    blank
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
main() {
  banner

  if load_state 2>/dev/null && [ -n "${APP_NAME:-}" ]; then
    info "Found settings from a previous run (app: $APP_NAME)."
    dim "  Re-running is safe — completed steps are detected and skipped."
    blank
  fi

  retry_step "Pre-flight checks"          preflight
  retry_step "Updating packages"          update_system
  retry_step "Installing Node.js"         install_node
  retry_step "Choosing a package manager" choose_package_manager
  retry_step "Repository details"         ask_repo
  retry_step "Repository access"          setup_deploy_key
  retry_step "Cloning the repository"     clone_repo
  retry_step "Environment variables"      setup_env_file
  retry_step "Install and build"          install_and_build
  retry_step "Starting with PM2"          setup_pm2
  retry_step "Setting up Nginx"           setup_nginx
  retry_step "Setting up HTTPS"           setup_tls

  save_state
  summary
}

main "$@"
