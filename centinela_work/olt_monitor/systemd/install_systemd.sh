#!/usr/bin/env bash
#
# install_systemd.sh — install/refresh OLT Optical Monitor systemd units.
#
# Idempotent: re-running picks up unit-file changes (overwritten on each
# install), but preserves /etc/default/olt-monitor if it already exists so
# local edits (BIND_HOST, BIND_PORT, OLT_MONITOR_AUTH) are not clobbered.

set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "ERROR: this installer must be run as root (try: sudo $0)" >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEMD_DIR="/etc/systemd/system"
ENV_DST="/etc/default/olt-monitor"

UNITS=(
    "olt-monitor-collect.service"
    "olt-monitor-collect.timer"
    "olt-monitor-web.service"
)

echo "==> Source dir:   ${SRC_DIR}"
echo "==> Systemd dir:  ${SYSTEMD_DIR}"
echo

# Sanity-check that all source files exist before touching the system.
for unit in "${UNITS[@]}"; do
    if [[ ! -f "${SRC_DIR}/${unit}" ]]; then
        echo "ERROR: missing source file: ${SRC_DIR}/${unit}" >&2
        exit 1
    fi
done
if [[ ! -f "${SRC_DIR}/olt-monitor.env" ]]; then
    echo "ERROR: missing source file: ${SRC_DIR}/olt-monitor.env" >&2
    exit 1
fi

# Install (overwrite) the unit files.
for unit in "${UNITS[@]}"; do
    install -m 0644 "${SRC_DIR}/${unit}" "${SYSTEMD_DIR}/${unit}"
    echo "    installed ${SYSTEMD_DIR}/${unit}"
done

# Install env file only if missing — do not clobber user edits.
if [[ -e "${ENV_DST}" ]]; then
    echo "    keeping existing ${ENV_DST} (not overwritten)"
else
    install -m 0644 -D "${SRC_DIR}/olt-monitor.env" "${ENV_DST}"
    echo "    installed ${ENV_DST}"
fi

echo
echo "==> systemctl daemon-reload"
systemctl daemon-reload

echo
echo "==> Enabling and starting timer + web service"
systemctl enable --now olt-monitor-collect.timer
systemctl enable --now olt-monitor-web.service

echo
echo "==> Status: olt-monitor-collect.timer"
systemctl status --no-pager olt-monitor-collect.timer || true

echo
echo "==> Status: olt-monitor-web.service"
systemctl status --no-pager olt-monitor-web.service || true

echo
echo "==> Next scheduled collect run"
systemctl list-timers --no-pager olt-monitor-collect.timer || true

echo
echo "Done. View logs with:"
echo "    journalctl -u olt-monitor-collect.service -f"
echo "    journalctl -u olt-monitor-web.service -f"
echo "    tail -f /var/log/olt-monitor.log /var/log/olt-monitor-web.log"
