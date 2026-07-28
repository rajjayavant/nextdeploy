# shellcheck shell=bash
# validate.sh — input validation and pre-flight checks.
#
# Everything here is cheap and side-effect free. The philosophy: catch a bad
# value at the prompt where we can explain it, rather than three commands
# later inside someone else's error message.

# ── Repo URLs ──────────────────────────────────────────────────────────────
# Accepts:  https://github.com/owner/repo(.git)
#           git@github.com:owner/repo(.git)
#           github.com/owner/repo
#           owner/repo
# Populates REPO_OWNER, REPO_NAME, REPO_HOST.
parse_repo_url() {
  local raw="$1"
  raw="${raw%/}"; raw="${raw%.git}"
  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"

  REPO_HOST=""; REPO_OWNER=""; REPO_NAME=""

  if [[ "$raw" =~ ^git@([^:]+):([^/]+)/(.+)$ ]]; then
    REPO_HOST="${BASH_REMATCH[1]}"; REPO_OWNER="${BASH_REMATCH[2]}"; REPO_NAME="${BASH_REMATCH[3]}"
  elif [[ "$raw" =~ ^ssh://git@([^/]+)/([^/]+)/(.+)$ ]]; then
    REPO_HOST="${BASH_REMATCH[1]}"; REPO_OWNER="${BASH_REMATCH[2]}"; REPO_NAME="${BASH_REMATCH[3]}"
  elif [[ "$raw" =~ ^https?://([^/]+)/([^/]+)/(.+)$ ]]; then
    REPO_HOST="${BASH_REMATCH[1]}"; REPO_OWNER="${BASH_REMATCH[2]}"; REPO_NAME="${BASH_REMATCH[3]}"
    REPO_HOST="${REPO_HOST#*@}"
  elif [[ "$raw" =~ ^([^/.]+\.[^/]+)/([^/]+)/(.+)$ ]]; then
    REPO_HOST="${BASH_REMATCH[1]}"; REPO_OWNER="${BASH_REMATCH[2]}"; REPO_NAME="${BASH_REMATCH[3]}"
  elif [[ "$raw" =~ ^([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)$ ]]; then
    REPO_HOST="github.com"; REPO_OWNER="${BASH_REMATCH[1]}"; REPO_NAME="${BASH_REMATCH[2]}"
  else
    return 1
  fi

  # Reject a nested path — owner/repo only, no deep links like /tree/main.
  [[ "$REPO_NAME" == */* ]] && return 1
  [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ] && return 1
  return 0
}

# Set by validate_domain / validate_port on failure and read by the caller.
# Initialised here so `set -u` can never trip on them.
DOMAIN_ERR=""
PORT_ERR=""

# ── Domains ────────────────────────────────────────────────────────────────
# Rejects scheme, path, port, trailing dot, and bare TLDs. This is the field
# users most often paste a full URL into.
validate_domain() {
  local d="$1"
  case "$d" in
    http://*|https://*)  DOMAIN_ERR="Leave off the http:// or https:// — just the domain itself." ; return 1 ;;
    *://*)               DOMAIN_ERR="Leave off the protocol prefix — just the domain itself."     ; return 1 ;;
    */*)                 DOMAIN_ERR="Leave off the trailing path — just the domain itself."       ; return 1 ;;
    *:*)                 DOMAIN_ERR="Leave off the port number — just the domain itself."         ; return 1 ;;
    www.*.*)             : ;;
    *@*)                 DOMAIN_ERR="That looks like an email address, not a domain."             ; return 1 ;;
  esac
  [ "${d: -1}" = "." ] && { DOMAIN_ERR="Remove the trailing dot."; return 1; }
  if [[ ! "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
    DOMAIN_ERR="That isn't a valid domain name."
    return 1
  fi
  [[ "$d" != *.* ]] && { DOMAIN_ERR="A domain needs at least one dot, like example.com."; return 1; }
  local tld="${d##*.}"
  [[ ! "$tld" =~ ^[A-Za-z]{2,}$ ]] && { DOMAIN_ERR="'.$tld' doesn't look like a valid ending."; return 1; }
  DOMAIN_ERR=""
  return 0
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || { PORT_ERR="Ports are numbers only, like 3000."; return 1; }
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { PORT_ERR="Ports must be between 1 and 65535."; return 1; }
  if [ "$p" -lt 1024 ]; then
    PORT_ERR="Ports below 1024 need root. Use something like 3000 and let Nginx handle 80/443."
    return 1
  fi
  PORT_ERR=""
  return 0
}

validate_email() {
  [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$ ]]
}

# ── Environment pre-flight ─────────────────────────────────────────────────

is_ubuntu() { [ -r /etc/os-release ] && grep -qi '^ID=ubuntu' /etc/os-release; }

ubuntu_version() {
  [ -r /etc/os-release ] || { echo "unknown"; return; }
  # shellcheck disable=SC1091
  ( . /etc/os-release; echo "${VERSION_ID:-unknown}" )
}

has_cmd() { command -v "$1" > /dev/null 2>&1; }

total_ram_mb() { awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0; }

free_disk_mb() { df -Pm / 2>/dev/null | awk 'NR==2 {print $4}' || echo 0; }

has_swap() { [ "$(awk 'NR>1 {s+=$3} END {print s+0}' /proc/swaps 2>/dev/null)" -gt 0 ] 2>/dev/null; }

# Public IPv4 of this box, via EC2 IMDSv2 with plain-internet fallbacks.
detect_public_ip() {
  local ip="" token=""
  token="$(curl -fsS --max-time 3 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
  if [ -n "$token" ]; then
    ip="$(curl -fsS --max-time 3 -H "X-aws-ec2-metadata-token: $token" \
      "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)"
  fi
  [ -z "$ip" ] && ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [ -z "$ip" ] && ip="$(curl -fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null || true)"
  printf '%s' "$ip"
}

# Resolve a hostname to A records without assuming dig is installed.
resolve_a() {
  local host="$1"
  if has_cmd dig; then
    dig +short +time=3 +tries=1 A "$host" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' || true
  elif has_cmd host; then
    host -W 3 -t A "$host" 2>/dev/null | awk '/has address/ {print $NF}' || true
  elif has_cmd getent; then
    getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u || true
  fi
}
