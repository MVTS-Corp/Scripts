#!/usr/bin/env bash
#
# bootstrap.sh
# 2026-10-18
# Version: v1.0.3
#
# CHANGELOG:
#   v1.0.3 - Installs curl and tar itself when the host does not have them
#            (common on minimal images) instead of stopping.
#   v1.0.2 - Wording only: setup-server.sh no longer requires an admin user,
#            so the no-terminal message and the usage notes now say
#            --yes alone is enough for an unattended run.
#   v1.0.1 - Documented `sudo bash -c "$(curl ...)"` as the interactive
#            form. Piping into sudo (`curl | sudo bash`) leaves the script
#            outside its pty's foreground process group on newer sudo
#            (seen on Ubuntu 26.04), so any prompt hangs or is refused.
#            The pipe form remains fine for unattended runs that pass
#            --admin-user and --yes, since those never prompt.
#
# PURPOSE:
# One-line remote installer for Server-Setup. Downloads a snapshot of the
# whole Scripts repo to a temp directory and hands off to this folder's
# setup-server.sh, so the tool can be run with a single curl command
# instead of a manual clone/cd sequence. setup-server.sh is still fully
# interactive unless --yes is given; this script only fetches it
# and reattaches the terminal so its prompts work. Any arguments given
# to this script are passed straight through to setup-server.sh.
#
# Usage (interactive - asks about the admin user, host name and time servers):
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Server-Setup/bootstrap.sh)"
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Server-Setup/bootstrap.sh)" bootstrap --admin-user jsmith
#
# Usage (unattended - must pass --yes so nothing prompts; --admin-user is
# optional and defaults to the invoking sudo user, or root only):
#   curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Server-Setup/bootstrap.sh | sudo bash -s -- --admin-user jsmith --yes

set -euo pipefail

REPO_TARBALL_URL="https://github.com/MVTS-Corp/Scripts/archive/refs/heads/main.tar.gz"
INSTALL_SUBPATH="Linux/Server-Setup"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This installer must be run as root (try: sudo bash -c \"\$(curl -fsSL ...)\")" >&2
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
    echo "No controlling terminal (/dev/tty) available; setup-server.sh needs one for its interactive prompts unless --yes is given." >&2
    echo "Run this from an interactive shell, or pass --yes, or clone the repo and run ./setup-server.sh directly." >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading Server-Setup (from MVTS-Corp/Scripts)..."
timeout 120 curl --connect-timeout 10 --max-time 90 -fsSL "$REPO_TARBALL_URL" | tar -xz -C "$TMP_DIR" --strip-components=1

INSTALL_DIR_SRC="$TMP_DIR/$INSTALL_SUBPATH"
if [[ ! -f "$INSTALL_DIR_SRC/setup-server.sh" ]]; then
    echo "ERROR: expected $INSTALL_SUBPATH/setup-server.sh in the downloaded repo snapshot but it was not found." >&2
    echo "The repo layout may have changed; check https://github.com/MVTS-Corp/Scripts" >&2
    exit 1
fi

chmod +x "$INSTALL_DIR_SRC/setup-server.sh"
# Not exec'd: exec replaces this process image, which would skip the EXIT
# trap above and leak $TMP_DIR on every successful run.
"$INSTALL_DIR_SRC/setup-server.sh" "$@" < /dev/tty
