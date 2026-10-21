#!/usr/bin/env bash
#
# install.sh
# 2026-10-18
# Version: v1.0.0
#
# PURPOSE:
# Installer for server-maintenance. Installs dependencies, deploys bin/ and
# lib/ to /opt/server-maintenance, writes /etc/server-maintenance/config.conf
# (asking for the common settings), and installs the systemd timers.
# Idempotent: re-run at any time to change settings; every prompt defaults
# to the current value, and hand-edited keys (such as image definitions)
# are left alone.
#
# Usage:
#   sudo ./install.sh               interactive
#   sudo ./install.sh --defaults    unattended: keep the current config, or
#                                   write the default one, without prompting
#   --ref <ref>                     recorded as the channel this install
#                                   follows (passed by bootstrap.sh)

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/server-maintenance"
CONFIG_DIR="/etc/server-maintenance"
CONFIG_FILE="$CONFIG_DIR/config.conf"
STATE_DIR="/var/lib/server-maintenance"
LOG_DIR="/var/log/server-maintenance"
BIN_LINK="/usr/local/sbin/server-maintenance"
UNIT_DIR="/etc/systemd/system"

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
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"

DEFAULTS=0
REF="local"
while (( $# )); do
    case "$1" in
        --defaults) DEFAULTS=1 ;;
        --ref)
            [[ $# -ge 2 ]] || { echo "ERROR: --ref needs a value" >&2; exit 2; }
            REF="$2"; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

require_root
NEW_VERSION="$(awk '/^# Version: v/ { print $3; exit }' "$SCRIPT_DIR/bin/server-maintenance.sh")"

log_info "Detecting Linux distribution..."
detect_distro
[[ -n "$PKG_MANAGER" ]] || die "Unsupported distribution '$DISTRO_NAME' (ID=$DISTRO_ID, ID_LIKE=$DISTRO_ID_LIKE)."
log_info "Detected: $DISTRO_NAME (family=$DISTRO_FAMILY, package manager=$PKG_MANAGER)"

if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null 2>&1; then
    die "systemd is required (the schedules are systemd timers) and is not running on this host."
fi

# ---------------------------------------------------------------------------
# 1. Dependencies, all in one pass, verified afterwards
# ---------------------------------------------------------------------------
pkgs_required=(jq curl acl)
pkgs_optional=()
case "$DISTRO_FAMILY" in
    debian) pkgs_optional+=(bind9-dnsutils) ;;
    fedora|rhel) pkgs_optional+=(bind-utils) ;;
esac

log_info "Installing dependencies: ${pkgs_required[*]}"
case "$PKG_MANAGER" in
    apt-get)
        timeout 600 apt-get update -q
        timeout 1200 apt-get install -y -q "${pkgs_required[@]}"
        # Provides /var/run/reboot-required on Ubuntu; not packaged on every
        # Debian release, so its absence is a warning (checked below).
        timeout 600 apt-get install -y -q update-notifier-common || true
        timeout 600 apt-get install -y -q "${pkgs_optional[@]}" || log_warn "Optional ${pkgs_optional[*]} not installed (DNS diagnostics will be shorter)"
        ;;
    dnf|yum)
        # needs-restarting moved between packages across releases; try the
        # usual names and verify the command below instead of trusting one.
        timeout 1200 "$PKG_MANAGER" install -y jq curl acl
        timeout 600 "$PKG_MANAGER" install -y dnf-utils || timeout 600 "$PKG_MANAGER" install -y yum-utils \
            || timeout 600 "$PKG_MANAGER" install -y dnf-plugins-core || true
        timeout 600 "$PKG_MANAGER" install -y "${pkgs_optional[@]}" || log_warn "Optional ${pkgs_optional[*]} not installed (DNS diagnostics will be shorter)"
        ;;
esac

