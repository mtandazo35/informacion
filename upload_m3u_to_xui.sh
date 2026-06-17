#!/usr/bin/env bash
# =============================================================================
# upload_m3u_to_xui.sh
# -----------------------------------------------------------------------------
# Automates the full M3U -> XUI bulk-load pipeline:
#
#   M3U file (local)
#     -> m3u_to_xui.py generates xui_load.sql (one TX per category)
#     -> gzip + base64 + split into ~60KB chunks
#     -> scp chunks to Proxmox PVE host
#     -> pvesh file-write each chunk into the XUI VM via the QEMU guest agent
#     -> concat + base64 -d + gunzip inside the VM
#     -> MD5 verify
#     -> (optional) TRUNCATE streams tables
#     -> mysql xui < xui_load.sql
#     -> verify row counts
#
# Why this dance? The XUI VM lives behind Proxmox with no direct SSH/SCP from
# our workstation; the only reliable channel is the QEMU guest agent, and
# pvesh file-write has a practical payload limit around ~100 KB, so we chunk
# at 60 KB and reassemble inside the guest.
#
# USAGE
#   ./upload_m3u_to_xui.sh \
#       --m3u ./ec387860_lista.m3u \
#       --pve-host 66.231.64.157 \
#       --vmid 105 \
#       [--server-id 1] \
#       [--on-demand 1] \
#       [--truncate] \
#       [--keep-temp]
#
# FLAGS
#   --m3u PATH         (required) local path to the .m3u playlist
#   --pve-host HOST    (required) Proxmox PVE host or IP (ssh root@HOST)
#   --vmid N           (required) Proxmox VM ID running XUI
#   --server-id N      (default 1) value for streams_servers.server_id
#   --on-demand 0|1    (default 1) value for streams_servers.on_demand
#   --truncate         TRUNCATE streams_servers/streams/streams_categories
#                      before loading (DESTRUCTIVE)
#   --keep-temp        keep /tmp/m3u_upload_$$ on both ends
#   --help             show this help
#
# REQUIREMENTS
#   - python3, gzip, base64, split, scp, ssh, md5sum on the workstation
#   - SSH key access to root@<pve-host>
#   - m3u_to_xui.py in the SAME directory as this script
#   - QEMU guest agent running in the XUI VM, with mysql client available
# =============================================================================

set -euo pipefail

# ---------- pretty output ----------------------------------------------------
if [[ -t 1 ]]; then
    C_OK="\033[1;32m"; C_WARN="\033[1;33m"; C_FAIL="\033[1;31m"
    C_DIM="\033[2m"; C_RST="\033[0m"
else
    C_OK=""; C_WARN=""; C_FAIL=""; C_DIM=""; C_RST=""
fi
ok()   { printf "${C_OK}[ ok ]${C_RST} %s\n"   "$*"; }
warn() { printf "${C_WARN}[warn]${C_RST} %s\n" "$*" >&2; }
fail() { printf "${C_FAIL}[fail]${C_RST} %s\n" "$*" >&2; exit 1; }
info() { printf "${C_DIM}[info]${C_RST} %s\n"  "$*"; }

# ---------- arg parsing ------------------------------------------------------
M3U=""
PVE_HOST=""
VMID=""
SERVER_ID=1
ON_DEMAND=1
DO_TRUNCATE=0
KEEP_TEMP=0

usage() {
    sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --m3u)        M3U="${2:-}"; shift 2 ;;
        --pve-host)   PVE_HOST="${2:-}"; shift 2 ;;
        --vmid)       VMID="${2:-}"; shift 2 ;;
        --server-id)  SERVER_ID="${2:-}"; shift 2 ;;
        --on-demand)  ON_DEMAND="${2:-}"; shift 2 ;;
        --truncate)   DO_TRUNCATE=1; shift ;;
        --keep-temp)  KEEP_TEMP=1; shift ;;
        --help|-h)    usage 0 ;;
        *)            warn "Unknown argument: $1"; usage 1 ;;
    esac
