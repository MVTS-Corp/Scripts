#!/usr/bin/env bash
#
# install.sh
# 2026-09-18
# Version: v2.2.0
#
# PURPOSE:
# Installer for the Linux side of NTP-Config. Copies configure-ntp-server.sh
# from the folder this script sits in (a repo snapshot fetched by
# bootstrap.sh, or a local clone) into /opt/ntp-config after verifying it,
# records the TLS choice for later self-updates, and symlinks the tool into
# /usr/local/sbin so it can be run from anywhere as
# `configure-ntp-server.sh`. No git and no cron entries are used or
# required; configure-ntp-server.sh checks for and applies updates on every
# run by itself.
#
# CHANGELOG:
#   v2.2.0 - Added --ref REF: which git ref (branch or tag) this install
#            follows for self-updates. Defaults to the "stable" branch, which
#            only ever points at a tagged release, instead of tracking main.
#            Pass a tag such as ntp-config-v1.0.0 to pin an exact release. The
#            ref is saved in the state file and, like the TLS choice, kept on
#            a re-run that does not name one.
#   v2.1.0 - Command-line mistakes now exit 2 (runtime failures stay 1) so a
#            calling script can tell them apart, and the exit codes are
#            documented. Package installs set NEEDRESTART_MODE and wait for
#            the dpkg lock so an unattended run neither prompts nor fails
#            on a concurrent apt. An unusable --cacert file (missing, or not
#            a PEM certificate) is now rejected up front with exit 2,
#            before the root check or any package install.
#   v2.0.0 - Moved from a self-hosted Git server to the public
#            MVTS-Corp/Scripts repo on GitHub, and dropped git entirely:
#            the tool is now installed as a single verified file instead of
#            a repo clone, and self-updates over HTTPS with curl. The
#            install path layout changed (the script now sits directly in
#            /opt/ntp-config), so an older git-clone install found there is
#            replaced. TLS handling is now --insecure / --cacert flags
#            instead of environment variables; a CA file passed with
#            --cacert is copied into the install directory so it keeps
#            working after the original file is gone. Re-running without a
#            TLS flag keeps the previous TLS choice.
#   v1.1.0 - Last version published from the previous self-hosted repo.
#
# Usage:
#   sudo ./install.sh [--ref REF] [--insecure | --cacert FILE]
#
#   --ref REF      git branch or tag to follow for updates (default: stable).
#                  A tag such as ntp-config-v1.0.0 pins that exact release.
#
#   --insecure     skip TLS verification for this tool's update checks
#                  (trusted networks only)
#   --cacert FILE  verify TLS against this CA chain (PEM) instead of the
#                  system trust store
#
# Never prompts, so it is safe to call from another script. Exit codes:
#   0  installed (re-running is safe and idempotent)
#   1  runtime failure (not root, missing dependency, bad source script...)
#   2  invalid command line; nothing on the system was touched

set -euo pipefail

SCRIPT_VERSION="v2.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/ntp-config"
DEFAULT_REF="stable"
BIN_LINK="/usr/local/sbin/configure-ntp-server.sh"
MAIN_SCRIPT_NAME="configure-ntp-server.sh"
STATE_FILE="${INSTALL_DIR}/.ntp-config-state"
CA_DEST="${INSTALL_DIR}/ca.pem"

fail_trap() {
    echo "ERROR: install.sh failed at line $1." >&2
}
trap 'fail_trap "$LINENO"' ERR

usage() {
    sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------
# A ref ends up inside download URLs and in the saved state, so only the
# characters git allows in a branch or tag name in practice are accepted.
valid_ref() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$1" != *..* && "$1" != */ ]]
}

