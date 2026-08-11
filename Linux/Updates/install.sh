#!/usr/bin/env bash
#
# install.sh
# 2026-08-10
# Version: v1.0.1
#
# PURPOSE:
# Interactive installer for linux-updates. Detects the host distro
# (Debian/Ubuntu today, Fedora/RHEL-family also supported), walks through
# picking an update schedule and configuring an SMTP relay for alerts,
# then deploys itself as a cron job. Re-run at any time to change the
# schedule, update mode, or SMTP settings.
#
# CHANGELOG:
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
install_prerequisites() {
    log_info "Installing prerequisites (cron, msmtp)..."
    case "$DISTRO_FAMILY" in
        debian)
            apt-get update -y
            apt-get install -y cron msmtp
            systemctl enable --now cron >/dev/null 2>&1 || true
            ;;
        fedora)
            dnf install -y cronie msmtp
            systemctl enable --now crond >/dev/null 2>&1 || true
            ;;
        rhel)
            "$PKG_MANAGER" install -y cronie msmtp
            if [[ "$PKG_MANAGER" == "yum" ]]; then
                "$PKG_MANAGER" install -y yum-plugin-security >/dev/null 2>&1 || true
            fi
            systemctl enable --now crond >/dev/null 2>&1 || true
            ;;
    esac
}
install_prerequisites

# Never trust the package manager's exit code alone - confirm the command
# actually resolves before relying on it below.
if ! command -v msmtp >/dev/null 2>&1; then
    die "msmtp installed but the 'msmtp' command still cannot be found. Check the package manager output above."
fi

mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" "$CONFIG_DIR" "$LOG_DIR"

# ---------------------------------------------------------------------------
# 2. Update mode
# ---------------------------------------------------------------------------
echo
log_info "== Update mode =="
echo "  1) All available updates (recommended)"
echo "  2) Security updates only"
UPDATE_MODE_CHOICE="$(ask "Choose an option" "1")"
case "$UPDATE_MODE_CHOICE" in
    2) UPDATE_MODE="security" ;;
    *) UPDATE_MODE="all" ;;
esac
log_info "Update mode set to: $UPDATE_MODE"

# ---------------------------------------------------------------------------
# 3. Maintenance schedule
# ---------------------------------------------------------------------------
echo
log_info "== Maintenance schedule =="
echo "  1) Daily at 03:00"
echo "  2) Weekly, Sunday at 03:00 (recommended)"
echo "  3) Monthly, 1st of the month at 03:00"
echo "  4) Custom cron expression"
SCHEDULE_CHOICE="$(ask "Choose an option" "2")"
case "$SCHEDULE_CHOICE" in
    1) CRON_SCHEDULE="0 3 * * *" ;;
    3) CRON_SCHEDULE="0 3 1 * *" ;;
    4)
        while true; do
            CRON_SCHEDULE="$(ask "Enter a 5-field cron expression (min hour dom mon dow)" "0 3 * * 0")"
            field_count="$(awk '{print NF}' <<< "$CRON_SCHEDULE")"
            if [[ "$field_count" -eq 5 ]]; then
                break
            fi
            log_warn "That doesn't look like a 5-field cron expression, try again."
        done
        ;;
    *) CRON_SCHEDULE="0 3 * * 0" ;;
esac
log_info "Schedule set to: $CRON_SCHEDULE"

# ---------------------------------------------------------------------------
# 4. SMTP relay for alerts
# ---------------------------------------------------------------------------
echo
log_info "== SMTP relay setup (for update alert emails) =="
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

SMTP_FROM="$(ask "\"From\" address for alert emails" "${SMTP_USER:-alerts@example.com}")"
ALERT_TO="$(ask "Alert recipient email address(es), comma-separated")"

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

# ---------------------------------------------------------------------------
# 5. Deploy scripts and config
# ---------------------------------------------------------------------------
log_info "Deploying scripts to $INSTALL_DIR..."
cp -f "$SCRIPT_DIR/bin/run-updates.sh" "$INSTALL_DIR/bin/run-updates.sh"
cp -f "$SCRIPT_DIR/lib/common.sh" "$SCRIPT_DIR/lib/distro.sh" "$SCRIPT_DIR/lib/notify.sh" "$INSTALL_DIR/lib/"
chmod +x "$INSTALL_DIR/bin/run-updates.sh"

log_info "Writing config to $CONFIG_FILE..."
{
    echo "# Managed by linux-updates installer - do not edit manually"
    echo "UPDATE_MODE=\"$UPDATE_MODE\""
    echo "ALERT_TO=\"$ALERT_TO\""
    echo "SMTP_FROM=\"$SMTP_FROM\""
} > "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"

log_info "Installing cron job at $CRON_FILE..."
{
    echo "# Managed by linux-updates installer - do not edit manually"
    echo "MAILTO=\"\""
    echo "$CRON_SCHEDULE root $INSTALL_DIR/bin/run-updates.sh"
} > "$CRON_FILE"
chmod 644 "$CRON_FILE"

# ---------------------------------------------------------------------------
# 6. Optional test email
# ---------------------------------------------------------------------------
echo
if [[ -n "$ALERT_TO" ]] && confirm "Send a test alert email now?" "y"; then
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