done

[[ -z "$M3U"      ]] && { warn "--m3u is required";      usage 1; }
[[ -z "$PVE_HOST" ]] && { warn "--pve-host is required"; usage 1; }
[[ -z "$VMID"     ]] && { warn "--vmid is required";     usage 1; }

[[ "$ON_DEMAND" == "0" || "$ON_DEMAND" == "1" ]] || fail "--on-demand must be 0 or 1"
[[ "$SERVER_ID" =~ ^[0-9]+$ ]] || fail "--server-id must be a positive integer"
[[ "$VMID"      =~ ^[0-9]+$ ]] || fail "--vmid must be a positive integer"

# ---------- validation -------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYSCRIPT="$SCRIPT_DIR/m3u_to_xui.py"

[[ -f "$M3U"      ]] || fail "M3U file not found: $M3U"
[[ -f "$PYSCRIPT" ]] || fail "m3u_to_xui.py not found next to this script: $PYSCRIPT"
command -v python3  >/dev/null || fail "python3 not in PATH"
command -v gzip     >/dev/null || fail "gzip not in PATH"
command -v base64   >/dev/null || fail "base64 not in PATH"
command -v split    >/dev/null || fail "split not in PATH"
command -v scp      >/dev/null || fail "scp not in PATH"
command -v ssh      >/dev/null || fail "ssh not in PATH"
command -v md5sum   >/dev/null || fail "md5sum not in PATH"

info "Validating SSH access to root@$PVE_HOST ..."
ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$PVE_HOST" \
    'echo pve_ok && hostname' >/dev/null \
    || fail "SSH to root@$PVE_HOST failed. Make sure your key is authorized."
ok "SSH to $PVE_HOST works"

# ---------- workspace --------------------------------------------------------
RUN_ID="$$"
LOCAL_TMP="/tmp/m3u_upload_${RUN_ID}"
REMOTE_TMP="/tmp/m3u_upload_${RUN_ID}"
SQL_LOCAL="$LOCAL_TMP/xui_load.sql"
B64_LOCAL="$LOCAL_TMP/xui_load.sql.gz.b64"
CHUNK_DIR="$LOCAL_TMP/chunks"

mkdir -p "$CHUNK_DIR"
info "Local workspace : $LOCAL_TMP"
info "Remote workspace: $REMOTE_TMP (on PVE $PVE_HOST)"

cleanup() {
    local rc=$?
    if (( KEEP_TEMP == 1 )); then
        warn "--keep-temp set; leaving $LOCAL_TMP and remote $REMOTE_TMP intact"
    else
        rm -rf "$LOCAL_TMP" 2>/dev/null || true
        ssh -o BatchMode=yes "root@$PVE_HOST" "rm -rf $REMOTE_TMP" 2>/dev/null || true
    fi
    exit "$rc"
}
trap cleanup EXIT

# =============================================================================
# Step 1: generate SQL
# =============================================================================
info "Generating SQL from $M3U ..."
python3 "$PYSCRIPT" "$M3U" "$SQL_LOCAL"

[[ -s "$SQL_LOCAL" ]] || fail "Generated SQL is empty: $SQL_LOCAL"

SQL_LINES=$(wc -l < "$SQL_LOCAL")
START_TX=$(grep -c '^START TRANSACTION;'      "$SQL_LOCAL" || true)
COMMITS=$(  grep -c '^COMMIT;'                 "$SQL_LOCAL" || true)
CAT_COUNT=$(grep -c '^-- ===== Category '      "$SQL_LOCAL" || true)

(( SQL_LINES > 0 )) || fail "Generated SQL has 0 lines"
[[ "$START_TX" == "$COMMITS"   ]] || fail "TX mismatch: $START_TX START / $COMMITS COMMIT"
[[ "$START_TX" == "$CAT_COUNT" ]] || fail "Category markers ($CAT_COUNT) != transactions ($START_TX)"
ok "SQL ok: $SQL_LINES lines, $CAT_COUNT categories, $START_TX transactions"

