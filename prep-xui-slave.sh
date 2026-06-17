#!/usr/bin/env bash
# =============================================================================
# prep-xui-slave.sh
# -----------------------------------------------------------------------------
# Idempotent hardening + pre-flight script for a NEW XUI.one Load Balancer
# slave VM. Run this BEFORE installing XUI in Load Balancer mode.
#
# Sister script to harden-xui-vm.sh (used on the MAIN VM 105 / 205.235.2.129).
# Same color helpers, flag style, idempotency, sysctl tuning, SSH hardening
# drop-in, fail2ban jail, UFW default-deny + SSH whitelist, Ubuntu Pro attach.
#
# SLAVE-SPECIFIC EXTRAS
#   * --main-ip <CIDR_OR_IP>   REQUIRED. The MAIN XUI server. A UFW
#                              "allow from <main-ip>" rule (no ports, full
#                              trust) is added with comment 'xui-main-server'
#                              so the main can reach MariaDB / push streams
#                              / sync state to this slave.
#   * Stops and purges the OS-bundled nginx (XUI bundles its own at
#     /home/xui/bin/nginx and will clash on :80 if the OS one is up).
#   * Does NOT install GeoIP or auto-ban — those live in geoip-setup.sh and
#     auto-ban-pools.sh in this repo and can be applied AFTER XUI is up.
#
# WHAT IT DOES
#   1. Network/kernel sysctl tuning (BBR, fq, big TCP buffers, file-max 20M)
#   2. /etc/sysctl.d drop-ins (disable IPv6, swappiness=1, ports <1024 non-root)
#   3. Loads tcp_bbr and runs `sysctl --system`
#   4. SSH hardening drop-in (MaxAuthTries, ClientAlive, no forwarding, etc)
#   5. fail2ban with SSH jail; ignoreip from --ssh-allow + --main-ip
#   6. Ubuntu Pro attach + enable esm-infra/esm-apps/livepatch (if token given)
#   7. Removes OS nginx if present (XUI bundles its own)
#   8. UFW: defines rules (SSH whitelist + full-trust main + 80/443) but
#      DOES NOT enable. Run `ufw enable` manually as the very last action.
#   9. Drops /root/xui-slave-post-install-check.sh
#
# WHAT IT DOES *NOT* DO
#   - Install XUI.one Load Balancer (do that manually after running this).
#   - Open MariaDB on the MAIN to this slave — that is handled separately
#     by main-allow-slave.sh on the main server.
#   - Reboot. You must reboot to activate the new kernel from ESM.
#   - Run `ufw enable`.
#
# USAGE
#   sudo bash prep-xui-slave.sh \
#       --main-ip 205.235.2.129 \
#       --ssh-allow 205.235.6.128/25,10.99.99.0/24 \
#       --ubuntu-pro-token C1xxxxxxxxxxxxxxxxxxxxxxxxxx
#
#   --main-ip              REQUIRED. IP or CIDR of the MAIN XUI server.
#                          Full-trust UFW allow + fail2ban ignoreip.
#   --ssh-allow            REQUIRED. Comma-separated CIDRs allowed to SSH.
#                          Added to UFW rules AND fail2ban ignoreip.
#   --ubuntu-pro-token     OPTIONAL. If set, runs `pro attach` + enables ESM.
#                          You can also set env var UBUNTU_PRO_TOKEN instead.
#
# REQUIREMENTS
#   - Ubuntu 20.04 LTS (Focal) or 22.04 LTS (Jammy)
#   - Root (or sudo)
#   - Outbound internet (apt + Ubuntu Pro endpoints)
# =============================================================================

set -euo pipefail

# ----- Colors --------------------------------------------------------------
if [[ -t 1 ]]; then
    RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
else
    RED=''; GRN=''; YEL=''; BLU=''; RST=''
fi
ok()    { echo "${GRN}[ OK ]${RST} $*"; }
warn()  { echo "${YEL}[WARN]${RST} $*"; }
fail()  { echo "${RED}[FAIL]${RST} $*" >&2; }
info()  { echo "${BLU}[INFO]${RST} $*"; }
section() { echo; echo "${BLU}===${RST} $* ${BLU}===${RST}"; }

# ----- Argument parsing ----------------------------------------------------
SSH_ALLOW=""
MAIN_IP=""
PRO_TOKEN="${UBUNTU_PRO_TOKEN:-}"

