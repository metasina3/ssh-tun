#!/usr/bin/env bash
set -euo pipefail

VERSION="v9.4.0"
SCRIPT_PATH="$(readlink -f "$0")"

APP_NAME="ssh-tun"
BIN_PATH="/usr/local/bin/ssh-tun"
GITHUB_REPO="metasina3/ssh-tun"
GITHUB_RAW_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main/ssh-tun.sh"
GITHUB_API_LATEST="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
UPDATE_CACHE_TTL=3600
UPDATE_FAIL_CACHE_TTL=600
BASE_DIR="/etc/ssh-tun"
UPDATE_CACHE_FILE="${BASE_DIR}/.update-check"
PROFILES_DIR="${BASE_DIR}/profiles"
LIBEXEC_DIR="/usr/local/libexec/ssh-tun"
SUPERVISOR_PATH="${LIBEXEC_DIR}/supervisor.sh"
SYSTEMD_TEMPLATE="/etc/systemd/system/ssh-tun@.service"
LEGACY_ENV_FILE="/etc/ssh-socks-farm.env"

ROOT_HOME="$(getent passwd root 2>/dev/null | cut -d: -f6)"
ROOT_HOME="${ROOT_HOME:-/root}"
ROOT_SSH_DIR="${ROOT_HOME}/.ssh"
KNOWN_HOSTS_FILE_DEFAULT="${ROOT_SSH_DIR}/known_hosts"
SSH_CONFIG_FILE="${ROOT_SSH_DIR}/config"

PREREQ_PKGS=(openssh-client curl iproute2 ca-certificates)

# Health-check endpoints (first = highest priority). Google generate_204 first,
# then gstatic, Cloudflare trace, Telegram, legacy HTTP fallbacks.
DEFAULT_HC_URLS="https://www.google.com/generate_204,https://connectivitycheck.gstatic.com/generate_204,https://www.cloudflare.com/cdn-cgi/trace,https://telegram.org/,http://clients3.google.com/generate_204,http://www.msftconnecttest.com/connecttest.txt"

log()  { echo "[INFO] $*"; }
ok()   { echo "[OK] $*"; }
warn() { echo "[WARN] $*" >&2; }
err()  { echo "[ERR] $*" >&2; }
die()  { err "$*"; exit 1; }

hr() { printf '%s\n' "------------------------------------------------------------"; }
section() { echo; hr; echo "$1"; hr; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }
need_root() { [[ "${EUID:-0}" -eq 0 ]] || die "Run as root (sudo -i)."; }

prompt_default() {
  local q="$1" def="$2" __var="$3"
  local ans
  read -r -p "$q [$def]: " ans || true
  ans="${ans:-$def}"
  printf -v "$__var" "%s" "$ans"
}

prompt_yesno() {
  local q="$1" def="$2" __var="$3"
  local def_lc ans
  def_lc="$(echo "$def" | tr '[:upper:]' '[:lower:]')"
  [[ "$def_lc" == "yes" || "$def_lc" == "no" ]] || die "prompt_yesno: default must be YES or NO"
  while true; do
    read -r -p "$q [yes/no] (default: $def_lc): " ans || true
    ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
    case "$ans" in
      yes) printf -v "$__var" "YES"; return 0 ;;
      no)  printf -v "$__var" "NO"; return 0 ;;
      "")  printf -v "$__var" "%s" "$(echo "$def_lc" | tr '[:lower:]' '[:upper:]')"; return 0 ;;
      *)   warn "Invalid answer. Type yes or no." ;;
    esac
  done
}

prompt_cipher_choice() {
  local __var="$1"
  local -a choices=(
    "chacha20-poly1305@openssh.com"
    "aes128-gcm@openssh.com"
    "aes256-gcm@openssh.com"
    "aes128-ctr"
    "aes256-ctr"
  )
  local default_idx=1 ans idx
  echo "SSH cipher options:"
  echo "  1) ${choices[0]} (default)"
  echo "  2) ${choices[1]}"
  echo "  3) ${choices[2]}"
  echo "  4) ${choices[3]}"
  echo "  5) ${choices[4]}"
  while true; do
    read -r -p "Choose cipher number [${default_idx}]: " ans || true
    ans="${ans:-$default_idx}"
    if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#choices[@]} )); then
      idx=$((ans - 1))
      printf -v "$__var" "%s" "${choices[$idx]}"
      return 0
    fi
    warn "Invalid choice. Enter a number between 1 and ${#choices[@]}."
  done
}

is_port() { [[ "$1" =~ ^[0-9]+$ ]] && ((1 <= $1 && $1 <= 65535)); }

is_local_port_free() {
  local p="$1"
  ! ss -lntH "sport = :${p}" 2>/dev/null | grep -q .
}

show_port_conflict() {
  local p="$1"
  local ans
  ans="$(ss -lntup "sport = :${p}" 2>/dev/null | sed '1d' | sed '/^[[:space:]]*$/d' || true)"
  if [[ -n "$ans" ]]; then
    echo "  - Port ${p} is already in use:"
    while IFS= read -r line; do
      echo "      ${line}"
    done <<< "$ans"
  else
    echo "  - Port ${p} appears busy (details unavailable)."
  fi
}

parse_ports_spec() {
  local spec="$1"
  spec="${spec// /}"
  [[ -n "$spec" ]] || return 1
  local tmp out part
  tmp="$(mktemp)"
  out="$(mktemp)"
  IFS=',' read -r -a parts <<< "$spec"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" p t
      is_port "$a" || { rm -f "$tmp" "$out"; return 2; }
      is_port "$b" || { rm -f "$tmp" "$out"; return 2; }
      if (( a > b )); then t="$a"; a="$b"; b="$t"; fi
      for ((p=a; p<=b; p++)); do echo "$p" >>"$tmp"; done
    else
      is_port "$part" || { rm -f "$tmp" "$out"; return 2; }
      echo "$part" >>"$tmp"
    fi
  done
  sort -n "$tmp" | awk '!seen[$0]++' >"$out"
  cat "$out"
  rm -f "$tmp" "$out"
}

safe_tag() { printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | sed 's/_\+/_/g'; }
profile_env_path() { printf '%s/%s.env' "$PROFILES_DIR" "$1"; }
profile_state_path() { printf '%s/%s.instances' "$PROFILES_DIR" "$1"; }

# Read a single variable from a profile env file WITHOUT polluting the caller's
# shell. Sourcing happens in a subshell so values never leak between profiles.
profile_get() {
  local env_file="$1" var="$2"
  [[ -r "$env_file" ]] || return 0
  (
    # shellcheck disable=SC1090
    source "$env_file" >/dev/null 2>&1 || true
    printf '%s' "${!var:-}"
  )
}

ensure_dirs() {
  mkdir -p "$PROFILES_DIR" "$LIBEXEC_DIR" "$ROOT_SSH_DIR"
  chmod 700 "$ROOT_SSH_DIR"
  touch "$KNOWN_HOSTS_FILE_DEFAULT" "$SSH_CONFIG_FILE"
  chmod 600 "$KNOWN_HOSTS_FILE_DEFAULT" "$SSH_CONFIG_FILE" || true
}

# --- Optional self-update from GitHub (never mandatory; failures are silent) ---
UPDATE_CHECK_OK="NO"
UPDATE_AVAILABLE="NO"
UPDATE_LATEST_VERSION=""

_version_key() {
  local v="${1#v}" a b c
  IFS=. read -r a b c <<< "$v"
  a=${a:-0}; b=${b:-0}; c=${c:-0}
  printf '%010d%010d%010d' "$a" "$b" "$c"
}

version_newer_than() {
  [[ "$(_version_key "$1")" -gt "$(_version_key "$2")" ]]
}