# ---------- patch server_id / on_demand if non-default -----------------------
# m3u_to_xui.py bakes SERVER_ID=1, ON_DEMAND=1 into the INSERT for
# streams_servers. Patch the generated SQL when the caller wants different
# values. The line shape is:
#   INSERT INTO streams_servers (...) VALUES (LAST_INSERT_ID(), 1, 1, 0);
if [[ "$SERVER_ID" != "1" || "$ON_DEMAND" != "1" ]]; then
    info "Patching streams_servers values: server_id=$SERVER_ID, on_demand=$ON_DEMAND"
    # Use a non-/ delimiter; values are integers so no escaping needed.
    sed -i.bak -E "s#(VALUES \(LAST_INSERT_ID\(\), )1, 1(, 0\);)#\1${SERVER_ID}, ${ON_DEMAND}\2#" "$SQL_LOCAL"
    rm -f "$SQL_LOCAL.bak"
    PATCHED=$(grep -c "VALUES (LAST_INSERT_ID(), ${SERVER_ID}, ${ON_DEMAND}, 0);" "$SQL_LOCAL" || true)
    (( PATCHED > 0 )) || fail "sed patch did not match any streams_servers rows"
    ok "Patched $PATCHED streams_servers rows"
fi

SQL_MD5_LOCAL=$(md5sum "$SQL_LOCAL" | awk '{print $1}')
info "Local SQL md5: $SQL_MD5_LOCAL"

# =============================================================================
# Step 2: compress + base64 + chunk
# =============================================================================
info "gzip + base64 + split ..."
gzip -9 -c "$SQL_LOCAL" | base64 -w0 > "$B64_LOCAL"
B64_SIZE=$(wc -c < "$B64_LOCAL")
split -b 60000 -d -a 4 "$B64_LOCAL" "$CHUNK_DIR/chunk_"
CHUNK_COUNT=$(find "$CHUNK_DIR" -name 'chunk_*' -type f | wc -l)
ok "Encoded payload: $B64_SIZE bytes -> $CHUNK_COUNT chunks of <=60KB"

# =============================================================================
# Step 3: ship chunks to PVE host
# =============================================================================
info "scp chunks to root@$PVE_HOST:$REMOTE_TMP/chunks/ ..."
ssh -o BatchMode=yes "root@$PVE_HOST" "mkdir -p $REMOTE_TMP/chunks"
scp -q "$CHUNK_DIR"/chunk_* "root@$PVE_HOST:$REMOTE_TMP/chunks/"
ok "Chunks uploaded to PVE"

# =============================================================================
# Step 4: push chunks into the VM via QEMU guest agent
# =============================================================================
# qm_guest_exec_retry CMD...
#   Runs `qm guest exec $VMID -- CMD...` on the PVE host with retry on the
#   "QEMU guest agent is not running" error (which happens when MariaDB
#   pegs the VM during heavy load).
qm_guest_exec_retry() {
    local attempt=1
    local max=5
    local sleep_s=30
    local out rc
    while (( attempt <= max )); do
        if out=$(ssh -o BatchMode=yes "root@$PVE_HOST" "$@" 2>&1); then
            printf '%s' "$out"
            return 0
        fi
        rc=$?
        if [[ "$out" == *"QEMU guest agent is not running"* ]] \
        || [[ "$out" == *"guest-exec"*"failed"*               ]] \
        || [[ "$out" == *"agent"*"not"*"responding"*          ]]; then
            warn "guest agent not responding (attempt $attempt/$max); sleeping ${sleep_s}s ..."
            sleep "$sleep_s"
            attempt=$(( attempt + 1 ))
            continue
        fi
        printf '%s' "$out" >&2
        return "$rc"
    done
    warn "Guest agent never came back after $max attempts."
    warn "Run this manually from your whitelisted SSH session:"
    warn "  ssh root@$PVE_HOST '$*'"
    return 1
}

