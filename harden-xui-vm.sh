#!/usr/bin/env bash
# =============================================================================
# harden-xui-vm.sh
# -----------------------------------------------------------------------------
# Idempotent hardening script for Ubuntu 20.04 VMs destined to run XUI.one.
#
# Replicates the production tuning verified against the reference VM at
# 205.235.1.161 (Proxmox) VMID 100, plus security hardening applied to the
# VM 105 maat-xui-one (205.235.2.129) on 2026-06-05.
#
# WHAT IT DOES
#   1. Network/kernel sysctl tuning (BBR, fq, big TCP buffers, file-max 20M)
#   2. /etc/sysctl.d drop-ins (disable IPv6, swappiness=1, ports <1024 non-root)
#   3. Loads tcp_bbr and runs `sysctl --system`
#   4. SSH hardening drop-in (MaxAuthTries, ClientAlive, no forwarding, etc)
#   5. fail2ban with SSH jail; ignoreip from --ssh-allow
#   6. Ubuntu Pro attach + enable esm-infra/esm-apps/livepatch (if token given)
#   7. UFW: defines rules but DOES NOT enable (you must run `ufw enable` last)
#   8. Drops /root/xui-post-install-check.sh
#
# WHAT IT DOES *NOT* DO
#   - Install XUI.one itself (do that manually after running this).
#   - Change hostname / FQDN / /etc/hosts.
#   - Reboot. You must reboot to activate the new kernel from ESM.
#   - Run `ufw enable`. Run it manually as the very last action so you don't
#     lock yourself out by accident.
#
# USAGE
#   sudo bash harden-xui-vm.sh \
#       --ssh-allow 205.235.6.128/25,10.99.99.0/24 \
#       --ubuntu-pro-token C1xxxxxxxxxxxxxxxxxxxxxxxxxx
#
#   --ssh-allow            REQUIRED. Comma-separated CIDRs allowed to SSH.
#                          These are added to UFW rules AND fail2ban ignoreip.
#   --ubuntu-pro-token     OPTIONAL. If set, runs `pro attach` + enables ESM.
#                          You can also set env var UBUNTU_PRO_TOKEN instead.
#
# REQUIREMENTS
#   - Ubuntu 20.04 LTS (Focal) with kernel 5.4.x
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
PRO_TOKEN="${UBUNTU_PRO_TOKEN:-}"

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-allow)            SSH_ALLOW="$2"; shift 2 ;;
        --ubuntu-pro-token)     PRO_TOKEN="$2"; shift 2 ;;
        -h|--help)              usage ;;
        *) fail "Unknown argument: $1"; usage ;;
    esac
done

[[ $EUID -eq 0 ]] || { fail "Must run as root"; exit 1; }
[[ -n "$SSH_ALLOW" ]] || { fail "--ssh-allow is required (e.g. 205.235.6.128/25,10.99.99.0/24)"; exit 1; }

# Normalize CIDRs (trim spaces, split by comma)
IFS=',' read -r -a SSH_CIDRS <<< "$(echo "$SSH_ALLOW" | tr -d ' ')"
[[ ${#SSH_CIDRS[@]} -ge 1 ]] || { fail "No valid CIDRs parsed from --ssh-allow"; exit 1; }
IGNOREIP_LIST="127.0.0.1/8 ::1 ${SSH_CIDRS[*]}"

# Detect Ubuntu version
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    [[ "${VERSION_ID:-}" == "20.04" ]] || warn "Tested on Ubuntu 20.04 — current: ${VERSION_ID:-unknown}"
fi

STAMP=$(date +%Y%m%d-%H%M%S)
backup() { [[ -f "$1" ]] && cp -a "$1" "$1.bak-$STAMP" && info "Backed up $1 -> $1.bak-$STAMP"; }

# =============================================================================
section "1/8  Sysctl tuning (/etc/sysctl.conf)"
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
section "2/8  Sysctl drop-ins (/etc/sysctl.d/)"
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
section "3/8  Load BBR and apply sysctl"
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
section "4/8  SSH hardening (/etc/ssh/sshd_config.d/70-hardening.conf)"
# =============================================================================
backup /etc/ssh/sshd_config.d/70-hardening.conf
cat > /etc/ssh/sshd_config.d/70-hardening.conf <<EOF
# Hardening applied $STAMP by harden-xui-vm.sh
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
section "5/8  fail2ban (/etc/fail2ban/jail.local)"
# =============================================================================
export DEBIAN_FRONTEND=noninteractive
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
# IPs never banned
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
section "6/8  Ubuntu Pro (ESM + Livepatch)"
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
section "7/8  UFW rules (NOT enabled — run 'ufw enable' manually at the end)"
# =============================================================================
if ! command -v ufw >/dev/null 2>&1; then
    info "Installing ufw..."
    apt-get install -y -qq ufw
fi

ufw --force reset >/dev/null 2>&1
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
for cidr in "${SSH_CIDRS[@]}"; do
    ufw allow from "$cidr" to any port 22 proto tcp comment "SSH whitelist" >/dev/null
    ok "Allowed SSH from $cidr"
done
ufw allow 80/tcp  comment 'HTTP'  >/dev/null && ok "Allowed 80/tcp from anywhere"
ufw allow 443/tcp comment 'HTTPS' >/dev/null && ok "Allowed 443/tcp from anywhere"

info "UFW rules staged. Current status: $(ufw status | head -1)"
info "Rules pending enable:"
ufw show added | grep -v "^Added" || true

# =============================================================================
section "8/8  Post-install checklist (/root/xui-post-install-check.sh)"
# =============================================================================
cat > /root/xui-post-install-check.sh <<'CHECKSCRIPT'
#!/bin/bash
# Post-install security check — run AFTER you finish installing XUI.one manually.
set -e
RED=$(printf "\033[31m"); GRN=$(printf "\033[32m"); YEL=$(printf "\033[33m"); RST=$(printf "\033[0m")
pass() { echo "${GRN}[OK]${RST} $1"; }
warn() { echo "${YEL}[WARN]${RST} $1"; }
fail() { echo "${RED}[FAIL]${RST} $1"; }

echo "========================================"
echo " XUI Post-Install Security Check"
echo "========================================"
echo

echo ">>> 1. Public listening ports (NOT 127.0.0.1)"
ss -tlnH | awk '{print $4}' | grep -vE "^127\.|^\[::1\]" | sort -u | while read addr; do
  port=$(echo "$addr" | awk -F: '{print $NF}')
  case $port in
    22|80|443) pass "Port $port on $addr (expected)" ;;
    25461|25462|25463|25500|8080|8443|31210|8880) warn "Port $port (XUI/RTMP) on $addr — review if must be public" ;;
    3306) fail "MySQL/MariaDB $port EXPOSED on $addr — MUST bind 127.0.0.1" ;;
    6379) fail "Redis $port EXPOSED on $addr — MUST bind 127.0.0.1 with requirepass" ;;
    *) warn "Port $port on $addr — unknown, validate" ;;
  esac
