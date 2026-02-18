#!/usr/bin/env bash
# ssh_socks_farm_installer_v4.sh
# Create & supervise multiple SSH dynamic SOCKS tunnels (one per port), optionally CPU-pinned,
# with robust key installation that NEVER drops into an interactive remote shell.
set -euo pipefail

VERSION="v6"

# ----------------------------- helpers -----------------------------
log()  { echo -e "[INFO] $*"; }
ok()   { echo -e "[OK] $*"; }
warn() { echo -e "[WARN] $*" >&2; }
err()  { echo -e "[ERR] $*" >&2; }

die() { err "$*"; exit 1; }

need_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    die "Run as root (sudo -i)."
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

install_pkgs() {
  local pkgs=("$@")
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y "${pkgs[@]}"
}

prompt_default() {
  # usage: prompt_default "Question" "default" varname
  local q="$1" def="$2" __var="$3"
  local ans
  read -r -p "$q [$def]: " ans || true
  ans="${ans:-$def}"
  printf -v "$__var" "%s" "$ans"
}

prompt_yesno() {
  # usage: prompt_yesno "Question" "YES|NO" varname
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
      "")  warn "Please type yes or no."; ;;
      *)   warn "Invalid answer. Type yes or no."; ;;
    esac
  done
}

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

hr() {
  printf '%s\n' "------------------------------------------------------------"
}

section() {
  echo
  hr
  echo "$1"
  hr
}

prompt_cipher_choice() {
  # usage: prompt_cipher_choice varname
  local __var="$1"
  local -a choices=(
    "chacha20-poly1305@openssh.com"
    "aes128-gcm@openssh.com"
    "aes256-gcm@openssh.com"
    "aes128-ctr"
    "aes256-ctr"
  )
  local default_idx=1 ans idx

  echo
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

base64_nowrap() {
  # Portable-ish base64 no-wrap.
  # usage: base64_nowrap [file]
  local input="${1:-}"
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    if [[ -n "$input" ]]; then
      base64 -w0 "$input"
    else
      base64 -w0
    fi
  else
    if [[ -n "$input" ]]; then
      base64 "$input" | tr -d '\n'
    else
      base64 | tr -d '\n'
    fi
  fi
}

is_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((1 <= $1 && $1 <= 65535))
}

