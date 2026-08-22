#!/usr/bin/env bash
#
# run-updates.sh
# 2026-08-22
# Version: v1.1.0
#
# PURPOSE:
# Runs OS package updates and emails a summary. Deployed to
# /opt/linux-updates by install.sh and invoked on schedule via
# /etc/cron.d/linux-updates. Safe to run manually for testing.
#
# CHANGELOG:
#   v1.1.0 - Logging (mkdir + LOG_FILE) now starts before any precondition
#            check, instead of after config/distro checks - a setup
#            failure (missing config, unsupported/undetected distro)
#            previously died with no log entry and no alert email, since
#            cron's MAILTO is disabled and die() had nothing to write to
#            yet. Added Dpkg::Options::=--force-confdef/--force-confold to
#            unattended apt-get calls, so a package with a modified
#            conffile can't block on an interactive dpkg prompt nobody is
#            present to answer. Debian security-update detection now
#            matches "security" only against the candidate version's own
#            source lines (the block right after apt-cache policy's "***"
#            marker), not the whole policy dump, which previously
#            misclassified a plain update as a security update whenever
#            the package also had an older, unrelated version-table entry
#            from a security repo. Reboot-required detection is now
#            distro-family aware and reports "unknown" (with the reason)
#            instead of a false "no" when its underlying tool
#            (update-notifier-common / needs-restarting) isn't installed.
#            msmtp.log is now trimmed at 5MB - it's a single continuously-
#            appended file whose mtime bumps on every run, so the existing
#            update-*.log mtime-based cleanup never matched it and it grew
#            unbounded. Log directory permissions are now reapplied via
#            apply_log_permissions() (lib/common.sh) once config.conf is
#            loaded, so an ACL-granted admin group stays in sync with
#            LOG_ACCESS_GROUP across re-installs.
#   v1.0.2 - Fixed a race between the async `exec > >(tee -a "$RUN_LOG")`
#            redirect and reading $RUN_LOG back moments later to build the
#            alert email's "Log tail": tee runs as a background process
#            under process substitution, so nothing guaranteed its writes
#            had landed before the read. Replaced it with a plain pipeline
#            scoped to just the update commands - unlike process
#            substitution, a plain pipeline blocks the script until every
#            stage (including tee) has finished, so by the time the "Log
#            tail" reads $RUN_LOG afterward, tee has already exited and
#            the file is guaranteed complete. log_info/log_warn/log_error
#            (lib/common.sh v1.0.1+) now write to $LOG_FILE themselves for
#            everything outside that pipeline, so the full-run log file is
#            unaffected.
#   v1.0.1 - Bounded every apt-get/dnf/yum call with a timeout (a held
#            dpkg/rpm lock or a stalled mirror could previously hang this
#            unattended cron job forever), and set DEBIAN_FRONTEND so a
#            package with a modified conffile cannot block on an
#            interactive dpkg prompt that nobody is present to answer.

set -uo pipefail
# Deliberately no -e: apt-get/dnf/yum's exit status is captured manually
# below so a failed update still produces a proper FAILED summary email
# instead of aborting the script before it can send one.

# Avoids apt-get blocking on a debconf/conffile prompt when a package
# maintainer script wants interactive input (e.g. grub-pc, openssh-server).
export DEBIAN_FRONTEND=noninteractive
APT_CONF_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

INSTALL_DIR="/opt/linux-updates"
CONFIG_FILE="/etc/linux-updates/config.conf"
LOG_DIR="/var/log/linux-updates"
LOG_RETENTION_DAYS=30
MSMTP_LOG_MAX_BYTES=$((5 * 1024 * 1024))

# shellcheck source=lib/common.sh
. "$INSTALL_DIR/lib/common.sh"
# shellcheck source=lib/distro.sh
. "$INSTALL_DIR/lib/distro.sh"
# shellcheck source=lib/notify.sh
. "$INSTALL_DIR/lib/notify.sh"

# Set up logging as early as possible, before any precondition check, so a
# setup failure (missing config, unsupported distro, not running as root)
# is captured in a log file instead of vanishing into cron's MAILTO="".
mkdir -p "$LOG_DIR" || die "Cannot create log directory: $LOG_DIR"
chmod 750 "$LOG_DIR" 2>/dev/null || true
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="$LOG_DIR/update-$RUN_STAMP.log"
LOG_FILE="$RUN_LOG"

require_root

[[ -f "$CONFIG_FILE" ]] || die "Missing config file: $CONFIG_FILE (re-run install.sh)"
# shellcheck source=/dev/null
. "$CONFIG_FILE"
UPDATE_MODE="${UPDATE_MODE:-all}"
# Overridable from config.conf for hosts with an unusually slow mirror or a
# large pending upgrade set. NETWORK bounds quick metadata-only calls
# (refreshing the package index, dry-run/query commands); INSTALL bounds
# calls that actually download and install packages.
APT_NETWORK_TIMEOUT="${APT_NETWORK_TIMEOUT:-300}"
APT_INSTALL_TIMEOUT="${APT_INSTALL_TIMEOUT:-3600}"

# Now that config.conf is loaded, reapply full log permissions (the base
# chmod above already happened so the directory is never briefly
# world-readable while waiting for this).
apply_log_permissions "$LOG_DIR" "${LOG_ACCESS_GROUP:-}"

detect_distro
[[ -n "$PKG_MANAGER" ]] || die "Unsupported or undetected distro/package manager"

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
log_info "Starting update run on $HOSTNAME_FQDN ($DISTRO_NAME, mode=$UPDATE_MODE)"

