#!/usr/bin/env bash
#
# bootstrap.sh
# 2026-08-09
# Version: v1.1.0
#
# PURPOSE:
# One-line remote installer for the linux-updates tool. Downloads a
# snapshot of the whole Scripts repo to a temp directory and hands off to
# this folder's install.sh, so the tool can be installed with a single
# curl command instead of a manual clone/cd/install sequence. install.sh
# is still fully interactive; this script only fetches it and reattaches
# the terminal so its prompts work.
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
curl -fsSL "$REPO_TARBALL_URL" | tar -xz -C "$TMP_DIR" --strip-components=1

INSTALL_DIR_SRC="$TMP_DIR/$INSTALL_SUBPATH"
if [[ ! -f "$INSTALL_DIR_SRC/install.sh" ]]; then
    echo "ERROR: expected $INSTALL_SUBPATH/install.sh in the downloaded repo snapshot but it was not found." >&2
    echo "The repo layout may have changed; check https://github.com/MVTS-Corp/Scripts" >&2
    exit 1
fi

chmod +x "$INSTALL_DIR_SRC/install.sh"
exec "$INSTALL_DIR_SRC/install.sh" < /dev/tty
