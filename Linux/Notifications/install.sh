#!/usr/bin/env bash
#
# install.sh
# 2026-08-10
# Version: v1.0.2
#
# PURPOSE:
# Interactive installer for linux-notifications: installs and configures
# an SMTP relay (via msmtp) so this host can send alert emails, and
# deploys a `send-alert` command onto PATH that any other script or cron
# job on the host can call. Re-run at any time to change the SMTP
# settings or default recipient.
#
# CHANGELOG:
#   v1.0.3 - config.conf values are now printf %q-escaped instead of being
#            interpolated with bare double quotes - a DEFAULT_ALERT_TO or
#            SMTP_FROM value containing a shell metacharacter (e.g. a
#            trailing `"$(...)`) previously allowed injection into a file
#            this tool's own send-alert command bash-sources on every
#            invocation. Matches the same fix in Linux/Updates/install.sh.
#   v1.0.2 - Preseed the msmtp/apparmor debconf question and pass
#            DEBIAN_FRONTEND=noninteractive on Debian-family hosts. Without
#            this, `apt-get install msmtp` drops into an interactive
#            whiptail "Enable AppArmor support?" dialog whenever a TTY is
#            attached, hanging the installer until someone answers it (and
#            on some consoles/serial links the dialog cannot be answered
#            at all because arrow-key escape sequences aren't interpreted
#            as navigation). AppArmor is now enabled by default; override
#            by exporting MSMTP_APPARMOR=false before running this script.
#   v1.0.1 - Added -E (errtrace) so the ERR trap below actually fires when
#            a command fails inside install_prerequisites() - without it,
#            bash does not propagate ERR traps into function bodies, so a
#            failed apt-get/dnf install there was silently missing its
#            "failed at line N" message (set -e still aborted the script
#            correctly either way).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/linux-notifications"
CONFIG_DIR="/etc/linux-notifications"
CONFIG_FILE="$CONFIG_DIR/config.conf"
MSMTP_CONFIG="$CONFIG_DIR/msmtprc"
LOG_DIR="/var/log/linux-notifications"
BIN_LINK="/usr/local/bin/send-alert"

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
# 0. Dependency check, all up front. mktemp/timeout/awk ship with coreutils
#    on virtually every distro; msmtp is what we are about to install, so
#    it is checked separately after the install step below.
# ---------------------------------------------------------------------------
required_cmds=(timeout hostname awk)
missing_cmds=()
for cmd in "${required_cmds[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing_cmds+=("$cmd")
done
if (( ${#missing_cmds[@]} > 0 )); then
    die "Missing required commands: ${missing_cmds[*]}. These ship with coreutils on virtually every distro; if they are absent, this is not a standard Linux environment."
fi

# ---------------------------------------------------------------------------
# 1. Install msmtp
# ---------------------------------------------------------------------------
install_prerequisites() {
    log_info "Installing prerequisites (msmtp)..."
    case "$DISTRO_FAMILY" in
        debian)
            apt-get update -y
            # Debian/Ubuntu's msmtp package asks an interactive "Enable
            # AppArmor support?" debconf question on first install. Preseed
            # it so apt-get never blocks on a whiptail dialog (which, on
            # some consoles, cannot even be answered - arrow keys land as
            # literal text instead of moving focus).
            echo "msmtp msmtp/apparmor boolean ${MSMTP_APPARMOR:-true}" | debconf-set-selections
            DEBIAN_FRONTEND=noninteractive apt-get install -y msmtp
            ;;
        fedora)
            dnf install -y msmtp
            ;;
        rhel)
            "$PKG_MANAGER" install -y msmtp
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
# 2. SMTP relay for alerts
# ---------------------------------------------------------------------------
echo
log_info "== SMTP relay setup (for alert emails) =="
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
DEFAULT_ALERT_TO="$(ask "Default alert recipient email address(es), comma-separated (individual callers can override this per message)")"

log_info "Writing SMTP relay config to $MSMTP_CONFIG..."
{
    echo "# Managed by linux-notifications installer - do not edit manually"
    echo "defaults"
    echo "logfile        $LOG_DIR/msmtp.log"
    echo
    echo "account        linux-notifications"
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
    echo "account default : linux-notifications"
} > "$MSMTP_CONFIG"
chmod 600 "$MSMTP_CONFIG"
chown root:root "$MSMTP_CONFIG"

# ---------------------------------------------------------------------------
# 3. Deploy scripts, config, and the send-alert PATH command
# ---------------------------------------------------------------------------
log_info "Deploying scripts to $INSTALL_DIR..."
cp -f "$SCRIPT_DIR/bin/send-alert.sh" "$INSTALL_DIR/bin/send-alert.sh"
cp -f "$SCRIPT_DIR/lib/common.sh" "$SCRIPT_DIR/lib/distro.sh" "$SCRIPT_DIR/lib/notify.sh" "$INSTALL_DIR/lib/"
chmod +x "$INSTALL_DIR/bin/send-alert.sh"

log_info "Linking $BIN_LINK -> $INSTALL_DIR/bin/send-alert.sh..."
ln -sf "$INSTALL_DIR/bin/send-alert.sh" "$BIN_LINK"

log_info "Writing config to $CONFIG_FILE..."
{
    echo "# Managed by linux-notifications installer - do not edit manually"
    printf 'DEFAULT_ALERT_TO=%q\n' "$DEFAULT_ALERT_TO"
    printf 'SMTP_FROM=%q\n' "$SMTP_FROM"
} > "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"

# ---------------------------------------------------------------------------
# 4. Optional test email - exercises the exact same deployed path
#    (the send-alert command) that every future real alert will use.
# ---------------------------------------------------------------------------
echo
if [[ -n "$DEFAULT_ALERT_TO" ]] && confirm "Send a test alert email now?" "y"; then
    if "$BIN_LINK" --self-test; then
        log_info "Test email sent. Check the inbox for $DEFAULT_ALERT_TO."
    else
        log_warn "Test email failed to send. Check $LOG_DIR/msmtp.log and re-run install.sh to fix the SMTP settings."
    fi
fi

echo
log_info "Installation complete."
echo "  Config:      $CONFIG_FILE"
echo "  SMTP relay:  $MSMTP_CONFIG"
echo "  Command:     send-alert (symlinked at $BIN_LINK)"
echo "  Logs:        $LOG_DIR"
echo
echo "Send an alert from any script or cron job with:"
echo "  send-alert \"Subject\" \"Body text\""
echo "Run a self-test at any time with:"
echo "  send-alert --self-test"
