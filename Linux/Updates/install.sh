#!/usr/bin/env bash
#
# install.sh
# 2026-08-22
# Version: v1.1.0
#
# PURPOSE:
# Interactive installer for linux-updates. Detects the host distro
# (Debian/Ubuntu today, Fedora/RHEL-family also supported), walks through
# picking an update schedule and configuring an SMTP relay for alerts,
# then deploys itself as a cron job. Re-run at any time to change the
# schedule, update mode, or SMTP settings.
#
# CHANGELOG:
#   v1.1.0 - Re-runs now default every prompt (update mode, schedule,
#            alert recipient, log access group) to the existing config
#            instead of resetting it, and skip SMTP re-entry unless
#            explicitly requested. config.conf values are now printf
#            %q-escaped instead of interpolated with bare double quotes -
#            a user-entered ALERT_TO/SMTP_FROM containing a shell
#            metacharacter previously allowed injection into a file that
#            run-updates.sh bash-sources. Custom cron expressions are now
#            field-validated (syntax and range), not just checked for a
#            5-field count. Also installs acl (for log-directory POSIX
#            ACLs) and the distro-appropriate reboot-required helper
#            (update-notifier-common / dnf-utils / yum-utils) as
#            prerequisites, verifies each systemctl-enabled service is
#            actually active rather than assuming enable succeeded, and
#            adds a log-access-group prompt that's applied via
#            apply_log_permissions() (lib/common.sh). The alert recipient
#            prompt now loops until non-blank instead of silently
#            accepting an empty value.
#   v1.0.1 - Switched to set -Eeuo pipefail with a fail-loud ERR trap (a
#            failed apt-get/dnf prerequisite install previously went
#            undetected - the script would proceed to write the cron job
#            and print "Installation complete" regardless), and added a
#            post-install check that the msmtp command actually resolves.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/linux-updates"
CONFIG_DIR="/etc/linux-updates"
CONFIG_FILE="$CONFIG_DIR/config.conf"
MSMTP_CONFIG="$CONFIG_DIR/msmtprc"
CRON_FILE="/etc/cron.d/linux-updates"
LOG_DIR="/var/log/linux-updates"

# Avoids apt-get blocking on a debconf/conffile prompt when a package
# maintainer script wants interactive input (e.g. grub-pc, openssh-server).
export DEBIAN_FRONTEND=noninteractive
APT_CONF_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

fail_trap() {
    local lineno="$1"
    echo "ERROR: ${0##*/} failed at line ${lineno}. No further changes were made past this point." >&2
    exit 1
}
trap 'fail_trap "$LINENO"' ERR

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/distro.sh
. "$SCRIPT_DIR/lib/distro.sh"

require_root

log_info "Detecting Linux distribution..."
detect_distro
if [[ -z "$PKG_MANAGER" ]]; then
    die "Could not determine a supported package manager for '$DISTRO_NAME' (ID=$DISTRO_ID, ID_LIKE=$DISTRO_ID_LIKE)."
fi
log_info "Detected: $DISTRO_NAME  (family=$DISTRO_FAMILY, package manager=$PKG_MANAGER)"

# ---------------------------------------------------------------------------
# 1. Install prerequisites
# ---------------------------------------------------------------------------
systemctl_enable_now() {
    local svc="$1"
    if ! command -v systemctl >/dev/null 2>&1; then
        log_warn "systemctl not found; skipping enable of '$svc'. Make sure it's started by your init system, or scheduled updates will never run."
        return 0
    fi
    systemctl enable --now "$svc" >/dev/null 2>&1
    if systemctl is-active --quiet "$svc"; then
        log_info "$svc service is active."
    else
        log_warn "$svc could not be verified as active. Scheduled updates may not run - check with: systemctl status $svc"
    fi
}

