#!/usr/bin/env bash
#
# uninstall.sh
# 2026-08-10
# Version: v1.0.1
#
# PURPOSE:
# Removes the linux-updates cron job, deployed scripts, and config.
# Package manager prerequisites (cron/msmtp) are left in place since
# other things on the host may depend on them.
#
# CHANGELOG:
#   v1.0.1 - Switched to set -Eeuo pipefail with a fail-loud ERR trap - a
#            failed removal step (e.g. a busy file under $INSTALL_DIR)
#            previously went undetected and the script still printed
#            "Uninstall complete".

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/linux-updates"
CONFIG_DIR="/etc/linux-updates"
CRON_FILE="/etc/cron.d/linux-updates"
LOG_DIR="/var/log/linux-updates"

fail_trap() {
    local lineno="$1"
    echo "ERROR: ${0##*/} failed at line ${lineno}." >&2
    exit 1
}
trap 'fail_trap "$LINENO"' ERR

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_root

if [[ -f "$CRON_FILE" ]]; then
    rm -f "$CRON_FILE"
    log_info "Removed cron job: $CRON_FILE"
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
