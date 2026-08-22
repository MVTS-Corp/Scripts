#!/usr/bin/env bash
#
# common.sh
# 2026-08-22
# Version: v1.1.0
#
# PURPOSE:
# Shared logging and helper functions used across Server-Setup scripts.
# Sourced, not executed. Deliberately a standalone copy rather than one
# shared with another Linux/ tool - see Linux/Notifications/lib/common.sh
# for why (each tool stays independently clone-and-installable).
#
# CHANGELOG:
#   v1.1.0 - Added apply_log_permissions(), matching Linux/Updates/lib/
#            common.sh, so setup-server.sh's run log is locked down
#            instead of left at whatever mkdir's inherited umask produced.
#   v1.0.1 - confirm() now accepts yes/Yes/YES, not just a bare y/Y,
#            matching Linux/Updates/lib/common.sh.

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_RESET='\033[0m'

log_info()  { printf '%b[*]%b %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"; }
log_warn()  { printf '%b[!]%b %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2; }
log_error() { printf '%b[x]%b %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2; }
die() { log_error "$*"; exit 1; }

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
# access) and one additional caller-supplied group via a POSIX ACL - used
# by setup-server.sh to grant usr_admin read access to its own run log
# once that group exists. Every step degrades to a warning rather than
# failing the caller, since this is a hardening step, not a required one.
apply_log_permissions() {
    local log_dir="$1" extra_group="${2:-}"

    chown root:root "$log_dir" 2>/dev/null || true
    chmod 750 "$log_dir" 2>/dev/null || true

    if getent group adm >/dev/null 2>&1; then
        chown root:adm "$log_dir" 2>/dev/null || true
    fi

    if ! command -v setfacl >/dev/null 2>&1; then
        [[ -n "$extra_group" ]] && log_warn "setfacl not available; cannot grant group '$extra_group' read access to $log_dir. Install the 'acl' package and re-run."
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
            log_warn "Group '$extra_group' does not exist on this host; skipping log access grant."
        fi
    fi
}
