#!/usr/bin/env bash
#
# bootstrap.sh
# 2026-10-18
# Version: v1.0.0
#
# PURPOSE:
# One-line remote installer for server-maintenance. Downloads a snapshot of
# the Scripts repo at a release channel or tag to a temp directory and hands
# off to this folder's install.sh. Any arguments are passed straight through
# to install.sh.
#
# Usage (interactive):
#   curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/stable/Linux/Server-Maintenance/bootstrap.sh | sudo bash
#
# Unattended (an RMM script, no terminal): add --defaults, which keeps an
# existing config or writes the default one without prompting:
#   ... | sudo bash -s -- --defaults
#
# To pin an exact release instead of following the stable channel:
#   ... | sudo bash -s -- --ref server-maintenance-v1.0.0

set -euo pipefail

INSTALL_SUBPATH="Linux/Server-Maintenance"
DEFAULT_REF="stable"
STATE_FILE="/opt/server-maintenance/.install-state"

# Only characters git allows in a branch or tag name in practice, since the
# value is placed in a download URL.
valid_ref() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$1" != *..* && "$1" != */ ]]
}

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

REF=""
DEFAULTS=0
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
        --defaults) DEFAULTS=1 ;;
    esac
done

# No --ref given: keep following whatever an existing install follows (so a
# pinned host stays pinned), else the default channel.
if [[ -z "$REF" && -f "$STATE_FILE" ]]; then
    saved_ref="$(awk -F= '$1 == "REF" { sub(/^[^=]*=/, ""); print; exit }' "$STATE_FILE")"
    if [[ -n "$saved_ref" ]] && valid_ref "$saved_ref"; then
        REF="$saved_ref"
    fi
fi
REF="${REF:-$DEFAULT_REF}"

if (( ! DEFAULTS )) && ! { : < /dev/tty; } 2>/dev/null; then
    echo "No controlling terminal (/dev/tty) available for install.sh's prompts." >&2
    echo "Run this from an interactive shell, or add --defaults for an unattended install." >&2
    exit 1
fi

# GitHub resolves archive/<ref> for a branch or a tag alike. The env override
# exists so the download can be tested against a local file:// tarball.
REPO_TARBALL_URL="${SERVER_MAINTENANCE_TARBALL_URL:-https://github.com/MVTS-Corp/Scripts/archive/${REF}.tar.gz}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading server-maintenance (from MVTS-Corp/Scripts, ref: $REF)..."
TARBALL="$TMP_DIR/repo.tar.gz"
rc=0
timeout 120 curl --connect-timeout 10 --max-time 90 -fsSL -o "$TARBALL" "$REPO_TARBALL_URL" || rc=$?
if (( rc != 0 )); then
    echo "ERROR: download failed (curl exit $rc)." >&2
    if (( rc == 22 )); then
        echo "GitHub answered with an HTTP error. Check that '$REF' is an existing branch or tag of MVTS-Corp/Scripts." >&2
    fi
    exit 1
fi

mkdir -p "$TMP_DIR/repo"
tar -xzf "$TARBALL" -C "$TMP_DIR/repo" --strip-components=1

INSTALL_DIR_SRC="$TMP_DIR/repo/$INSTALL_SUBPATH"
if [[ ! -f "$INSTALL_DIR_SRC/install.sh" ]]; then
    echo "ERROR: $INSTALL_SUBPATH/install.sh is not in the '$REF' snapshot." >&2
    echo "If no server-maintenance release has been cut to '$REF' yet, pass --ref with a tag (or main, for testing only)." >&2
    exit 1
fi

# --ref is always passed on, so install.sh records exactly what was installed.
filtered=()
for (( i = 0; i < ${#args[@]}; i++ )); do
    if [[ "${args[i]}" == "--ref" ]]; then
        i=$(( i + 1 ))
        continue
    fi
    filtered+=("${args[i]}")
done

chmod +x "$INSTALL_DIR_SRC/install.sh"
# Not exec'd: exec would skip the EXIT trap above and leak $TMP_DIR.
if (( DEFAULTS )); then
    "$INSTALL_DIR_SRC/install.sh" --ref "$REF" ${filtered[@]+"${filtered[@]}"}
else
    "$INSTALL_DIR_SRC/install.sh" --ref "$REF" ${filtered[@]+"${filtered[@]}"} < /dev/tty
fi