done
echo

echo ">>> 2. MariaDB bind-address"
BIND=$(grep -hE "^bind-address" /etc/mysql/mariadb.conf.d/*.cnf /etc/mysql/my.cnf 2>/dev/null | tail -1 | awk '{print $NF}')
[ "$BIND" = "127.0.0.1" ] && pass "MariaDB bound to 127.0.0.1" || fail "MariaDB bind = \"$BIND\" (must be 127.0.0.1)"
echo

echo ">>> 3. Redis bind and requirepass"
RBIND=$(grep -E "^bind" /etc/redis/redis.conf 2>/dev/null | awk '{$1=""; print}')
RPASS=$(grep -E "^requirepass" /etc/redis/redis.conf 2>/dev/null)
[ -n "$RBIND" ] && (echo "$RBIND" | grep -q "127.0.0.1" && pass "Redis bind includes 127.0.0.1:$RBIND" || fail "Redis NOT bound to 127.0.0.1:$RBIND") || warn "/etc/redis/redis.conf not found"
[ -n "$RPASS" ] && pass "Redis has requirepass" || warn "Redis WITHOUT requirepass"
echo

echo ">>> 4. UFW status"
ufw status numbered 2>/dev/null | head -20
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
echo " - Redis exposed:    nano /etc/redis/redis.conf  ->  bind 127.0.0.1 + requirepass <hash>"
echo " - MariaDB exposed:  nano /etc/mysql/mariadb.conf.d/50-server.cnf  ->  bind-address = 127.0.0.1"
echo " - XUI admin port:   panel admin -> Settings -> change from 25461/25500"
echo " - Open new port:    ufw allow <port>/tcp comment \"XUI admin\""
echo " - Close port:       ufw delete allow <port>"
CHECKSCRIPT
chmod 700 /root/xui-post-install-check.sh
ok "Wrote /root/xui-post-install-check.sh"

# =============================================================================
section "FINAL SUMMARY"
# =============================================================================
echo
ok "Sysctl tuning + drop-ins applied (BBR, fq, file-max 20.9M, IPv6 off, swappiness=1)"
ok "SSH hardened (MaxAuth=3, ClientAlive=300s, no forwarding)"
ok "fail2ban active (jail sshd, ignoreip: $IGNOREIP_LIST)"
ok "/root/xui-post-install-check.sh ready to run after XUI install"
echo
echo "${YEL}PENDING ACTIONS (you must do these):${RST}"
echo "  1. ${YEL}ufw enable${RST}    ← last step; will lock out IPs outside whitelist"
if [[ -z "$PRO_TOKEN" ]]; then
    echo "  2. ${YEL}pro attach <TOKEN>${RST}    ← get free token at ubuntu.com/pro"
fi
echo "  3. ${YEL}reboot${RST}        ← activate new kernel (if upgraded via ESM)"
echo "  4. Install XUI.one manually."
echo "  5. After XUI installed: bash /root/xui-post-install-check.sh"
echo
ok "Done."
