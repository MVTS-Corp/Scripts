#!/usr/bin/env bash
#
# common.sh
# 2026-08-22
# Version: v1.1.0
#
# PURPOSE:
# Shared logging and helper functions used across linux-updates scripts.
# Sourced, not executed.
#
# CHANGELOG:
#   v1.1.0 - die() now emails a failure alert via send_alert() (lib/notify.sh)
#            when it's sourced and ALERT_TO is known, so a precondition
#            failure during an unattended cron run doesn't fail completely
#            silently. confirm() now accepts yes/Yes/YES, not just a bare
#            y/Y. Added apply_log_permissions() for locking the log
#            directory down to root plus the "adm" group and an optional
#            caller-supplied group via POSIX ACL.
#   v1.0.1 - log_info/log_warn/log_error now also append to $LOG_FILE
#            directly (when the caller has set it), instead of relying on
#            the caller wrapping the whole script's stdout/stderr in
#            `exec > >(tee -a "$LOG_FILE")`. That process-substitution
#            pattern runs tee asynchronously in the background, which lets
#            a caller that reads $LOG_FILE back moments later (e.g. to
#            build an alert email) race the write - see run-updates.sh's
#            changelog for where this actually bit. LOG_FILE is unset by
#            default, so this is a no-op for install.sh/uninstall.sh.

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_RESET='\033[0m'

# Internal: mirrors a plain-text (no ANSI color codes) copy of a log line
# to $LOG_FILE, if the caller has set one. Failures here (e.g. disk full)
# never abort the caller.
_log_to_file() {
    [[ -n "${LOG_FILE:-}" ]] || return 0
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

log_info()  { printf '%b[*]%b %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"; _log_to_file "[*] $*"; }
log_warn()  { printf '%b[!]%b %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2; _log_to_file "[!] $*"; }
log_error() { printf '%b[x]%b %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2; _log_to_file "[x] $*"; }

# die "message" - logs the error and exits. If send_alert (lib/notify.sh) is
# sourced and an ALERT_TO recipient is known, also emails the failure, so a
# precondition failure during a cron run doesn't fail completely silently
# (cron's MAILTO is disabled by the deployed crontab entry).
die() {
    log_error "$*"
    if declare -f send_alert >/dev/null 2>&1 && [[ -n "${ALERT_TO:-}" ]]; then
        send_alert "[linux-updates] FAILED on $(hostname -f 2>/dev/null || hostname)" \
            "The update run aborted before it could complete:
$*" 2>/dev/null || true
    fi
    exit 1
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "This script must be run as root (try: sudo $0)"
    fi
}

# confirm "Prompt text" [default y|n]
confirm() {
    local prompt="$1" default="${2:-y}" reply hint="y/N"
    [[ "$default" == "y" ]] && hint="Y/n"
    read -r -p "$prompt [$hint] " reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ask "Prompt text" [default value] -> echoes the answer
ask() {
    local prompt="$1" default="${2:-}" reply
    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " reply
        echo "${reply:-$default}"
    else
        read -r -p "$prompt: " reply
        echo "$reply"
    fi
}

# apply_log_permissions <log_dir> [extra_group]
# Locks the log directory down to root (750) plus, where available, the
# "adm" group (the standard Debian/Ubuntu convention for log-reading
# access) and one additional caller-supplied group via a POSIX ACL, so
# multiple admin groups can read logs without needing root or a shared
# Unix group. Every step degrades to a warning rather than failing the
# caller, since this is a hardening step, not a required one.
apply_log_permissions() {
    local log_dir="$1" extra_group="${2:-}"

    chown root:root "$log_dir" 2>/dev/null || true
    chmod 750 "$log_dir" 2>/dev/null || true

    if getent group adm >/dev/null 2>&1; then
        chown root:adm "$log_dir" 2>/dev/null || true
    fi

    if ! command -v setfacl >/dev/null 2>&1; then
        [[ -n "$extra_group" ]] && log_warn "setfacl not available; cannot grant group '$extra_group' read access to $log_dir. Install the 'acl' package and re-run install.sh."
        return 0
    fi

    # Reset extended ACL entries first so a group removed/changed between
    # re-runs doesn't linger with stale access.
    setfacl -b "$log_dir" 2>/dev/null || true

    if getent group adm >/dev/null 2>&1; then
        setfacl -m g:adm:rx "$log_dir" 2>/dev/null || true
        setfacl -d -m g:adm:rx "$log_dir" 2>/dev/null || true
    fi

    if [[ -n "$extra_group" ]]; then
        if getent group "$extra_group" >/dev/null 2>&1; then
            setfacl -m g:"$extra_group":rx "$log_dir" 2>/dev/null || true
            setfacl -d -m g:"$extra_group":rx "$log_dir" 2>/dev/null || true
        else
            log_warn "Group '$extra_group' does not exist on this host; skipping log access grant. Create the group and re-run install.sh to apply it."
        fi
    fi
}
