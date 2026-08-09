#!/usr/bin/env bash
#
# common.sh
# 2026-08-09
# Version: v1.0.0
#
# PURPOSE:
# Shared logging and helper functions used across linux-notifications
# scripts. Sourced, not executed. Deliberately a standalone copy rather
# than a shared file sourced from Linux/Updates, so this folder stays
# independently clone-and-installable.

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