parse_ports_spec() {
  # Accept: "100-150" or "101,104,105" or mix "4040,1660-1665,1667"
  # Prints one port per line (unique, sorted numeric).
  local spec="$1"
  spec="${spec// /}"
  [[ -n "$spec" ]] || return 1
  local tmp out
  tmp="$(mktemp)"
  out="$(mktemp)"
  IFS=',' read -r -a parts <<< "$spec"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
      is_port "$a" || { rm -f "$tmp" "$out"; return 2; }
      is_port "$b" || { rm -f "$tmp" "$out"; return 2; }
      if (( a > b )); then
        local t="$a"; a="$b"; b="$t"
      fi
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

safe_host_tag() {
  # safe for filenames/paths; locale-safe to avoid tr range issues
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._:-' '_' | sed 's/_\+/_/g'
}

safe_alias_tag() {
  # safe for SSH Host alias in ~/.ssh/config
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | sed 's/_\+/_/g'
}

systemd_reload() {
  systemctl daemon-reload
}

# ----------------------------- SSH key install (non-interactive) -----------------------------
ssh_pw_opts() {
  # Options that force password-style auth and prevent agent/pubkey attempts.
  # Include keyboard-interactive because many servers expose password via PAM challenge.
  # Printed as words (for array usage).
  cat <<'OPTS'
-o PubkeyAuthentication=no
-o PreferredAuthentications=keyboard-interactive,password
-o KbdInteractiveAuthentication=yes
-o IdentitiesOnly=yes
-o IdentityFile=/dev/null
-o RequestTTY=no
-o LogLevel=ERROR
-o StrictHostKeyChecking=accept-new
-o UserKnownHostsFile=/root/.ssh/known_hosts
-o ConnectTimeout=10
OPTS
}

ssh_key_opts() {
  # Options for KEY auth (BatchMode=yes should be set by caller when testing).
  cat <<'OPTS'
-o IdentitiesOnly=yes
-o LogLevel=ERROR
-o StrictHostKeyChecking=accept-new
-o UserKnownHostsFile=/root/.ssh/known_hosts
-o ConnectTimeout=10
OPTS
}

ssh_common_opts() {
  # Common non-auth SSH options.
  cat <<'OPTS'
-o LogLevel=ERROR
-o StrictHostKeyChecking=accept-new
-o UserKnownHostsFile=/root/.ssh/known_hosts
-o ConnectTimeout=10
OPTS
}

remote_password_probe() {
  local user="$1" host="$2" port="$3"
  local -a pw_opts
  mapfile -t pw_opts < <(ssh_pw_opts)
  # This is an interactive probe (you will type password in ssh prompt).
  ssh -F /dev/null -T -o RequestTTY=no -p "$port" \
    "${pw_opts[@]}" \
    "${user}@${host}" "true"
}

remote_install_pubkey_via_password() {
  local user="$1" host="$2" port="$3" pubkey_path="$4"
  local -a pw_opts common_opts
  mapfile -t pw_opts < <(ssh_pw_opts)
  mapfile -t common_opts < <(ssh_common_opts)
  [[ -r "$pubkey_path" ]] || return 1

  local pub_b64 tmpdir sock rc remote_cmd
  pub_b64="$(base64_nowrap "$pubkey_path")"
  [[ -n "$pub_b64" ]] || return 1
  tmpdir="$(mktemp -d /tmp/sshcm.XXXXXX)"
  sock="$tmpdir/cm.sock"
  rc=1
  remote_cmd="PUB_B64='$pub_b64' bash -c 'set -euo pipefail
umask 077
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

if pub=\$(printf \"%s\" \"\$PUB_B64\" | base64 -d 2>/dev/null); then
  true
else
  pub=\$(printf \"%s\" \"\$PUB_B64\" | base64 --decode)
fi

[[ -n \"\$pub\" ]] || { echo \"[ERR] decoded pubkey is empty\"; exit 1; }

if grep -qxF \"\$pub\" ~/.ssh/authorized_keys; then
  echo \"[OK] Key already present.\"
else
  echo \"\$pub\" >> ~/.ssh/authorized_keys
  echo \"[OK] Key appended.\"
fi
'"

  # 1) Establish a short-lived multiplex master using password ONCE.
  #    (You will type the password in the ssh prompt.)
  if ssh -F /dev/null -fN -p "$port" -T -o RequestTTY=no \
      -o ControlMaster=yes -o ControlPath="$sock" -o ControlPersist=60 \
      "${pw_opts[@]}" \
      "${user}@${host}"; then
    # 2) Run the remote install through the master; -n ensures we never drop into an interactive shell.
    #    Also avoid login shells (-l) so remote profile scripts can't hijack the session.
    if ssh -F /dev/null -n -T -o RequestTTY=no -p "$port" \
        -o ControlMaster=auto -o ControlPath="$sock" \
        "${common_opts[@]}" \
        "${user}@${host}" \
        "$remote_cmd"; then
      rc=0
    fi
    # Close master.
    ssh -F /dev/null -p "$port" -o ControlPath="$sock" -O exit "${user}@${host}" >/dev/null 2>&1 || true
  fi

  # Fallback: if ControlMaster path failed for any reason, do direct password command once.
  if (( rc != 0 )); then
    if ssh -F /dev/null -T -o RequestTTY=no -p "$port" \
        "${pw_opts[@]}" \
        "${user}@${host}" \
        "$remote_cmd"; then
      rc=0
    fi
  fi

  rm -rf "$tmpdir"
  return "$rc"
}

remote_test_key() {
  local user="$1" host="$2" port="$3" key_path="$4"
  local -a key_opts
  mapfile -t key_opts < <(ssh_key_opts)
  ssh -F /dev/null -T -p "$port" -i "$key_path" -o BatchMode=yes "${key_opts[@]}" "${user}@${host}" "true"
}

# ----------------------------- tuning (local/remote optional) -----------------------------
apply_local_tuning() {
  # Conservative tuning for many local sockets (SOCKS listeners, many conns).
  # Does NOT change congestion control here.
  cat >/etc/sysctl.d/99-ssh-socks-farm.conf <<'EOF'
# ssh socks farm tuning (conservative)
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
EOF
  sysctl --system >/dev/null
  ok "Applied local sysctl tuning (/etc/sysctl.d/99-ssh-socks-farm.conf)."
}

apply_remote_tuning() {
  local user="$1" host="$2" port="$3" key_path="$4"
  local -a key_opts
  mapfile -t key_opts < <(ssh_key_opts)
  # Use KEY auth; if it fails, we skip.
  if ! remote_test_key "$user" "$host" "$port" "$key_path" >/dev/null 2>&1; then
    warn "Remote tuning skipped: key auth not working yet."
    return 0
  fi

  ssh -F /dev/null -T -p "$port" -i "$key_path" -o BatchMode=yes "${key_opts[@]}" "${user}@${host}" \
    "bash -lc 'set -euo pipefail
      echo \"[INFO] Applying remote sysctl tuning...\"
      cat >/etc/sysctl.d/99-ssh-socks-farm.conf <<\"EOF\"
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_mtu_probing = 1
EOF
      sysctl --system >/dev/null || true

      echo \"[INFO] Applying sshd tuning drop-in...\"
      mkdir -p /etc/ssh/sshd_config.d
      cat >/etc/ssh/sshd_config.d/99-ssh-socks-farm.conf <<\"EOF\"
# ssh socks farm tuning
ClientAliveInterval 30
ClientAliveCountMax 3
TCPKeepAlive yes
MaxSessions 1024
# MaxStartups: start:rate:full
MaxStartups 2000:30:2000
EOF

      if systemctl is-active --quiet ssh; then
        systemctl reload ssh || systemctl restart ssh
      elif systemctl is-active --quiet sshd; then
        systemctl reload sshd || systemctl restart sshd
      fi
      echo \"[OK] Remote tuning done.\"
    '"
}

# ----------------------------- systemd + supervisor -----------------------------
write_supervisor() {
  cat >/usr/local/bin/ssh_socks_farm_supervisor.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

ENV_BASE_DIR="/etc/ssh-socks-farm"
LEGACY_ENV_FILE="/etc/ssh-socks-farm.env"

log()  { echo -e "$(date -Is) [INFO] $*"; }
warn() { echo -e "$(date -Is) [WARN] $*" >&2; }

INSTANCE_RAW="${1:-}"
[[ -n "$INSTANCE_RAW" ]] || { echo "[ERR] Missing instance id"; exit 1; }

PROFILE_ID="default"
INSTANCE="$INSTANCE_RAW"
if [[ "$INSTANCE_RAW" == *"__"* ]]; then
  PROFILE_ID="${INSTANCE_RAW%%__*}"
  INSTANCE="${INSTANCE_RAW#*__}"
fi

ENV_FILE="${ENV_BASE_DIR}/${PROFILE_ID}.env"
if [[ ! -r "$ENV_FILE" ]]; then
  if [[ -r "$LEGACY_ENV_FILE" ]]; then
    ENV_FILE="$LEGACY_ENV_FILE"
  else
    echo "[ERR] Missing $ENV_FILE"
    exit 1
  fi
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

CORE=""
SOCKS_PORT=""

if [[ "$INSTANCE" == *"-"* ]]; then
  CORE="${INSTANCE%%-*}"
  SOCKS_PORT="${INSTANCE##*-}"
else
  SOCKS_PORT="$INSTANCE"
fi

if ! [[ "$SOCKS_PORT" =~ ^[0-9]+$ ]]; then
  echo "[ERR] Bad port in instance: $INSTANCE"
  exit 1
fi

PINNING="${PINNING:-NO}"

# Health check target: Google generate_204 (HTTP 204)
HC_URL="${HC_URL:-http://clients3.google.com/generate_204}"
HC_TIMEOUT="${HC_TIMEOUT:-5}"
HC_RETRIES="${HC_RETRIES:-3}"
HC_INTERVAL="${HC_INTERVAL:-15}"
HC_FAILS_TO_RESTART="${HC_FAILS_TO_RESTART:-3}"

SSH_BASE_OPTS=(
  -F /dev/null
  -N
  -D "${BIND_ADDR}:${SOCKS_PORT}"
  -o "IdentitiesOnly=yes"
  -o "Compression=no"
  -o "Ciphers=${CIPHERS}"
  -o "RekeyLimit=${REKEY_LIMIT}"
  -o "ExitOnForwardFailure=yes"
  -o "ServerAliveInterval=${SERVER_ALIVE_INTERVAL}"
  -o "ServerAliveCountMax=${SERVER_ALIVE_COUNTMAX}"
  -o "TCPKeepAlive=yes"
  -o "GSSAPIAuthentication=no"
  -o "LogLevel=ERROR"
  -o "StrictHostKeyChecking=accept-new"
  -o "UserKnownHostsFile=/root/.ssh/known_hosts"
  -o "ConnectTimeout=10"
)
SSH_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
SSH_CONN_OPTS=(
  -p "${REMOTE_PORT}"
  -i "${KEY_PATH}"
  -o "HostName=${REMOTE_HOST}"
  -o "User=${REMOTE_USER}"
)

start_ssh() {
  if [[ "$PINNING" == "YES" && "$CORE" =~ ^[0-9]+$ ]]; then
    log "starting ssh (core=$CORE port=$SOCKS_PORT)"
    exec taskset -c "$CORE" ssh "${SSH_CONN_OPTS[@]}" "${SSH_BASE_OPTS[@]}" "$SSH_TARGET"
  else
    log "starting ssh (port=$SOCKS_PORT)"
    exec ssh "${SSH_CONN_OPTS[@]}" "${SSH_BASE_OPTS[@]}" "$SSH_TARGET"
  fi
}

probe_socks_http() {
  # Returns 0 if ok, 1 if fail.
  # Use socks5h (hostname resolution through proxy) to be robust.
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout "$HC_TIMEOUT" --max-time "$HC_TIMEOUT" \
    --retry "$HC_RETRIES" --retry-delay 0 --retry-max-time $((HC_TIMEOUT*HC_RETRIES)) \
    --proxy "socks5h://${BIND_ADDR}:${SOCKS_PORT}" \
    "$HC_URL" || true)"

  # Accept 204 (generate_204) or 200.
  [[ "$code" == "204" || "$code" == "200" ]]
}

# Supervisor loop:
# - starts ssh
# - periodically checks HTTP through SOCKS
# - if consecutive failures >= threshold, kills ssh and restarts
FAILS=0

while true; do
  # Start ssh in background so we can supervise it.
  if [[ "$PINNING" == "YES" && "$CORE" =~ ^[0-9]+$ ]]; then
    taskset -c "$CORE" ssh "${SSH_CONN_OPTS[@]}" "${SSH_BASE_OPTS[@]}" "$SSH_TARGET" &
  else
    ssh "${SSH_CONN_OPTS[@]}" "${SSH_BASE_OPTS[@]}" "$SSH_TARGET" &
  fi
  SSH_PID=$!
  FAILS=0
  log "ssh started pid=$SSH_PID"

  # Give it a moment to bind.
  sleep 1

  while kill -0 "$SSH_PID" >/dev/null 2>&1; do
    if probe_socks_http; then
      FAILS=0
    else
      FAILS=$((FAILS + 1))
      warn "healthcheck failed ($FAILS/${HC_FAILS_TO_RESTART}) for port $SOCKS_PORT"
      if (( FAILS >= HC_FAILS_TO_RESTART )); then
        warn "restarting ssh for port $SOCKS_PORT"
        kill "$SSH_PID" >/dev/null 2>&1 || true
        # wait a bit for cleanup
        sleep 1
        break
      fi
    fi
    sleep "$HC_INTERVAL"
  done

  # If ssh exited, restart.
  wait "$SSH_PID" >/dev/null 2>&1 || true
  warn "ssh exited for port $SOCKS_PORT; restarting in 2s"
  sleep 2
done
EOS
  chmod 0755 /usr/local/bin/ssh_socks_farm_supervisor.sh
  ok "Wrote supervisor: /usr/local/bin/ssh_socks_farm_supervisor.sh"
}

write_ssh_config_host() {
  local alias="$1" remote_host="$2" remote_user="$3" remote_port="$4" key_path="$5"
  local cfg="/root/.ssh/config"
  local start_marker end_marker tmp
  start_marker="# >>> ssh-socks-farm ${alias}"
  end_marker="# <<< ssh-socks-farm ${alias}"

  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  touch "$cfg"
  chmod 600 "$cfg"

  tmp="$(mktemp)"
  awk -v s="$start_marker" -v e="$end_marker" '
    BEGIN { drop = 0 }
    $0 == s { drop = 1; next }
    $0 == e { drop = 0; next }
    drop == 0 { print }
  ' "$cfg" >"$tmp"

  if [[ -s "$tmp" ]]; then
    printf '\n' >>"$tmp"
  fi

  cat >>"$tmp" <<EOF
$start_marker
Host $alias
  HostName $remote_host
  User $remote_user
  Port $remote_port
  IdentityFile $key_path
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile /root/.ssh/known_hosts
$end_marker
EOF

  mv "$tmp" "$cfg"
  chmod 600 "$cfg"
  ok "Updated SSH config alias: ${alias} (${cfg})"
}

write_env_file() {
  local remote_host="$1" remote_user="$2" remote_port="$3" key_path="$4" bind_addr="$5"
  local ciphers="$6" rekey="$7"
  local sa_int="$8" sa_cnt="$9"
  local pinning="${10}"
  local ssh_host_alias="${11:-}"
  local profile_id="${12:-default}"
  local env_dir="/etc/ssh-socks-farm"
  local env_file="${env_dir}/${profile_id}.env"

  mkdir -p "$env_dir"

  {
    printf 'PROFILE_ID=%q\n' "$profile_id"
    printf 'REMOTE_HOST=%q\n' "$remote_host"
    printf 'REMOTE_USER=%q\n' "$remote_user"
    printf 'REMOTE_PORT=%q\n' "$remote_port"
    printf 'KEY_PATH=%q\n' "$key_path"
    printf 'BIND_ADDR=%q\n' "$bind_addr"
    echo
    printf 'CIPHERS=%q\n' "$ciphers"
    printf 'REKEY_LIMIT=%q\n' "$rekey"
    printf 'SERVER_ALIVE_INTERVAL=%q\n' "$sa_int"
    printf 'SERVER_ALIVE_COUNTMAX=%q\n' "$sa_cnt"
    echo
    printf 'PINNING=%q\n' "$pinning"
    printf 'SSH_HOST_ALIAS=%q\n' "$ssh_host_alias"
    cat <<'EOF'

# Health check settings (edit if needed)
HC_URL=http://clients3.google.com/generate_204
HC_TIMEOUT=5
HC_RETRIES=3
HC_INTERVAL=15
HC_FAILS_TO_RESTART=3
EOF
  } >"$env_file"
  chmod 0644 "$env_file"
  ok "Wrote env: $env_file"
}

write_systemd_units() {
  cat >/etc/systemd/system/ssh-socks@.service <<'EOF'
[Unit]
Description=SSH SOCKS tunnel supervisor (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssh_socks_farm_supervisor.sh %i
Restart=always
RestartSec=2
# avoid killing all children if curl hangs etc; supervisor handles
KillMode=process
TimeoutStopSec=5
# raise fd limit for many local sockets
LimitNOFILE=200000

[Install]
WantedBy=multi-user.target
EOF

  ok "Wrote systemd template: /etc/systemd/system/ssh-socks@.service"
}

write_farm_unit() {
  # Generates a per-profile unit that pulls up all configured instances.
  local profile_id="$1"
  shift
  local instances=("$@")
  local farm_service="ssh-socks-farm-${profile_id}.service"
  FARM_SERVICE_NAME="$farm_service"
  {
    echo "[Unit]"
    echo "Description=SSH SOCKS farm (${profile_id})"
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
  } >"/etc/systemd/system/${farm_service}"

  # Add Wants= via drop-in (cleaner)
  mkdir -p "/etc/systemd/system/${farm_service}.d"
  {
    echo "[Unit]"
    for inst in "${instances[@]}"; do
      echo "Wants=ssh-socks@${inst}.service"
      echo "After=ssh-socks@${inst}.service"
    done
  } >"/etc/systemd/system/${farm_service}.d/wants.conf"

  ok "Wrote farm unit: /etc/systemd/system/${farm_service} (+ drop-in wants.conf)"
}

# ----------------------------- main -----------------------------
main() {
  need_root

  echo
  echo "============================================================"
  echo " SSH SOCKS Farm Installer ${VERSION}"
  echo "============================================================"

  if ! have_cmd apt-get; then
    die "This script currently supports Debian/Ubuntu (apt-get)."
  fi

  section "Step 1/5 - Prerequisites"
  log "Installing prerequisites (openssh-client, autossh, curl, iproute2)..."
  install_pkgs openssh-client autossh curl iproute2 ca-certificates >/dev/null
  ok "Prereqs installed."

  # Inputs
  section "Step 2/5 - Connection & Ports"
  local REMOTE_HOST REMOTE_PORT REMOTE_USER
  prompt_default "Remote host/IP" "65.109.180.169" REMOTE_HOST
  prompt_default "Remote SSH port" "22" REMOTE_PORT
  prompt_default "Remote SSH user" "root" REMOTE_USER

  local BIND_ADDR
  prompt_default "Local bind address for SOCKS" "127.0.0.1" BIND_ADDR

  local PORT_SPEC
  local PORTS=()
  local p ports_ok
  PORT_SPEC="4040,1660,1661,1663,1664,1665,1667,1668,1669,1671,1672"
  while true; do
    prompt_default "SOCKS ports spec (e.g. 100-150 or 101,104,105)" "$PORT_SPEC" PORT_SPEC
    if ! mapfile -t PORTS < <(parse_ports_spec "$PORT_SPEC"); then
      warn "Bad ports spec. Try again."
      continue
    fi
    (( ${#PORTS[@]} > 0 )) || { warn "No ports parsed. Try again."; continue; }

    ports_ok="YES"
    for p in "${PORTS[@]}"; do
      if ! is_local_port_free "$p"; then
        ports_ok="NO"
        break
      fi
    done
    if [[ "$ports_ok" == "YES" ]]; then
      break
    fi

    warn "One or more selected SOCKS ports are already in use:"
    for p in "${PORTS[@]}"; do
      if ! is_local_port_free "$p"; then
        show_port_conflict "$p"
      fi
    done
    warn "Please choose different local SOCKS ports."
  done

  local PINNING
  prompt_yesno "Pin each SSH tunnel to a CPU core (round-robin)?" "YES" PINNING

  local APPLY_LOCAL_TUNE APPLY_REMOTE_TUNE
  prompt_yesno "Apply LOCAL network tuning (sysctl)?" "YES" APPLY_LOCAL_TUNE
  prompt_yesno "Apply REMOTE tuning (sysctl + sshd drop-in) after key works?" "NO" APPLY_REMOTE_TUNE

  # Crypto options
  section "Step 3/5 - Crypto & Keepalive"
  local CIPHERS REKEY_LIMIT SA_INT SA_CNT
  prompt_cipher_choice CIPHERS
  prompt_default "RekeyLimit (bytes time)" "4G 1h" REKEY_LIMIT
  prompt_default "ServerAliveInterval (sec)" "30" SA_INT
  prompt_default "ServerAliveCountMax" "3" SA_CNT

  # Key setup
  section "Step 4/5 - SSH Key & Access"
  local KEY_PATH GEN_KEY INSTALL_KEY
  local host_tag alias_tag profile_tag SSH_HOST_ALIAS PROFILE_ID
  host_tag="$(safe_host_tag "$REMOTE_HOST")"
  alias_tag="$(safe_alias_tag "$REMOTE_HOST")"
  SSH_HOST_ALIAS="sshfarm_${alias_tag}_p${REMOTE_PORT}"
  profile_tag="${alias_tag//./_}"
  PROFILE_ID="farm_${profile_tag}_p${REMOTE_PORT}"
  PROFILE_ID="$(printf '%s' "$PROFILE_ID" | sed 's/_\+/_/g')"
  prompt_default "SSH private key path" "/root/.ssh/id_ed25519_tunnel_${host_tag}_p${REMOTE_PORT}" KEY_PATH
  prompt_yesno "Generate key if missing?" "YES" GEN_KEY
  prompt_yesno "Install public key on remote (one-time, using password)?" "YES" INSTALL_KEY

  mkdir -p /root/.ssh
  chmod 700 /root/.ssh

  if [[ ! -f "$KEY_PATH" ]]; then
    if [[ "$GEN_KEY" == "YES" ]]; then
      log "Generating ed25519 key: $KEY_PATH"
      ssh-keygen -t ed25519 -a 64 -N '' -f "$KEY_PATH" >/dev/null
      ok "Generated key: $KEY_PATH"
    else
      die "Key not found and generation declined."
    fi
  else
    ok "Key exists: $KEY_PATH"
  fi
  chmod 600 "$KEY_PATH" || true
  write_ssh_config_host "$SSH_HOST_ALIAS" "$REMOTE_HOST" "$REMOTE_USER" "$REMOTE_PORT" "$KEY_PATH"

  local PUB_PATH="${KEY_PATH}.pub"
  [[ -f "$PUB_PATH" ]] || die "Missing public key: $PUB_PATH"

  if [[ "$INSTALL_KEY" == "YES" ]]; then
    ok "Password login will be tested (you will type the password in the SSH prompt)."
    local attempt
    for attempt in 1 2 3 4 5; do
      log "Password probe attempt ${attempt}/5 ..."
      if remote_password_probe "$REMOTE_USER" "$REMOTE_HOST" "$REMOTE_PORT"; then
        ok "Password auth OK."
        break
      fi
      warn "Password probe failed."
      if [[ "$attempt" -eq 5 ]]; then
        die "Password login failed after 5 attempts."
      fi
    done

    ok "Installing key on remote (you may be prompted for password again)..."
    for attempt in 1 2 3 4 5; do
      log "Key install attempt ${attempt}/5 ..."
      if remote_install_pubkey_via_password "$REMOTE_USER" "$REMOTE_HOST" "$REMOTE_PORT" "$PUB_PATH"; then
        ok "Key installed on remote."
        break
      fi
      warn "Key install failed (attempt ${attempt}/5)."
      if [[ "$attempt" -eq 5 ]]; then
        die "Failed to install key after 5 attempts."
      fi
    done

    log "Testing key auth..."
    if remote_test_key "$REMOTE_USER" "$REMOTE_HOST" "$REMOTE_PORT" "$KEY_PATH"; then
      ok "Key auth works."
    else
      warn "Key auth test FAILED. You may need to check remote sshd or authorized_keys."
    fi
  else
    warn "Skipped remote key install."
  fi

  if [[ "$APPLY_LOCAL_TUNE" == "YES" ]]; then
    apply_local_tuning
  fi

  section "Step 5/5 - Deploy Services"
  # Write env + supervisor + systemd
  write_env_file "$REMOTE_HOST" "$REMOTE_USER" "$REMOTE_PORT" "$KEY_PATH" "$BIND_ADDR" "$CIPHERS" "$REKEY_LIMIT" "$SA_INT" "$SA_CNT" "$PINNING" "$SSH_HOST_ALIAS" "$PROFILE_ID"
  write_supervisor
  write_systemd_units
  systemd_reload

  local CORES
  CORES="$(nproc)"
  log "Detected CPU cores: $CORES"

  # Prepare instances (core-port if pinning else port) and profile-bound unit instance ids.
  local instances=()
  local unit_instances=()
  local idx=0
  for p in "${PORTS[@]}"; do
    local short_inst
    if [[ "$PINNING" == "YES" ]]; then
      local core=$(( idx % CORES ))
      short_inst="${core}-${p}"
    else
      short_inst="${p}"
    fi
    instances+=("${short_inst}")
    unit_instances+=("${PROFILE_ID}__${short_inst}")
    idx=$((idx+1))
  done

  local FARM_SERVICE_NAME
  write_farm_unit "$PROFILE_ID" "${unit_instances[@]}"
  systemd_reload

  # Enable and start everything via the farm service
  systemctl enable --now "$FARM_SERVICE_NAME" >/dev/null 2>&1 || true
  ok "Enabled+started: ${FARM_SERVICE_NAME}"

  # Start instances explicitly (to ensure immediate start even if systemd ordering is slow)
  for inst in "${unit_instances[@]}"; do
    systemctl enable --now "ssh-socks@${inst}.service" >/dev/null 2>&1 || systemctl start "ssh-socks@${inst}.service" >/dev/null 2>&1 || true
  done
  ok "Started ${#unit_instances[@]} tunnel instance(s)."

  if [[ "$APPLY_REMOTE_TUNE" == "YES" ]]; then
    log "Applying remote tuning (requires key auth)."
    apply_remote_tuning "$REMOTE_USER" "$REMOTE_HOST" "$REMOTE_PORT" "$KEY_PATH" || true
  fi

  local env_file_path ports_csv instances_csv unit_instances_csv ports_regex sample_instance
  env_file_path="/etc/ssh-socks-farm/${PROFILE_ID}.env"
  ports_csv="$(IFS=,; echo "${PORTS[*]}")"
  instances_csv="$(IFS=,; echo "${instances[*]}")"
  unit_instances_csv="$(IFS=,; echo "${unit_instances[*]}")"
  ports_regex="$(printf '%s|' "${PORTS[@]}")"
  ports_regex="${ports_regex%|}"
  sample_instance="${unit_instances[0]:-}"

  section "Completed"
  echo "Setup summary:"
  echo "  Profile ID           : ${PROFILE_ID}"
  echo "  Remote target        : ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}"
  echo "  SSH config alias     : ${SSH_HOST_ALIAS}"
  echo "  SSH config file      : /root/.ssh/config"
  echo "  Env file             : ${env_file_path}"
  echo "  SSH private key      : ${KEY_PATH}"
  echo "  Local bind           : ${BIND_ADDR}"
  echo "  SOCKS ports          : ${ports_csv}"
  echo "  Instance IDs         : ${instances_csv}"
  echo "  Unit instances       : ${unit_instances_csv}"
  echo "  Farm service         : ${FARM_SERVICE_NAME}"
  echo "  Cipher               : ${CIPHERS}"
  echo "  RekeyLimit           : ${REKEY_LIMIT}"
  echo "  ServerAlive          : interval=${SA_INT}s countmax=${SA_CNT}"
  echo "  CPU pinning          : ${PINNING}"
  echo "  Local tuning         : ${APPLY_LOCAL_TUNE}"
  echo "  Remote tuning        : ${APPLY_REMOTE_TUNE}"
  echo "  Healthcheck URL      : http://clients3.google.com/generate_204"
  echo
  echo "Useful commands:"
  echo "  ssh ${SSH_HOST_ALIAS} 'hostname -f'"
  echo "  systemctl status ${FARM_SERVICE_NAME}"
  echo "  systemctl --no-pager --full status 'ssh-socks@*'"
  if [[ -n "$sample_instance" ]]; then
    echo "  journalctl -u ssh-socks@${sample_instance} -f --no-pager"
  fi
  if [[ -n "$ports_regex" ]]; then
    echo "  ss -lntp | egrep ':(${ports_regex})\\b'"
  fi
}

main "$@"