REMOTE_VM_TMP="/tmp/m3u_upload_${RUN_ID}"

# Initialize the VM-side workspace and the concatenated b64 file.
info "Preparing workspace inside VM $VMID ..."
qm_guest_exec_retry "qm guest exec $VMID -- /bin/bash -c \
    'mkdir -p $REMOTE_VM_TMP && : > $REMOTE_VM_TMP/xui_load.sql.gz.b64'" \
    >/dev/null

info "Streaming $CHUNK_COUNT chunks into VM $VMID via pvesh + qm guest exec ..."
i=0
for chunk in "$CHUNK_DIR"/chunk_*; do
    name=$(basename "$chunk")
    i=$(( i + 1 ))
    # 4a) write the chunk into the VM with pvesh file-write
    #     (content is the base64 blob itself, already <=60KB)
    # 4b) append it to the cumulative b64 file inside the VM
    ssh -o BatchMode=yes "root@$PVE_HOST" bash -s -- \
        "$VMID" "$name" "$REMOTE_TMP/chunks/$name" "$REMOTE_VM_TMP" <<'REMOTE_EOF'
set -euo pipefail
VMID="$1"; NAME="$2"; SRC="$3"; VMTMP="$4"
NODE=$(hostname)
CONTENT=$(cat "$SRC")
# Push the chunk into the VM as /tmp/<name>
pvesh create "/nodes/$NODE/qemu/$VMID/agent/file-write" \
    --file "/tmp/$NAME" \
    --content "$CONTENT" >/dev/null
# Append it to the cumulative b64 in the VM, then drop the per-chunk file.
qm guest exec "$VMID" -- /bin/bash -c \
    "cat /tmp/$NAME >> $VMTMP/xui_load.sql.gz.b64 && rm -f /tmp/$NAME" >/dev/null
REMOTE_EOF
    if (( i % 20 == 0 )) || (( i == CHUNK_COUNT )); then
        info "  pushed $i/$CHUNK_COUNT chunks"
    fi
done
ok "All $CHUNK_COUNT chunks delivered into VM"

# =============================================================================
# Step 5: decode inside the VM and verify MD5
# =============================================================================
info "Decoding base64 + gunzip inside VM ..."
qm_guest_exec_retry "qm guest exec $VMID -- /bin/bash -c \
    'base64 -d $REMOTE_VM_TMP/xui_load.sql.gz.b64 | gunzip > $REMOTE_VM_TMP/xui_load.sql'" \
    >/dev/null

info "Verifying MD5 inside VM ..."
REMOTE_MD5_RAW=$(qm_guest_exec_retry "qm guest exec $VMID -- /bin/bash -c \
    'md5sum $REMOTE_VM_TMP/xui_load.sql'")
# `qm guest exec` returns JSON; extract the md5 hex no matter the wrapper.
REMOTE_MD5=$(printf '%s' "$REMOTE_MD5_RAW" | grep -oE '[0-9a-f]{32}' | head -n1 || true)
[[ -n "$REMOTE_MD5" ]] || fail "Could not extract remote MD5 from guest output"

info "VM SQL md5  : $REMOTE_MD5"
info "Local SQL md5: $SQL_MD5_LOCAL"
[[ "$REMOTE_MD5" == "$SQL_MD5_LOCAL" ]] \
    || fail "MD5 mismatch! VM file is corrupt; aborting before touching MariaDB."
ok "MD5 verified: VM SQL matches local"

# =============================================================================
# Step 6: optional TRUNCATE
# =============================================================================
if (( DO_TRUNCATE == 1 )); then
    warn "TRUNCATING streams_servers, streams, streams_categories in xui ..."
    qm_guest_exec_retry "qm guest exec $VMID -- /bin/bash -c \
        \"mysql xui -e 'TRUNCATE TABLE streams_servers; TRUNCATE TABLE streams; TRUNCATE TABLE streams_categories;'\"" \
        >/dev/null
    ok "Tables truncated"