OPT_INSECURE=0
OPT_CACERT=""
OPT_REF=""
while (( $# > 0 )); do
    case "$1" in
        --insecure) OPT_INSECURE=1; shift ;;
        --ref)
            if (( $# < 2 )); then
                echo "ERROR: --ref needs a branch or tag name." >&2
                exit 2
            fi
            valid_ref "$2" || { echo "ERROR: --ref '$2' is not a valid branch or tag name." >&2; exit 2; }
            OPT_REF="$2"
            shift 2
            ;;
        --cacert)
            if (( $# < 2 )); then
                echo "ERROR: --cacert needs a file path." >&2
                exit 2
            fi
            OPT_CACERT="$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "ERROR: unknown argument '$1'." >&2
            usage >&2
            exit 2
            ;;
    esac
done

if (( OPT_INSECURE == 1 )) && [[ -n "${OPT_CACERT}" ]]; then
    echo "ERROR: --insecure and --cacert are mutually exclusive. Pick one." >&2
    exit 2
fi

# An unusable CA file is a command-line mistake, so it is caught here (exit 2,
# nothing touched) rather than after packages have been installed.
if [[ -n "${OPT_CACERT}" ]]; then
    if [[ ! -f "${OPT_CACERT}" ]]; then
        echo "ERROR: --cacert file '${OPT_CACERT}' does not exist." >&2
        exit 2
    fi
    if ! grep -q 'BEGIN CERTIFICATE' "${OPT_CACERT}"; then
        echo "ERROR: '${OPT_CACERT}' does not look like a PEM certificate file." >&2
        exit 2
    fi
fi

# --------------------------------------------------------------------------
# Root check
# --------------------------------------------------------------------------
if [[ ${EUID} -ne 0 ]]; then
    echo "ERROR: this installer must be run as root (sudo)." >&2
    exit 1
fi

# --------------------------------------------------------------------------
# Dependency check (curl is what self-update uses; everything else is
# checked by configure-ntp-server.sh itself on first run). All missing
# commands are collected first and installed in one pass.
# --------------------------------------------------------------------------
missing=()
for cmd in curl bash; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
done

if (( ${#missing[@]} > 0 )); then
    echo "Missing required command(s): ${missing[*]}. Installing..."
    if command -v apt-get >/dev/null 2>&1; then
        export NEEDRESTART_MODE=a
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 update -qq
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y "${missing[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${missing[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${missing[@]}"
    else
        echo "ERROR: no known package manager (apt-get/dnf/yum) found to install: ${missing[*]}" >&2
        echo "Install these manually and re-run install.sh." >&2
        exit 1
    fi

    still_missing=()
    for cmd in "${missing[@]}"; do
        command -v "${cmd}" >/dev/null 2>&1 || still_missing+=("${cmd}")
    done
    if (( ${#still_missing[@]} > 0 )); then
        echo "ERROR: still missing after install attempt: ${still_missing[*]}" >&2
        exit 1
    fi
fi

# --------------------------------------------------------------------------
# Verify the source script before anything on disk is touched
# --------------------------------------------------------------------------
SRC_SCRIPT="${SCRIPT_DIR}/${MAIN_SCRIPT_NAME}"
if [[ ! -f "${SRC_SCRIPT}" ]]; then
    echo "ERROR: ${MAIN_SCRIPT_NAME} not found next to install.sh (${SCRIPT_DIR})." >&2
    exit 1
fi
if ! bash -n "${SRC_SCRIPT}"; then
    echo "ERROR: ${MAIN_SCRIPT_NAME} failed a syntax check. Refusing to install it." >&2
    exit 1
fi

# --------------------------------------------------------------------------
# Decide the TLS state to record
#
# Explicit flags win. With no flag, an existing install's choice is kept
# rather than silently reset, so re-running the installer for an unrelated
# reason never changes how update checks verify TLS.
# --------------------------------------------------------------------------
TLS_MODE="default"
CA_CERT=""
if (( OPT_INSECURE == 1 )); then
    echo "WARNING: --insecure set. Update checks will skip TLS verification."
    echo "         Only appropriate on a trusted network."
    TLS_MODE="insecure"
elif [[ -n "${OPT_CACERT}" ]]; then
    TLS_MODE="cacert"
    CA_CERT="${CA_DEST}"
elif [[ -f "${STATE_FILE}" ]]; then
    prev_mode="$(awk -F= '$1 == "TLS_MODE" { sub(/^[^=]*=/, ""); print; exit }' "${STATE_FILE}")"
    case "${prev_mode}" in
        insecure) TLS_MODE="insecure" ;;
        cacert)
            if [[ -f "${CA_DEST}" ]]; then
                TLS_MODE="cacert"
                CA_CERT="${CA_DEST}"
            fi
            ;;
    esac
    echo "Keeping the existing TLS setting (${TLS_MODE})."
fi

# --------------------------------------------------------------------------
# Decide the ref to follow for updates. Same rule as TLS: an explicit --ref
# wins; otherwise an existing install's ref is kept (so re-running the
# installer never silently moves a pinned host onto the moving channel);
# otherwise the default channel.
# --------------------------------------------------------------------------
REF="${DEFAULT_REF}"
if [[ -n "${OPT_REF}" ]]; then
    REF="${OPT_REF}"
elif [[ -f "${STATE_FILE}" ]]; then
    prev_ref="$(awk -F= '$1 == "REF" { sub(/^[^=]*=/, ""); print; exit }' "${STATE_FILE}")"
    if [[ -n "${prev_ref}" ]] && valid_ref "${prev_ref}"; then
        REF="${prev_ref}"
        echo "Keeping the existing update ref (${REF})."
    fi
fi

# --------------------------------------------------------------------------
# Replace an older git-clone install
#
# Earlier versions cloned a git repo into ${INSTALL_DIR} and linked into
# it. Only a directory that is verifiably such a clone is removed; anything
# else already at this path is left alone and the install stops.
# --------------------------------------------------------------------------
if [[ -d "${INSTALL_DIR}/.git" ]]; then
    if grep -qs 'url *=.*ntp-config' "${INSTALL_DIR}/.git/config"; then
        echo "Replacing older git-clone install at ${INSTALL_DIR}..."
        rm -rf -- "${INSTALL_DIR}"
    else
        echo "ERROR: ${INSTALL_DIR} is a git repository that does not look like an ntp-config clone." >&2
        echo "Move or remove it and re-run install.sh." >&2
        exit 1
    fi
fi

# --------------------------------------------------------------------------
# Install
# --------------------------------------------------------------------------
install -d -m 0755 -o root -g root "${INSTALL_DIR}"

# Written next to the destination and renamed into place so an interrupted
# install can never leave a half-written script behind the symlink.
tmp_script="$(mktemp "${INSTALL_DIR}/.install.XXXXXX")"
trap 'rm -f "${tmp_script}"' EXIT
install -m 0755 -o root -g root "${SRC_SCRIPT}" "${tmp_script}"
mv -f "${tmp_script}" "${INSTALL_DIR}/${MAIN_SCRIPT_NAME}"

if [[ "${TLS_MODE}" == "cacert" && -n "${OPT_CACERT}" ]]; then
    install -m 0644 -o root -g root "${OPT_CACERT}" "${CA_DEST}"
fi

{
    echo "REF=${REF}"
    echo "TLS_MODE=${TLS_MODE}"
    echo "CA_CERT=${CA_CERT}"
} > "${STATE_FILE}"
chmod 0644 "${STATE_FILE}"
chown root:root "${STATE_FILE}"

ln -sf "${INSTALL_DIR}/${MAIN_SCRIPT_NAME}" "${BIN_LINK}"

# Confirm the live command actually resolves to the file just installed.
if [[ "$(readlink -f "${BIN_LINK}")" != "$(readlink -f "${INSTALL_DIR}/${MAIN_SCRIPT_NAME}")" ]]; then
    echo "ERROR: ${BIN_LINK} does not resolve to ${INSTALL_DIR}/${MAIN_SCRIPT_NAME}." >&2
    exit 1
fi

echo ""
echo "install.sh ${SCRIPT_VERSION} complete."
echo "  Installed: ${INSTALL_DIR}/${MAIN_SCRIPT_NAME}"
echo "  Linked:    ${BIN_LINK}"
echo "  Follows:   ${REF}"
echo "  TLS mode:  ${TLS_MODE}"
echo ""
echo "Run it with: sudo configure-ntp-server.sh"
echo "It checks for and applies updates automatically on every run."
echo "No cron entries were created; none are needed for this tool."