missing=()
for cmd in jq curl flock timeout awk sed find mktemp systemd-analyze; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
(( ${#missing[@]} == 0 )) || die "Still missing after install: ${missing[*]}"
case "$DISTRO_FAMILY" in
    debian) dpkg -s update-notifier-common >/dev/null 2>&1 || log_warn "update-notifier-common missing: reboot-required will report 'unknown'" ;;
    fedora|rhel) command -v needs-restarting >/dev/null 2>&1 || log_warn "needs-restarting missing: reboot-required will report 'unknown'" ;;
esac

if command -v send-alert >/dev/null 2>&1; then
    log_info "send-alert found: failures will be emailed through it"
else
    log_warn "send-alert is NOT installed. Failures will only be logged (and visible through missed heartbeats)."
    log_warn "Install it first with: curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Notifications/bootstrap.sh | sudo bash"
fi

HAVE_DOCKER=0
if command -v docker >/dev/null 2>&1 && timeout 30 docker info >/dev/null 2>&1; then
    HAVE_DOCKER=1
    timeout 30 docker compose version >/dev/null 2>&1 || log_warn "Docker is installed but the compose plugin is not; container updates need 'docker compose'."
fi

if [[ "$DISTRO_FAMILY" == "debian" ]] && systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
    log_info "Note: unattended-upgrades is enabled. It installs security updates daily and, by default, never reboots."
    log_info "      server-maintenance waits for its apt lock and handles the full upgrade and the reboot. Leaving it on is fine."
fi

# ---------------------------------------------------------------------------
# 2. Configuration
# ---------------------------------------------------------------------------
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
FIRST_INSTALL=0
if [[ ! -f "$CONFIG_FILE" ]]; then
    install -m 600 -o root -g root "$SCRIPT_DIR/config.conf.example" "$CONFIG_FILE"
    FIRST_INSTALL=1
    log_info "Created $CONFIG_FILE from config.conf.example"
fi
chown root:root "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

config_defaults
# shellcheck source=/dev/null
. "$CONFIG_FILE"

# set_conf_key KEY VALUE - replaces the active KEY= line (or appends one),
# with the value %q-escaped so the file stays safe to source. Uses ENVIRON
# rather than awk -v, which would interpret backslashes in the value.
set_conf_key() {
    local tmp
    tmp="$(mktemp "$CONFIG_FILE.XXXXXX")"
    K="$1" LINE="$1=$(printf '%q' "$2")" awk '
        index($0, ENVIRON["K"] "=") == 1 { if (!done) print ENVIRON["LINE"]; done = 1; next }
        { print }
        END { if (!done) print ENVIRON["LINE"] }' "$CONFIG_FILE" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
}

# ask_choice "Prompt" current choice1 choice2 ... -> echoes a valid choice
ask_choice() {
    local prompt="$1" current="$2"; shift 2
    local reply c
    while :; do
        reply="$(ask "$prompt ($*)" "$current")"
        for c in "$@"; do [[ "$reply" == "$c" ]] && { echo "$reply"; return 0; }; done
        echo "Please answer one of: $*" >&2
    done
}

# ask_uint "Prompt" current
ask_uint() {
    local reply
    while :; do
        reply="$(ask "$1" "$2")"
        is_uint "$reply" && { echo "$reply"; return 0; }
        echo "Please enter a whole number." >&2
    done
}

# ask_calendar "Prompt" current -> a systemd OnCalendar expression that
# systemd-analyze accepts, with the next run shown before accepting it.
ask_calendar() {
    local reply next
    while :; do
        reply="$(ask "$1" "$2")"
        if [[ "$reply" =~ ^[A-Za-z0-9\ *.,:/~-]+$ ]] && next="$(systemd-analyze calendar "$reply" 2>/dev/null | awk -F': ' '/Next elapse/ { print $2; exit }')" && [[ -n "$next" ]]; then
            echo "    Next run: $next" >&2
            echo "$reply"
            return 0
        fi
        echo "Not a valid systemd OnCalendar expression (example: 'Sun *-*-01..07 03:00')." >&2
    done
}

# ask_secret_url "Prompt" current_value -> new value; blank keeps the
# current one, "-" clears it. The current URL is never displayed.
ask_secret_url() {
    local prompt="$1" current="$2" reply state="not set"
    [[ -n "$current" ]] && state="set"
    while :; do
        read -r -p "$prompt (currently $state; Enter keeps it, '-' clears): " reply
        if [[ -z "$reply" ]]; then echo "$current"; return 0; fi
        if [[ "$reply" == "-" ]]; then echo ""; return 0; fi
        if [[ "$reply" =~ ^https?://[^[:space:]]+$ ]]; then echo "$reply"; return 0; fi
        echo "Please paste a full http(s) URL." >&2
    done
}

if (( ! DEFAULTS )); then
    echo
    log_info "== OS updates =="
    UPDATE_MODE="$(ask_choice "Update mode" "$UPDATE_MODE" all security)"
    REBOOT_POLICY="$(ask_choice "Reboot when the OS requires it, during the maintenance window" "$REBOOT_POLICY" if-required never)"

    echo
    log_info "== Schedules (systemd OnCalendar syntax) =="
    echo "    Examples: 'Sun *-*-01..07 03:00' (first Sunday monthly), 'Sun 03:00' (weekly), '*-*-* 03:00' (daily)"
    RUN_CALENDAR="$(ask_calendar "Maintenance window" "$RUN_CALENDAR")"
    CHECK_CALENDAR="$(ask_calendar "Daily read-only check" "$CHECK_CALENDAR")"

    if (( HAVE_DOCKER )); then
        echo
        log_info "== Container image updates =="
        if confirm "Manage container image updates on this host?" "$(is_true "$CONTAINER_UPDATES_ENABLED" && echo y || echo n)"; then
            CONTAINER_UPDATES_ENABLED=true
            SOAK_DAYS="$(ask_uint "Days a release must be out before it is applied" "$SOAK_DAYS")"
            if confirm "Require 'server-maintenance containers approve' before applying an update?" "$(is_true "$REQUIRE_APPROVAL" && echo y || echo n)"; then
                REQUIRE_APPROVAL=true
            else
                REQUIRE_APPROVAL=false
            fi
        else
            CONTAINER_UPDATES_ENABLED=false
        fi
    fi

    echo
    log_info "== Monitoring =="
    HEARTBEAT_URL_CHECK="$(ask_secret_url "Uptime Kuma push URL for the daily check" "$HEARTBEAT_URL_CHECK")"
    HEARTBEAT_URL_RUN="$(ask_secret_url "Uptime Kuma push URL for the maintenance window" "$HEARTBEAT_URL_RUN")"
    ALERT_TO="$(ask "Alert recipient(s), comma-separated (blank = send-alert's default)" "$ALERT_TO")"
fi

for key in UPDATE_MODE REBOOT_POLICY RUN_CALENDAR CHECK_CALENDAR CONTAINER_UPDATES_ENABLED \
           SOAK_DAYS REQUIRE_APPROVAL HEARTBEAT_URL_CHECK HEARTBEAT_URL_RUN ALERT_TO; do
    set_conf_key "$key" "${!key}"
done

# Validate what was written before anything is scheduled.
config_defaults
# shellcheck source=/dev/null
. "$CONFIG_FILE"
errors="$(validate_config)"
if [[ -n "$errors" ]]; then
    log_warn "The config has problems that must be fixed before the jobs can run:"
    printf '    %s\n' "$errors" >&2
fi

# ---------------------------------------------------------------------------
# 3. Deploy: stage, syntax-check, then swap into place
# ---------------------------------------------------------------------------
STAGE="$(mktemp -d /opt/.server-maintenance.XXXXXX)"
trap 'rm -rf "$STAGE"; fail_trap "$LINENO"' ERR
mkdir -p "$STAGE/bin" "$STAGE/lib"
cp "$SCRIPT_DIR/bin/server-maintenance.sh" "$STAGE/bin/"
cp "$SCRIPT_DIR"/lib/*.sh "$STAGE/lib/"
for f in "$STAGE"/bin/*.sh "$STAGE"/lib/*.sh; do
    bash -n "$f" || die "Syntax check failed for $(basename "$f"); nothing deployed"
done
chmod 755 "$STAGE" "$STAGE/bin" "$STAGE/lib"
chmod 755 "$STAGE"/bin/*.sh
chmod 644 "$STAGE"/lib/*.sh
chown -R root:root "$STAGE"
printf 'REF=%s\nVERSION=%s\nINSTALLED_AT=%s\n' "$REF" "$NEW_VERSION" "$(now_stamp)" > "$STAGE/.install-state"
if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR.old"
    mv "$INSTALL_DIR" "$INSTALL_DIR.old"
fi
mv "$STAGE" "$INSTALL_DIR"
rm -rf "$INSTALL_DIR.old"
trap 'fail_trap "$LINENO"' ERR
ln -sfn "$INSTALL_DIR/bin/server-maintenance.sh" "$BIN_LINK"
log_info "Deployed $NEW_VERSION to $INSTALL_DIR (command: server-maintenance, channel: $REF)"

mkdir -p "$STATE_DIR" "$LOG_DIR"
chmod 750 "$STATE_DIR"
apply_log_permissions "$LOG_DIR" "${LOG_ACCESS_GROUP:-}"

# ---------------------------------------------------------------------------
# 4. systemd units
# ---------------------------------------------------------------------------
render_unit() {
    local src="$1" dst tmp
    dst="$UNIT_DIR/$(basename "$src")"
    tmp="$(mktemp "$dst.XXXXXX")"
    CHECK_CAL="$CHECK_CALENDAR" RUN_CAL="$RUN_CALENDAR" RUN_DELAY="$RUN_RANDOM_DELAY" awk '
        { gsub(/@CHECK_CALENDAR@/, ENVIRON["CHECK_CAL"]); gsub(/@RUN_CALENDAR@/, ENVIRON["RUN_CAL"]);
          gsub(/@RUN_RANDOM_DELAY@/, ENVIRON["RUN_DELAY"]); print }' "$src" > "$tmp"
    grep -q '@[A-Z_]*@' "$tmp" && { rm -f "$tmp"; die "Unrendered placeholder left in $(basename "$src")"; }
    chmod 644 "$tmp"
    mv -f "$tmp" "$dst"
}
for unit in "$SCRIPT_DIR"/systemd/*; do
    render_unit "$unit"
done
systemctl daemon-reload
systemctl enable --now server-maintenance-check.timer server-maintenance-run.timer >/dev/null
systemctl enable server-maintenance-post-boot.service >/dev/null
log_info "Timers enabled:"
systemctl list-timers --all --no-pager 'server-maintenance-*' 2>/dev/null | sed 's/^/    /' || true

# ---------------------------------------------------------------------------
# 5. Verify and wrap up
# ---------------------------------------------------------------------------
echo
if [[ -z "$errors" ]]; then
    "$BIN_LINK" validate || log_warn "Validation reported problems (see above)."
fi

if (( ! DEFAULTS )) && command -v send-alert >/dev/null 2>&1; then
    if confirm "Send a test alert email now?" "n"; then
        "$BIN_LINK" test-alert || log_warn "Test alert failed"
    fi
fi

echo
log_info "Install complete."
if (( FIRST_INSTALL )); then
    log_info "Next: define the container images to manage (MANAGED_IMAGES and IMAGE_<id>_* in $CONFIG_FILE),"
    log_info "      then run: sudo server-maintenance validate && sudo server-maintenance check"
fi