fi

# =============================================================================
# Step 7: load the SQL
# =============================================================================
info "Loading SQL into xui (this can take a while) ..."
LOAD_OUT=$(qm_guest_exec_retry "qm guest exec $VMID -- /bin/bash -c \
    'cd /tmp && { time mysql xui < $REMOTE_VM_TMP/xui_load.sql; } 2>&1 | tail -n 20; echo EXIT=\$?'") \
    || fail "mysql import failed (see output above)"

printf '%s\n' "$LOAD_OUT"
MYSQL_EXIT=$(printf '%s' "$LOAD_OUT" | grep -oE 'EXIT=[0-9]+' | tail -n1 | cut -d= -f2 || true)
if [[ -z "$MYSQL_EXIT" ]]; then
    warn "Could not parse mysql exit code from output; assuming 0"
    MYSQL_EXIT=0
fi
if [[ "$MYSQL_EXIT" != "0" ]]; then
    warn "mysql reported exit code $MYSQL_EXIT (partial categories may have survived; see verify step)"
fi

# =============================================================================
# Step 8: verify row counts
# =============================================================================
info "Counting rows in xui ..."
COUNT_OUT=$(qm_guest_exec_retry "qm guest exec $VMID -- /bin/bash -c \
    \"mysql xui -N -B -e 'SELECT COUNT(*) FROM streams WHERE type=1; SELECT COUNT(*) FROM streams_categories WHERE category_type=\\\"live\\\";'\"")

# Extract the two integer counts from whatever wrapping qm uses.
COUNTS=$(printf '%s' "$COUNT_OUT" | grep -oE '^[0-9]+$' || true)
STREAMS_DB=$( printf '%s' "$COUNTS" | sed -n '1p')
CATS_DB=$(    printf '%s' "$COUNTS" | sed -n '2p')

[[ -n "$STREAMS_DB" && -n "$CATS_DB" ]] \
    || fail "Could not parse row counts from VM output:\n$COUNT_OUT"

info "DB live streams    : $STREAMS_DB"
info "DB live categories : $CATS_DB  (expected: $CAT_COUNT)"

if [[ "$CATS_DB" != "$CAT_COUNT" ]]; then
    warn "Category count mismatch: DB=$CATS_DB, expected=$CAT_COUNT"
    warn "Listing categories present in SQL but missing in DB ..."
    # Extract expected category names from the SQL comments.
    EXPECTED_CATS=$(grep -oE '^-- ===== Category [0-9]+/[0-9]+: .*  \([0-9]+ streams' "$SQL_LOCAL" \
                    | sed -E 's/^-- ===== Category [0-9]+\/[0-9]+: (.*)  \([0-9]+ streams.*/\1/')
    DB_CATS_RAW=$(qm_guest_exec_retry "qm guest exec $VMID -- /bin/bash -c \
        \"mysql xui -N -B -e 'SELECT category_name FROM streams_categories WHERE category_type=\\\"live\\\";'\"")
    # Best-effort diff; we strip JSON wrapping by keeping non-empty short lines.
    DB_CATS=$(printf '%s' "$DB_CATS_RAW" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true)
    MISSING=$(comm -23 <(printf '%s\n' "$EXPECTED_CATS" | sort -u) \
                       <(printf '%s\n' "$DB_CATS"      | sort -u) || true)
    if [[ -n "$MISSING" ]]; then
        warn "Missing categories:"
        printf '%s\n' "$MISSING" | sed 's/^/    - /' >&2
    fi
    fail "Aborting non-zero: load incomplete."
fi

ok "Load complete: $STREAMS_DB streams across $CATS_DB categories"
ok "Done."
