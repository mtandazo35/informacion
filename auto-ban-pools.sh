#!/usr/bin/env bash
# =============================================================================
# auto-ban-pools.sh
# -----------------------------------------------------------------------------
# Detect scanner IP pools hitting UFW and ban whole /24s automatically.
# Runs every 15 min via cron. Looks at journalctl -k for UFW BLOCK lines in
# the last 20 min, groups by /24, and bans pools above threshold.
#
# Thresholds (any triggers a ban):
#   * >= 30 unique source IPs from the same /24 in 20 min
#   * >= 100 total UFW BLOCK hits from the same /24 in 20 min
#
# Bans are TTL-tracked in /var/lib/auto-ban-pools.state and removed after 7d.
# Cooldown: same /24 won't be re-banned within 6h.
#
# USAGE
#   sudo /usr/local/bin/auto-ban-pools.sh             # normal run (silent)
#   sudo /usr/local/bin/auto-ban-pools.sh --dry-run   # show decisions, no changes
#   sudo /usr/local/bin/auto-ban-pools.sh --stats     # show current state
#
# Exclusions (NEVER banned, even if threshold hit):
#   - RFC1918 (10/8, 172.16/12, 192.168/16)
#   - 127.0.0.0/8
#   - 205.235.0.0/16 (datacenter Maat)
#   - 66.231.64.0/24 (PVE Maat range)
#   - Lines in /etc/auto-ban-pools.exclude (CIDR per line, # comments allowed)
# =============================================================================

set -euo pipefail

STATE=/var/lib/auto-ban-pools.state
LOGF=/var/log/auto-ban-pools.log
EXCLUDE_FILE=/etc/auto-ban-pools.exclude
THRESHOLD_UNIQUE_IPS=30
THRESHOLD_TOTAL_HITS=100
WINDOW_MIN=20
COOLDOWN_HOURS=6
TTL_DAYS=7

DRY_RUN=0
STATS=0

# Color output only when stdout is a TTY
if [[ -t 1 ]]; then
    RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
else
    RED=''; GRN=''; YEL=''; BLU=''; RST=''
fi
ok()   { echo "${GRN}[OK]${RST}   $*"; }
warn() { echo "${YEL}[WARN]${RST} $*"; }
fail() { echo "${RED}[FAIL]${RST} $*" >&2; }
info() { echo "${BLU}[INFO]${RST} $*"; }
log()  { echo "$(date -Iseconds) $*" >> "$LOGF"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --stats)   STATS=1; shift ;;
        --help|-h)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) fail "Unknown arg: $1"; exit 1 ;;
    esac
done

[[ $EUID -eq 0 ]] || { fail "Must run as root"; exit 1; }
[[ -d /var/lib ]] && touch "$STATE" "$LOGF"

# ----- Hardcoded exclusions (RFC1918 + user's network) ---------------------
BASE_EXCLUDES=(
    "10."
    "172.16." "172.17." "172.18." "172.19." "172.20." "172.21." "172.22." "172.23."
    "172.24." "172.25." "172.26." "172.27." "172.28." "172.29." "172.30." "172.31."
    "192.168."
    "127."
    "205.235."
    "66.231.64."
)
is_excluded() {
    local cidr=$1
    local prefix
    # cidr is e.g. 79.124.62.0/24, get the /24 prefix
    prefix="${cidr%.*/24}."
    for ex in "${BASE_EXCLUDES[@]}"; do
        [[ "$cidr" == "$ex"* ]] && return 0
    done
    if [[ -r "$EXCLUDE_FILE" ]]; then
        while IFS= read -r line; do
            line="${line%%#*}"           # strip comments
            line="${line//[[:space:]]/}" # strip whitespace
            [[ -z "$line" ]] && continue
            [[ "$cidr" == "$line" ]] && return 0
        done < "$EXCLUDE_FILE"
    fi
    return 1
}

# ----- Stats mode ----------------------------------------------------------
if [[ $STATS -eq 1 ]]; then
    echo "=== Auto-ban pools status ==="
    if [[ -s "$STATE" ]]; then
        echo "Currently tracked bans:"
        awk -F'|' '{ printf "  %-20s banned_at=%s expires_at=%s reason=%s\n", $1, $2, $3, $4 }' "$STATE"
        echo "Total: $(wc -l < "$STATE")"
    else
        echo "No active bans tracked."
    fi
    echo
    echo "=== UFW rules with auto-ban comment ==="
    ufw status numbered 2>/dev/null | grep -i autoban || echo "  none"
    echo
    echo "=== Recent log entries (last 20) ==="
    [[ -s "$LOGF" ]] && tail -20 "$LOGF" || echo "  log empty"
    exit 0
fi

# ----- Step 1: gather UFW BLOCK events from the last WINDOW_MIN min ---------
NOW_EPOCH=$(date +%s)
since="$WINDOW_MIN minutes ago"

