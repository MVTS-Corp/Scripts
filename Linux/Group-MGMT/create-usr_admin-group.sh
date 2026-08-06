#!/usr/bin/env bash
#
# create-usr_admin-group.sh
# 2026-08-05
# Version: v1.0.0
#
# PURPOSE:
# Creates the usr_admin group at a fixed GID (default 3000), verifying the
# GID if the group already exists rather than silently reusing a mismatched
# one. Optionally adds one or more existing local users to the group,
# either interactively (numbered prompt) or unattended via --users for
# RMM / orchestration use.

set -euo pipefail

fail_trap() {
    local lineno="$1"
    echo "ERROR: ${0##*/} failed at line ${lineno}. No further changes were made past this point." >&2
    exit 1
}
trap 'fail_trap "$LINENO"' ERR

readonly GROUP_NAME="usr_admin"
readonly DEFAULT_GID="3000"
readonly MIN_HUMAN_UID="1000"

TARGET_GID="${USR_ADMIN_GID:-${DEFAULT_GID}}"
USERS_ARG=""
ASSUME_YES=0

usage() {
    cat <<EOF
Usage: sudo ${0##*/} [--users user1,user2,...] [--gid N] [--yes]

  --users     Comma separated list of existing local usernames to add to
              ${GROUP_NAME}. Required for unattended runs (RMM, cron,
              orchestration). If omitted on an interactive terminal, you
              will be prompted to select from a numbered list instead.
  --gid N     Override the target GID (default: ${DEFAULT_GID}). Only
              applies when the group does not already exist; an existing
              group's GID is never changed by this script.
  --yes       Skip the confirmation prompt before adding users. Implied
              automatically when --users is passed with no TTY attached.
  -h, --help  Show this help text.

Examples:
  sudo ./${0##*/}                          # interactive
  sudo ./${0##*/} --users jsmith,tzh-freepbx-admin --yes
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --users)
            [[ $# -ge 2 ]] || { echo "ERROR: --users requires a value." >&2; exit 1; }
            USERS_ARG="$2"; shift 2 ;;
        --gid)
            [[ $# -ge 2 ]] || { echo "ERROR: --gid requires a value." >&2; exit 1; }
            TARGET_GID="$2"; shift 2 ;;
        --yes)
            ASSUME_YES=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage
            exit 1 ;;
    esac
done

if [[ ! "${TARGET_GID}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --gid must be numeric, got '${TARGET_GID}'." >&2
    exit 1
fi

# --- privilege check --------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: this script must be run as root (use sudo)." >&2
    exit 1
fi

# --- dependency check, all up front -----------------------------------------
required_cmds=(getent groupadd usermod id awk)
missing_cmds=()
for cmd in "${required_cmds[@]}"; do
    command -v "${cmd}" >/dev/null 2>&1 || missing_cmds+=("${cmd}")
done
if (( ${#missing_cmds[@]} > 0 )); then
    echo "ERROR: missing required commands: ${missing_cmds[*]}" >&2
    echo "These ship with shadow-utils/coreutils on virtually every distro;" >&2
    echo "if they are absent, this is not a standard Linux environment." >&2
    exit 1
fi

# --- group existence / GID verification -------------------------------------
existing_group_entry="$(getent group "${GROUP_NAME}" || true)"

if [[ -n "${existing_group_entry}" ]]; then
    existing_gid="$(awk -F: '{print $3}' <<< "${existing_group_entry}")"
    if [[ "${existing_gid}" != "${TARGET_GID}" ]]; then
        echo "ERROR: group '${GROUP_NAME}' already exists with GID ${existing_gid}," >&2
        echo "which does not match the expected GID ${TARGET_GID}." >&2
        echo "Stopping without making any changes. Resolve the GID mismatch" >&2
        echo "manually (either accept the existing GID with --gid ${existing_gid}," >&2
        echo "or reconcile it against the rest of the fleet) before re-running." >&2
        exit 1
    fi
    echo "Group '${GROUP_NAME}' already exists with the correct GID (${TARGET_GID}). Skipping creation."
else
    echo "Creating group '${GROUP_NAME}' with GID ${TARGET_GID}..."
    groupadd -g "${TARGET_GID}" "${GROUP_NAME}"
    # Verify the group manager's exit code actually reflects reality.
    created_gid="$(getent group "${GROUP_NAME}" | awk -F: '{print $3}')"
    if [[ "${created_gid}" != "${TARGET_GID}" ]]; then
        echo "ERROR: group creation reported success but GID is '${created_gid}', not '${TARGET_GID}'." >&2
        exit 1
    fi
    echo "Group '${GROUP_NAME}' created with GID ${TARGET_GID}."
fi

# --- build the candidate user list (local human accounts) -------------------
mapfile -t candidate_users < <(
    awk -F: -v min="${MIN_HUMAN_UID}" \
        '($3 >= min) && ($3 != 65534) {print $1}' /etc/passwd | sort
)

if (( ${#candidate_users[@]} == 0 )); then
    echo "No local human user accounts (UID >= ${MIN_HUMAN_UID}) were found. Nothing to add. Done."
    exit 0
fi

# --- resolve which users to add ---------------------------------------------
declare -a target_users=()

if [[ -n "${USERS_ARG}" ]]; then
    IFS=',' read -r -a target_users <<< "${USERS_ARG}"
elif [[ -t 0 ]]; then
    echo ""
    echo "Local human user accounts on this system:"
    for i in "${!candidate_users[@]}"; do
        printf '  %2d) %s\n' "$((i + 1))" "${candidate_users[$i]}"
    done
    echo ""
    echo "Enter the numbers of the users to add to '${GROUP_NAME}',"
    echo "space or comma separated (example: 1 3 4). Enter 'all' for"
    echo "everyone listed, or press Enter to skip adding anyone."
    read -r -p "Selection: " selection
    selection="${selection//,/ }"

    if [[ -z "${selection}" ]]; then
        echo "No selection made. Group is ready; no users were added. Done."
        exit 0
    elif [[ "${selection,,}" == "all" ]]; then
        target_users=("${candidate_users[@]}")
    else
        for token in ${selection}; do
            if [[ ! "${token}" =~ ^[0-9]+$ ]] || (( token < 1 || token > ${#candidate_users[@]} )); then
                echo "ERROR: invalid selection '${token}'. Valid range is 1-${#candidate_users[@]}." >&2
                exit 1
            fi
            target_users+=("${candidate_users[$((token - 1))]}")
        done
    fi
else
    echo "No --users supplied and no interactive terminal is attached."
    echo "The group is ready, but I am not guessing who to add to it."
    echo "Re-run with --users user1,user2 for unattended/RMM use." >&2
    exit 1
fi

# --- validate every requested user before changing anything -----------------
invalid_users=()
for u in "${target_users[@]}"; do
    id -u "${u}" >/dev/null 2>&1 || invalid_users+=("${u}")
done
if (( ${#invalid_users[@]} > 0 )); then
    echo "ERROR: the following users do not exist on this system: ${invalid_users[*]}" >&2
    echo "No group membership changes were made." >&2
    exit 1
fi

if [[ "${ASSUME_YES}" -ne 1 && -t 0 && -z "${USERS_ARG}" ]]; then
    echo ""
    echo "About to add the following users to '${GROUP_NAME}': ${target_users[*]}"
    read -r -p "Proceed? [y/N]: " confirm
    [[ "${confirm,,}" == "y" || "${confirm,,}" == "yes" ]] || { echo "Aborted, no changes made."; exit 0; }
fi

# --- add users, idempotently -------------------------------------------------
for u in "${target_users[@]}"; do
    if id -nG "${u}" | tr ' ' '\n' | grep -qx "${GROUP_NAME}"; then
        echo "  ${u} is already a member of ${GROUP_NAME}, skipping."
    else
        usermod -aG "${GROUP_NAME}" "${u}"
        echo "  Added ${u} to ${GROUP_NAME}."
    fi
done

echo ""
echo "Done. Note: users already logged in must log out and back in (or run"
echo "'newgrp ${GROUP_NAME}') before the new membership takes effect in their session."
