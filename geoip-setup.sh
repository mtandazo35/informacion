#!/usr/bin/env bash
# =============================================================================
# geoip-setup.sh
# -----------------------------------------------------------------------------
# Set up country-based filtering for ports 80/443 using ipset + iptables.
# Only the LATAM + US + ES + CA allowlist can reach HTTP/HTTPS; everyone else
# is dropped by UFW before-rules.
#
# Source: sapics/ip-location-db (free, no MaxMind license required).
# https://github.com/sapics/ip-location-db
#
# Set name: latam_allow (ipset hash:net)
#
# USAGE
#   sudo bash geoip-setup.sh        # initial install + first build
# =============================================================================

set -euo pipefail

ALLOWED_COUNTRIES="AR BO BR CA CL CO CR CU DO EC ES GT HN HT JM MX NI PA PE PR PY SV TT US UY VE"
SET_NAME=latam_allow
SOURCE_URL="https://raw.githubusercontent.com/sapics/ip-location-db/main/geolite2-country/geolite2-country-ipv4-num.csv"
SOURCE_FALLBACK="https://cdn.jsdelivr.net/npm/@ip-location-db/geolite2-country/geolite2-country-ipv4-num.csv"
UPDATE_SCRIPT=/usr/local/bin/geoip-update.sh
CRON_FILE=/etc/cron.d/geoip-update
WORKDIR=/var/cache/geoip-allow
RULE_TAG="# managed-by-geoip-setup.sh"

if [[ -t 1 ]]; then
    RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
else
    RED=''; GRN=''; YEL=''; BLU=''; RST=''
fi
ok()   { echo "${GRN}[ OK ]${RST} $*"; }
warn() { echo "${YEL}[WARN]${RST} $*"; }
fail() { echo "${RED}[FAIL]${RST} $*" >&2; exit 1; }
info() { echo "${BLU}[INFO]${RST} $*"; }

[[ $EUID -eq 0 ]] || fail "Must run as root"

info "Installing dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ipset iptables-persistent netfilter-persistent curl >/dev/null
ok "Dependencies ready"

mkdir -p "$WORKDIR"

# -----------------------------------------------------------------------------
# Install the update script (called now and weekly via cron)
# -----------------------------------------------------------------------------
cat > "$UPDATE_SCRIPT" << 'UPDATE_EOF'
#!/usr/bin/env bash
# geoip-update.sh — refresh the latam_allow ipset from upstream.
# Idempotent. Atomic swap (build new, swap, destroy old).
set -euo pipefail

ALLOWED_COUNTRIES="AR BO BR CA CL CO CR CU DO EC ES GT HN HT JM MX NI PA PE PR PY SV TT US UY VE"
SET_NAME=latam_allow
SOURCE_URL="https://raw.githubusercontent.com/sapics/ip-location-db/main/geolite2-country/geolite2-country-ipv4-num.csv"
SOURCE_FALLBACK="https://cdn.jsdelivr.net/npm/@ip-location-db/geolite2-country/geolite2-country-ipv4-num.csv"
WORKDIR=/var/cache/geoip-allow
LOGF=/var/log/geoip-update.log

log() { echo "$(date -Iseconds) $*" >> "$LOGF"; }

cd "$WORKDIR"

log "fetching upstream CSV..."
if ! curl -fsSL --max-time 60 -o ipv4-num.csv "$SOURCE_URL"; then
    log "primary failed, trying fallback"
    curl -fsSL --max-time 60 -o ipv4-num.csv "$SOURCE_FALLBACK" || { log "both sources failed"; exit 1; }
fi
size=$(wc -c < ipv4-num.csv)
[[ $size -lt 100000 ]] && { log "CSV too small ($size bytes), aborting"; exit 1; }
log "csv size: $size bytes"

# Build allowed-country grep pattern
pattern=$(echo "$ALLOWED_COUNTRIES" | tr ' ' '|')

# Convert num range -> CIDR list using pure awk
# Input format: start_int,end_int,country_code
awk -F, -v cc="$pattern" '
BEGIN { count = 0 }
$3 ~ "^(" cc ")$" {
    start = $1; end = $2
    # range_to_cidrs: emit CIDRs covering [start..end]
    while (start <= end) {
        # max prefix size for current start (largest aligned block)
        max_prefix = 32
        while (max_prefix > 0) {
            mask = lshift(1, 32 - (max_prefix - 1)) - 1
            if (and(start, mask) != 0) break
            block = lshift(1, 32 - (max_prefix - 1))
            if (start + block - 1 > end) break
            max_prefix--
        }
        # convert prefix length back from bit-test math
        n = 32 - max_prefix
        block_size = lshift(1, n)
        printf "%d.%d.%d.%d/%d\n",
            int(start/16777216) % 256,
            int(start/65536) % 256,
            int(start/256) % 256,
            start % 256,
            max_prefix
        start += block_size
        count++
    }
}
END { print "TOTAL_CIDRS=" count > "/dev/stderr" }
' ipv4-num.csv > cidrs.new.txt 2>>"$LOGF"