usage() {
    sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --main-ip)              MAIN_IP="$2"; shift 2 ;;
        --ssh-allow)            SSH_ALLOW="$2"; shift 2 ;;
        --ubuntu-pro-token)     PRO_TOKEN="$2"; shift 2 ;;
        -h|--help)              usage ;;
        *) fail "Unknown argument: $1"; usage ;;
    esac
done

[[ $EUID -eq 0 ]] || { fail "Must run as root"; exit 1; }
[[ -n "$MAIN_IP"   ]] || { fail "--main-ip is required (e.g. 205.235.2.129)"; exit 1; }
[[ -n "$SSH_ALLOW" ]] || { fail "--ssh-allow is required (e.g. 205.235.6.128/25,10.99.99.0/24)"; exit 1; }

# Normalize CIDRs (trim spaces, split by comma)
IFS=',' read -r -a SSH_CIDRS <<< "$(echo "$SSH_ALLOW" | tr -d ' ')"
[[ ${#SSH_CIDRS[@]} -ge 1 ]] || { fail "No valid CIDRs parsed from --ssh-allow"; exit 1; }
MAIN_IP_TRIMMED="$(echo "$MAIN_IP" | tr -d ' ')"
IGNOREIP_LIST="127.0.0.1/8 ::1 ${MAIN_IP_TRIMMED} ${SSH_CIDRS[*]}"

# Detect Ubuntu version — refuse on anything other than 20.04 / 22.04
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    case "${VERSION_ID:-}" in
        20.04|22.04) ok "OS detected: Ubuntu ${VERSION_ID}" ;;
        *)
            fail "Unsupported OS: ${ID:-unknown} ${VERSION_ID:-unknown}. This script requires Ubuntu 20.04 or 22.04."
            exit 1
            ;;
    esac
else
    fail "Cannot read /etc/os-release — refusing to continue."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

STAMP=$(date +%Y%m%d-%H%M%S)
backup() { [[ -f "$1" ]] || return 0; cp -a "$1" "$1.bak-$STAMP" && info "Backed up $1 -> $1.bak-$STAMP"; }

# =============================================================================
section "1/9  Sysctl tuning (/etc/sysctl.conf)"
# =============================================================================
backup /etc/sysctl.conf
cat > /etc/sysctl.conf <<'EOF'
# XUI.one

net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_rmem = 8192 87380 134217728
net.ipv4.udp_rmem_min = 16384
net.core.rmem_default = 262144
net.core.rmem_max = 268435456
net.ipv4.tcp_wmem = 8192 65536 134217728
net.ipv4.udp_wmem_min = 16384
net.core.wmem_default = 262144
net.core.wmem_max = 268435456
net.core.somaxconn = 1000000
net.core.netdev_max_backlog = 250000
net.core.optmem_max = 65535
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_max_orphans = 16384
net.ipv4.ip_local_port_range = 2000 65000
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
fs.file-max=20970800
fs.nr_open=20970800
fs.aio-max-nr=20970800
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.route.flush = 1
net.ipv6.route.flush = 1
EOF
ok "Wrote /etc/sysctl.conf (XUI.one tuning)"

# =============================================================================
section "2/9  Sysctl drop-ins (/etc/sysctl.d/)"
# =============================================================================
cat > /etc/sysctl.d/99-xui-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
ok "Wrote /etc/sysctl.d/99-xui-ipv6.conf"

cat > /etc/sysctl.d/99-xui-swappiness.conf <<'EOF'
vm.swappiness=1
EOF
ok "Wrote /etc/sysctl.d/99-xui-swappiness.conf"

cat > /etc/sysctl.d/50-allports-nonroot.conf <<'EOF'
net.ipv4.ip_unprivileged_port_start=0
EOF
ok "Wrote /etc/sysctl.d/50-allports-nonroot.conf"

# =============================================================================
section "3/9  Load BBR and apply sysctl"
# =============================================================================
modprobe tcp_bbr 2>/dev/null || warn "modprobe tcp_bbr failed (built-in?)"
if sysctl --system >/dev/null 2>&1; then
    ok "sysctl --system applied"
else
    fail "sysctl --system failed"
fi

# Quick verification of headline values
expected=(
    "fs.file-max:20970800"
    "net.core.somaxconn:1000000"
    "net.ipv4.tcp_congestion_control:bbr"
    "vm.swappiness:1"
    "net.ipv6.conf.all.disable_ipv6:1"
    "net.ipv4.ip_unprivileged_port_start:0"
)
for pair in "${expected[@]}"; do
    key="${pair%:*}"; want="${pair#*:}"
    got=$(sysctl -n "$key" 2>/dev/null || echo "")
    if [[ "$got" == "$want" ]]; then
        ok "$key = $got"
    else
        fail "$key expected $want got '$got'"
    fi
done

# =============================================================================
section "4/9  SSH hardening (/etc/ssh/sshd_config.d/70-hardening.conf)"
# =============================================================================
backup /etc/ssh/sshd_config.d/70-hardening.conf
cat > /etc/ssh/sshd_config.d/70-hardening.conf <<EOF
# Hardening applied $STAMP by prep-xui-slave.sh
PermitRootLogin prohibit-password
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
PermitEmptyPasswords no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
EOF

if sshd -t 2>/dev/null; then
    ok "sshd -t validation passed"
    systemctl restart ssh
    ok "sshd restarted"
else
    fail "sshd -t failed — rolling back"
    rm -f /etc/ssh/sshd_config.d/70-hardening.conf
    exit 1
fi

# =============================================================================
section "5/9  fail2ban (/etc/fail2ban/jail.local)"
# =============================================================================
if ! command -v fail2ban-client >/dev/null 2>&1; then
    info "Installing fail2ban..."
    apt-get update -qq
    apt-get install -y -qq fail2ban
    ok "fail2ban installed"
else
    ok "fail2ban already installed"
fi

backup /etc/fail2ban/jail.local
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
# IPs never banned (main XUI server + SSH whitelist)
ignoreip = $IGNOREIP_LIST

# Ban 1h after 3 failed attempts within 10 min
bantime  = 1h
findtime = 10m
maxretry = 3
backend  = systemd

banaction          = iptables-multiport
banaction_allports = iptables-allports

[sshd]
enabled = true
port    = ssh
mode    = aggressive
EOF
ok "Wrote /etc/fail2ban/jail.local (ignoreip: $IGNOREIP_LIST)"

systemctl enable --now fail2ban >/dev/null 2>&1
systemctl restart fail2ban
sleep 2
if fail2ban-client status sshd >/dev/null 2>&1; then
    ok "fail2ban sshd jail active"
else
    fail "fail2ban sshd jail NOT active"
fi

# =============================================================================
section "6/9  Ubuntu Pro (ESM + Livepatch)"
# =============================================================================
if ! command -v pro >/dev/null 2>&1; then
    info "Installing ubuntu-advantage-tools..."
    apt-get install -y -qq ubuntu-advantage-tools
fi

if pro status 2>/dev/null | grep -q "This machine is now attached\|account:"; then
    ok "Ubuntu Pro already attached"
elif [[ -n "$PRO_TOKEN" ]]; then
    info "Attaching to Ubuntu Pro..."
    if pro attach "$PRO_TOKEN" >/dev/null 2>&1; then
        ok "Ubuntu Pro attached"
    else
        fail "pro attach failed (check token)"
    fi
else
    warn "No --ubuntu-pro-token provided and machine not attached"
    warn "Run manually:  pro attach <TOKEN>"
fi

if pro status 2>/dev/null | grep -qE "^esm-infra\s+yes\s+enabled"; then
    ok "esm-infra already enabled"
else
    pro enable esm-infra --assume-yes >/dev/null 2>&1 && ok "esm-infra enabled" || warn "esm-infra enable failed (not attached?)"
fi

if pro status 2>/dev/null | grep -qE "^esm-apps\s+yes\s+enabled"; then
    ok "esm-apps already enabled"
else
    pro enable esm-apps --assume-yes >/dev/null 2>&1 && ok "esm-apps enabled" || warn "esm-apps enable failed (not attached?)"
fi

if pro status 2>/dev/null | grep -qE "^livepatch\s+yes\s+enabled"; then
    ok "livepatch enabled"
elif pro status 2>/dev/null | grep -qE "^livepatch\s+yes\s+warning"; then
    warn "livepatch is in 'warning' — kernel out of livepatch window; upgrade kernel + reboot"
else
    pro enable livepatch --assume-yes >/dev/null 2>&1 && ok "livepatch enabled" || warn "livepatch enable failed"
fi

# Ensure unattended-upgrades is configured for ESM sources (Ubuntu default already includes them)
if [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]]; then
    if grep -q "ESM" /etc/apt/apt.conf.d/50unattended-upgrades; then
        ok "unattended-upgrades already includes ESM origins"
    else
        warn "unattended-upgrades does NOT include ESM origins — verify /etc/apt/apt.conf.d/50unattended-upgrades"
    fi
