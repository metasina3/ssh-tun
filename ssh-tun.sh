#!/usr/bin/env bash
set -euo pipefail

VERSION="v8"
SCRIPT_PATH="$(readlink -f "$0")"

APP_NAME="ssh-tun"
BIN_PATH="/usr/local/bin/ssh-tun"
BASE_DIR="/etc/ssh-tun"
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

ensure_dirs() {
  mkdir -p "$PROFILES_DIR" "$LIBEXEC_DIR" "$ROOT_SSH_DIR"
  chmod 700 "$ROOT_SSH_DIR"
  touch "$KNOWN_HOSTS_FILE_DEFAULT" "$SSH_CONFIG_FILE"
  chmod 600 "$KNOWN_HOSTS_FILE_DEFAULT" "$SSH_CONFIG_FILE" || true
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

HC_URLS="${HC_URLS:-http://clients3.google.com/generate_204,http://connectivitycheck.gstatic.com/generate_204,http://www.msftconnecttest.com/connecttest.txt}"
HC_TIMEOUT="${HC_TIMEOUT:-5}"
HC_RETRIES="${HC_RETRIES:-2}"
HC_INTERVAL="${HC_INTERVAL:-15}"
HC_FAILS_TO_RESTART="${HC_FAILS_TO_RESTART:-3}"
HEARTBEAT_EVERY="${HEARTBEAT_EVERY:-20}"
DEBUG_HEALTHCHECK="${DEBUG_HEALTHCHECK:-NO}"

SSH_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
SSH_OPTS=(
  -F /dev/null
  -N
  -D "${BIND_ADDR}:${SOCKS_PORT}"
  -p "${REMOTE_PORT}"
  -i "${KEY_PATH}"
  -o "IdentitiesOnly=yes"
  -o "Compression=no"
  -o "Ciphers=${CIPHERS}"
  -o "RekeyLimit=${REKEY_LIMIT}"
  -o "ExitOnForwardFailure=yes"
  -o "ServerAliveInterval=${SERVER_ALIVE_INTERVAL}"
  -o "ServerAliveCountMax=${SERVER_ALIVE_COUNTMAX}"
  -o "TCPKeepAlive=yes"
  -o "GSSAPIAuthentication=no"
  -o "StrictHostKeyChecking=accept-new"
  -o "UserKnownHostsFile=${KNOWN_HOSTS_FILE}"
  -o "ConnectTimeout=10"
  -o "BatchMode=yes"
  -o "LogLevel=ERROR"
)

probe_socks_http() {
  local endpoint code
  IFS=',' read -r -a endpoints <<< "$HC_URLS"
  for endpoint in "${endpoints[@]}"; do
    [[ -n "$endpoint" ]] || continue
    code="$(curl -s -o /dev/null -w '%{http_code}' \
      --connect-timeout "$HC_TIMEOUT" --max-time "$HC_TIMEOUT" \
      --retry "$HC_RETRIES" --retry-delay 0 --retry-max-time $((HC_TIMEOUT*HC_RETRIES)) \
      --proxy "socks5h://${BIND_ADDR}:${SOCKS_PORT}" \
      "$endpoint" 2>/dev/null || true)"

    if [[ "$code" == "204" || "$code" == "200" ]]; then
      return 0
    fi
    if [[ "$DEBUG_HEALTHCHECK" == "YES" ]]; then
      warn "HC endpoint failed: port=$SOCKS_PORT endpoint=$endpoint code=${code:-n/a}"
    fi
  done
  return 1
}

start_ssh_bg() {
  if [[ "$PINNING" == "YES" && "$CORE" =~ ^[0-9]+$ ]]; then
    taskset -c "$CORE" ssh "${SSH_OPTS[@]}" "$SSH_TARGET" &
  else
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" &
  fi
  echo $!
}

FAILS=0
HEARTBEAT_COUNT=0
LAST_STATE="STARTING"

