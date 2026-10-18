#!/usr/bin/env bash
#
# bootstrap.sh
# 2026-10-18
# Version: v1.1.2
#
# PURPOSE:
# One-line remote installer for the linux-updates tool. Downloads a
# snapshot of the whole Scripts repo to a temp directory and hands off to
# this folder's install.sh, so the tool can be installed with a single
# curl command instead of a manual clone/cd/install sequence. install.sh
# is still fully interactive; this script only fetches it and reattaches
# the terminal so its prompts work.
#
# CHANGELOG:
#   v1.1.2 - Installs curl and tar itself when the host does not have them
#            (common on minimal images) instead of stopping.
#   v1.1.1 - Bounded the download with a timeout (a stalled connection
#            previously hung with no limit), and stopped exec'ing into
#            install.sh so the EXIT trap below can still fire and clean
#            up $TMP_DIR on a successful run (exec replaces the process
#            image, which skips EXIT traps - every prior successful
#            bootstrap leaked its downloaded repo snapshot under /tmp).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Updates/bootstrap.sh | sudo bash

set -euo pipefail

REPO_TARBALL_URL="https://github.com/MVTS-Corp/Scripts/archive/refs/heads/main.tar.gz"
INSTALL_SUBPATH="Linux/Updates"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This installer must be run as root (try: curl -fsSL ... | sudo bash)" >&2
    exit 1
fi

# Minimal images often ship without curl or tar. Install whichever is
# missing with the host's package manager instead of stopping.
missing_pkgs=()
command -v curl >/dev/null 2>&1 || missing_pkgs+=(curl)
command -v tar >/dev/null 2>&1 || missing_pkgs+=(tar)
if (( ${#missing_pkgs[@]} )); then
    echo "Installing missing prerequisites: ${missing_pkgs[*]}..."
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y ca-certificates "${missing_pkgs[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ca-certificates "${missing_pkgs[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y ca-certificates "${missing_pkgs[@]}"
    else
        echo "Missing ${missing_pkgs[*]} and no supported package manager (apt-get, dnf, yum) was found to install it." >&2
        exit 1
    fi
fi

for cmd in curl tar mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Required command not found: $cmd" >&2; exit 1; }
done

if [[ ! -e /dev/tty ]]; then
    echo "No controlling terminal (/dev/tty) available; install.sh needs one for its interactive prompts." >&2
    echo "Run this from an interactive shell, or clone the repo and run ./install.sh directly." >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading linux-updates (from MVTS-Corp/Scripts)..."
timeout 120 curl --connect-timeout 10 --max-time 90 -fsSL "$REPO_TARBALL_URL" | tar -xz -C "$TMP_DIR" --strip-components=1

INSTALL_DIR_SRC="$TMP_DIR/$INSTALL_SUBPATH"
if [[ ! -f "$INSTALL_DIR_SRC/install.sh" ]]; then
    echo "ERROR: expected $INSTALL_SUBPATH/install.sh in the downloaded repo snapshot but it was not found." >&2
    echo "The repo layout may have changed; check https://github.com/MVTS-Corp/Scripts" >&2
    exit 1
fi

chmod +x "$INSTALL_DIR_SRC/install.sh"
# Not exec'd: exec replaces this process image, which would skip the EXIT
# trap above and leak $TMP_DIR on every successful run.
"$INSTALL_DIR_SRC/install.sh" < /dev/tty