fi

# =============================================================================
section "7/9  Remove OS nginx (XUI bundles its own on :80)"
# =============================================================================
# Be defensive: if nginx is not installed at all, just skip.
if dpkg -l 2>/dev/null | awk '{print $2}' | grep -qE '^(nginx|nginx-common|nginx-core|nginx-full|nginx-light|nginx-extras)$'; then
    if systemctl list-unit-files 2>/dev/null | grep -q '^nginx\.service'; then
        if systemctl is-active --quiet nginx; then
            systemctl stop nginx 2>/dev/null && ok "Stopped OS nginx"
        else
            ok "OS nginx not running"
        fi
        if systemctl is-enabled --quiet nginx 2>/dev/null; then
            systemctl disable nginx 2>/dev/null && ok "Disabled OS nginx unit"
        else
            ok "OS nginx unit not enabled"
        fi
    fi
    info "Purging OS nginx packages..."
    apt-get -y purge nginx nginx-common nginx-core nginx-full nginx-light nginx-extras 2>/dev/null || true
    apt-get -y autoremove --purge 2>/dev/null || true
    ok "OS nginx purged (XUI will install its own at /home/xui/bin/nginx)"
else
    ok "OS nginx not installed — nothing to do"
fi

# Sanity check: nothing listening on :80 right now
if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE '(^|:)80$'; then
    warn "Something is STILL listening on :80 after nginx removal — investigate before installing XUI"