run_debian_update() {
    timeout "$APT_NETWORK_TIMEOUT" apt-get update -y || return $?

    if [[ "$UPDATE_MODE" == "security" ]]; then
        local pkg upgradable=""
        while read -r pkg; do
            [[ -z "$pkg" ]] && continue
            # Only match "security" against the candidate version's own
            # source lines (the block right after the "***" marker), not
            # the whole apt-cache policy dump - otherwise a package whose
            # candidate is a plain update, but which also has an older,
            # unrelated version-table entry from a security repo, gets
            # misclassified as a security update.
            if timeout "$APT_NETWORK_TIMEOUT" apt-cache policy "$pkg" 2>/dev/null | awk '
                    /\*\*\*/ { incand=1; next }
                    {
                        if (incand && $0 ~ /^[[:space:]]+[0-9]+[[:space:]]/) {
                            print
                        } else {
                            incand = 0
                        }
                    }
                ' | grep -qi 'security'; then
                upgradable="$upgradable $pkg"
            fi
        done < <(timeout "$APT_NETWORK_TIMEOUT" apt-get --just-print upgrade 2>/dev/null | awk '/^Inst/ {print $2}')

        if [[ -n "$upgradable" ]]; then
            # shellcheck disable=SC2086
            timeout "$APT_INSTALL_TIMEOUT" apt-get install -y "${APT_CONF_OPTS[@]}" --only-upgrade $upgradable
        else
            log_info "No security updates available"
        fi
    else
        timeout "$APT_INSTALL_TIMEOUT" apt-get upgrade -y "${APT_CONF_OPTS[@]}"
    fi
    local status=$?
    timeout "$APT_NETWORK_TIMEOUT" apt-get autoremove -y || true
    return $status
}

run_dnf_yum_update() {
    local security_flag=()
    [[ "$UPDATE_MODE" == "security" ]] && security_flag=(--security)
    timeout "$APT_INSTALL_TIMEOUT" "$PKG_MANAGER" upgrade -y "${security_flag[@]}"
    local status=$?
    timeout "$APT_NETWORK_TIMEOUT" "$PKG_MANAGER" autoremove -y || true
    return $status
}

case "$PKG_MANAGER" in
    apt-get|dnf|yum) ;;
    *) die "Unsupported or undetected package manager: $PKG_MANAGER" ;;
esac

# Run the actual update through a plain pipeline scoped to just this step,
# rather than a script-wide `exec > >(tee)`. A plain pipeline (unlike
# process substitution) is synchronous: the shell waits for every stage,
# including tee, to finish before continuing - so by the time the "Log
# tail" below reads $RUN_LOG, it is guaranteed complete. tee's own stdout
# is never redirected here, so a manual/interactive run still sees this
# output live, same as before.
# LOG_FILE is cleared inside the braced group (which runs in its own
# subshell as a non-last pipeline stage - this does not affect the parent
# shell's LOG_FILE) because tee is already writing everything printed in
# here to $RUN_LOG; leaving LOG_FILE set would double-log any log_info/
# log_warn call made from inside run_debian_update/run_dnf_yum_update.
{
    LOG_FILE=""
    case "$PKG_MANAGER" in
        apt-get) run_debian_update ;;
        dnf|yum) run_dnf_yum_update ;;
    esac
} 2>&1 | tee -a "$RUN_LOG"
UPDATE_STATUS="${PIPESTATUS[0]}"

# Reboot-required detection is family-specific and depends on a helper
# (update-notifier-common on Debian, needs-restarting on Fedora/RHEL) that
# install.sh installs as a prerequisite. If that helper is missing for any
# reason, report "unknown" rather than a false "no" - the two are not the
# same thing to an operator deciding whether to schedule a reboot.
REBOOT_REQUIRED="no"
case "$DISTRO_FAMILY" in
    debian)
        if [[ -f /var/run/reboot-required ]]; then
            REBOOT_REQUIRED="yes"
        elif ! dpkg -s update-notifier-common >/dev/null 2>&1; then
            REBOOT_REQUIRED="unknown (update-notifier-common not installed)"
        fi
        ;;
    fedora|rhel)
        if command -v needs-restarting >/dev/null 2>&1; then
            needs-restarting -r >/dev/null 2>&1 || REBOOT_REQUIRED="yes"
        else
            REBOOT_REQUIRED="unknown (needs-restarting not installed)"
        fi
        ;;
    *)
        REBOOT_REQUIRED="unknown (no detection method for this distro family)"
        ;;
esac

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

# update-*.log gets the mtime-based cleanup above, but msmtp.log is a
# single continuously-appended file whose mtime bumps on every run, so it
# would never match -mtime and would grow forever. Trim it by size instead.
MSMTP_LOG_FILE="$LOG_DIR/msmtp.log"
if [[ -f "$MSMTP_LOG_FILE" ]]; then
    msmtp_log_size="$(stat -c%s "$MSMTP_LOG_FILE" 2>/dev/null || echo 0)"
    if (( msmtp_log_size > MSMTP_LOG_MAX_BYTES )); then
        if tail -n 2000 "$MSMTP_LOG_FILE" > "$MSMTP_LOG_FILE.tmp" 2>/dev/null; then
            mv "$MSMTP_LOG_FILE.tmp" "$MSMTP_LOG_FILE"
            log_info "Trimmed msmtp.log (exceeded $((MSMTP_LOG_MAX_BYTES / 1024 / 1024))MB)"
        fi
    fi
fi

log_info "Update run complete: $STATUS_LABEL (reboot_required=$REBOOT_REQUIRED)"
exit "$UPDATE_STATUS"
