#!/usr/bin/env bash
#
# distro.sh
# 2026-08-09
# Version: v1.0.0
#
# PURPOSE:
# Detects the host Linux distribution family and its package manager.
# Sourced, not executed. Requires common.sh (for die) to already be sourced.

# Populates: DISTRO_ID, DISTRO_ID_LIKE, DISTRO_NAME, DISTRO_FAMILY, PKG_MANAGER
detect_distro() {
    if [[ ! -r /etc/os-release ]]; then
        die "Cannot detect distro: /etc/os-release not found"
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    DISTRO_ID="${ID:-unknown}"
    DISTRO_ID_LIKE="${ID_LIKE:-}"
    DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"

    case "$DISTRO_ID" in
        debian|ubuntu|raspbian|linuxmint|pop|elementary|kali|zorin)
            DISTRO_FAMILY="debian" ;;
        fedora)
            DISTRO_FAMILY="fedora" ;;
        rhel|centos|rocky|almalinux|ol|amzn)
            DISTRO_FAMILY="rhel" ;;
        *)
            case " $DISTRO_ID_LIKE " in
                *" debian "*) DISTRO_FAMILY="debian" ;;
                *" fedora "*) DISTRO_FAMILY="fedora" ;;
                *" rhel "*|*" centos "*) DISTRO_FAMILY="rhel" ;;
                *) DISTRO_FAMILY="unknown" ;;
            esac
            ;;
    esac

    case "$DISTRO_FAMILY" in
        debian)
            PKG_MANAGER="apt-get" ;;
        fedora|rhel)
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        *)
            PKG_MANAGER="" ;;
    esac

    export DISTRO_ID DISTRO_ID_LIKE DISTRO_NAME DISTRO_FAMILY PKG_MANAGER
}
