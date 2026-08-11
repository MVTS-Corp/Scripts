#!/usr/bin/env bash
#
# common.sh
# 2026-08-10
# Version: v1.0.1
#
# PURPOSE:
# Shared logging and helper functions used across linux-updates scripts.
# Sourced, not executed.
#
# CHANGELOG:
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
    [[ "$reply" =~ ^[Yy]$ ]]
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
