#!/usr/bin/env bash
#
# uninstall.sh
# 2026-08-09
# Version: v1.0.0
#
# PURPOSE:
# Removes the linux-notifications deployed scripts, config, and the
# send-alert PATH command. The msmtp package itself is left in place
# since other things on the host may depend on it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/linux-notifications"
CONFIG_DIR="/etc/linux-notifications"
LOG_DIR="/var/log/linux-notifications"
BIN_LINK="/usr/local/bin/send-alert"

fail_trap() {
    local lineno="$1"
    echo "ERROR: ${0##*/} failed at line ${lineno}." >&2
    exit 1
}
trap 'fail_trap "$LINENO"' ERR

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_root

if [[ -L "$BIN_LINK" || -e "$BIN_LINK" ]]; then
    rm -f "$BIN_LINK"
    log_info "Removed command: $BIN_LINK"
fi

if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    log_info "Removed deployed scripts: $INSTALL_DIR"
fi

if [[ -d "$CONFIG_DIR" ]]; then
    rm -rf "$CONFIG_DIR"
    log_info "Removed config: $CONFIG_DIR"
fi

if [[ -d "$LOG_DIR" ]]; then
    if confirm "Also delete logs in $LOG_DIR?" "n"; then
        rm -rf "$LOG_DIR"
        log_info "Removed logs: $LOG_DIR"
    else
        log_info "Left logs in place: $LOG_DIR"
    fi
fi

log_info "Uninstall complete."