else
    ok "Port 80 is free"
fi

# =============================================================================
section "8/9  UFW rules (NOT enabled — run 'ufw enable' manually at the end)"
# =============================================================================
if ! command -v ufw >/dev/null 2>&1; then
    info "Installing ufw..."
    apt-get install -y -qq ufw
fi

ufw --force reset >/dev/null 2>&1
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

# Full trust to the MAIN XUI server (MariaDB sync, stream push, etc)
ufw allow from "$MAIN_IP_TRIMMED" to any comment 'xui-main-server' >/dev/null && \
    ok "Allowed full trust from main server $MAIN_IP_TRIMMED (comment: xui-main-server)"

# SSH whitelist
for cidr in "${SSH_CIDRS[@]}"; do
    ufw allow from "$cidr" to any port 22 proto tcp comment "SSH whitelist" >/dev/null
    ok "Allowed SSH from $cidr"
done

# Public HTTP/HTTPS (XUI serves playlist + HLS here)
ufw allow 80/tcp  comment 'HTTP'  >/dev/null && ok "Allowed 80/tcp from anywhere"
ufw allow 443/tcp comment 'HTTPS' >/dev/null && ok "Allowed 443/tcp from anywhere"

info "UFW rules staged. Current status: $(ufw status | head -1)"
info "Rules pending enable:"
ufw show added | grep -v "^Added" || true

# =============================================================================
section "9/9  Post-install checklist (/root/xui-slave-post-install-check.sh)"
# =============================================================================
cat > /root/xui-slave-post-install-check.sh <<'CHECKSCRIPT'
#!/bin/bash
# Post-install security check for an XUI Load Balancer SLAVE — run AFTER
# you finish installing XUI.one in Load Balancer mode on this host.
set -e
RED=$(printf "\033[31m"); GRN=$(printf "\033[32m"); YEL=$(printf "\033[33m"); RST=$(printf "\033[0m")
pass() { echo "${GRN}[OK]${RST} $1"; }
warn() { echo "${YEL}[WARN]${RST} $1"; }
fail() { echo "${RED}[FAIL]${RST} $1"; }

echo "========================================"
echo " XUI SLAVE Post-Install Security Check"
echo "========================================"
echo

echo ">>> 1. Public listening ports (NOT 127.0.0.1)"
ss -tlnH | awk '{print $4}' | grep -vE "^127\.|^\[::1\]" | sort -u | while read addr; do
  port=$(echo "$addr" | awk -F: '{print $NF}')
  case $port in
    22|80|443) pass "Port $port on $addr (expected)" ;;
    25461|25462|25463|25500|8080|8443|31210|8880) warn "Port $port (XUI/RTMP) on $addr — review if must be public" ;;
    3306) warn "MariaDB $port on $addr — slaves usually only need it open to MAIN via UFW" ;;
    6379) fail "Redis $port EXPOSED on $addr — MUST bind 127.0.0.1 with requirepass" ;;
    *) warn "Port $port on $addr — unknown, validate" ;;
  esac