_fetch_latest_version_remote() {
  local tag ver
  if have_cmd curl; then
    tag="$(curl -fsSL --connect-timeout 5 --max-time 10 \
      -H "Accept: application/vnd.github+json" \
      "$GITHUB_API_LATEST" 2>/dev/null \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)" || true
    if [[ -n "$tag" ]]; then
      printf '%s' "$tag"
      return 0
    fi
    ver="$(curl -fsSL --connect-timeout 5 --max-time 20 "$GITHUB_RAW_URL" 2>/dev/null \
      | sed -n 's/^VERSION="\([^"]*\)".*/\1/p' | head -1)" || true
    if [[ -n "$ver" ]]; then
      printf '%s' "$ver"
      return 0
    fi
  fi
  return 1
}

_save_update_cache() {
  local now
  now="$(date +%s)"
  mkdir -p "$BASE_DIR"
  cat >"$UPDATE_CACHE_FILE" <<EOF
LAST_CHECK_EPOCH=${now}
UPDATE_CHECK_OK=${UPDATE_CHECK_OK}
UPDATE_AVAILABLE=${UPDATE_AVAILABLE}
UPDATE_LATEST_VERSION=${UPDATE_LATEST_VERSION}
EOF
  chmod 0644 "$UPDATE_CACHE_FILE" 2>/dev/null || true
}

_load_update_cache() {
  local now age epoch
  [[ -r "$UPDATE_CACHE_FILE" ]] || return 1
  # shellcheck disable=SC1090
  source "$UPDATE_CACHE_FILE" 2>/dev/null || return 1
  now="$(date +%s)"
  epoch="${LAST_CHECK_EPOCH:-0}"
  age=$((now - epoch))
  if [[ "${UPDATE_CHECK_OK:-NO}" == "NO" ]]; then
    (( age >= 0 && age < UPDATE_FAIL_CACHE_TTL )) || return 1
  else
    (( age >= 0 && age < UPDATE_CACHE_TTL )) || return 1
  fi
  UPDATE_CHECK_OK="${UPDATE_CHECK_OK:-NO}"
  UPDATE_AVAILABLE="${UPDATE_AVAILABLE:-NO}"
  UPDATE_LATEST_VERSION="${UPDATE_LATEST_VERSION:-}"
  return 0
}

# Check GitHub for a newer release. Returns 0 when check succeeded (even if up-to-date).
# Never prints errors — callers decide what to show.
check_for_update() {
  local latest
  UPDATE_CHECK_OK="NO"
  UPDATE_AVAILABLE="NO"
  UPDATE_LATEST_VERSION=""

  if _load_update_cache; then
    [[ "${UPDATE_CHECK_OK:-NO}" == "YES" ]]
    return $?
  fi

  latest="$(_fetch_latest_version_remote)" || {
    UPDATE_CHECK_OK="NO"
    UPDATE_AVAILABLE="NO"
    UPDATE_LATEST_VERSION=""
    _save_update_cache
    return 1
  }

  UPDATE_CHECK_OK="YES"
  UPDATE_LATEST_VERSION="$latest"
  if version_newer_than "$latest" "$VERSION"; then
    UPDATE_AVAILABLE="YES"
  else
    UPDATE_AVAILABLE="NO"
  fi
  _save_update_cache
  return 0
}

maybe_show_update_notice() {
  check_for_update >/dev/null 2>&1 || return 0
  if [[ "$UPDATE_AVAILABLE" == "YES" && -n "$UPDATE_LATEST_VERSION" ]]; then
    echo
    echo "  >>> Update available: ${VERSION} -> ${UPDATE_LATEST_VERSION}  (option 13: update program from GitHub)"
  fi
}

cmd_check_update() {
  need_root
  ensure_dirs
  section "Program update check"
  if ! check_for_update; then
    log "Could not reach GitHub (optional check). Current version: ${VERSION}"
    log "You can continue using the program normally."
    return 0
  fi
  if [[ "$UPDATE_AVAILABLE" == "YES" ]]; then
    ok "New version available: ${UPDATE_LATEST_VERSION} (installed: ${VERSION})"
    log "Run: ssh-tun self-update   or choose menu option 13"
  else
    ok "You are on the latest known version (${VERSION})."
  fi
}

cmd_self_update() {
  local auto_yes="NO" ask tmp new_ver dl_ok
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) auto_yes="YES"; shift ;;
      *) shift ;;
    esac
  done

  need_root
  ensure_dirs
  have_cmd curl || { warn "curl is required for self-update. Current version ${VERSION} unchanged."; return 0; }

  section "Update program from GitHub"

  if ! check_for_update; then
    warn "Could not reach GitHub. Update skipped; current version ${VERSION} is unchanged."
    log "This is optional — the program continues to work normally."
    return 0
  fi

  if [[ "$UPDATE_AVAILABLE" != "YES" ]]; then
    ok "Already up to date (${VERSION})."
    return 0
  fi

  log "Downloading latest script from GitHub (${UPDATE_LATEST_VERSION})..."
  tmp="$(mktemp)"
  dl_ok="NO"
  if curl -fsSL --connect-timeout 10 --max-time 90 "$GITHUB_RAW_URL" -o "$tmp" 2>/dev/null; then
    dl_ok="YES"
  fi
  if [[ "$dl_ok" != "YES" ]]; then
    warn "Download failed (GitHub unreachable?). Current version ${VERSION} unchanged."
    rm -f "$tmp"
    return 0
  fi

  new_ver="$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$tmp" | head -1)"
  if [[ -z "$new_ver" ]] || ! bash -n "$tmp" 2>/dev/null; then
    warn "Downloaded file looks invalid. Update aborted; keeping ${VERSION}."
    rm -f "$tmp"
    return 0
  fi

  if [[ "$auto_yes" != "YES" ]]; then
    prompt_yesno "Install update ${VERSION} -> ${new_ver}?" "YES" ask
    if [[ "$ask" != "YES" ]]; then
      log "Update skipped."
      rm -f "$tmp"
      return 0
    fi
  fi

  install -m 0755 "$tmp" "$BIN_PATH"
  if [[ "$SCRIPT_PATH" != "$BIN_PATH" && -e "$SCRIPT_PATH" ]]; then
    install -m 0755 "$tmp" "$SCRIPT_PATH" 2>/dev/null || true
  fi
  rm -f "$tmp"

  # Refresh runtime assets from the new script (supervisor + systemd template).
  write_supervisor
  write_systemd_template
  systemd_reload

  UPDATE_CHECK_OK="YES"
  UPDATE_AVAILABLE="NO"
  UPDATE_LATEST_VERSION="$new_ver"
  _save_update_cache

  ok "Updated to ${new_ver} at ${BIN_PATH}"
  log "Re-run 'ssh-tun' to use the new version in this shell."
  log "Optional: ssh-tun doctor  or  ssh-tun update <profile>  to refresh running tunnels."
}

ensure_apt() {
  have_cmd apt-get || die "Only Debian/Ubuntu (apt-get) is supported."
}

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

show_prereq_table() {
  section "Prerequisites"
  local pkg mark
  for pkg in "${PREREQ_PKGS[@]}"; do
    if pkg_installed "$pkg"; then
      mark="[INSTALLED]"
    else
      mark="[MISSING]"
    fi
    printf "  %s %s\n" "$mark" "$pkg"
  done
}

