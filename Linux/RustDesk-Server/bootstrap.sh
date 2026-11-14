#!/usr/bin/env bash
#
# bootstrap.sh
# 2026-11-14
# Version: v1.0.0
#
# PURPOSE:
# One-line remote runner for RustDesk-Server. Downloads a snapshot of the
# Scripts repo at a chosen ref (branch, tag, or commit) to a temp directory
# and hands off to install-rustdesk-server.sh with every argument passed
# through. Pin a release tag for fleet use, so every host runs exactly the
# same installer; "main" is only the default for convenience.
#
# Usage (interactive, asks before changing anything):
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/RustDesk-Server/bootstrap.sh)" \
#       bootstrap --relay-host rd.example.com --version 1.2.3 --digest sha256:...
#
# Usage (unattended, pinned installer ref):
#   curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/<ref>/Linux/RustDesk-Server/bootstrap.sh \
#       | sudo RD_REF=<ref> bash -s -- --relay-host rd.example.com --version 1.2.3 --digest sha256:... --yes
#
# CHANGELOG:
#   v1.0.0 - First release.

set -euo pipefail

REF="${RD_REF:-main}"
INSTALL_SUBPATH="Linux/RustDesk-Server"

[[ "$REF" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "RD_REF contains unexpected characters: $REF" >&2; exit 1; }
REPO_TARBALL_URL="https://github.com/MVTS-Corp/Scripts/archive/${REF}.tar.gz"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This must be run as root (try: sudo bash -c \"\$(curl -fsSL ...)\")" >&2
    exit 1
fi

for cmd in curl tar mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Required command not found: $cmd" >&2; exit 1; }
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading RustDesk-Server (Scripts repo, ref ${REF})..."
timeout 120 curl --connect-timeout 10 --max-time 90 -fsSL "$REPO_TARBALL_URL" | tar -xz -C "$TMP_DIR" --strip-components=1

SRC="${TMP_DIR}/${INSTALL_SUBPATH}"
if [[ ! -f "${SRC}/install-rustdesk-server.sh" ]]; then
    echo "ERROR: ${INSTALL_SUBPATH}/install-rustdesk-server.sh not found at ref ${REF}." >&2
    exit 1
fi
chmod +x "${SRC}/install-rustdesk-server.sh"

# Reattach the terminal for prompts when there is one; an unattended run
# with --yes needs none. Not exec'd, so the EXIT trap still cleans up.
if { : < /dev/tty; } 2>/dev/null; then
    "${SRC}/install-rustdesk-server.sh" "$@" < /dev/tty
else
    "${SRC}/install-rustdesk-server.sh" "$@"
fi
