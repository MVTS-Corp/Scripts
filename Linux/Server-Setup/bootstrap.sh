#!/usr/bin/env bash
#
# bootstrap.sh
# 2026-09-18
# Version: v1.0.1
#
# CHANGELOG:
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
# interactive if --admin-user is omitted; this script only fetches it
# and reattaches the terminal so its prompts work. Any arguments given
# to this script are passed straight through to setup-server.sh.
#
# Usage (interactive - prompts for the admin username):
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Server-Setup/bootstrap.sh)"
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Server-Setup/bootstrap.sh)" bootstrap --admin-user jsmith
#
# Usage (unattended - must pass --yes so nothing prompts; --admin-user is
# optional and defaults to the invoking sudo user):
#   curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Server-Setup/bootstrap.sh | sudo bash -s -- --admin-user jsmith --yes

set -euo pipefail

REPO_TARBALL_URL="https://github.com/MVTS-Corp/Scripts/archive/refs/heads/main.tar.gz"
INSTALL_SUBPATH="Linux/Server-Setup"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This installer must be run as root (try: sudo bash -c \"\$(curl -fsSL ...)\")" >&2
    exit 1
fi

for cmd in curl tar mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Required command not found: $cmd" >&2; exit 1; }
done

if [[ ! -e /dev/tty ]]; then
    echo "No controlling terminal (/dev/tty) available; setup-server.sh needs one for its interactive prompts unless --admin-user and --yes are both given." >&2
    echo "Run this from an interactive shell, or pass --admin-user NAME --yes, or clone the repo and run ./setup-server.sh directly." >&2
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