cidr_count=$(wc -l < cidrs.new.txt)
log "produced $cidr_count CIDRs"
[[ $cidr_count -lt 1000 ]] && { log "suspiciously low CIDR count, aborting"; exit 1; }

# Build new set with a temp name, then atomic swap
TMP_SET="${SET_NAME}_new"
ipset destroy "$TMP_SET" 2>/dev/null || true
ipset create "$TMP_SET" hash:net family inet maxelem 200000

while IFS= read -r cidr; do
    ipset add "$TMP_SET" "$cidr" 2>/dev/null || true
done < cidrs.new.txt

if ipset list "$SET_NAME" >/dev/null 2>&1; then
    ipset swap "$TMP_SET" "$SET_NAME"
    ipset destroy "$TMP_SET"
    log "atomic swap done"
else
    ipset rename "$TMP_SET" "$SET_NAME"
    log "set created fresh"
fi

# Persist for reboot
ipset save > /etc/ipset.conf
log "saved to /etc/ipset.conf ($(wc -l < /etc/ipset.conf) entries)"

log "update complete"
UPDATE_EOF
chmod +x "$UPDATE_SCRIPT"
ok "Wrote $UPDATE_SCRIPT"

# -----------------------------------------------------------------------------
# Systemd unit to restore ipset on boot
# -----------------------------------------------------------------------------
cat > /etc/systemd/system/ipset-restore.service << 'UNIT'
[Unit]
Description=Restore ipset rules
Before=ufw.service
DefaultDependencies=no
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '[ -f /etc/ipset.conf ] && ipset restore < /etc/ipset.conf || true'

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable ipset-restore.service
ok "ipset-restore.service enabled"

# -----------------------------------------------------------------------------
# Cron: weekly refresh
# -----------------------------------------------------------------------------
cat > "$CRON_FILE" << 'CRON'
# Refresh GeoIP allowlist weekly (Sunday 3am)
0 3 * * 0 root /usr/local/bin/geoip-update.sh >/dev/null 2>&1
CRON
ok "Wrote $CRON_FILE"

# -----------------------------------------------------------------------------
# First build
# -----------------------------------------------------------------------------
info "Running first build (this may take 1-2 minutes)..."
bash "$UPDATE_SCRIPT"
size=$(ipset list "$SET_NAME" 2>/dev/null | grep -c "^[0-9]" || echo 0)
ok "ipset $SET_NAME built with $size CIDRs"

# -----------------------------------------------------------------------------
# UFW integration: patch /etc/ufw/before.rules idempotently
# -----------------------------------------------------------------------------
BEFORE_RULES=/etc/ufw/before.rules
SENTINEL_START="# BEGIN geoip-allow $RULE_TAG"
SENTINEL_END="# END geoip-allow $RULE_TAG"

cp -a "$BEFORE_RULES" "$BEFORE_RULES.bak-$(date +%Y%m%d-%H%M%S)"

# Remove existing managed block if present (idempotent re-run)
if grep -q "$SENTINEL_START" "$BEFORE_RULES"; then
    sed -i "/$SENTINEL_START/,/$SENTINEL_END/d" "$BEFORE_RULES"
    info "Removed previous managed block"
fi

# Insert our block AFTER the *filter line (top of file)
TMP=$(mktemp)
awk -v start="$SENTINEL_START" -v end="$SENTINEL_END" '
1
/^\*filter/ && !inserted {
    print ""
    print start
    print ":ufw-geoip-input - [0:0]"
    print "-A ufw-before-input -p tcp -m multiport --dports 80,443 -m set ! --match-set latam_allow src -j DROP"
    print end
    inserted=1
}
' "$BEFORE_RULES" > "$TMP" && mv "$TMP" "$BEFORE_RULES"
ok "Patched $BEFORE_RULES"

ufw reload >/dev/null && ok "UFW reloaded"

echo
ok "Done."
echo "  Set name:       $SET_NAME"
echo "  CIDR count:     $size"
echo "  Update cron:    $CRON_FILE (weekly Sunday 03:00)"
echo "  Manual refresh: $UPDATE_SCRIPT"
echo "  Test an IP:     ipset test $SET_NAME 200.32.5.1"
echo
echo "If you want to whitelist a non-LATAM IP temporarily:"
echo "  ufw insert 1 allow from 1.2.3.4 to any port 80,443 proto tcp"