# IPs already explicitly allowed in UFW (don't ban these even if scanning)
mapfile -t ALLOWED_CIDRS < <(ufw status 2>/dev/null | awk '/ALLOW/{print $NF}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' || true)
is_in_allow_set() {
    local cidr=$1
    for a in "${ALLOWED_CIDRS[@]}"; do
        [[ "$cidr" == "$a" ]] && return 0
    done
    return 1
}

# Extract SRC=ip from journal, group by /24 (first 3 octets)
# Format: pool|unique_ips|total_hits
declare -A POOL_HITS POOL_UNIQ
while IFS= read -r ip; do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    pool="${ip%.*}.0/24"
    POOL_HITS[$pool]=$(( ${POOL_HITS[$pool]:-0} + 1 ))
done < <(journalctl -k --since "$since" --no-pager 2>/dev/null | grep -oP 'SRC=\K[0-9.]+' || true)

# Recompute unique IPs per pool (separate pass for clarity)
declare -A POOL_UNIQ_SET
while IFS= read -r ip; do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    pool="${ip%.*}.0/24"
    key="$pool|$ip"
    POOL_UNIQ_SET[$key]=1
done < <(journalctl -k --since "$since" --no-pager 2>/dev/null | grep -oP 'SRC=\K[0-9.]+' || true)
for key in "${!POOL_UNIQ_SET[@]}"; do
    pool="${key%|*}"
    POOL_UNIQ[$pool]=$(( ${POOL_UNIQ[$pool]:-0} + 1 ))
done

# ----- Step 2: load existing state ----------------------------------------
declare -A STATE_BANNED_AT
if [[ -s "$STATE" ]]; then
    while IFS='|' read -r cidr banned_at expires_at reason; do
        [[ -z "$cidr" ]] && continue
        STATE_BANNED_AT[$cidr]=$banned_at
    done < "$STATE"
fi

# ----- Step 3: evaluate each pool ------------------------------------------
candidates_total=0
banned_now=0
for pool in "${!POOL_HITS[@]}"; do
    hits=${POOL_HITS[$pool]}
    uniq=${POOL_UNIQ[$pool]:-0}
    candidates_total=$((candidates_total + 1))

    if (( uniq < THRESHOLD_UNIQUE_IPS && hits < THRESHOLD_TOTAL_HITS )); then
        continue
    fi

    if is_excluded "$pool"; then
        info "Skipping excluded pool $pool (hits=$hits uniq=$uniq)"
        continue
    fi

    if is_in_allow_set "$pool"; then
        warn "Pool $pool is in UFW ALLOW set — skipping"
        continue
    fi

    # Cooldown
    if [[ -n "${STATE_BANNED_AT[$pool]:-}" ]]; then
        last=$(date -d "${STATE_BANNED_AT[$pool]}" +%s 2>/dev/null || echo 0)
        if (( NOW_EPOCH - last < COOLDOWN_HOURS * 3600 )); then
            info "Pool $pool already banned within cooldown — skipping"
            continue
        fi
    fi

    expires=$(date -d "+$TTL_DAYS days" -Iseconds)
    reason="hits=$hits uniq=$uniq"
    msg="BAN $pool ($reason expires=$expires)"

    if [[ $DRY_RUN -eq 1 ]]; then
        warn "[DRY-RUN] $msg"
    else
        if ufw insert 1 deny from "$pool" to any comment "autoban_$(date +%Y%m%d_%H%M)" 2>/dev/null; then
            log "$msg"
            ok "$msg"
            # Update state (append; expired entries pruned in step 4)
            echo "$pool|$(date -Iseconds)|$expires|$reason" >> "$STATE"
            banned_now=$((banned_now + 1))
        else
            fail "ufw insert failed for $pool"
        fi
    fi
done

# ----- Step 4: expire old bans (TTL) --------------------------------------
expired_now=0
if [[ -s "$STATE" && $DRY_RUN -eq 0 ]]; then
    tmpfile=$(mktemp)
    while IFS='|' read -r cidr banned_at expires_at reason; do
        [[ -z "$cidr" ]] && continue
        exp_epoch=$(date -d "$expires_at" +%s 2>/dev/null || echo 0)
        if (( NOW_EPOCH >= exp_epoch )); then
            # Expire: remove from UFW
            if ufw delete deny from "$cidr" to any 2>/dev/null | grep -q "Rule deleted"; then
                log "EXPIRE $cidr (banned_at=$banned_at)"
                expired_now=$((expired_now + 1))
            fi
            # Don't keep in state
        else
            echo "$cidr|$banned_at|$expires_at|$reason" >> "$tmpfile"
        fi
    done < "$STATE"
    mv "$tmpfile" "$STATE"
fi

# ----- Summary on TTY -----------------------------------------------------
if [[ -t 1 ]]; then
    echo
    echo "Summary: candidates=$candidates_total  newly_banned=$banned_now  expired=$expired_now  dry_run=$DRY_RUN"
fi

exit 0
