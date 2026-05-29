# ssh-tun

A single-file Bash tool to run and supervise **resilient SSH SOCKS5 tunnel farms** on Debian/Ubuntu.

It turns one or more remote SSH servers into local SOCKS5 proxies, runs each tunnel as a self-healing `systemd` service, spreads many tunnels across CPU cores, and ships one-command **network performance tuning** for both the local host and the remote endpoint.

> Typical use case: a local server (e.g. in a restricted network) that needs many parallel, always-up SOCKS5 proxies to one or more servers abroad, with maximum bandwidth and automatic recovery.

---

## Table of contents

- [Features](#features)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Installation](#installation)
- [Usage](#usage)
  - [Interactive menu](#interactive-menu)
  - [CLI commands](#cli-commands)
- [Profiles](#profiles)
  - [Normal vs pinned ports](#normal-vs-pinned-ports)
  - [Health checks & auto-restart](#health-checks--auto-restart)
- [Performance tuning](#performance-tuning)
- [Using the proxies](#using-the-proxies)
- [File layout](#file-layout)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)
- [Uninstall](#uninstall)
- [License](#license)

---

## Features

- **SOCKS5 proxy farm** – open many `ssh -D` dynamic forwards at once, each on its own local port.
- **Self-healing** – every tunnel runs under a supervisor that performs HTTP health checks through the proxy and restarts the tunnel automatically when it degrades.
- **systemd-native** – one `systemd` instance per port plus a per-profile "farm" unit, so everything survives reboots and crashes.
- **CPU core pinning** – optionally pin tunnels to CPU cores (`taskset`) to spread crypto load across cores on busy hosts.
- **Profiles** – named, editable configurations for different remote servers; create/update/enable/disable/delete from a menu or CLI.
- **Automatic key setup** – generates an `ed25519` key and installs it on the remote via password auth (one-time), then switches to key-only auth.
- **Max-bandwidth optimization** – one command applies BBR + `fq`, large TCP buffers, and high file-descriptor limits on **both** the local host and the remote server (with `sshd -t` validation before reload).
- **Single file, no dependencies to build** – just a Bash script.

## How it works

```
                 ┌──────────────────────── local host ────────────────────────┐
 app / browser   │   127.0.0.1:1660  ──┐                                        │
   │             │   127.0.0.1:1661  ──┤   ssh -D (SOCKS5)                       │
   └─ SOCKS5 ───▶│   127.0.0.1:....  ──┼────────────── encrypted SSH ──────────┐│
                 │   supervisor.sh (health-check + auto-restart, 1 per port)   ││
                 │   systemd: ssh-tun@<profile>__<port>.service                ││
                 └─────────────────────────────────────────────────────────────┘│
                                                                                  ▼
                                                                      ┌── remote server (abroad) ──┐
                                                                      │   sshd → direct-tcpip      │
                                                                      │   out to the internet      │
                                                                      └────────────────────────────┘
```

Each local SOCKS5 port maps to one persistent SSH connection. A lightweight supervisor probes the proxy (`curl` to `generate_204`-style URLs) and restarts the SSH process when it fails repeatedly. `systemd` keeps the supervisor itself alive.

## Requirements

- **OS:** Debian or Ubuntu (uses `apt-get` and `systemd`).
- **Privileges:** root (`sudo -i`).
- **Kernel:** Linux ≥ 4.9 for BBR congestion control (optional, for tuning).
- Packages (auto-installed): `openssh-client`, `curl`, `iproute2`, `ca-certificates`.

## Quick start

```bash
# 1) Download and install the CLI
curl -fsSL https://raw.githubusercontent.com/metasina3/ssh-tun/main/ssh-tun.sh -o ssh-tun.sh
chmod +x ssh-tun.sh
sudo ./ssh-tun.sh install

# 2) Create your first profile (interactive) and deploy it
sudo ssh-tun create myserver

# 3) (Recommended) Tune both ends for maximum bandwidth
sudo ssh-tun optimize-local
sudo ssh-tun optimize-remote myserver
```

That's it — your SOCKS5 proxies are now live on the local ports you chose and will auto-start on boot.

## Installation

Clone or download, then install the command into `/usr/local/bin`:

```bash
git clone https://github.com/metasina3/ssh-tun.git
cd ssh-tun
sudo ./ssh-tun.sh install
```

`install` copies the script to `/usr/local/bin/ssh-tun`, writes the supervisor and the `systemd` template, and reloads `systemd`. After that you can just run `ssh-tun`.

You can also run everything straight from the script without installing:

```bash
sudo ./ssh-tun.sh           # interactive menu
sudo ./ssh-tun.sh create myserver
```

## Usage

### Interactive menu

Run with no arguments for a guided menu:

```bash
sudo ssh-tun
```

```
Options:
  1) Install/upgrade prerequisites
  2) List profiles
  3) Create new profile
  4) Update existing profile
  5) Enable profile
  6) Disable profile
  7) Delete profile
  8) Profile status
  9) Profile logs (follow)
  10) Install command to /usr/local/bin/ssh-tun
  11) Optimize THIS server (network/sysctl/limits)
  12) Optimize REMOTE server of a profile (sshd/sysctl)
  0) Exit
```

### CLI commands

```bash
ssh-tun                          # interactive menu
ssh-tun install                  # install command to /usr/local/bin/ssh-tun
ssh-tun doctor                   # check/install prereqs + refresh runtime assets
ssh-tun list                     # list profiles
ssh-tun create <profile>         # create profile and deploy
ssh-tun update <profile>         # update profile and redeploy
ssh-tun enable <profile>         # enable/start profile
ssh-tun disable <profile>        # disable/stop profile
ssh-tun delete <profile>         # remove profile and units
ssh-tun status <profile>         # show detailed status
ssh-tun logs <profile> [--follow]
ssh-tun optimize-local           # tune THIS host (BBR/fq, buffers, nofile)
ssh-tun optimize-remote <profile> # tune the remote endpoint (sshd/sysctl)
```

## Profiles

A profile describes one remote server and the set of local SOCKS5 ports to open against it. Profiles are stored as `*.env` files under `/etc/ssh-tun/profiles/`.

When you `create` or `update` a profile, the tool will ask for:

| Prompt | Meaning |
| --- | --- |
| Remote host/IP, port, user | The SSH server abroad |
| Local bind address | Usually `127.0.0.1` (use `0.0.0.0` to expose on the LAN — be careful) |
| Normal SOCKS ports | Ports that run as plain tunnels |
| Pinned-per-core SOCKS ports | Ports pinned to CPU cores via `taskset` |
| SSH cipher | `chacha20-poly1305` (default) or AES-GCM/CTR variants |
| Key path / generate / install | Auto-generates `ed25519` and installs it on the remote using a one-time password login |
| Health-check settings | URLs, timeout, retries, interval, fails-before-restart, heartbeat |

> Profile names may use `A–Z a–z 0–9 . _ -`, must not contain `__`, and must not start with `.` or `-`.

### Normal vs pinned ports

- **Normal ports** – simple SOCKS5 tunnels. Good default.
- **Pinned-per-core ports** – each tunnel is bound to a CPU core (round-robin) with `taskset`. Useful when SSH encryption becomes CPU-bound and you want to spread many high-throughput tunnels across cores.

Ports accept comma lists and ranges, e.g. `1660,1661,1670-1675`.

### Health checks & auto-restart

Each tunnel's supervisor periodically sends a request through the SOCKS5 proxy to lightweight connectivity-check URLs. If checks fail `HC_FAILS_TO_RESTART` times in a row, the SSH process is restarted. `systemd` keeps the supervisor running and starts everything on boot.

Watch it live:

```bash
ssh-tun logs myserver --follow
ssh-tun status myserver
```

## Performance tuning

Two optional commands push throughput to the maximum on a high-latency international link. They are **symmetric** — the same network tuning is applied on both ends.

```bash
sudo ssh-tun optimize-local            # the host running the tunnels
sudo ssh-tun optimize-remote myserver  # the server abroad (over SSH)
```

What gets applied:

- **Congestion control:** BBR + `fq` qdisc (loss-tolerant, great for long-fat pipes).
- **Socket buffers:** up to 64 MiB, autotuned per socket, to cover a large bandwidth-delay product.
- **Latency/fairness:** `tcp_notsent_lowat` to curb bufferbloat across many multiplexed streams.
- **Scale:** larger `somaxconn`, backlogs, port range, `tw_reuse`, and `fs.file-max`.
- **File descriptors:** `nofile` raised to 1048576 (limits.d + systemd unit + remote sshd drop-in).
- **SSH daemon (remote):** keepalive, `MaxSessions`/`MaxStartups` raised, `UseDNS no`, `Compression no`.
- **SSH client (local):** `IPQoS=throughput`, compression disabled.

Safety:

- The remote `sshd` config is written as a drop-in (`/etc/ssh/sshd_config.d/99-ssh-tun.conf`) and **validated with `sshd -t` before any reload/restart**. If invalid, it is removed and nothing changes.
- Restarting `sshd` does **not** drop established tunnels (forked sessions survive); it is required only so the new `LimitNOFILE` takes effect.

> After tuning, run `ssh-tun update <profile>` (or restart the units) so running tunnels pick up the new supervisor/limits.

> On very low-RAM VPSs the 64 MiB buffer ceiling is a cap, not a reservation (sockets autotune), but keep an eye on memory under heavy load.

## Using the proxies

Point any SOCKS5-aware client at a local port, e.g. port `1660`:

```bash
# curl
curl --proxy socks5h://127.0.0.1:1660 https://ifconfig.me

# git
git config --global http.proxy socks5h://127.0.0.1:1660

# environment
export ALL_PROXY=socks5h://127.0.0.1:1660
```

Use `socks5h://` (note the `h`) so DNS is resolved on the remote side.

## File layout

| Path | Purpose |
| --- | --- |
| `/usr/local/bin/ssh-tun` | Installed CLI |
| `/etc/ssh-tun/profiles/*.env` | Profile configuration |
| `/etc/ssh-tun/profiles/*.instances` | Deployed unit list per profile |
| `/usr/local/libexec/ssh-tun/supervisor.sh` | Per-tunnel supervisor |
| `/etc/systemd/system/ssh-tun@.service` | systemd template (one instance per port) |
| `/etc/systemd/system/ssh-tun-farm-<profile>.service` | Per-profile group unit |
| `/etc/sysctl.d/99-ssh-tun.conf` | Network tuning |
| `/etc/security/limits.d/99-ssh-tun.conf` | Open-file limits |
| `~/.ssh/id_ed25519_tunnel_*` | Generated tunnel keys |

## Troubleshooting

- **Tunnel won't come up / "Key auth test failed".** Verify you can `ssh` to the remote with the generated key; re-run `ssh-tun update <profile>` to reinstall the key via password.
- **Port already in use.** The creator checks local ports and shows the conflicting process; pick a free port.
- **Health checks always fail but the network works.** The default check URLs may be blocked; set custom `Health URLs` in the profile to an endpoint you can reach through the proxy.
- **BBR not active after tuning.** Your kernel may predate BBR (needs ≥ 4.9) or lack the `tcp_bbr` module.
- **Inspect a single unit:**

```bash
systemctl status 'ssh-tun@myserver__1660.service'
journalctl -u 'ssh-tun@myserver__1660.service' -f
```

## Security notes

- Profiles store connection metadata (host, user, key path) in `/etc/ssh-tun/profiles/` — no passwords are stored.
- Private keys are generated locally with `chmod 600`. Keep `~/.ssh` private.
- Binding SOCKS to `0.0.0.0` exposes an open proxy on your network; prefer `127.0.0.1` unless you front it with a firewall.
- Run as root only; the tool manages `systemd` units and system sysctl/limits.

## Uninstall

```bash
# Remove a profile and its units
sudo ssh-tun delete myserver

# Remove the CLI and runtime assets
sudo rm -f /usr/local/bin/ssh-tun
sudo rm -rf /usr/local/libexec/ssh-tun /etc/ssh-tun
sudo rm -f /etc/systemd/system/ssh-tun@.service
sudo rm -f /etc/sysctl.d/99-ssh-tun.conf /etc/security/limits.d/99-ssh-tun.conf
sudo systemctl daemon-reload
```

## License

Released under the MIT License. See [`LICENSE`](LICENSE) if present, or treat as MIT.