install_prereqs_interactive() {
  ensure_apt
  local missing=() installed=() pkg ask_upgrade
  for pkg in "${PREREQ_PKGS[@]}"; do
    if pkg_installed "$pkg"; then
      installed+=("$pkg")
    else
      missing+=("$pkg")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    ok "All prerequisites are already installed."
    prompt_yesno "Do you want to run package upgrades for installed prerequisites?" "NO" ask_upgrade
    if [[ "$ask_upgrade" == "YES" ]]; then
      apt-get update -y >/dev/null
      apt-get install --only-upgrade -y "${installed[@]}"
      ok "Requested upgrades applied."
    else
      log "Upgrade skipped."
    fi
    return 0
  fi

  log "Missing packages: ${missing[*]}"
  apt-get update -y >/dev/null
  apt-get install -y "${missing[@]}"
  ok "Missing prerequisites installed."

  if (( ${#installed[@]} > 0 )); then
    prompt_yesno "Upgrade already-installed prerequisite packages as well?" "NO" ask_upgrade
    if [[ "$ask_upgrade" == "YES" ]]; then
      apt-get install --only-upgrade -y "${installed[@]}"
      ok "Requested upgrades applied."
    fi
  fi
}

write_supervisor() {
  cat >"$SUPERVISOR_PATH" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/etc/ssh-tun"
PROFILES_DIR="${BASE_DIR}/profiles"
ROOT_HOME="$(getent passwd root 2>/dev/null | cut -d: -f6)"
ROOT_HOME="${ROOT_HOME:-/root}"

log()  { echo "$(date -Is) [INFO] $*"; }
warn() { echo "$(date -Is) [WARN] $*" >&2; }

INSTANCE_RAW="${1:-}"
[[ -n "$INSTANCE_RAW" ]] || { echo "[ERR] Missing instance id"; exit 1; }

PROFILE_ID="${INSTANCE_RAW%%__*}"
INSTANCE="${INSTANCE_RAW#*__}"
if [[ "$PROFILE_ID" == "$INSTANCE_RAW" ]]; then
  echo "[ERR] Invalid instance id: $INSTANCE_RAW"
  exit 1
fi

ENV_FILE="${PROFILES_DIR}/${PROFILE_ID}.env"
[[ -r "$ENV_FILE" ]] || { echo "[ERR] Missing profile env: $ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

CORE=""
SOCKS_PORT="$INSTANCE"
if [[ "$INSTANCE" == *"-"* ]]; then
  CORE="${INSTANCE%%-*}"
  SOCKS_PORT="${INSTANCE##*-}"
fi
[[ "$SOCKS_PORT" =~ ^[0-9]+$ ]] || { echo "[ERR] Bad port in instance: $INSTANCE"; exit 1; }

PINNING="${PINNING:-NO}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
KNOWN_HOSTS_FILE="${KNOWN_HOSTS_FILE:-${ROOT_HOME}/.ssh/known_hosts}"
mkdir -p "$(dirname "$KNOWN_HOSTS_FILE")"
touch "$KNOWN_HOSTS_FILE"
chmod 600 "$KNOWN_HOSTS_FILE" || true

HC_URLS="${HC_URLS:-https://www.google.com/generate_204,https://connectivitycheck.gstatic.com/generate_204,https://www.cloudflare.com/cdn-cgi/trace,https://telegram.org/,http://clients3.google.com/generate_204,http://www.msftconnecttest.com/connecttest.txt}"
HC_TIMEOUT="${HC_TIMEOUT:-5}"
HC_RETRIES="${HC_RETRIES:-2}"
HC_INTERVAL="${HC_INTERVAL:-15}"
HC_FAILS_TO_RESTART="${HC_FAILS_TO_RESTART:-3}"
HEARTBEAT_EVERY="${HEARTBEAT_EVERY:-20}"
DEBUG_HEALTHCHECK="${DEBUG_HEALTHCHECK:-NO}"

SOURCE_IP_MODE="${SOURCE_IP_MODE:-auto}"
SOURCE_IPS_MANUAL="${SOURCE_IPS:-}"
SOURCE_IP_REFRESH="${SOURCE_IP_REFRESH:-60}"
SOURCE_IP_CONNECT_TIMEOUT="${SOURCE_IP_CONNECT_TIMEOUT:-12}"
SOURCE_IP_FAILS_TO_SWITCH="${SOURCE_IP_FAILS_TO_SWITCH:-3}"

PUBLIC_IPS=()
PUBLIC_IPS_CSV=""
CURRENT_SOURCE_IP=""
LAST_IP_REFRESH=0
SSH_OPTS=()
DYNF=()
PROBE_HOST="127.0.0.1"
SWITCH_SOURCE=0

ipv6_stack_available() { [[ -e /proc/net/if_inet6 ]]; }

ipv6_loopback_available() {
  [[ -e /proc/net/if_inet6 ]] || return 1
  if command -v ip >/dev/null 2>&1; then
    if ip -6 addr show dev lo 2>/dev/null | grep -q 'inet6 ::1/'; then
      return 0
    fi
    return 1
  fi
  local d=/proc/sys/net/ipv6/conf/lo/disable_ipv6
  [[ -r "$d" ]] || return 1
  [[ "$(cat "$d" 2>/dev/null)" == "0" ]]
}

is_private_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^127\. ]] && return 0
  [[ "$ip" =~ ^10\. ]] && return 0
  [[ "$ip" =~ ^192\.168\. ]] && return 0
  [[ "$ip" =~ ^169\.254\. ]] && return 0
  [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  return 1
}

# Discover global (public) IPv4 addresses, or use a manual list from the profile.
refresh_public_ips() {
  local -a found=() manual=() ip old_csv
  old_csv="$PUBLIC_IPS_CSV"
  found=()

  if [[ -n "${SOURCE_IPS_MANUAL// /}" && "$SOURCE_IP_MODE" != "auto" ]]; then
    IFS=',' read -r -a manual <<< "${SOURCE_IPS_MANUAL// /}"
    for ip in "${manual[@]}"; do
      [[ -n "$ip" ]] || continue
      found+=("$ip")
    done
  elif [[ "$SOURCE_IP_MODE" != "none" ]]; then
    while IFS= read -r ip; do
      [[ -n "$ip" ]] || continue
      is_private_ipv4 "$ip" && continue
      found+=("$ip")
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u)
  fi

  PUBLIC_IPS=("${found[@]}")
  if (( ${#PUBLIC_IPS[@]} > 0 )); then
    PUBLIC_IPS_CSV="$(IFS=,; echo "${PUBLIC_IPS[*]}")"
  else
    PUBLIC_IPS_CSV=""
  fi
  LAST_IP_REFRESH=$SECONDS

  if [[ "$PUBLIC_IPS_CSV" != "$old_csv" && -n "$old_csv$PUBLIC_IPS_CSV" ]]; then
    log "public IP pool changed: was=[${old_csv:-none}] now=[${PUBLIC_IPS_CSV:-none}] instance=$INSTANCE"
  fi
}

maybe_refresh_public_ips() {
  (( SECONDS - LAST_IP_REFRESH >= SOURCE_IP_REFRESH )) || return 0
  refresh_public_ips
}

# Pick a random outbound source IP, optionally excluding the current one.
pick_source_ip() {
  local exclude="${1:-}" pick idx
  refresh_public_ips
  if (( ${#PUBLIC_IPS[@]} == 0 )); then
    CURRENT_SOURCE_IP=""
    return 0
  fi
  if (( ${#PUBLIC_IPS[@]} == 1 )); then
    CURRENT_SOURCE_IP="${PUBLIC_IPS[0]}"
    return 0
  fi
  local -a pool=()
  for ip in "${PUBLIC_IPS[@]}"; do
    [[ "$ip" == "$exclude" ]] && continue
    pool+=("$ip")
  done
  (( ${#pool[@]} > 0 )) || pool=("${PUBLIC_IPS[@]}")
  idx=$((RANDOM % ${#pool[@]}))
  CURRENT_SOURCE_IP="${pool[$idx]}"
}

build_dyn_forwards() {
  DYNF=()
  PROBE_HOST="127.0.0.1"
  case "$BIND_ADDR" in
    127.0.0.1|localhost|loopback|both|dual|"")
      DYNF+=(-D "127.0.0.1:${SOCKS_PORT}")
      if ipv6_loopback_available; then DYNF+=(-D "[::1]:${SOCKS_PORT}"); fi
      PROBE_HOST="127.0.0.1"
      ;;
    0.0.0.0|any|all|"*")
      DYNF+=(-D "0.0.0.0:${SOCKS_PORT}")
      if ipv6_stack_available; then DYNF+=(-D "[::]:${SOCKS_PORT}"); fi
      PROBE_HOST="127.0.0.1"
      ;;
    ::1)
      DYNF+=(-D "[::1]:${SOCKS_PORT}")
      PROBE_HOST="[::1]"
      ;;
    ::)
      DYNF+=(-D "[::]:${SOCKS_PORT}")
      PROBE_HOST="[::1]"
      ;;
    *:*)
      DYNF+=(-D "[${BIND_ADDR}]:${SOCKS_PORT}")
      PROBE_HOST="[${BIND_ADDR}]"
      ;;
    *)
      DYNF+=(-D "${BIND_ADDR}:${SOCKS_PORT}")
      PROBE_HOST="${BIND_ADDR}"
      ;;
  esac
}

build_ssh_opts() {
  build_dyn_forwards
  SSH_OPTS=(
    -F /dev/null
    -N
    "${DYNF[@]}"
    -p "${REMOTE_PORT}"
    -i "${KEY_PATH}"
    -o "IdentitiesOnly=yes"
    -o "Compression=no"
    -o "IPQoS=throughput"
    -o "Ciphers=${CIPHERS}"
    -o "RekeyLimit=${REKEY_LIMIT}"
    -o "ExitOnForwardFailure=yes"
    -o "ServerAliveInterval=${SERVER_ALIVE_INTERVAL}"
    -o "ServerAliveCountMax=${SERVER_ALIVE_COUNTMAX}"
    -o "TCPKeepAlive=yes"
    -o "GSSAPIAuthentication=no"
    -o "StrictHostKeyChecking=accept-new"
    -o "UserKnownHostsFile=${KNOWN_HOSTS_FILE}"
    -o "ConnectTimeout=${SOURCE_IP_CONNECT_TIMEOUT}"
    -o "BatchMode=yes"
    -o "LogLevel=ERROR"
  )
  if [[ -n "$CURRENT_SOURCE_IP" ]]; then
    SSH_OPTS+=(-o "BindAddress=${CURRENT_SOURCE_IP}")
  fi
}

socks_port_listening() {
  ss -lntH "sport = :${SOCKS_PORT}" 2>/dev/null | grep -q .
}

probe_socks_http() {
  local endpoint code
  IFS=',' read -r -a endpoints <<< "$HC_URLS"
  for endpoint in "${endpoints[@]}"; do
    [[ -n "$endpoint" ]] || continue
    code="$(curl -s -o /dev/null -w '%{http_code}' \
      --connect-timeout "$HC_TIMEOUT" --max-time "$HC_TIMEOUT" \
      --retry "$HC_RETRIES" --retry-delay 0 --retry-max-time $((HC_TIMEOUT*HC_RETRIES)) \
      --proxy "socks5h://${PROBE_HOST}:${SOCKS_PORT}" \
      "$endpoint" 2>/dev/null || true)"

    if [[ "$code" == "204" || "$code" == "200" ]]; then
      return 0
    fi
    if [[ "$DEBUG_HEALTHCHECK" == "YES" ]]; then
      warn "HC endpoint failed: port=$SOCKS_PORT source=${CURRENT_SOURCE_IP:-default} endpoint=$endpoint code=${code:-n/a}"
    fi
  done
  return 1
}

SSH_PID=""
start_ssh_bg() {
  if [[ "$PINNING" == "YES" && "$CORE" =~ ^[0-9]+$ ]]; then
    taskset -c "$CORE" ssh "${SSH_OPTS[@]}" "$SSH_TARGET" &
  else
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" &
  fi
  SSH_PID=$!
}

wait_tunnel_ready() {
  local deadline=$((SECONDS + SOURCE_IP_CONNECT_TIMEOUT))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$SSH_PID" >/dev/null 2>&1; then
      return 1
    fi
    if socks_port_listening && probe_socks_http; then
      return 0
    fi
    sleep 1
  done
  return 1
}

kill_ssh() {
  [[ -n "${SSH_PID:-}" ]] || return 0
  kill "$SSH_PID" >/dev/null 2>&1 || true
  wait "$SSH_PID" >/dev/null 2>&1 || true
  SSH_PID=""
}

# Try each available public IP (shuffled) until SSH+SOCKS comes up or all fail.
start_tunnel_with_source_rotation() {
  local -a try_order=() ip i n old_random
  SWITCH_SOURCE=0
  refresh_public_ips

  if (( ${#PUBLIC_IPS[@]} <= 1 )); then
    if (( ${#PUBLIC_IPS[@]} == 1 )); then
      CURRENT_SOURCE_IP="${PUBLIC_IPS[0]}"
    else
      CURRENT_SOURCE_IP=""
    fi
    build_ssh_opts
    start_ssh_bg
    if wait_tunnel_ready; then
      log "tunnel started: profile=${PROFILE_NAME:-$PROFILE_ID} instance=$INSTANCE pid=$SSH_PID source=${CURRENT_SOURCE_IP:-default}"
      return 0
    fi
    warn "tunnel failed: instance=$INSTANCE source=${CURRENT_SOURCE_IP:-default}"
    kill_ssh
    return 1
  fi

  # Spread instances across IPs; re-shuffle on each full rotation pass.
  old_random=$RANDOM
  RANDOM=$(( (SOCKS_PORT * 9973 + ${#PROFILE_ID} * 17) % 32768 ))
  try_order=("${PUBLIC_IPS[@]}")
  for ((i=${#try_order[@]}-1; i>0; i--)); do
    j=$((RANDOM % (i + 1)))
    ip="${try_order[$i]}"
    try_order[$i]="${try_order[$j]}"
    try_order[$j]="$ip"
  done
  RANDOM=$old_random

  if [[ -n "$CURRENT_SOURCE_IP" ]]; then
    local -a rotated=()
    for ip in "${try_order[@]}"; do
      [[ "$ip" == "$CURRENT_SOURCE_IP" ]] && continue
      rotated+=("$ip")
    done
    rotated+=("$CURRENT_SOURCE_IP")
    try_order=("${rotated[@]}")
  fi

  n=${#try_order[@]}
  for ((i=0; i<n; i++)); do
    CURRENT_SOURCE_IP="${try_order[$i]}"
    build_ssh_opts
    start_ssh_bg
    log "trying source=${CURRENT_SOURCE_IP} instance=$INSTANCE pid=$SSH_PID (${i+1}/${n})"
    if wait_tunnel_ready; then
      log "tunnel started: profile=${PROFILE_NAME:-$PROFILE_ID} instance=$INSTANCE pid=$SSH_PID source=$CURRENT_SOURCE_IP"
      return 0
    fi
    warn "source failed: instance=$INSTANCE source=$CURRENT_SOURCE_IP"
    kill_ssh
  done

  CURRENT_SOURCE_IP=""
  build_ssh_opts
  start_ssh_bg
  log "fallback without BindAddress: instance=$INSTANCE pid=$SSH_PID"
  if wait_tunnel_ready; then
    log "tunnel started (no bind): profile=${PROFILE_NAME:-$PROFILE_ID} instance=$INSTANCE pid=$SSH_PID"
    return 0
  fi
  kill_ssh
  return 1
}

cleanup() {
  trap - TERM INT
  kill_ssh
  exit 0
}
trap cleanup TERM INT

SSH_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
FAILS=0
HEARTBEAT_COUNT=0
LAST_STATE="STARTING"

while true; do
  if ! start_tunnel_with_source_rotation; then
    warn "all source IPs failed for instance=$INSTANCE; retry in 5s"
    sleep 5
    continue
  fi

  FAILS=0
  HEARTBEAT_COUNT=0
  LAST_STATE="UP"

  while kill -0 "$SSH_PID" >/dev/null 2>&1; do
    maybe_refresh_public_ips

    if probe_socks_http; then
      FAILS=0
      HEARTBEAT_COUNT=$((HEARTBEAT_COUNT + 1))
      if [[ "$LAST_STATE" != "UP" ]]; then
        log "tunnel recovered: instance=$INSTANCE source=${CURRENT_SOURCE_IP:-default}"
        LAST_STATE="UP"
      fi
      if (( HEARTBEAT_COUNT % HEARTBEAT_EVERY == 0 )); then
        log "tunnel alive: instance=$INSTANCE pid=$SSH_PID source=${CURRENT_SOURCE_IP:-default}"
      fi
    else
      FAILS=$((FAILS + 1))
      LAST_STATE="DEGRADED"
      warn "healthcheck failed: instance=$INSTANCE source=${CURRENT_SOURCE_IP:-default} (${FAILS}/${HC_FAILS_TO_RESTART})"

      if (( FAILS >= SOURCE_IP_FAILS_TO_SWITCH && ${#PUBLIC_IPS[@]} > 1 )); then
        warn "switching outbound source IP after ${FAILS} failures: instance=$INSTANCE was=${CURRENT_SOURCE_IP:-default}"
        pick_source_ip "$CURRENT_SOURCE_IP"
        kill_ssh
        SWITCH_SOURCE=1
        break
      fi

      if (( FAILS >= HC_FAILS_TO_RESTART )); then
        warn "healthcheck threshold reached; restarting instance=$INSTANCE source=${CURRENT_SOURCE_IP:-default}"
        kill_ssh
        break
      fi
    fi
    sleep "$HC_INTERVAL"
  done

  if (( SWITCH_SOURCE == 1 )); then
    SWITCH_SOURCE=0
    sleep 1
    continue
  fi

  if [[ -n "${SSH_PID:-}" ]]; then
    wait "$SSH_PID" >/dev/null 2>&1 || true
    SSH_PID=""
  fi
  if (( ${#PUBLIC_IPS[@]} > 1 )); then
    pick_source_ip "$CURRENT_SOURCE_IP"
    warn "ssh exited: instance=$INSTANCE; try next source=${CURRENT_SOURCE_IP:-default} in 2s"
  else
    warn "ssh exited: instance=$INSTANCE; restart in 2s"
  fi
  sleep 2
done
EOS
  chmod 0755 "$SUPERVISOR_PATH"
}

write_systemd_template() {
  cat >"$SYSTEMD_TEMPLATE" <<EOF
[Unit]
Description=SSH Tunnel Supervisor (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SUPERVISOR_PATH} %i
Restart=always
RestartSec=2
KillMode=control-group
TimeoutStopSec=5
LimitNOFILE=1048576
CPUWeight=200
IOWeight=200

[Install]
WantedBy=multi-user.target
EOF
}

systemd_reload() {
  systemctl daemon-reload
}

ssh_key_opts() {
  local known_hosts="$1"
  cat <<EOF
-o IdentitiesOnly=yes
-o LogLevel=ERROR
-o StrictHostKeyChecking=accept-new
-o UserKnownHostsFile=${known_hosts}
-o ConnectTimeout=10
EOF
}

ssh_pw_opts() {
  local known_hosts="$1"
  cat <<EOF
-o PubkeyAuthentication=no
-o PreferredAuthentications=keyboard-interactive,password
-o KbdInteractiveAuthentication=yes
-o IdentitiesOnly=yes
-o IdentityFile=/dev/null
-o RequestTTY=no
-o LogLevel=ERROR
-o StrictHostKeyChecking=accept-new
-o UserKnownHostsFile=${known_hosts}
-o ConnectTimeout=10
EOF
}

remote_test_key() {
  local user="$1" host="$2" port="$3" key_path="$4" known_hosts="$5"
  local -a key_opts
  mapfile -t key_opts < <(ssh_key_opts "$known_hosts")
  ssh -F /dev/null -T -p "$port" -i "$key_path" -o BatchMode=yes "${key_opts[@]}" "${user}@${host}" "true"
}

remote_password_probe() {
  local user="$1" host="$2" port="$3" known_hosts="$4"
  local -a pw_opts
  mapfile -t pw_opts < <(ssh_pw_opts "$known_hosts")
  ssh -F /dev/null -T -o RequestTTY=no -p "$port" "${pw_opts[@]}" "${user}@${host}" "true"
}

base64_nowrap() {
  local input="${1:-}"
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    [[ -n "$input" ]] && base64 -w0 "$input" || base64 -w0
  else
    [[ -n "$input" ]] && base64 "$input" | tr -d '\n' || base64 | tr -d '\n'
  fi
}

remote_install_pubkey_via_password() {
  local user="$1" host="$2" port="$3" pubkey_path="$4" known_hosts="$5"
  local -a pw_opts
  mapfile -t pw_opts < <(ssh_pw_opts "$known_hosts")
  [[ -r "$pubkey_path" ]] || return 1

  local pub_b64 remote_cmd
  pub_b64="$(base64_nowrap "$pubkey_path")"
  [[ -n "$pub_b64" ]] || return 1

  remote_cmd="PUB_B64='$pub_b64' bash -c 'set -euo pipefail
umask 077
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
pub=\$(printf \"%s\" \"\$PUB_B64\" | base64 -d 2>/dev/null || printf \"%s\" \"\$PUB_B64\" | base64 --decode)
[[ -n \"\$pub\" ]] || exit 1
grep -qxF \"\$pub\" ~/.ssh/authorized_keys || echo \"\$pub\" >> ~/.ssh/authorized_keys
'"

  ssh -F /dev/null -T -o RequestTTY=no -p "$port" "${pw_opts[@]}" "${user}@${host}" "$remote_cmd"
}

write_ssh_config_host() {
  local alias="$1" remote_host="$2" remote_user="$3" remote_port="$4" key_path="$5" known_hosts="$6"
  local cfg="$SSH_CONFIG_FILE"
  local start_marker="# >>> ssh-tun ${alias}"
  local end_marker="# <<< ssh-tun ${alias}"
  local tmp

  mkdir -p "$ROOT_SSH_DIR"
  chmod 700 "$ROOT_SSH_DIR"
  touch "$cfg"
  chmod 600 "$cfg"

  tmp="$(mktemp)"
  awk -v s="$start_marker" -v e="$end_marker" '
    BEGIN { drop = 0 }
    $0 == s { drop = 1; next }
    $0 == e { drop = 0; next }
    drop == 0 { print }
  ' "$cfg" >"$tmp"

  [[ -s "$tmp" ]] && printf '\n' >>"$tmp"
  cat >>"$tmp" <<EOF
$start_marker
Host $alias
  HostName $remote_host
  User $remote_user
  Port $remote_port
  IdentityFile $key_path
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $known_hosts
$end_marker
EOF

  mv "$tmp" "$cfg"
  chmod 600 "$cfg"
}

write_profile_env() {
  local profile="$1" remote_host="$2" remote_port="$3" remote_user="$4" key_path="$5" bind_addr="$6"
  local ports_csv="$7" normal_ports_csv="$8" pinned_ports_csv="$9" pinning="${10}" ciphers="${11}" rekey="${12}" sa_int="${13}" sa_cnt="${14}"
  local known_hosts="${15}" ssh_alias="${16}" profile_enabled="${17}" hc_urls="${18}" hc_timeout="${19}" hc_retries="${20}"
  local hc_interval="${21}" hc_fails="${22}" heartbeat_every="${23}" debug_hc="${24}"
  local source_ip_mode="${25:-auto}" source_ips="${26:-}" source_ip_refresh="${27:-60}"
  local source_ip_connect_timeout="${28:-12}" source_ip_fails_to_switch="${29:-3}"

  local env_file
  env_file="$(profile_env_path "$profile")"

  {
    printf 'PROFILE_NAME=%q\n' "$profile"
    printf 'PROFILE_ENABLED=%q\n' "$profile_enabled"
    printf 'REMOTE_HOST=%q\n' "$remote_host"
    printf 'REMOTE_PORT=%q\n' "$remote_port"
    printf 'REMOTE_USER=%q\n' "$remote_user"
    printf 'KEY_PATH=%q\n' "$key_path"
    printf 'BIND_ADDR=%q\n' "$bind_addr"
    printf 'PORT_SPEC=%q\n' "$ports_csv"
    printf 'NORMAL_PORT_SPEC=%q\n' "$normal_ports_csv"
    printf 'PINNED_PORT_SPEC=%q\n' "$pinned_ports_csv"
    printf 'PINNING=%q\n' "$pinning"
    printf 'CIPHERS=%q\n' "$ciphers"
    printf 'REKEY_LIMIT=%q\n' "$rekey"
    printf 'SERVER_ALIVE_INTERVAL=%q\n' "$sa_int"
    printf 'SERVER_ALIVE_COUNTMAX=%q\n' "$sa_cnt"
    printf 'KNOWN_HOSTS_FILE=%q\n' "$known_hosts"
    printf 'SSH_HOST_ALIAS=%q\n' "$ssh_alias"
    printf 'HC_URLS=%q\n' "$hc_urls"
    printf 'HC_TIMEOUT=%q\n' "$hc_timeout"
    printf 'HC_RETRIES=%q\n' "$hc_retries"
    printf 'HC_INTERVAL=%q\n' "$hc_interval"
    printf 'HC_FAILS_TO_RESTART=%q\n' "$hc_fails"
    printf 'HEARTBEAT_EVERY=%q\n' "$heartbeat_every"
    printf 'DEBUG_HEALTHCHECK=%q\n' "$debug_hc"
    printf 'SOURCE_IP_MODE=%q\n' "$source_ip_mode"
    printf 'SOURCE_IPS=%q\n' "$source_ips"
    printf 'SOURCE_IP_REFRESH=%q\n' "$source_ip_refresh"
    printf 'SOURCE_IP_CONNECT_TIMEOUT=%q\n' "$source_ip_connect_timeout"
    printf 'SOURCE_IP_FAILS_TO_SWITCH=%q\n' "$source_ip_fails_to_switch"
  } >"$env_file"

  chmod 0644 "$env_file"
}

load_profile() {
  local profile="$1" env_file
  env_file="$(profile_env_path "$profile")"
  [[ -r "$env_file" ]] || die "Profile not found: $profile"
  # shellcheck disable=SC1090
  source "$env_file"
}

list_profiles() {
  section "Profiles"
  local found=0 env_file profile enabled state_file unit_count active_count unit
  local port_spec remote_user remote_host remote_port
  local idx=0
  shopt -s nullglob
  for env_file in "$PROFILES_DIR"/*.env; do
    found=1
    idx=$((idx + 1))
    profile="$(basename "$env_file" .env)"
    port_spec="$(profile_get "$env_file" PORT_SPEC)"
    enabled="$(profile_get "$env_file" PROFILE_ENABLED)"; enabled="${enabled:-YES}"
    remote_user="$(profile_get "$env_file" REMOTE_USER)"
    remote_host="$(profile_get "$env_file" REMOTE_HOST)"
    remote_port="$(profile_get "$env_file" REMOTE_PORT)"
    state_file="$(profile_state_path "$profile")"
    unit_count=0
    active_count=0
    if [[ -r "$state_file" ]]; then
      while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        unit_count=$((unit_count + 1))
        if systemctl is-active --quiet "$unit"; then
          active_count=$((active_count + 1))
        fi
      done <"$state_file"
    fi
    printf "  %d) %s (%s) | enabled=%s | active=%s/%s | %s@%s:%s\n" \
      "$idx" "$profile" "$port_spec" "$enabled" "$active_count" "$unit_count" "$remote_user" "$remote_host" "$remote_port"
  done
  shopt -u nullglob
  (( found == 1 )) || echo "  (no profiles yet)"
}

choose_profile_interactive() {
  # NOTE: This function is called via $(...) so its stdout is captured as the
  # selected profile name. All UI output MUST go to stderr, otherwise the menu
  # is swallowed by the command substitution and the user sees no list.
  local -a names=() ports=()
  local env_file item_profile
  shopt -s nullglob
  for env_file in "$PROFILES_DIR"/*.env; do
    item_profile="$(basename "$env_file" .env)"
    names+=("$item_profile")
    ports+=("$(profile_get "$env_file" PORT_SPEC)")
  done
  shopt -u nullglob

  if (( ${#names[@]} == 0 )); then
    warn "No profiles available."
    return 1
  fi

  echo "Profiles:" >&2
  local i ans idx
  for ((i=0; i<${#names[@]}; i++)); do
    echo "  $((i+1))) ${names[$i]} (${ports[$i]})" >&2
  done
  while true; do
    read -r -p "Select profile number (or b to back): " ans || true
    case "${ans:-}" in
      b|B|"")
        return 1
        ;;
    esac
    if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#names[@]} )); then
      idx=$((ans - 1))
      printf '%s\n' "${names[$idx]}"
      return 0
    fi
    warn "Invalid selection. Choose a valid number."
  done
}

build_instances_for_profile() {
  local profile="$1"
  load_profile "$profile"

  local -a normal_ports=() pinned_ports=() legacy_ports=() instances=() unit_instances=()
  local p idx=0 cores core short

  # Backward compatibility:
  # Old profiles may only have PORT_SPEC + PINNING.
  if [[ -n "${NORMAL_PORT_SPEC:-}" || -n "${PINNED_PORT_SPEC:-}" ]]; then
    if [[ -n "${NORMAL_PORT_SPEC:-}" ]]; then
      mapfile -t normal_ports < <(parse_ports_spec "$NORMAL_PORT_SPEC")
    fi
    if [[ -n "${PINNED_PORT_SPEC:-}" ]]; then
      mapfile -t pinned_ports < <(parse_ports_spec "$PINNED_PORT_SPEC")
    fi
  else
    mapfile -t legacy_ports < <(parse_ports_spec "$PORT_SPEC")
    if [[ "${PINNING:-NO}" == "YES" ]]; then
      pinned_ports=("${legacy_ports[@]}")
    else
      normal_ports=("${legacy_ports[@]}")
    fi
  fi
  (( ${#normal_ports[@]} + ${#pinned_ports[@]} > 0 )) || die "Profile has no valid ports: $profile"

  cores="$(nproc)"
  for p in "${normal_ports[@]}"; do
    short="${p}"
    instances+=("$short")
    unit_instances+=("ssh-tun@${profile}__${short}.service")
  done
  for p in "${pinned_ports[@]}"; do
    core=$(( idx % cores ))
    short="${core}-${p}"
    instances+=("$short")
    unit_instances+=("ssh-tun@${profile}__${short}.service")
    idx=$((idx + 1))
  done

  printf '%s\n' "${instances[@]}" >"$TMP_INSTANCES"
  printf '%s\n' "${unit_instances[@]}" >"$TMP_UNIT_INSTANCES"
}

write_farm_unit() {
  local profile="$1"
  local farm_service="ssh-tun-farm-${profile}.service"
  local dropin_dir="/etc/systemd/system/${farm_service}.d"
  local farm_unit="/etc/systemd/system/${farm_service}"

  {
    echo "[Unit]"
    echo "Description=SSH tunnel farm (${profile})"
    echo "After=network-online.target"
    echo "Wants=network-online.target"
    echo
    echo "[Service]"
    echo "Type=oneshot"
    echo "RemainAfterExit=yes"
    echo "ExecStart=/bin/true"
    echo
    echo "[Install]"
    echo "WantedBy=multi-user.target"
  } >"$farm_unit"

  mkdir -p "$dropin_dir"
  {
    echo "[Unit]"
    while IFS= read -r unit; do
      [[ -n "$unit" ]] || continue
      echo "Wants=${unit}"
      echo "After=${unit}"
    done <"$TMP_UNIT_INSTANCES"
  } >"${dropin_dir}/wants.conf"
}

reconcile_instances() {
  local profile="$1"
  local state_file old_file
  state_file="$(profile_state_path "$profile")"
  old_file="$TMP_OLD_UNITS"

  if [[ -r "$state_file" ]]; then
    cp "$state_file" "$old_file"
  else
    : >"$old_file"
  fi

  cp "$TMP_UNIT_INSTANCES" "$state_file"

  while IFS= read -r old; do
    [[ -n "$old" ]] || continue
    if ! grep -qxF "$old" "$state_file"; then
      systemctl disable --now "$old" >/dev/null 2>&1 || true
    fi
  done <"$old_file"
}

deploy_profile() {
  local profile="$1"
  load_profile "$profile"

  # Per-deploy unique temp files so two concurrent deploys never clobber each
  # other's instance/unit lists. Cleaned up on any exit from this function.
  local tag
  tag="$(safe_tag "$profile")"
  TMP_INSTANCES="$(mktemp "${BASE_DIR}/.${tag}.instances.XXXXXX")"
  TMP_UNIT_INSTANCES="$(mktemp "${BASE_DIR}/.${tag}.units.XXXXXX")"
  TMP_OLD_UNITS="$(mktemp "${BASE_DIR}/.${tag}.old.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$TMP_INSTANCES' '$TMP_UNIT_INSTANCES' '$TMP_OLD_UNITS'" RETURN

  build_instances_for_profile "$profile"
  write_farm_unit "$profile"
  write_supervisor
  write_systemd_template
  systemd_reload
  reconcile_instances "$profile"

  local farm_service="ssh-tun-farm-${profile}.service"
  if [[ "${PROFILE_ENABLED:-YES}" == "YES" ]]; then
    systemctl enable --now "$farm_service" >/dev/null 2>&1 || true
    while IFS= read -r unit; do
      [[ -n "$unit" ]] || continue
      systemctl enable --now "$unit" >/dev/null 2>&1 || systemctl restart "$unit" >/dev/null 2>&1 || true
    done <"$TMP_UNIT_INSTANCES"
    ok "Profile deployed and enabled: $profile"
  else
    systemctl disable --now "$farm_service" >/dev/null 2>&1 || true
    while IFS= read -r unit; do
      [[ -n "$unit" ]] || continue
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
    done <"$TMP_UNIT_INSTANCES"
    ok "Profile deployed in disabled state: $profile"
  fi
}

set_profile_enabled() {
  local profile="$1" desired="$2"
  local env_file
  env_file="$(profile_env_path "$profile")"
  [[ -r "$env_file" ]] || die "Profile not found: $profile"
  sed -i -E "s/^PROFILE_ENABLED=.*/PROFILE_ENABLED=${desired}/" "$env_file"
  deploy_profile "$profile"
}

remove_profile() {
  local profile="$1"
  local env_file state_file farm_service unit bind_addr
  local -a ports=()
  env_file="$(profile_env_path "$profile")"
  state_file="$(profile_state_path "$profile")"
  [[ -r "$env_file" ]] || die "Profile not found: $profile"
  # shellcheck disable=SC1090
  source "$env_file"
  bind_addr="${BIND_ADDR:-127.0.0.1}"
  mapfile -t ports < <(parse_ports_spec "${PORT_SPEC:-}" || true)

  if [[ -r "$state_file" ]]; then
    while IFS= read -r unit; do
      [[ -n "$unit" ]] || continue
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
    done <"$state_file"
  fi

  farm_service="ssh-tun-farm-${profile}.service"
  systemctl disable --now "$farm_service" >/dev/null 2>&1 || true

  # Safety cleanup: if any ssh child survives stop (shouldn't with control-group), kill it.
  local p pid comm
  for p in "${ports[@]}"; do
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      comm="$(cat "/proc/${pid}/comm" 2>/dev/null || true)"
      [[ "$comm" == "ssh" ]] || continue
      kill "$pid" >/dev/null 2>&1 || true
    done < <(pgrep -f -- "-D ${bind_addr}:${p}" || true)
  done
  sleep 1
  for p in "${ports[@]}"; do
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      comm="$(cat "/proc/${pid}/comm" 2>/dev/null || true)"
      [[ "$comm" == "ssh" ]] || continue
      kill -9 "$pid" >/dev/null 2>&1 || true
    done < <(pgrep -f -- "-D ${bind_addr}:${p}" || true)
  done

  rm -f "$env_file" "$state_file" "/etc/systemd/system/${farm_service}" "/etc/systemd/system/${farm_service}.d/wants.conf"
  rmdir "/etc/systemd/system/${farm_service}.d" >/dev/null 2>&1 || true
  systemd_reload
  ok "Removed profile: $profile"
}

show_profile_status() {
  local profile="$1" state_file unit
  load_profile "$profile"
  echo "Profile: $profile"
  echo "  Enabled: ${PROFILE_ENABLED:-YES}"
  echo "  Remote : ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}"
  echo "  Ports  : ${PORT_SPEC}"
  echo "  Bind   : ${BIND_ADDR}"
  echo "  Source : ${SOURCE_IP_MODE:-auto} outbound IP rotation (refresh ${SOURCE_IP_REFRESH:-60}s, switch after ${SOURCE_IP_FAILS_TO_SWITCH:-3} HC fails)"

  state_file="$(profile_state_path "$profile")"
  if [[ ! -r "$state_file" ]]; then
    echo "  Units  : not deployed yet"
    return 0
  fi
  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    if systemctl is-active --quiet "$unit"; then
      echo "  [UP]   $unit"
    else
      echo "  [DOWN] $unit"
    fi
  done <"$state_file"
}

show_profile_logs() {
  local profile="$1" follow="${2:-NO}" state_file unit
  state_file="$(profile_state_path "$profile")"
  [[ -r "$state_file" ]] || die "No deployed units for profile: $profile"

  local -a args=(journalctl --no-pager)
  if [[ "$follow" == "YES" ]]; then
    args=(journalctl -f)
  fi

  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    args+=( -u "$unit" )
  done <"$state_file"

  "${args[@]}"
}

validate_profile_name() {
  local profile="$1"
  [[ "$profile" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid profile name. Use only A-Za-z0-9._-"
  # '__' is the reserved delimiter between profile id and instance in systemd
  # instance names (ssh-tun@<profile>__<instance>), so it must not appear here.
  [[ "$profile" != *"__"* ]] || die "Invalid profile name: '__' is reserved and not allowed."
  # Leading dot/dash collide with hidden temp files and getopt-style parsing.
  [[ "$profile" != .* && "$profile" != -* ]] || die "Profile name must not start with '.' or '-'."
}

create_or_update_profile_interactive() {
  local mode="$1" profile="$2"
  local env_file exists overwrite
  validate_profile_name "$profile"
  ensure_dirs

  env_file="$(profile_env_path "$profile")"
  exists="NO"
  [[ -r "$env_file" ]] && exists="YES"

  if [[ "$mode" == "create" && "$exists" == "YES" ]]; then
    prompt_yesno "Profile exists. Overwrite and redeploy?" "NO" overwrite
    [[ "$overwrite" == "YES" ]] || die "Cancelled."
  fi
  if [[ "$mode" == "update" && "$exists" == "NO" ]]; then
    die "Profile not found: $profile"
  fi

  local REMOTE_HOST REMOTE_PORT REMOTE_USER BIND_ADDR PORT_SPEC NORMAL_PORT_SPEC PINNED_PORT_SPEC PINNING OLD_PORT_SPEC OLD_NORMAL_PORT_SPEC OLD_PINNED_PORT_SPEC
  local CIPHERS REKEY_LIMIT SA_INT SA_CNT KEY_PATH GEN_KEY INSTALL_KEY
  local KNOWN_HOSTS_FILE SSH_ALIAS PROFILE_ENABLED
  local HC_URLS HC_TIMEOUT HC_RETRIES HC_INTERVAL HC_FAILS HEARTBEAT_EVERY DEBUG_HC
  local SOURCE_IP_MODE SOURCE_IPS SOURCE_IP_REFRESH SOURCE_IP_CONNECT_TIMEOUT SOURCE_IP_FAILS_TO_SWITCH

  if [[ "$exists" == "YES" ]]; then
    # shellcheck disable=SC1090
    source "$env_file"
    OLD_PORT_SPEC="${PORT_SPEC:-}"
    OLD_NORMAL_PORT_SPEC="${NORMAL_PORT_SPEC:-}"
    OLD_PINNED_PORT_SPEC="${PINNED_PORT_SPEC:-}"
  fi

  section "Profile: $profile"
  prompt_default "Remote host/IP" "${REMOTE_HOST:-}" REMOTE_HOST
  prompt_default "Remote SSH port" "${REMOTE_PORT:-22}" REMOTE_PORT
  prompt_default "Remote SSH user" "${REMOTE_USER:-root}" REMOTE_USER
  # 127.0.0.1 (default) binds BOTH 127.0.0.1 and ::1 when IPv6 is available.
  echo "  (loopback default listens on both 127.0.0.1 and ::1; use 0.0.0.0 for all v4+v6, or a specific IP)"
  prompt_default "Local bind address" "${BIND_ADDR:-127.0.0.1}" BIND_ADDR

  local default_normal_ports="${NORMAL_PORT_SPEC:-4040}"
  local default_pinned_ports
  if [[ -n "${PINNED_PORT_SPEC:-}" ]]; then
    default_pinned_ports="${PINNED_PORT_SPEC}"
  else
    default_pinned_ports="${PORT_SPEC:-1660,1661,1663,1664,1665,1667,1668,1669,1671,1672}"
  fi
  local -a normal_ports=() pinned_ports=() parsed_ports=()
  local -a old_ports=() old_normal_ports=() old_pinned_ports=()
  local ports_ok p
  if [[ "$exists" == "YES" ]]; then
    if [[ -n "${OLD_NORMAL_PORT_SPEC:-}" ]]; then
      mapfile -t old_normal_ports < <(parse_ports_spec "$OLD_NORMAL_PORT_SPEC" || true)
    fi
    if [[ -n "${OLD_PINNED_PORT_SPEC:-}" ]]; then
      mapfile -t old_pinned_ports < <(parse_ports_spec "$OLD_PINNED_PORT_SPEC" || true)
    fi
    if [[ ${#old_normal_ports[@]} -eq 0 && ${#old_pinned_ports[@]} -eq 0 && -n "${OLD_PORT_SPEC:-}" ]]; then
      mapfile -t old_ports < <(parse_ports_spec "$OLD_PORT_SPEC" || true)
      if [[ "${PINNING:-NO}" == "YES" ]]; then
        old_pinned_ports=("${old_ports[@]}")
      else
        old_normal_ports=("${old_ports[@]}")
      fi
    fi
  fi
  while true; do
    prompt_default "Normal SOCKS ports (optional, type 'none' for no normal tunnel)" "$default_normal_ports" NORMAL_PORT_SPEC
    prompt_default "Pinned-per-core SOCKS ports (optional, type 'none' for no pinned tunnel)" "$default_pinned_ports" PINNED_PORT_SPEC
    if [[ "${NORMAL_PORT_SPEC,,}" == "none" ]]; then NORMAL_PORT_SPEC=""; fi
    if [[ "${PINNED_PORT_SPEC,,}" == "none" ]]; then PINNED_PORT_SPEC=""; fi

    normal_ports=()
    pinned_ports=()
    local parse_out
    if [[ -n "${NORMAL_PORT_SPEC// /}" ]]; then
      # mapfile always succeeds, so capture parse output first and check its
      # real exit code; otherwise invalid specs are silently dropped.
      if ! parse_out="$(parse_ports_spec "$NORMAL_PORT_SPEC")" || [[ -z "$parse_out" ]]; then
        warn "Invalid normal ports spec."
        continue
      fi
      mapfile -t normal_ports <<< "$parse_out"
    fi
    if [[ -n "${PINNED_PORT_SPEC// /}" ]]; then
      if ! parse_out="$(parse_ports_spec "$PINNED_PORT_SPEC")" || [[ -z "$parse_out" ]]; then
        warn "Invalid pinned ports spec."
        continue
      fi
      mapfile -t pinned_ports <<< "$parse_out"
    fi

    parsed_ports=("${normal_ports[@]}" "${pinned_ports[@]}")
    if (( ${#parsed_ports[@]} == 0 )); then
      warn "At least one normal or pinned port is required."
      continue
    fi

    if printf '%s\n' "${parsed_ports[@]}" | sort -n | uniq -d | grep -q .; then
      warn "Duplicate ports detected across normal/pinned groups. Remove duplicates."
      continue
    fi

    ports_ok="YES"
    for p in "${parsed_ports[@]}"; do
      if is_local_port_free "$p"; then
        continue
      fi
      if [[ "$exists" == "YES" ]] && (printf '%s\n' "${old_normal_ports[@]}" | grep -qx "$p" || printf '%s\n' "${old_pinned_ports[@]}" | grep -qx "$p"); then
        continue
      fi
      ports_ok="NO"
    done
    if [[ "$ports_ok" == "YES" ]]; then
      break
    fi
    warn "One or more selected ports are already in use. Choose different ports."
    for p in "${parsed_ports[@]}"; do
      if is_local_port_free "$p"; then
        continue
      fi
      if [[ "$exists" == "YES" ]] && (printf '%s\n' "${old_normal_ports[@]}" | grep -qx "$p" || printf '%s\n' "${old_pinned_ports[@]}" | grep -qx "$p"); then
        continue
      fi
      show_port_conflict "$p"
    done
  done
  if (( ${#pinned_ports[@]} > 0 )); then
    PINNING="YES"
  else
    PINNING="NO"
  fi
  PORT_SPEC="$(IFS=,; echo "${parsed_ports[*]}")"

  if [[ -n "${CIPHERS:-}" ]]; then
    prompt_yesno "Change SSH cipher? (current: $CIPHERS)" "NO" overwrite
    if [[ "$overwrite" == "YES" ]]; then
      prompt_cipher_choice CIPHERS
    fi
  else
    prompt_cipher_choice CIPHERS
  fi

  prompt_default "RekeyLimit" "${REKEY_LIMIT:-4G 1h}" REKEY_LIMIT
  prompt_default "ServerAliveInterval" "${SERVER_ALIVE_INTERVAL:-30}" SA_INT
  prompt_default "ServerAliveCountMax" "${SERVER_ALIVE_COUNTMAX:-3}" SA_CNT

  KNOWN_HOSTS_FILE="${KNOWN_HOSTS_FILE:-$KNOWN_HOSTS_FILE_DEFAULT}"
  prompt_default "Known hosts file" "$KNOWN_HOSTS_FILE" KNOWN_HOSTS_FILE

  local host_tag
  host_tag="$(safe_tag "$REMOTE_HOST")"
  prompt_default "SSH private key path" "${KEY_PATH:-${ROOT_SSH_DIR}/id_ed25519_tunnel_${host_tag}_p${REMOTE_PORT}}" KEY_PATH
  prompt_yesno "Generate key if missing?" "YES" GEN_KEY
  prompt_yesno "Install public key on remote using password?" "${INSTALL_KEY:-YES}" INSTALL_KEY

  prompt_default "Health URLs (comma-separated)" "${HC_URLS:-$DEFAULT_HC_URLS}" HC_URLS
  prompt_default "Health timeout (sec)" "${HC_TIMEOUT:-5}" HC_TIMEOUT
  prompt_default "Health retries" "${HC_RETRIES:-2}" HC_RETRIES
  prompt_default "Health interval (sec)" "${HC_INTERVAL:-15}" HC_INTERVAL
  prompt_default "Fails before restart" "${HC_FAILS_TO_RESTART:-3}" HC_FAILS
  prompt_default "Heartbeat every N checks" "${HEARTBEAT_EVERY:-20}" HEARTBEAT_EVERY
  prompt_yesno "Enable detailed health debug logs?" "${DEBUG_HEALTHCHECK:-NO}" DEBUG_HC

  echo "  Outbound IP: auto-detect public IPv4s and rotate per tunnel (BindAddress)."
  echo "  Set SOURCE_IP_MODE=none in the env file to disable; SOURCE_IPS=1.2.3.4,5.6.7.8 for manual list."
  SOURCE_IP_MODE="${SOURCE_IP_MODE:-auto}"
  SOURCE_IPS="${SOURCE_IPS:-}"
  SOURCE_IP_REFRESH="${SOURCE_IP_REFRESH:-60}"
  SOURCE_IP_CONNECT_TIMEOUT="${SOURCE_IP_CONNECT_TIMEOUT:-12}"
  SOURCE_IP_FAILS_TO_SWITCH="${SOURCE_IP_FAILS_TO_SWITCH:-3}"

  prompt_yesno "Enable this profile right after deploy?" "${PROFILE_ENABLED:-YES}" PROFILE_ENABLED

  mkdir -p "$ROOT_SSH_DIR"
  chmod 700 "$ROOT_SSH_DIR"
  touch "$KNOWN_HOSTS_FILE"
  chmod 600 "$KNOWN_HOSTS_FILE" || true

  if [[ ! -f "$KEY_PATH" ]]; then
    if [[ "$GEN_KEY" == "YES" ]]; then
      log "Generating key: $KEY_PATH"
      ssh-keygen -t ed25519 -a 64 -N '' -f "$KEY_PATH" >/dev/null
      ok "Key generated."
    else
      die "Key missing and generation declined."
    fi
  fi
  chmod 600 "$KEY_PATH" || true
  [[ -f "${KEY_PATH}.pub" ]] || die "Missing public key: ${KEY_PATH}.pub"

  SSH_ALIAS="ssh_tun_${profile}"
  write_ssh_config_host "$SSH_ALIAS" "$REMOTE_HOST" "$REMOTE_USER" "$REMOTE_PORT" "$KEY_PATH" "$KNOWN_HOSTS_FILE"

  if [[ "$INSTALL_KEY" == "YES" ]]; then
    local attempt
    for attempt in 1 2 3; do
      log "Password auth probe ${attempt}/3"
      if remote_password_probe "$REMOTE_USER" "$REMOTE_HOST" "$REMOTE_PORT" "$KNOWN_HOSTS_FILE"; then
        ok "Password auth works."
        break
      fi
      [[ "$attempt" -eq 3 ]] && die "Password probe failed after 3 attempts."
    done

    for attempt in 1 2 3; do
      log "Installing pubkey ${attempt}/3"
      if remote_install_pubkey_via_password "$REMOTE_USER" "$REMOTE_HOST" "$REMOTE_PORT" "${KEY_PATH}.pub" "$KNOWN_HOSTS_FILE"; then
        ok "Public key installed."
        break
      fi
      [[ "$attempt" -eq 3 ]] && die "Failed to install key after 3 attempts."
    done
  fi

  if remote_test_key "$REMOTE_USER" "$REMOTE_HOST" "$REMOTE_PORT" "$KEY_PATH" "$KNOWN_HOSTS_FILE"; then
    ok "Key auth test passed."
  else
    warn "Key auth test failed. Tunnel may not start until SSH key access works."
  fi

  write_profile_env "$profile" "$REMOTE_HOST" "$REMOTE_PORT" "$REMOTE_USER" "$KEY_PATH" "$BIND_ADDR" "$PORT_SPEC" \
    "$NORMAL_PORT_SPEC" "$PINNED_PORT_SPEC" "$PINNING" "$CIPHERS" "$REKEY_LIMIT" "$SA_INT" "$SA_CNT" "$KNOWN_HOSTS_FILE" "$SSH_ALIAS" "$PROFILE_ENABLED" \
    "$HC_URLS" "$HC_TIMEOUT" "$HC_RETRIES" "$HC_INTERVAL" "$HC_FAILS" "$HEARTBEAT_EVERY" "$DEBUG_HC" \
    "$SOURCE_IP_MODE" "$SOURCE_IPS" "$SOURCE_IP_REFRESH" "$SOURCE_IP_CONNECT_TIMEOUT" "$SOURCE_IP_FAILS_TO_SWITCH"

  deploy_profile "$profile"
}

LOCAL_SYSCTL_FILE="/etc/sysctl.d/99-ssh-tun.conf"
LOCAL_LIMITS_FILE="/etc/security/limits.d/99-ssh-tun.conf"
REMOTE_SSHD_DROPIN="/etc/ssh/sshd_config.d/99-ssh-tun.conf"
REMOTE_SYSCTL_FILE="/etc/sysctl.d/99-ssh-tun.conf"
NOFILE_LIMIT="1048576"

# Single source of truth for the network tuning, used verbatim on BOTH the
# local host and the remote endpoint so the whole path is symmetric.
# Goal: maximum sustained bandwidth over a high-latency international link for
# many concurrent SSH/SOCKS flows.
#   - BBR + fq: best loss-tolerant congestion control + pacing.
#   - 64 MiB socket buffers: covers a large bandwidth-delay product
#     (e.g. ~1 Gbps at ~500 ms RTT) while still being autotuned per socket.
#   - notsent_lowat: caps unsent data in the local queue -> lower latency and
#     better fairness across the many multiplexed SOCKS streams.
#   - tw_reuse + wide port range: survive heavy short-lived connection churn.
print_sysctl_tuning() {
  cat <<'SYS'
# Managed by ssh-tun. Tuning for many concurrent SSH/SOCKS tunnels.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 131072 67108864
net.core.somaxconn = 16384
net.core.netdev_max_backlog = 32768
net.core.netdev_budget = 600
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
fs.file-max = 4194304
SYS
}

print_sshd_tuning() {
  cat <<'SSHD'
# Managed by ssh-tun (remote endpoint).
AllowTcpForwarding yes
GatewayPorts no
PermitTunnel no
ClientAliveInterval 30
ClientAliveCountMax 3
TCPKeepAlive yes
Compression no
UseDNS no
MaxSessions 100
MaxStartups 200:30:600
SSHD
}

optimize_local() {
  need_root
  section "Local network optimization (max bandwidth)"

  print_sysctl_tuning >"$LOCAL_SYSCTL_FILE"

  # Try to load BBR now and persist the module.
  modprobe tcp_bbr >/dev/null 2>&1 || true
  echo "tcp_bbr" >/etc/modules-load.d/ssh-tun-bbr.conf

  if sysctl --system >/dev/null 2>&1; then
    ok "Applied sysctl tuning ($LOCAL_SYSCTL_FILE)."
  else
    warn "sysctl --system reported issues; check $LOCAL_SYSCTL_FILE."
  fi

  local cc qd
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  if [[ "$cc" == "bbr" ]]; then
    ok "Congestion control active: bbr / qdisc: $qd"
  else
    warn "Congestion control is '$cc' (kernel may lack BBR; >=4.9 required)."
  fi

  # Raise open-file limits so many tunnels/channels don't hit EMFILE.
  cat >"$LOCAL_LIMITS_FILE" <<EOF
# Managed by ssh-tun.
*    soft nofile ${NOFILE_LIMIT}
*    hard nofile ${NOFILE_LIMIT}
root soft nofile ${NOFILE_LIMIT}
root hard nofile ${NOFILE_LIMIT}
EOF
  ok "Wrote open-file limits ($LOCAL_LIMITS_FILE). Re-login for shells to pick it up."

  # Make sure the systemd-managed tunnels also get the high fd limit and the
  # new supervisor that sets IPQoS=throughput.
  write_systemd_template
  write_supervisor
  systemd_reload
  ok "Refreshed unit template (LimitNOFILE=${NOFILE_LIMIT}) and supervisor."
  log "Run 'ssh-tun update <profile>' (or restart units) to apply to running tunnels."
}

# Build ssh args (key auth) for talking to a profile's remote host as admin.
remote_admin_ssh() {
  local profile="$1"; shift
  load_profile "$profile"
  local kh="${KNOWN_HOSTS_FILE:-$KNOWN_HOSTS_FILE_DEFAULT}"
  ssh -F /dev/null -T \
    -p "$REMOTE_PORT" -i "$KEY_PATH" \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$kh" \
    -o LogLevel=ERROR \
    "${REMOTE_USER}@${REMOTE_HOST}" "$@"
}

optimize_remote() {
  local profile="$1"
  load_profile "$profile"
  section "Remote optimization: $profile (${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT})"

  if ! remote_admin_ssh "$profile" "true"; then
    die "Cannot reach remote with key auth. Create/repair the profile first."
  fi

  local SUDO=""
  if [[ "$REMOTE_USER" != "root" ]]; then
    if remote_admin_ssh "$profile" "command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null"; then
      SUDO="sudo "
    else
      warn "Remote user is not root and passwordless sudo is unavailable."
      warn "Skipping remote tuning. Re-run with a root profile or grant sudo."
      return 1
    fi
  fi

  # Push config bodies as base64 to avoid heredoc nesting/quoting pitfalls.
  local sysctl_b64 sshd_b64
  sysctl_b64="$(print_sysctl_tuning | base64_nowrap)"
  sshd_b64="$(print_sshd_tuning | base64_nowrap)"

  # Remote tuning: identical sysctl (BBR/fq + big buffers), an sshd drop-in for
  # keepalive + connection limits, and a systemd drop-in raising LimitNOFILE for
  # the ssh daemon. sshd config is validated with `sshd -t` before any reload.
  # Restarting sshd does NOT drop established tunnels (forked sessions survive),
  # so it is safe and is required for the new LimitNOFILE to take effect.
  local remote_script
  remote_script="$(cat <<EOF
set -e
b64d() { base64 -d 2>/dev/null || base64 --decode; }
${SUDO}mkdir -p /etc/sysctl.d /etc/ssh/sshd_config.d /etc/modules-load.d

printf %s '${sysctl_b64}' | b64d | ${SUDO}tee ${REMOTE_SYSCTL_FILE} >/dev/null
echo tcp_bbr | ${SUDO}tee /etc/modules-load.d/ssh-tun-bbr.conf >/dev/null
${SUDO}modprobe tcp_bbr 2>/dev/null || true
${SUDO}sysctl --system >/dev/null 2>&1 || true

printf %s '${sshd_b64}' | b64d | ${SUDO}tee ${REMOTE_SSHD_DROPIN} >/dev/null

# Detect the ssh daemon unit and raise its open-file limit via a systemd drop-in.
SVC=""
if command -v systemctl >/dev/null 2>&1; then
  for s in ssh sshd; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^\${s}.service"; then SVC="\$s"; break; fi
  done
  if [ -n "\$SVC" ]; then
    ${SUDO}mkdir -p /etc/systemd/system/\${SVC}.service.d
    printf '[Service]\nLimitNOFILE=${NOFILE_LIMIT}\n' | ${SUDO}tee /etc/systemd/system/\${SVC}.service.d/99-ssh-tun.conf >/dev/null
    ${SUDO}systemctl daemon-reload 2>/dev/null || true
  fi
fi

if ${SUDO}sshd -t 2>/tmp/ssh-tun-sshd-test; then
  if [ -n "\$SVC" ]; then
    ${SUDO}systemctl restart "\$SVC" 2>/dev/null || ${SUDO}systemctl reload "\$SVC" 2>/dev/null || true
  else
    ${SUDO}service ssh restart 2>/dev/null || ${SUDO}service sshd restart 2>/dev/null || true
  fi
  echo "REMOTE_OK cc=\$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) qdisc=\$(sysctl -n net.core.default_qdisc 2>/dev/null) svc=\${SVC:-service}"
else
  ${SUDO}rm -f ${REMOTE_SSHD_DROPIN}
  echo "REMOTE_SSHD_INVALID"
  cat /tmp/ssh-tun-sshd-test
  exit 1
fi
EOF
)"

  local out
  if out="$(remote_admin_ssh "$profile" "$remote_script" 2>&1)"; then
    echo "$out"
    ok "Remote optimization applied to $profile."
  else
    echo "$out" >&2
    die "Remote optimization failed for $profile (sshd config left unchanged)."
  fi
}

install_cli() {
  need_root
  ensure_dirs
  install -m 0755 "$SCRIPT_PATH" "$BIN_PATH"
  write_supervisor
  write_systemd_template
  systemd_reload
  ok "Installed CLI: $BIN_PATH"
  ok "Run: ssh-tun"
}

list_profile_names() {
  local -a names=() env_file
  shopt -s nullglob
  for env_file in "$PROFILES_DIR"/*.env; do
    names+=("$(basename "$env_file" .env)")
  done
  shopt -u nullglob
  ((${#names[@]} > 0)) && printf '%s\n' "${names[@]}"
}

clean_ssh_config_entries() {
  local cfg="$SSH_CONFIG_FILE" tmp
  [[ -f "$cfg" ]] || return 0
  tmp="$(mktemp)"
  awk '
    /^# >>> ssh-tun / { drop = 1; next }
    /^# <<< ssh-tun / { drop = 0; next }
    drop == 0 { print }
  ' "$cfg" >"$tmp"
  mv "$tmp" "$cfg"
  chmod 600 "$cfg" 2>/dev/null || true
}

stop_orphan_ssh_tun_units() {
  local unit farm f
  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
  done < <(systemctl list-unit-files 'ssh-tun@*.service' --no-legend --no-pager 2>/dev/null | awk '{print $1}')
  shopt -s nullglob
  for f in /etc/systemd/system/ssh-tun-farm-*.service; do
    systemctl disable --now "$(basename "$f")" >/dev/null 2>&1 || true
    rm -f "$f" "${f}.d/wants.conf"
    rmdir "${f}.d" >/dev/null 2>&1 || true
  done
  shopt -u nullglob
}

remove_local_tuning_files() {
  rm -f "$LOCAL_SYSCTL_FILE" "$LOCAL_LIMITS_FILE" /etc/modules-load.d/ssh-tun-bbr.conf
  if have_cmd sysctl; then
    sysctl --system >/dev/null 2>&1 || true
  fi
}

cmd_uninstall() {
  local auto_yes="NO" keep_tuning="NO" clean_ssh="NO" ask tuning_ask ssh_ask
  local -a profiles=() profile env_file

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) auto_yes="YES"; shift ;;
      --keep-tuning) keep_tuning="YES"; shift ;;
      --clean-ssh-config) clean_ssh="YES"; shift ;;
      *) shift ;;
    esac
  done

  need_root
  section "Uninstall ${APP_NAME} from this server"

  mapfile -t profiles < <(list_profile_names || true)

  echo "This will stop all SSH tunnel services and remove ${APP_NAME} from this host."
  echo
  if (( ${#profiles[@]} > 0 )); then
    echo "  Profiles (${#profiles[@]}): ${profiles[*]}"
  else
    echo "  Profiles: (none)"
  fi
  echo "  Remove: ${BIN_PATH}"
  echo "          ${LIBEXEC_DIR}/"
  echo "          ${BASE_DIR}/"
  echo "          ${SYSTEMD_TEMPLATE}"
  echo "          all ssh-tun@*.service and ssh-tun-farm-*.service units"
  echo
  echo "  SSH private keys in ${ROOT_SSH_DIR} are kept (not deleted)."
  echo

  if [[ "$auto_yes" != "YES" ]]; then
    prompt_yesno "Proceed with uninstall?" "NO" ask
    [[ "$ask" == "YES" ]] || { log "Uninstall cancelled."; return 0; }
  fi

  if [[ "$keep_tuning" != "YES" ]]; then
    if [[ "$auto_yes" != "YES" ]]; then
      prompt_yesno "Also remove local network tuning files (sysctl/limits/BBR module load)?" "NO" tuning_ask
      [[ "$tuning_ask" == "YES" ]] && keep_tuning="NO" || keep_tuning="YES"
    fi
  fi

  if [[ "$clean_ssh" != "YES" && "$auto_yes" != "YES" ]]; then
    prompt_yesno "Remove ssh-tun Host blocks from ${SSH_CONFIG_FILE}?" "NO" ssh_ask
    [[ "$ssh_ask" == "YES" ]] && clean_ssh="YES"
  fi

  log "Stopping and removing profiles..."
  for profile in "${profiles[@]}"; do
    remove_profile "$profile" 2>/dev/null || true
  done

  stop_orphan_ssh_tun_units

  log "Removing program files..."
  rm -f "$BIN_PATH" "$SYSTEMD_TEMPLATE" "$UPDATE_CACHE_FILE"
  rm -rf "$LIBEXEC_DIR" "$BASE_DIR"

  if [[ "$keep_tuning" != "YES" ]]; then
    log "Removing local tuning files..."
    remove_local_tuning_files
  else
    log "Keeping local tuning files (${LOCAL_SYSCTL_FILE}, ${LOCAL_LIMITS_FILE})."
  fi

  if [[ "$clean_ssh" == "YES" ]]; then
    clean_ssh_config_entries
    ok "Removed ssh-tun entries from ${SSH_CONFIG_FILE}."
  fi

  systemd_reload
  ok "Uninstall complete. ${APP_NAME} has been removed from this server."
  if [[ "$SCRIPT_PATH" == "$BIN_PATH" ]]; then
    log "This shell was running the installed binary; the command 'ssh-tun' is no longer available."
  fi
}

cmd_doctor() {
  need_root
  ensure_dirs
  show_prereq_table
  install_prereqs_interactive
  write_supervisor
  write_systemd_template
  systemd_reload
  ok "Runtime assets validated."
}

cmd_create() {
  need_root
  ensure_dirs
  create_or_update_profile_interactive "create" "$1"
}

cmd_update() {
  need_root
  ensure_dirs
  create_or_update_profile_interactive "update" "$1"
}

main_menu() {
  need_root
  ensure_dirs
    local choice profile
  while true; do
    section "${APP_NAME} ${VERSION}"
    show_prereq_table
    maybe_show_update_notice
    echo
    echo "Options:"
    echo "  1) Install/upgrade prerequisites"
    echo "  2) List profiles"
    echo "  3) Create new profile"
    echo "  4) Update existing profile"
    echo "  5) Enable profile"
    echo "  6) Disable profile"
    echo "  7) Delete profile"
    echo "  8) Profile status"
    echo "  9) Profile logs (follow)"
    echo "  10) Install command to /usr/local/bin/ssh-tun"
    echo "  11) Optimize THIS server (network/sysctl/limits)"
    echo "  12) Optimize REMOTE server of a profile (sshd/sysctl)"
    echo "  13) Update program from GitHub (optional)"
    echo "  14) Uninstall ssh-tun from this server"
    echo "  0) Exit"
    echo
    echo "Tip: for profile actions, type 'b' to go back to this menu."

    read -r -p "Choose option: " choice || true
    case "${choice:-}" in
      1) ( cmd_doctor ) || true ;;
      2) ( list_profiles ) || true ;;
      3)
        read -r -p "New profile name (or b to back): " profile || true
        [[ "${profile:-}" == "b" || "${profile:-}" == "B" || -z "${profile:-}" ]] || ( cmd_create "$profile" ) || true
        ;;
      4)
        profile="$(choose_profile_interactive || true)"
        [[ -n "$profile" ]] && ( cmd_update "$profile" ) || true
        ;;
      5)
        profile="$(choose_profile_interactive || true)"
        [[ -n "$profile" ]] && ( set_profile_enabled "$profile" "YES" ) || true
        ;;
      6)
        profile="$(choose_profile_interactive || true)"
        [[ -n "$profile" ]] && ( set_profile_enabled "$profile" "NO" ) || true
        ;;
      7)
        profile="$(choose_profile_interactive || true)"
        [[ -n "$profile" ]] && ( remove_profile "$profile" ) || true
        ;;
      8)
        profile="$(choose_profile_interactive || true)"
        [[ -n "$profile" ]] && ( show_profile_status "$profile" ) || true
        ;;
      9)
        profile="$(choose_profile_interactive || true)"
        [[ -n "$profile" ]] && ( show_profile_logs "$profile" "YES" ) || true
        ;;
      10) ( install_cli ) || true ;;
      11) ( optimize_local ) || true ;;
      12)
        profile="$(choose_profile_interactive || true)"
        [[ -n "$profile" ]] && ( optimize_remote "$profile" ) || true
        ;;
      13) ( cmd_self_update ) || true ;;
      14) ( cmd_uninstall ) || true ;;
      0) break ;;
      *) warn "Invalid option." ;;
    esac

    echo
    read -r -p "Press Enter to continue..." _ || true
  done
}

usage() {
  cat <<EOF
${APP_NAME} ${VERSION}
Usage:
  ssh-tun                         # interactive menu
  ssh-tun install                # install command to /usr/local/bin/ssh-tun
  ssh-tun doctor                 # check/install prereqs + refresh runtime assets
  ssh-tun list                   # list profiles
  ssh-tun create <profile>       # create profile and deploy
  ssh-tun update <profile>       # update profile and redeploy
  ssh-tun enable <profile>       # enable/start profile
  ssh-tun disable <profile>      # disable/stop profile
  ssh-tun delete <profile>       # remove profile and units
  ssh-tun status <profile>       # show detailed status
  ssh-tun logs <profile> [--follow]
  ssh-tun optimize-local         # tune THIS host (BBR/fq, buffers, nofile)
  ssh-tun optimize-remote <profile>  # tune the remote endpoint (sshd/sysctl)
  ssh-tun check-update           # check GitHub for a newer version (optional)
  ssh-tun self-update [--yes]    # download and install latest from GitHub (optional)
  ssh-tun uninstall [--yes] [--keep-tuning] [--clean-ssh-config]
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    "") main_menu ;;
    install) shift; install_cli ;;
    doctor) shift; cmd_doctor ;;
    list) shift; need_root; ensure_dirs; list_profiles ;;
    create) shift; [[ $# -ge 1 ]] || die "Profile name required."; cmd_create "$1" ;;
    update) shift; [[ $# -ge 1 ]] || die "Profile name required."; cmd_update "$1" ;;
    enable) shift; [[ $# -ge 1 ]] || die "Profile name required."; need_root; set_profile_enabled "$1" "YES" ;;
    disable) shift; [[ $# -ge 1 ]] || die "Profile name required."; need_root; set_profile_enabled "$1" "NO" ;;
    delete) shift; [[ $# -ge 1 ]] || die "Profile name required."; need_root; remove_profile "$1" ;;
    status) shift; [[ $# -ge 1 ]] || die "Profile name required."; need_root; show_profile_status "$1" ;;
    logs)
      shift
      [[ $# -ge 1 ]] || die "Profile name required."
      need_root
      if [[ "${2:-}" == "--follow" || "${2:-}" == "-f" ]]; then
        show_profile_logs "$1" "YES"
      else
        show_profile_logs "$1" "NO"
      fi
      ;;
    optimize-local) shift; optimize_local ;;
    optimize-remote) shift; [[ $# -ge 1 ]] || die "Profile name required."; need_root; optimize_remote "$1" ;;
    check-update) shift; cmd_check_update ;;
    self-update) shift; cmd_self_update "$@" ;;
    uninstall) shift; cmd_uninstall "$@" ;;
    -h|--help|help) usage ;;
    *) usage; die "Unknown command: $cmd" ;;
  esac
}

main "$@"