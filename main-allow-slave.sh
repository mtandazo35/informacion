#!/usr/bin/env bash
# =============================================================================
# main-allow-slave.sh
# -----------------------------------------------------------------------------
# Authorize (or revoke) a new XUI.one load-balancer slave on the MAIN VM.
#
# Designed to run on the MAIN: VM 105 maat-xui-one (205.235.2.129).
# The MAIN is hardened (UFW default-deny, MariaDB bound to 127.0.0.1 via
# /etc/mysql/mariadb.conf.d/99-bind-localhost.cnf). To let a slave register
# itself and replicate state, the MAIN must:
#
#   1. Open MariaDB (3306) to the slave through UFW (single-host /32 only).
#   2. Re-bind mysqld to 0.0.0.0 so it actually accepts the connection.
#      Security is preserved because UFW default-deny covers 3306 to the world;
#      only whitelisted IPs (slaves + existing SSH/HTTP/HTTPS rules) get in.
#   3. Emit a SQL GRANT block the operator can paste manually (we DO NOT run
#      it — the XUI Load Balancer installer often creates its own user).
#
# IDEMPOTENT. Re-running is safe: UFW rule deduped by comment, bind file
# rename only happens once, target config only written if not already in
# target state.
#
# USAGE
#   sudo bash main-allow-slave.sh --slave-ip 205.235.1.159
#   sudo bash main-allow-slave.sh --slave-ip 205.235.1.159 --dry-run
#   sudo bash main-allow-slave.sh --undo --slave-ip 205.235.1.159
#   sudo bash main-allow-slave.sh --slave-ip 205.235.1.159 --force   # skip hostname check
#
#   --slave-ip <IP[/32]>   REQUIRED. IPv4 of the slave (single host). /32 OK.
#   --dry-run              Show what would change; apply nothing.
#   --undo                 Reverse: drop UFW rule for the IP; if it was the
#                          last slave, restore the localhost-only bind.
#   --force                Skip the "am I on the main VM?" sanity check.
#
# REQUIREMENTS
#   - Root (or sudo)
#   - UFW + MariaDB installed (provided by harden-xui-vm.sh + XUI install)
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

# ----- Defaults ------------------------------------------------------------
SLAVE_IP=""
DRY_RUN=0
UNDO=0
FORCE=0
MAIN_HOSTNAME="maat-xui-one"
MAIN_IP="205.235.2.129"
BIND_LOCAL_FILE="/etc/mysql/mariadb.conf.d/99-bind-localhost.cnf"
BIND_LOCAL_DISABLED="${BIND_LOCAL_FILE}.disabled-by-main-allow-slave"
BIND_REMOTE_FILE="/etc/mysql/mariadb.conf.d/99-bind-remote.cnf"
SLAVE_COMMENT_PREFIX="xui-slave-"

usage() {
    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

# ----- Argument parsing ----------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --slave-ip)   SLAVE_IP="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --undo)       UNDO=1; shift ;;
        --force)      FORCE=1; shift ;;
        -h|--help)    usage ;;
        *) fail "Unknown argument: $1"; usage ;;
    esac
done

[[ $EUID -eq 0 ]] || { fail "Must run as root"; exit 1; }
[[ -n "$SLAVE_IP" ]] || { fail "--slave-ip is required (e.g. 205.235.1.159)"; exit 1; }

