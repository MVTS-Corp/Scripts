#!/usr/bin/env bash
#
# bootstrap.sh
# 2026-09-18
# Version: v1.1.0
#
# PURPOSE:
# One-line remote installer for NTP-Config. Downloads a snapshot of the
# whole Scripts repo from GitHub to a temp directory and hands off to this
# folder's install.sh, so the tool can be installed with a single curl
# command instead of a manual clone/cd/install sequence. install.sh does not
# prompt, so both the pipe form and the sudo bash -c form work. Any
# arguments given to this script are passed straight through to install.sh.
#
# CHANGELOG:
#   v1.1.0 - Added --ref REF (a branch or tag). The repo snapshot is now
#            downloaded from that ref, defaulting to the "stable" branch
#            instead of main, or to the ref an existing install already
#            follows, so re-running the one-liner never moves a pinned host.
#   v1.0.1 - A missing --cacert value now exits 2 (invalid command line)
#            instead of 1, matching install.sh, so a calling script can
#            tell a usage mistake from a runtime failure.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/stable/Linux/NTP-Config/bootstrap.sh | sudo bash
#
# To pin an exact release instead of following the stable channel, add
# --ref with a release tag:
#   ... | sudo bash -s -- --ref ntp-config-v1.0.0
#
# If the host cannot verify GitHub's certificate (a TLS-inspecting proxy
# with a private CA, for example), pick one of these instead:
#   ... | sudo bash -s -- --cacert /path/to/ca-chain.pem   (verifies TLS)
#   ... | sudo bash -s -- --insecure                       (skips TLS checks)
# The choice is saved so later update checks use it too.

set -euo pipefail

INSTALL_SUBPATH="Linux/NTP-Config"
DEFAULT_REF="stable"
STATE_FILE="/opt/ntp-config/.ntp-config-state"

# Same rule install.sh applies: only characters git allows in a branch or tag
# name in practice, since the value is placed in a download URL.
valid_ref() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$1" != *..* && "$1" != */ ]]
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This installer must be run as root (try: curl -fsSL ... | sudo bash)" >&2
    exit 1
fi

for cmd in curl tar mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Required command not found: $cmd" >&2; exit 1; }
done

# Only --ref and the two TLS flags matter here; everything (including those)
# is forwarded to install.sh untouched.
CURL_TLS=()
REF=""
args=("$@")
for (( i = 0; i < ${#args[@]}; i++ )); do
    case "${args[i]}" in
        --ref)
            if (( i + 1 >= ${#args[@]} )); then
                echo "ERROR: --ref needs a branch or tag name." >&2
                exit 2
            fi
            valid_ref "${args[i+1]}" || { echo "ERROR: --ref '${args[i+1]}' is not a valid branch or tag name." >&2; exit 2; }
            REF="${args[i+1]}"
            ;;
        --insecure) CURL_TLS=(-k) ;;
        --cacert)
            if (( i + 1 >= ${#args[@]} )); then
                echo "ERROR: --cacert needs a file path." >&2
                exit 2
            fi
            CURL_TLS=(--cacert "${args[i+1]}")
            ;;
    esac
done

# No --ref given: keep following whatever an existing install follows (so a
# pinned host stays pinned), else the default channel.
if [[ -z "${REF}" && -f "${STATE_FILE}" ]]; then
    saved_ref="$(awk -F= '$1 == "REF" { sub(/^[^=]*=/, ""); print; exit }' "${STATE_FILE}")"
    if [[ -n "${saved_ref}" ]] && valid_ref "${saved_ref}"; then
        REF="${saved_ref}"
    fi
fi
REF="${REF:-${DEFAULT_REF}}"

# GitHub resolves archive/<ref> for a branch or a tag alike. The env override
# exists so the download can be tested against a local file:// tarball.
REPO_TARBALL_URL="${NTP_CONFIG_TARBALL_URL:-https://github.com/MVTS-Corp/Scripts/archive/${REF}.tar.gz}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading NTP-Config (from MVTS-Corp/Scripts, ref: ${REF})..."
# curl is run on its own (not piped into tar) so its exit status is visible
# and a TLS failure can be explained instead of surfacing as a tar error.
TARBALL="$TMP_DIR/repo.tar.gz"
rc=0
timeout 120 curl --connect-timeout 10 --max-time 90 -fsSL ${CURL_TLS[@]+"${CURL_TLS[@]}"} -o "$TARBALL" "$REPO_TARBALL_URL" || rc=$?
if (( rc != 0 )); then
    echo "ERROR: download failed (curl exit ${rc})." >&2
    case "$rc" in
        22)
            echo "GitHub answered with an HTTP error. If you passed --ref, check that '${REF}' is an existing branch or tag of MVTS-Corp/Scripts." >&2
            ;;
        35|51|58|59|60|77|82|83)
            echo "This looks like a TLS/certificate problem. Re-run with one of:" >&2
            echo "  --cacert /path/to/ca-chain.pem   verify TLS against your CA (preferred)" >&2
            echo "  --insecure                       skip TLS verification (trusted networks only)" >&2
            ;;
    esac
    exit 1
fi

mkdir -p "$TMP_DIR/repo"
tar -xzf "$TARBALL" -C "$TMP_DIR/repo" --strip-components=1

INSTALL_DIR_SRC="$TMP_DIR/repo/$INSTALL_SUBPATH"
if [[ ! -f "$INSTALL_DIR_SRC/install.sh" ]]; then
    echo "ERROR: expected $INSTALL_SUBPATH/install.sh in the downloaded repo snapshot but it was not found." >&2
    echo "The repo layout may have changed; check https://github.com/MVTS-Corp/Scripts" >&2
    exit 1
fi

chmod +x "$INSTALL_DIR_SRC/install.sh"
# Not exec'd: exec replaces this process image, which would skip the EXIT
# trap above and leak $TMP_DIR on every successful run.
"$INSTALL_DIR_SRC/install.sh" "$@"