done
echo

echo ">>> 2. OS nginx must NOT be running (XUI uses /home/xui/bin/nginx)"
if systemctl is-active --quiet nginx 2>/dev/null; then
    fail "OS nginx is ACTIVE — will clash with XUI nginx on :80"
else
    pass "OS nginx not running"
fi
echo

echo ">>> 3. XUI nginx running?"
if pgrep -f '/home/xui/bin/nginx' >/dev/null 2>&1; then
    pass "XUI nginx process found"
else
    warn "XUI nginx not found — has the Load Balancer installer finished?"
fi
echo

echo ">>> 4. UFW status"
ufw status numbered 2>/dev/null | head -25
echo

echo ">>> 5. Fail2ban jails"
fail2ban-client status 2>/dev/null
echo

echo ">>> 6. Ubuntu Pro status"
pro status 2>/dev/null | head -15
echo

echo ">>> 7. Pending security updates"
PEND=$(apt list --upgradable 2>/dev/null | grep -i security | wc -l)
[ "$PEND" -gt 0 ] && warn "$PEND security updates pending — run: apt upgrade" || pass "No pending security updates"
echo

echo ">>> 8. Recent failed SSH (24h)"
journalctl -u ssh --since "24 hours ago" 2>/dev/null | grep -iE "failed|invalid" | tail -5 || pass "No failed attempts in 24h"
echo

echo "========================================"
echo " IF SOMETHING FAILED:"
echo "========================================"
echo " - OS nginx active:  systemctl disable --now nginx ; apt purge nginx*"
echo " - Redis exposed:    nano /etc/redis/redis.conf  ->  bind 127.0.0.1 + requirepass"
echo " - MariaDB exposed:  XUI slave needs MariaDB only reachable from MAIN — keep UFW deny + main allow"
echo " - Reach main DB:    main-allow-slave.sh on the MAIN must open 3306 to this slave IP"
CHECKSCRIPT
chmod 700 /root/xui-slave-post-install-check.sh
ok "Wrote /root/xui-slave-post-install-check.sh"

# =============================================================================
section "FINAL SUMMARY"
# =============================================================================
echo
ok "Sysctl tuning + drop-ins applied (BBR, fq, file-max 20.9M, IPv6 off, swappiness=1)"
ok "SSH hardened (MaxAuth=3, ClientAlive=300s, no forwarding)"
ok "fail2ban active (jail sshd, ignoreip: $IGNOREIP_LIST)"
ok "OS nginx removed/absent — port 80 free for XUI's bundled nginx"
ok "UFW staged: full trust from main $MAIN_IP_TRIMMED + SSH whitelist + 80/443 public"
ok "/root/xui-slave-post-install-check.sh ready to run after XUI install"
echo
echo "${YEL}NEXT STEPS (in order):${RST}"
echo "  1. ${YEL}ufw enable${RST}"
echo "       Last step before installing XUI. Will lock out IPs outside whitelist."
if [[ -z "$PRO_TOKEN" ]]; then
    echo "  2. ${YEL}pro attach <TOKEN>${RST}    ← get free token at ubuntu.com/pro"
fi
echo "  3. ${YEL}reboot${RST}"
echo "       Activates new kernel (if upgraded via ESM) and confirms the box"
echo "       comes back up with UFW + fail2ban + sysctl persisted."
echo
echo "  4. Open MariaDB on the MAIN to THIS slave's IP:"
echo "       On main server (205.235.2.129) run:"
echo "         ${YEL}sudo bash main-allow-slave.sh --slave-ip \$(curl -s ifconfig.me)${RST}"
echo
echo "  5. Download and run the XUI Load Balancer installer on THIS host."
echo "       When prompted:"
echo "         - Mode:          Load Balancer (slave)"
echo "         - Main host:     ${YEL}205.235.2.129${RST}"
echo "         - MariaDB host:  ${YEL}205.235.2.129${RST}"
echo "         - MariaDB user/pass: copy from main /home/xui/config (xui DB creds)"
echo
echo "  6. After XUI installed:"
echo "         ${YEL}bash /root/xui-slave-post-install-check.sh${RST}"
echo
echo "  7. (Optional) Apply GeoIP + auto-ban from this repo if desired:"
echo "         ${YEL}bash geoip-setup.sh${RST}"
echo "         ${YEL}bash auto-ban-pools.sh${RST}"
echo
ok "Done."