# ----- Validate IP (dotted-quad, optional /32 only) ------------------------
validate_ip() {
    local ip="$1"
    local cidr=""
    if [[ "$ip" == */* ]]; then
        cidr="${ip#*/}"
        ip="${ip%/*}"
        if [[ "$cidr" != "32" ]]; then
            fail "Only /32 (single host) accepted. Got /$cidr"
            exit 1
        fi
    fi
    if [[ ! "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        fail "Not a dotted-quad IPv4: $ip"
        exit 1
    fi
    local oct
    for oct in "${BASH_REMATCH[@]:1:4}"; do
        if (( oct > 255 )); then
            fail "Octet out of range in $ip"
            exit 1
        fi
    done
    # Strip the optional /32 — UFW takes bare IP fine and our comment match is exact
    SLAVE_IP="$ip"
}

validate_ip "$SLAVE_IP"
SLAVE_COMMENT="${SLAVE_COMMENT_PREFIX}${SLAVE_IP}"

# ----- Sanity: am I on the main? -------------------------------------------
HOST_NOW="$(hostname 2>/dev/null || echo unknown)"
if [[ "$HOST_NOW" != "$MAIN_HOSTNAME" ]]; then
    if [[ $FORCE -eq 1 ]]; then
        warn "hostname is '$HOST_NOW' (expected '$MAIN_HOSTNAME') — proceeding due to --force"
    else
        fail "hostname is '$HOST_NOW', expected '$MAIN_HOSTNAME'. Use --force to override."
        exit 1
    fi
fi

# ----- Dry-run wrapper -----------------------------------------------------
run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "${YEL}[DRY ]${RST} $*"
    else
        eval "$@"
    fi
}

# ===========================================================================
# UNDO PATH
# ===========================================================================
if [[ $UNDO -eq 1 ]]; then
    section "UNDO mode — revoking slave $SLAVE_IP"

    # 1. Remove UFW rule(s) for this slave comment
    if command -v ufw >/dev/null 2>&1; then
        # Find rule numbers with our comment; delete from highest to lowest to keep numbering stable
        mapfile -t TO_DELETE < <(ufw status numbered 2>/dev/null \
            | awk -v c="$SLAVE_COMMENT" '$0 ~ c { match($0, /\[ *([0-9]+)\]/, m); if (m[1]) print m[1] }' \
            | sort -rn)
        if [[ ${#TO_DELETE[@]} -eq 0 ]]; then
            warn "No UFW rules with comment '$SLAVE_COMMENT' found"
        else
            for rn in "${TO_DELETE[@]}"; do
                if [[ $DRY_RUN -eq 1 ]]; then
                    echo "${YEL}[DRY ]${RST} ufw --force delete $rn  (rule for $SLAVE_IP)"
                else
                    yes | ufw delete "$rn" >/dev/null 2>&1 && ok "Removed UFW rule #$rn ($SLAVE_COMMENT)" \
                        || fail "Failed to remove UFW rule #$rn"
                fi
            done
        fi
    else
        warn "ufw not installed — skipping UFW cleanup"
    fi

    # 2. If no other slave rules remain, restore localhost-only bind
    REMAINING=0
    if command -v ufw >/dev/null 2>&1; then
        REMAINING=$(ufw status 2>/dev/null | grep -c "${SLAVE_COMMENT_PREFIX}" || true)
    fi
    if [[ "$REMAINING" -eq 0 ]]; then
        info "No other XUI slaves remain — restoring localhost-only MariaDB bind"
        if [[ -f "$BIND_LOCAL_DISABLED" ]]; then
            run "mv '$BIND_LOCAL_DISABLED' '$BIND_LOCAL_FILE'"
            ok "Restored $BIND_LOCAL_FILE"
        else
            warn "$BIND_LOCAL_DISABLED not found — nothing to restore"
        fi
        if [[ -f "$BIND_REMOTE_FILE" ]]; then
            run "rm -f '$BIND_REMOTE_FILE'"
            ok "Removed $BIND_REMOTE_FILE"
        fi
        if [[ $DRY_RUN -eq 0 ]]; then
            if systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null; then
                ok "MariaDB restarted"
            else
                fail "MariaDB restart failed — check 'journalctl -u mariadb -n 50'"
            fi
            sleep 1
            BIND_OBSERVED=$(ss -Hnlt sport = :3306 2>/dev/null | awk '{print $4}' | head -1)
            if [[ "$BIND_OBSERVED" == "127.0.0.1:3306" ]]; then
                ok "mysqld now listening on $BIND_OBSERVED"
            else
                warn "mysqld listening on '$BIND_OBSERVED' (expected 127.0.0.1:3306)"
            fi
        fi
    else
        info "$REMAINING other slave rule(s) still present — leaving MariaDB bound to 0.0.0.0"
    fi

    section "UNDO COMPLETE"
    ok "Slave $SLAVE_IP revoked."
    echo
    echo "Manual cleanup (if you created a DB user for this slave):"
    echo "  ${YEL}mysql -u root -e \"DROP USER IF EXISTS 'xui_slave'@'${SLAVE_IP}'; FLUSH PRIVILEGES;\"${RST}"
    exit 0
fi

# ===========================================================================
# APPLY PATH
# ===========================================================================
section "Authorizing slave $SLAVE_IP on main ($MAIN_IP)"
[[ $DRY_RUN -eq 1 ]] && warn "DRY-RUN — no changes will be applied"

# ----- 1/4  UFW rule -------------------------------------------------------
section "1/4  UFW allow from slave"
if ! command -v ufw >/dev/null 2>&1; then
    fail "ufw not installed — cannot proceed"
    exit 1
fi

if ufw status 2>/dev/null | grep -qE "[[:space:]]${SLAVE_IP}[[:space:]].*${SLAVE_COMMENT}"; then
    ok "UFW rule already present for $SLAVE_IP (comment: $SLAVE_COMMENT)"
elif ufw status verbose 2>/dev/null | grep -q "$SLAVE_COMMENT"; then
    ok "UFW rule already present for $SLAVE_IP (comment: $SLAVE_COMMENT)"
else
    run "ufw allow from '$SLAVE_IP' to any comment '$SLAVE_COMMENT'"
    if [[ $DRY_RUN -eq 0 ]]; then
        ok "Added UFW rule: allow from $SLAVE_IP (comment: $SLAVE_COMMENT)"
    fi
fi

# ----- 2/4  MariaDB bind ---------------------------------------------------
section "2/4  MariaDB bind-address"

# (a) Disable the localhost-only override, if still active
if [[ -f "$BIND_LOCAL_FILE" ]]; then
    run "mv '$BIND_LOCAL_FILE' '$BIND_LOCAL_DISABLED'"
    [[ $DRY_RUN -eq 0 ]] && ok "Disabled $BIND_LOCAL_FILE (kept as $(basename "$BIND_LOCAL_DISABLED"))"
elif [[ -f "$BIND_LOCAL_DISABLED" ]]; then
    ok "$BIND_LOCAL_FILE already disabled (evidence: $(basename "$BIND_LOCAL_DISABLED"))"
else
    info "No $BIND_LOCAL_FILE override present — relying on stock 50-server.cnf"
fi

# (b) Write remote-bind drop-in if not already exactly correct
DESIRED_BIND=$'[mysqld]\nbind-address = 0.0.0.0\n'
if [[ -f "$BIND_REMOTE_FILE" ]] && [[ "$(cat "$BIND_REMOTE_FILE")" == "$DESIRED_BIND" ]]; then
    ok "$BIND_REMOTE_FILE already in target state (bind-address = 0.0.0.0)"
else
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "${YEL}[DRY ]${RST} write $BIND_REMOTE_FILE with [mysqld]/bind-address=0.0.0.0"
    else
        printf '%s' "$DESIRED_BIND" > "$BIND_REMOTE_FILE"
        chmod 0644 "$BIND_REMOTE_FILE"
        ok "Wrote $BIND_REMOTE_FILE (bind-address = 0.0.0.0)"
    fi
fi

# (c) Restart MariaDB and verify
section "3/4  Restart + verify mysqld listening on 0.0.0.0:3306"
if [[ $DRY_RUN -eq 1 ]]; then
    echo "${YEL}[DRY ]${RST} systemctl restart mariadb"
    echo "${YEL}[DRY ]${RST} ss -Hnlt sport = :3306"
else
    if systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null; then
        ok "MariaDB restarted"
    else
        fail "MariaDB restart failed — check 'journalctl -u mariadb -n 50'"
        exit 1
    fi
    sleep 1
    BIND_OBSERVED=$(ss -Hnlt sport = :3306 2>/dev/null | awk '{print $4}' | head -1)
    if [[ "$BIND_OBSERVED" == "0.0.0.0:3306" ]] || [[ "$BIND_OBSERVED" == "*:3306" ]]; then
        ok "mysqld listening on $BIND_OBSERVED"
    else
        fail "mysqld listening on '$BIND_OBSERVED' (expected 0.0.0.0:3306). UFW still protects, but investigate."
    fi
fi

# ----- 4/4  Connectivity probe to slave ------------------------------------
section "4/4  Connectivity probe to slave (best effort)"
if command -v nc >/dev/null 2>&1; then
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "${YEL}[DRY ]${RST} nc -zv -w 3 $SLAVE_IP 22 80 443 8880"
    else
        info "Probing $SLAVE_IP on 22, 80, 443, 8880..."
        nc -zv -w 3 "$SLAVE_IP" 22 80 443 8880 2>&1 || true
    fi
else
    warn "nc not installed — skipping connectivity probe (apt install -y netcat-openbsd)"
fi

# ----- SQL block (printed only — operator chooses whether to apply) --------
section "SQL GRANT block (manual paste — NOT executed)"
GEN_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)
cat <<SQLBLOCK

-- Run on main (mysql -u root):
CREATE USER IF NOT EXISTS 'xui_slave'@'${SLAVE_IP}' IDENTIFIED BY '${GEN_PASSWORD}';
GRANT ALL PRIVILEGES ON xui.* TO 'xui_slave'@'${SLAVE_IP}';
FLUSH PRIVILEGES;

SQLBLOCK
info "Password is 40 chars [A-Za-z0-9] generated from /dev/urandom."
info "If you let the XUI Load Balancer installer create its own user, skip the SQL above."

# ===========================================================================
section "FINAL SUMMARY"
# ===========================================================================
echo
ok "UFW: allow from $SLAVE_IP (comment: $SLAVE_COMMENT)"
ok "MariaDB: bind-address = 0.0.0.0 via $BIND_REMOTE_FILE"
ok "MariaDB: localhost-only override neutralized ($BIND_LOCAL_DISABLED)"
ok "Generated GRANT SQL printed above (copy/paste if needed)"
echo
echo "${YEL}NEXT STEPS:${RST}"
echo "  1. ${YEL}On the slave (${SLAVE_IP}):${RST} run prep-xui-slave.sh first."
echo "  2. ${YEL}On the slave:${RST} run the XUI Load Balancer installer, pointing to:"
echo "       MySQL host:  ${MAIN_IP}"
echo "       MySQL port:  3306"
echo "       DB name:     xui"
echo "       User:        either the installer-created user OR 'xui_slave' from the SQL above"
echo "  3. After registration, the row in main's \`servers\` table for this slave will get"
echo "     its UUID populated by the install handshake. Verify with:"
echo "       ${YEL}mysql -u root xui -e \"SELECT id, server_name, ip, uuid_key FROM servers WHERE ip='${SLAVE_IP}';\"${RST}"
echo "  4. Roll back with: ${YEL}sudo bash $0 --undo --slave-ip ${SLAVE_IP}${RST}"
echo
ok "Done."