while true; do
  SSH_PID="$(start_ssh_bg)"
  FAILS=0
  HEARTBEAT_COUNT=0
  LAST_STATE="UP"
  log "tunnel started: profile=${PROFILE_NAME:-$PROFILE_ID} instance=$INSTANCE pid=$SSH_PID"
  sleep 1

  while kill -0 "$SSH_PID" >/dev/null 2>&1; do
    if probe_socks_http; then
      FAILS=0
      HEARTBEAT_COUNT=$((HEARTBEAT_COUNT + 1))
      if [[ "$LAST_STATE" != "UP" ]]; then
        log "tunnel recovered: instance=$INSTANCE"
        LAST_STATE="UP"
      fi
      if (( HEARTBEAT_COUNT % HEARTBEAT_EVERY == 0 )); then
        log "tunnel alive: instance=$INSTANCE pid=$SSH_PID"
      fi
    else
      FAILS=$((FAILS + 1))
      LAST_STATE="DEGRADED"
      warn "healthcheck failed: instance=$INSTANCE (${FAILS}/${HC_FAILS_TO_RESTART})"
      if (( FAILS >= HC_FAILS_TO_RESTART )); then
        warn "healthcheck threshold reached; restarting instance=$INSTANCE"
        kill "$SSH_PID" >/dev/null 2>&1 || true
        sleep 1
        break
      fi
    fi
    sleep "$HC_INTERVAL"
  done

  wait "$SSH_PID" >/dev/null 2>&1 || true
  warn "ssh exited: instance=$INSTANCE; restart in 2s"
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
LimitNOFILE=200000

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
  local idx=0
  shopt -s nullglob
  for env_file in "$PROFILES_DIR"/*.env; do
    found=1
    idx=$((idx + 1))
    profile="$(basename "$env_file" .env)"
    # shellcheck disable=SC1090
    source "$env_file"
    enabled="${PROFILE_ENABLED:-YES}"
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
      "$idx" "$profile" "$PORT_SPEC" "$enabled" "$active_count" "$unit_count" "$REMOTE_USER" "$REMOTE_HOST" "$REMOTE_PORT"
  done
  shopt -u nullglob
  (( found == 1 )) || echo "  (no profiles yet)"
}

choose_profile_interactive() {
  local -a names=() ports=()
  local env_file item_profile
  shopt -s nullglob
  for env_file in "$PROFILES_DIR"/*.env; do
    item_profile="$(basename "$env_file" .env)"
    # shellcheck disable=SC1090
    source "$env_file"
    names+=("$item_profile")
    ports+=("${PORT_SPEC:-}")
  done
  shopt -u nullglob

  if (( ${#names[@]} == 0 )); then
    warn "No profiles available."
    return 1
  fi

  echo "Profiles:"
  local i ans idx
  for ((i=0; i<${#names[@]}; i++)); do
    echo "  $((i+1))) ${names[$i]} (${ports[$i]})"
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

  printf '%s\n' "${instances[@]}" >"${BASE_DIR}/.instances.tmp"
  printf '%s\n' "${unit_instances[@]}" >"${BASE_DIR}/.unit_instances.tmp"
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
    done <"${BASE_DIR}/.unit_instances.tmp"
  } >"${dropin_dir}/wants.conf"
}

reconcile_instances() {
  local profile="$1"
  local state_file old_file
  state_file="$(profile_state_path "$profile")"
  old_file="${BASE_DIR}/.old_units.tmp"

  if [[ -r "$state_file" ]]; then
    cp "$state_file" "$old_file"
  else
    : >"$old_file"
  fi

  cp "${BASE_DIR}/.unit_instances.tmp" "$state_file"

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
    done <"${BASE_DIR}/.unit_instances.tmp"
    ok "Profile deployed and enabled: $profile"
  else
    systemctl disable --now "$farm_service" >/dev/null 2>&1 || true
    while IFS= read -r unit; do
      [[ -n "$unit" ]] || continue
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
    done <"${BASE_DIR}/.unit_instances.tmp"
    ok "Profile deployed in disabled state: $profile"
  fi

  rm -f "${BASE_DIR}/.instances.tmp" "${BASE_DIR}/.unit_instances.tmp" "${BASE_DIR}/.old_units.tmp"
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
    if [[ -n "${NORMAL_PORT_SPEC// /}" ]]; then
      if ! mapfile -t normal_ports < <(parse_ports_spec "$NORMAL_PORT_SPEC"); then
        warn "Invalid normal ports spec."
        continue
      fi
    fi
    if [[ -n "${PINNED_PORT_SPEC// /}" ]]; then
      if ! mapfile -t pinned_ports < <(parse_ports_spec "$PINNED_PORT_SPEC"); then
        warn "Invalid pinned ports spec."
        continue
      fi
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

  prompt_default "Health URLs (comma-separated)" "${HC_URLS:-http://clients3.google.com/generate_204,http://connectivitycheck.gstatic.com/generate_204,http://www.msftconnecttest.com/connecttest.txt}" HC_URLS
  prompt_default "Health timeout (sec)" "${HC_TIMEOUT:-5}" HC_TIMEOUT
  prompt_default "Health retries" "${HC_RETRIES:-2}" HC_RETRIES
  prompt_default "Health interval (sec)" "${HC_INTERVAL:-15}" HC_INTERVAL
  prompt_default "Fails before restart" "${HC_FAILS_TO_RESTART:-3}" HC_FAILS
  prompt_default "Heartbeat every N checks" "${HEARTBEAT_EVERY:-20}" HEARTBEAT_EVERY
  prompt_yesno "Enable detailed health debug logs?" "${DEBUG_HEALTHCHECK:-NO}" DEBUG_HC

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
    "$HC_URLS" "$HC_TIMEOUT" "$HC_RETRIES" "$HC_INTERVAL" "$HC_FAILS" "$HEARTBEAT_EVERY" "$DEBUG_HC"

  deploy_profile "$profile"
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
    -h|--help|help) usage ;;
    *) usage; die "Unknown command: $cmd" ;;
  esac
}

main "$@"