install_prerequisites() {
    log_info "Installing prerequisites (cron, msmtp, acl, reboot-check tools)..."
    case "$DISTRO_FAMILY" in
        debian)
            apt-get update -y || die "apt-get update failed; check network/repo configuration and re-run."
            apt-get install -y "${APT_CONF_OPTS[@]}" cron msmtp acl update-notifier-common \
                || die "Failed to install prerequisite packages (cron, msmtp, acl, update-notifier-common)."
            systemctl_enable_now cron
            ;;
        fedora)
            dnf install -y cronie msmtp acl dnf-utils \
                || die "Failed to install prerequisite packages (cronie, msmtp, acl, dnf-utils)."
            systemctl_enable_now crond
            ;;
        rhel)
            "$PKG_MANAGER" install -y cronie msmtp acl yum-utils \
                || die "Failed to install prerequisite packages (cronie, msmtp, acl, yum-utils)."
            if [[ "$PKG_MANAGER" == "yum" ]]; then
                "$PKG_MANAGER" install -y yum-plugin-security >/dev/null 2>&1 \
                    || log_warn "Could not install yum-plugin-security; 'security only' mode may not work on this host."
            fi
            systemctl_enable_now crond
            ;;
    esac
}
install_prerequisites

# Never trust the package manager's exit code alone - confirm the command
# actually resolves before relying on it below.
if ! command -v msmtp >/dev/null 2>&1; then
    die "msmtp installed but the 'msmtp' command still cannot be found. Check the package manager output above."
fi

mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" "$CONFIG_DIR" "$LOG_DIR" \
    || die "Failed to create required directories."

# ---------------------------------------------------------------------------
# 2. Load existing configuration, if any, so a re-run can default to it
# ---------------------------------------------------------------------------
EXISTING_UPDATE_MODE=""
EXISTING_ALERT_TO=""
EXISTING_SMTP_FROM=""
EXISTING_LOG_ACCESS_GROUP=""
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
    EXISTING_UPDATE_MODE="${UPDATE_MODE:-}"
    EXISTING_ALERT_TO="${ALERT_TO:-}"
    EXISTING_SMTP_FROM="${SMTP_FROM:-}"
    EXISTING_LOG_ACCESS_GROUP="${LOG_ACCESS_GROUP:-}"
    unset UPDATE_MODE ALERT_TO SMTP_FROM LOG_ACCESS_GROUP
fi

EXISTING_CRON_SCHEDULE=""
if [[ -f "$CRON_FILE" ]]; then
    EXISTING_CRON_SCHEDULE="$(awk '!/^#/ && !/^MAILTO/ && NF>=7 {print $1, $2, $3, $4, $5; exit}' "$CRON_FILE" 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# 3. Update mode
# ---------------------------------------------------------------------------
echo
log_info "== Update mode =="
echo "  1) All available updates (recommended)"
echo "  2) Security updates only"
DEFAULT_MODE_CHOICE="1"
[[ "$EXISTING_UPDATE_MODE" == "security" ]] && DEFAULT_MODE_CHOICE="2"
UPDATE_MODE_CHOICE="$(ask "Choose an option" "$DEFAULT_MODE_CHOICE")"
case "$UPDATE_MODE_CHOICE" in
    2) UPDATE_MODE="security" ;;
    *) UPDATE_MODE="all" ;;
esac
log_info "Update mode set to: $UPDATE_MODE"

# ---------------------------------------------------------------------------
# 4. Maintenance schedule
# ---------------------------------------------------------------------------
echo
log_info "== Maintenance schedule =="
echo "  1) Daily at 03:00"
echo "  2) Weekly, Sunday at 03:00 (recommended)"
echo "  3) Monthly, 1st of the month at 03:00"
echo "  4) Custom cron expression"

DEFAULT_SCHEDULE_CHOICE="2"
DEFAULT_CUSTOM_CRON="0 3 * * 0"
case "$EXISTING_CRON_SCHEDULE" in
    "0 3 * * *") DEFAULT_SCHEDULE_CHOICE="1" ;;
    "0 3 1 * *") DEFAULT_SCHEDULE_CHOICE="3" ;;
    "0 3 * * 0"|"") : ;;
    *) DEFAULT_SCHEDULE_CHOICE="4"; DEFAULT_CUSTOM_CRON="$EXISTING_CRON_SCHEDULE" ;;
esac

