#!/usr/bin/env bash
#
# run-updates.sh
# 2026-08-09
# Version: v1.0.0
#
# PURPOSE:
# Runs OS package updates and emails a summary. Deployed to
# /opt/linux-updates by install.sh and invoked on schedule via
# /etc/cron.d/linux-updates. Safe to run manually for testing.

set -uo pipefail

INSTALL_DIR="/opt/linux-updates"
CONFIG_FILE="/etc/linux-updates/config.conf"
LOG_DIR="/var/log/linux-updates"
LOG_RETENTION_DAYS=30

# shellcheck source=lib/common.sh
. "$INSTALL_DIR/lib/common.sh"
# shellcheck source=lib/distro.sh
. "$INSTALL_DIR/lib/distro.sh"
# shellcheck source=lib/notify.sh
. "$INSTALL_DIR/lib/notify.sh"

require_root

[[ -f "$CONFIG_FILE" ]] || die "Missing config file: $CONFIG_FILE (re-run install.sh)"
# shellcheck source=/dev/null
. "$CONFIG_FILE"
UPDATE_MODE="${UPDATE_MODE:-all}"

detect_distro
[[ -n "$PKG_MANAGER" ]] || die "Unsupported or undetected distro/package manager"

mkdir -p "$LOG_DIR"
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="$LOG_DIR/update-$RUN_STAMP.log"
exec > >(tee -a "$RUN_LOG") 2>&1

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
log_info "Starting update run on $HOSTNAME_FQDN ($DISTRO_NAME, mode=$UPDATE_MODE)"

run_debian_update() {
    apt-get update -y || return $?

    if [[ "$UPDATE_MODE" == "security" ]]; then
        local pkg upgradable=""
        while read -r pkg; do
            [[ -z "$pkg" ]] && continue
            if apt-cache policy "$pkg" 2>/dev/null | grep -qi 'security'; then
                upgradable="$upgradable $pkg"
            fi
        done < <(apt-get --just-print upgrade 2>/dev/null | awk '/^Inst/ {print $2}')

        if [[ -n "$upgradable" ]]; then
            # shellcheck disable=SC2086
            apt-get install -y --only-upgrade $upgradable
        else
            log_info "No security updates available"
        fi
    else
        apt-get upgrade -y
    fi
    local status=$?
    apt-get autoremove -y || true
    return $status
}

run_dnf_yum_update() {
    local security_flag=()
    [[ "$UPDATE_MODE" == "security" ]] && security_flag=(--security)
    "$PKG_MANAGER" upgrade -y "${security_flag[@]}"
    local status=$?
    "$PKG_MANAGER" autoremove -y || true
    return $status
}

case "$PKG_MANAGER" in
    apt-get) run_debian_update ;;
    dnf|yum) run_dnf_yum_update ;;
    *) die "Unsupported or undetected package manager: $PKG_MANAGER" ;;
esac
UPDATE_STATUS=$?

REBOOT_REQUIRED="no"
if [[ -f /var/run/reboot-required ]]; then
    REBOOT_REQUIRED="yes"
elif command -v needs-restarting >/dev/null 2>&1; then
    needs-restarting -r >/dev/null 2>&1 || REBOOT_REQUIRED="yes"
fi

if [[ $UPDATE_STATUS -eq 0 ]]; then
    STATUS_LABEL="SUCCESS"
else
    STATUS_LABEL="FAILED"
fi

SUBJECT="[linux-updates] $STATUS_LABEL on $HOSTNAME_FQDN"
BODY="Update run finished with status: $STATUS_LABEL
Host:            $HOSTNAME_FQDN
Distro:          $DISTRO_NAME
Package manager: $PKG_MANAGER
Update mode:     $UPDATE_MODE
Reboot required: $REBOOT_REQUIRED
Log file:        $RUN_LOG

--- Log tail ---
$(tail -n 60 "$RUN_LOG")"

send_alert "$SUBJECT" "$BODY" || log_warn "Alert email not sent"

find "$LOG_DIR" -name 'update-*.log' -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true

log_info "Update run complete: $STATUS_LABEL (reboot_required=$REBOOT_REQUIRED)"
exit "$UPDATE_STATUS"
