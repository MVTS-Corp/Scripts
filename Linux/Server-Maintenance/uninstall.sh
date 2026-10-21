#!/usr/bin/env bash
#
# uninstall.sh
# 2026-10-18
# Version: v1.0.0
#
# PURPOSE:
# Removes server-maintenance: systemd units, the deployed scripts and the
# command link. Asks before deleting the config (which holds the heartbeat
# URLs), the state (approvals, compose file backups, history) and the logs.
# Packages it installed (jq, curl, acl, ...) are left in place, since other
# things on the host may use them. Compose files and containers are never
# touched.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/server-maintenance"
CONFIG_DIR="/etc/server-maintenance"
STATE_DIR="/var/lib/server-maintenance"
LOG_DIR="/var/log/server-maintenance"
BIN_LINK="/usr/local/sbin/server-maintenance"
UNIT_DIR="/etc/systemd/system"
UNITS=(server-maintenance-check.timer server-maintenance-run.timer server-maintenance-post-boot.service
       server-maintenance-check.service server-maintenance-run.service)

fail_trap() {
    local lineno="$1"
    echo "ERROR: ${0##*/} failed at line ${lineno}." >&2
    exit 1
}
trap 'fail_trap "$LINENO"' ERR

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_root

if systemctl is-active --quiet server-maintenance-run.service 2>/dev/null; then
    die "A maintenance run is in progress right now; wait for it to finish, then re-run this."
fi

for unit in "${UNITS[@]}"; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    if [[ -f "$UNIT_DIR/$unit" ]]; then
        rm -f "$UNIT_DIR/$unit"
        log_info "Removed unit: $unit"
    fi
done
systemctl daemon-reload

if [[ -L "$BIN_LINK" || -e "$BIN_LINK" ]]; then
    rm -f "$BIN_LINK"
    log_info "Removed command: $BIN_LINK"
fi

if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    log_info "Removed deployed scripts: $INSTALL_DIR"
fi

if [[ -d "$CONFIG_DIR" ]] && confirm "Delete the config in $CONFIG_DIR (includes heartbeat URLs and image definitions)?" "n"; then
    rm -rf "$CONFIG_DIR"
    log_info "Removed config: $CONFIG_DIR"
fi

if [[ -d "$STATE_DIR" ]] && confirm "Delete state in $STATE_DIR (approvals, compose file backups, update history)?" "n"; then
    rm -rf "$STATE_DIR"
    log_info "Removed state: $STATE_DIR"
fi

if [[ -d "$LOG_DIR" ]] && confirm "Delete logs in $LOG_DIR?" "n"; then
    rm -rf "$LOG_DIR"
    log_info "Removed logs: $LOG_DIR"
fi

log_info "Uninstall complete."