# validate_cron_field <field> <min> <max> - accepts "*" or standard
# list/range/step syntax outright, and range-checks a bare number.
validate_cron_field() {
    local field="$1" min="$2" max="$3"
    [[ "$field" == "*" ]] && return 0
    [[ "$field" =~ ^[0-9,/*-]+$ ]] || return 1
    if [[ "$field" =~ ^[0-9]+$ ]]; then
        (( field >= min && field <= max )) || return 1
    fi
    return 0
}

SCHEDULE_CHOICE="$(ask "Choose an option" "$DEFAULT_SCHEDULE_CHOICE")"
case "$SCHEDULE_CHOICE" in
    1) CRON_SCHEDULE="0 3 * * *" ;;
    3) CRON_SCHEDULE="0 3 1 * *" ;;
    4)
        while true; do
            CRON_SCHEDULE="$(ask "Enter a 5-field cron expression (min hour dom mon dow)" "$DEFAULT_CUSTOM_CRON")"
            read -r c_min c_hour c_dom c_mon c_dow extra <<< "$CRON_SCHEDULE" || true
            if [[ -n "$c_min" && -n "$c_hour" && -n "$c_dom" && -n "$c_mon" && -n "$c_dow" && -z "${extra:-}" ]] \
                && validate_cron_field "$c_min" 0 59 \
                && validate_cron_field "$c_hour" 0 23 \
                && validate_cron_field "$c_dom" 1 31 \
                && validate_cron_field "$c_mon" 1 12 \
                && validate_cron_field "$c_dow" 0 7; then
                break
            fi
            log_warn "That doesn't look like a valid 5-field cron expression, try again."
        done
        ;;
    *) CRON_SCHEDULE="0 3 * * 0" ;;
esac
log_info "Schedule set to: $CRON_SCHEDULE"

# ---------------------------------------------------------------------------
# 5. SMTP relay for alerts
# ---------------------------------------------------------------------------
echo
log_info "== SMTP relay setup (for update alert emails) =="

RECONFIGURE_SMTP="y"
if [[ -f "$MSMTP_CONFIG" ]] && confirm "Existing SMTP relay config found at $MSMTP_CONFIG. Keep it as-is?" "y"; then
    RECONFIGURE_SMTP="n"
fi

if [[ "$RECONFIGURE_SMTP" == "y" ]]; then
    SMTP_HOST="$(ask "SMTP relay host" "smtp.example.com")"

    echo "  1) STARTTLS (typical port 587)"
    echo "  2) Implicit TLS/SSL (typical port 465)"
    echo "  3) None / unencrypted (not recommended)"
    ENC_CHOICE="$(ask "Encryption" "1")"
    case "$ENC_CHOICE" in
        2) TLS_ON="on"; STARTTLS_ON="off"; DEFAULT_PORT="465" ;;
        3) TLS_ON="off"; STARTTLS_ON="off"; DEFAULT_PORT="25" ;;
        *) TLS_ON="on"; STARTTLS_ON="on"; DEFAULT_PORT="587" ;;
    esac
    SMTP_PORT="$(ask "SMTP port" "$DEFAULT_PORT")"

    SMTP_AUTH="on"
    if ! confirm "Does this relay require authentication?" "y"; then
        SMTP_AUTH="off"
    fi

    SMTP_USER=""
    SMTP_PASS=""
    if [[ "$SMTP_AUTH" == "on" ]]; then
        SMTP_USER="$(ask "SMTP username")"
        read -r -s -p "SMTP password: " SMTP_PASS
        echo
    fi

    SMTP_FROM="$(ask "\"From\" address for alert emails" "${SMTP_USER:-${EXISTING_SMTP_FROM:-alerts@example.com}}")"

    log_info "Writing SMTP relay config to $MSMTP_CONFIG..."
    {
        echo "# Managed by linux-updates installer - do not edit manually"
        echo "defaults"
        echo "logfile        $LOG_DIR/msmtp.log"
        echo
        echo "account        linux-updates"
        echo "host           $SMTP_HOST"
        echo "port           $SMTP_PORT"
        echo "from           $SMTP_FROM"
        echo "tls            $TLS_ON"
        echo "tls_starttls   $STARTTLS_ON"
        echo "tls_certcheck  on"
        echo "auth           $SMTP_AUTH"
        if [[ "$SMTP_AUTH" == "on" ]]; then
            echo "user           $SMTP_USER"
            echo "password       $SMTP_PASS"
        fi
        echo
        echo "account default : linux-updates"
    } > "$MSMTP_CONFIG"
    chmod 600 "$MSMTP_CONFIG"
    chown root:root "$MSMTP_CONFIG"
else
    SMTP_FROM="$EXISTING_SMTP_FROM"
    log_info "Keeping existing SMTP relay config."
fi

# ---------------------------------------------------------------------------
# 6. Alert recipient
# ---------------------------------------------------------------------------
echo
while true; do
    ALERT_TO="$(ask "Alert recipient email address(es), comma-separated" "$EXISTING_ALERT_TO")"
    [[ -n "$ALERT_TO" ]] && break
    log_warn "An alert recipient is required - otherwise you'll never be notified of update results."
done

# ---------------------------------------------------------------------------
# 7. Log access
# ---------------------------------------------------------------------------
echo
log_info "== Log access =="
echo "Update logs at $LOG_DIR are root-only by default. The 'adm' group (if it"
echo "exists on this host) is also granted read access, matching the usual"
echo "Debian/Ubuntu convention."
LOG_ACCESS_GROUP="$(ask "Additional group to grant read access to update logs (optional, leave blank for none)" "$EXISTING_LOG_ACCESS_GROUP")"

# ---------------------------------------------------------------------------
# 8. Deploy scripts and config
# ---------------------------------------------------------------------------
log_info "Deploying scripts to $INSTALL_DIR..."
cp -f "$SCRIPT_DIR/bin/run-updates.sh" "$INSTALL_DIR/bin/run-updates.sh" || die "Failed to deploy run-updates.sh"
cp -f "$SCRIPT_DIR/lib/common.sh" "$SCRIPT_DIR/lib/distro.sh" "$SCRIPT_DIR/lib/notify.sh" "$INSTALL_DIR/lib/" || die "Failed to deploy lib files"
chmod +x "$INSTALL_DIR/bin/run-updates.sh"

log_info "Writing config to $CONFIG_FILE..."
{
    echo "# Managed by linux-updates installer - do not edit manually"
    printf 'UPDATE_MODE=%q\n' "$UPDATE_MODE"
    printf 'ALERT_TO=%q\n' "$ALERT_TO"
    printf 'SMTP_FROM=%q\n' "$SMTP_FROM"
    printf 'LOG_ACCESS_GROUP=%q\n' "$LOG_ACCESS_GROUP"
} > "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"

apply_log_permissions "$LOG_DIR" "$LOG_ACCESS_GROUP"

log_info "Installing cron job at $CRON_FILE..."
{
    echo "# Managed by linux-updates installer - do not edit manually"
    echo "MAILTO=\"\""
    echo "$CRON_SCHEDULE root $INSTALL_DIR/bin/run-updates.sh"
} > "$CRON_FILE"
chmod 644 "$CRON_FILE"

# ---------------------------------------------------------------------------
# 9. Optional test email
# ---------------------------------------------------------------------------
echo
if confirm "Send a test alert email now?" "y"; then
    # shellcheck source=lib/notify.sh
    . "$INSTALL_DIR/lib/notify.sh"
    if send_alert "[linux-updates] Test email from $(hostname -f 2>/dev/null || hostname)" \
        "This is a test message confirming the linux-updates SMTP relay is working."; then
        log_info "Test email sent. Check the inbox for $ALERT_TO."
    else
        log_warn "Test email failed to send. Check $LOG_DIR/msmtp.log and re-run install.sh to fix the SMTP settings."
    fi
fi

echo
log_info "Installation complete."
echo "  Config:      $CONFIG_FILE"
echo "  SMTP relay:  $MSMTP_CONFIG"
echo "  Cron job:    $CRON_FILE  ($CRON_SCHEDULE)"
echo "  Logs:        $LOG_DIR"
echo
echo "Run a manual test at any time with:"
echo "  sudo $INSTALL_DIR/bin/run-updates.sh"
