#!/usr/bin/env bash
#
# gitea-backup.sh
# 2026-08-08
# Version: v2.0.0
#
# PURPOSE:
# Runs "gitea dump" inside a running Gitea container (repos + LFS + DB dump
# + config in one archive), verifies the result, and ships it to a NAS via
# rsync over SSH for off-site/cloud backup. Gives an independent recovery
# path for Gitea separate from the host's full-container-set backup.
#
# USAGE:
#   gitea-backup.sh                 Normal run
#   gitea-backup.sh --dry-run       Run all checks and the dump, but do not
#                                    transfer to the NAS or delete anything
#   gitea-backup.sh --check         Dependency and pre-flight checks only
#                                    (includes a live SSH connectivity test)
#
# CONFIG:
#   Reads /etc/gitea-backup/gitea-backup.conf by default. Override with
#   GITEA_BACKUP_CONF=/path/to/file.conf gitea-backup.sh

set -euo pipefail

CONF_FILE="${GITEA_BACKUP_CONF:-/etc/gitea-backup/gitea-backup.conf}"
DRY_RUN=0
CHECK_ONLY=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --check) CHECK_ONLY=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*"
    echo "$line"
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "$line" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

FAILED_CONTEXT=""
fail_trap() {
    local lineno="$1"
    log ERROR "gitea-backup.sh failed at line ${lineno}. ${FAILED_CONTEXT}"
    send_failure_notification "Failed at line ${lineno}. ${FAILED_CONTEXT}"
    exit 1
}
trap 'fail_trap "$LINENO"' ERR

# ---------------------------------------------------------------------------
# Notification (bounded retry, never blocks/hangs the run)
# ---------------------------------------------------------------------------
send_mail_raw() {
    local subject="$1" body="$2"
    local max_attempts=3 attempt=1
    [[ -z "${NOTIFY_EMAIL:-}" ]] && return 0
    while (( attempt <= max_attempts )); do
        if echo "$body" | timeout 30 mail -s "$subject" -r "${MAIL_FROM:-gitea-backup@localhost}" "$NOTIFY_EMAIL"; then
            return 0
        fi
        (( attempt < max_attempts )) && sleep $(( attempt * 5 ))
        (( attempt++ ))
    done
    log WARN "Failed to send notification email after ${max_attempts} attempts."
    return 0
}

send_failure_notification() {
    local detail="$1"
    local tail_log=""
    [[ -f "${LOG_FILE:-}" ]] && tail_log="$(tail -n 30 "$LOG_FILE" 2>/dev/null || true)"
    send_mail_raw "Gitea backup FAILED on $(hostname)" "$(printf 'Gitea backup failed.\n\nDetail: %s\n\nLast log lines:\n%s\n' "$detail" "$tail_log")"
}

# Use this for every deliberate, anticipated failure (bad config, a failed
# pre-flight check, a failed verification). A bare `exit 1` does NOT trigger
# the ERR trap below - bash only runs an ERR trap for a command that itself
# fails, not for an explicit `exit` call - so any intentional failure exit
# that bypasses this function will fail silently with no notification even
# though it logs and exits non-zero.
die() {
    local msg="$1"
    log ERROR "$msg"
    send_failure_notification "$msg"
    exit 1
}

send_heartbeat() {
    [[ -z "${HEARTBEAT_URL:-}" ]] && return 0
    if ! timeout 10 curl -fsS "$HEARTBEAT_URL" >/dev/null 2>&1; then
        log WARN "Heartbeat ping failed (non-fatal)."
    fi
}

# Retention cleanup runs after the backup is already verified and safely
# transferred. A transient failure here (a dropped SSH session, a slow NAS)
# must not flip an already-successful backup run into a reported failure,
# so these are deliberately non-fatal: log and move on rather than letting
# the ERR trap fire.
cleanup_nas_retention() {
    local output
    # shellcheck disable=SC2086
    if ! output="$(timeout 30 ssh $SSH_OPTS "${NAS_SSH_USER}@${NAS_SSH_HOST}" \
        "find '${NAS_REMOTE_PATH}' -maxdepth 1 -name 'gitea-dump-*.zip' -mtime +${RETENTION_DAYS} -print -delete" 2>&1)"; then
        log WARN "Retention cleanup on NAS failed (backup itself already succeeded). Output: ${output}"
        return 0
    fi
    if [[ -n "$output" ]]; then
        while IFS= read -r deleted; do log INFO "Deleted (retention, NAS): ${deleted}"; done <<< "$output"
    fi
    return 0
}

cleanup_staging_retention() {
    local output
    if ! output="$(find "$STAGING_DIR" -maxdepth 1 -name 'gitea-dump-*.zip' -mtime "+${STAGING_RETENTION_DAYS}" -print -delete 2>&1)"; then
        log WARN "Retention cleanup on staging failed. Output: ${output}"
        return 0
    fi
    if [[ -n "$output" ]]; then
        while IFS= read -r deleted; do log INFO "Deleted (retention, staging): ${deleted}"; done <<< "$output"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
if [[ ! -f "$CONF_FILE" ]]; then
    die "Config file not found: ${CONF_FILE}"
fi
conf_perm="$(stat -c '%a' "$CONF_FILE" 2>/dev/null || echo '000')"
if [[ "$conf_perm" != "600" && "$conf_perm" != "640" ]]; then
    echo "WARNING: ${CONF_FILE} has permissions ${conf_perm}. Recommend 600 (it can reference key paths)." >&2
fi
# shellcheck disable=SC1090
source "$CONF_FILE"

for required_var in GITEA_CONTAINER_NAME GITEA_CONTAINER_USER GITEA_APP_INI \
                     GITEA_CONTAINER_TMP STAGING_DIR STAGING_RETENTION_DAYS \
                     NAS_SSH_HOST NAS_SSH_PORT NAS_SSH_USER NAS_SSH_KEY \
                     NAS_KNOWN_HOSTS NAS_REMOTE_PATH RSYNC_TIMEOUT \
                     MAX_TRANSFER_ATTEMPTS RETENTION_DAYS MIN_DUMP_SIZE_BYTES; do
    if [[ -z "${!required_var:-}" ]]; then
        die "${required_var} is not set in ${CONF_FILE}"
    fi
done

# Numeric config values feed directly into arithmetic contexts and command
# arguments (timeouts, retry counts, port numbers). A malformed value here
# should fail clearly at load time, not as a cryptic bash arithmetic error
# deep into a run.
for numeric_var in RSYNC_TIMEOUT MAX_TRANSFER_ATTEMPTS RETENTION_DAYS \
                    STAGING_RETENTION_DAYS MIN_DUMP_SIZE_BYTES NAS_SSH_PORT; do
    if ! [[ "${!numeric_var}" =~ ^[0-9]+$ ]]; then
        die "${numeric_var}='${!numeric_var}' in ${CONF_FILE} is not a positive integer."
    fi
done

# Optional, defaulted rather than required so existing deployed configs do
# not need editing: bounds the "gitea dump" step (see DUMP_TIMEOUT below).
DUMP_TIMEOUT="${DUMP_TIMEOUT:-21600}"
if ! [[ "$DUMP_TIMEOUT" =~ ^[0-9]+$ ]]; then
    die "DUMP_TIMEOUT='${DUMP_TIMEOUT}' in ${CONF_FILE} is not a positive integer (seconds)."
fi

# ---------------------------------------------------------------------------
# Dependency check (all up front, one pass)
# ---------------------------------------------------------------------------
FAILED_CONTEXT="Dependency check"
declare -A REQUIRED_PKGS=(
    [docker]="docker.io"
    [unzip]="unzip"
    [sha256sum]="coreutils"
    [curl]="curl"
    [rsync]="rsync"
    [ssh]="openssh-client"
    [flock]="util-linux"
    [timeout]="coreutils"
)
missing_cmds=()
for cmd in "${!REQUIRED_PKGS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing_cmds+=("$cmd")
done
if (( ${#missing_cmds[@]} )); then
    for c in "${missing_cmds[@]}"; do
        log ERROR "Missing required command: ${c} -> apt package: ${REQUIRED_PKGS[$c]}"
    done
    die "Missing required commands: ${missing_cmds[*]}"
fi
# "mail" is optional (only needed if NOTIFY_EMAIL is set)
if [[ -n "${NOTIFY_EMAIL:-}" ]] && ! command -v mail >/dev/null 2>&1; then
    log WARN "NOTIFY_EMAIL is set but 'mail' command is not installed (mailutils/bsd-mailx). Alerts will not be sent."
fi

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
FAILED_CONTEXT="Pre-flight: container running check"
running="$(docker inspect -f '{{.State.Running}}' "$GITEA_CONTAINER_NAME" 2>/dev/null || echo false)"
if [[ "$running" != "true" ]]; then
    die "Container '${GITEA_CONTAINER_NAME}' is not running (or docker itself is unreachable)."
fi

FAILED_CONTEXT="Pre-flight: SSH key checks"
if [[ ! -f "$NAS_SSH_KEY" ]]; then
    die "SSH key not found: ${NAS_SSH_KEY}"
fi
key_perm="$(stat -c '%a' "$NAS_SSH_KEY")"
if [[ "$key_perm" != "600" && "$key_perm" != "400" ]]; then
    die "SSH key ${NAS_SSH_KEY} has permissions ${key_perm}, expected 600 or 400. Refusing to use it: 'chmod 600 ${NAS_SSH_KEY}'."
fi
if [[ ! -f "$NAS_KNOWN_HOSTS" ]]; then
    die "known_hosts file not found: ${NAS_KNOWN_HOSTS}. Pre-seed it with: ssh-keyscan -p ${NAS_SSH_PORT} ${NAS_SSH_HOST} > ${NAS_KNOWN_HOSTS}"
fi

# Built once, reused for every SSH/rsync call. rsync's -e re-splits this on
# whitespace itself (it does not pass through a shell), so this string must
# not contain paths with spaces.
SSH_OPTS="-i ${NAS_SSH_KEY} -p ${NAS_SSH_PORT} -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${NAS_KNOWN_HOSTS}"

FAILED_CONTEXT="Pre-flight: SSH connectivity and remote path check"
# shellcheck disable=SC2086
if ! timeout 20 ssh $SSH_OPTS "${NAS_SSH_USER}@${NAS_SSH_HOST}" \
    "test -d '${NAS_REMOTE_PATH}' && test -w '${NAS_REMOTE_PATH}'"; then
    die "Cannot reach ${NAS_SSH_HOST} as ${NAS_SSH_USER}, or ${NAS_REMOTE_PATH} does not exist / is not writable. Confirm the actual filesystem path on the NAS - the SMB share name is not the same as the filesystem path."
fi
log INFO "Confirmed SSH access and write permission to ${NAS_SSH_HOST}:${NAS_REMOTE_PATH}"

FAILED_CONTEXT="Pre-flight: staging directory"
mkdir -p "$STAGING_DIR"

if (( CHECK_ONLY )); then
    log INFO "Checks passed. --check specified, exiting without running a backup."
    exit 0
fi

# ---------------------------------------------------------------------------
# Exclusive lock. Prevents two runs racing on the same container/staging
# dir/NAS path - e.g. cron firing again while a previous run's dump is
# still going on a large instance, or a manual run overlapping cron. Held
# via a file descriptor rather than a PID file, so it can never go stale:
# the kernel releases it automatically the moment this process exits, for
# any reason including a crash. --check is exempt on purpose (read-only,
# safe to run concurrently with anything).
# ---------------------------------------------------------------------------
LOCK_FILE="${STAGING_DIR}/.gitea-backup.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log WARN "Another gitea-backup.sh run appears to be in progress (lock: ${LOCK_FILE}). Exiting without action."
    exit 0
fi

# ---------------------------------------------------------------------------
# Run the dump
# ---------------------------------------------------------------------------
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
DUMP_NAME="gitea-dump-${TIMESTAMP}.zip"
CONTAINER_DUMP_PATH="${GITEA_CONTAINER_TMP}/${DUMP_NAME}"

# Best-effort cleanup of the in-container scratch file on ANY exit from
# here on (success, timeout, or an unrelated later failure). Without this,
# a dump that fails partway - or a docker cp that fails after a successful
# dump - leaves the archive sitting in the container's tmp dir forever,
# slowly eating its disk across repeated failures, since the old code only
# cleaned this up on the success path. Also makes a best-effort attempt to
# kill a still-running "gitea dump" process after a DUMP_TIMEOUT hit: a
# local "docker exec"/timeout returning does not guarantee the process
# inside the container actually stopped, since the timeout is enforced
# client-side, not delivered to the remote process. Neither half of this is
# guaranteed (pkill may be absent from a minimal Gitea image), which is why
# it is "|| true" throughout and a real failure still exits loudly via die().
cleanup_container_scratch() {
    docker exec -u "$GITEA_CONTAINER_USER" "$GITEA_CONTAINER_NAME" \
        pkill -f "gitea dump -c ${GITEA_APP_INI}" >/dev/null 2>&1 || true
    docker exec -u "$GITEA_CONTAINER_USER" "$GITEA_CONTAINER_NAME" \
        rm -f "$CONTAINER_DUMP_PATH" >/dev/null 2>&1 || true
}
trap cleanup_container_scratch EXIT

FAILED_CONTEXT="Running gitea dump inside container"
log INFO "Starting gitea dump (container=${GITEA_CONTAINER_NAME}, timeout=${DUMP_TIMEOUT}s)."
docker exec -u "$GITEA_CONTAINER_USER" "$GITEA_CONTAINER_NAME" mkdir -p "$GITEA_CONTAINER_TMP"
if ! timeout "$DUMP_TIMEOUT" docker exec -u "$GITEA_CONTAINER_USER" "$GITEA_CONTAINER_NAME" \
    gitea dump -c "$GITEA_APP_INI" --type zip -f "$CONTAINER_DUMP_PATH"; then
    die "gitea dump did not complete within DUMP_TIMEOUT (${DUMP_TIMEOUT}s), or failed outright. If this is a large instance that legitimately needs longer, raise DUMP_TIMEOUT in ${CONF_FILE}. Check inside the container for a still-running or orphaned dump process."
fi
log INFO "gitea dump completed inside container."

FAILED_CONTEXT="Copying dump out of container"
if ! timeout "$DUMP_TIMEOUT" docker cp "${GITEA_CONTAINER_NAME}:${CONTAINER_DUMP_PATH}" "${STAGING_DIR}/${DUMP_NAME}"; then
    die "docker cp of the dump archive out of the container did not complete within DUMP_TIMEOUT (${DUMP_TIMEOUT}s), or failed."
fi

# ---------------------------------------------------------------------------
# Verify the staged copy before trusting it
# ---------------------------------------------------------------------------
FAILED_CONTEXT="Verifying staged dump"
STAGED_FILE="${STAGING_DIR}/${DUMP_NAME}"
if [[ ! -s "$STAGED_FILE" ]]; then
    die "Staged dump file is missing or empty: ${STAGED_FILE}"
fi
dump_size="$(stat -c '%s' "$STAGED_FILE")"
if (( dump_size < MIN_DUMP_SIZE_BYTES )); then
    die "Dump file is suspiciously small (${dump_size} bytes, minimum ${MIN_DUMP_SIZE_BYTES}). Not trusting it."
fi
if ! unzip -tq "$STAGED_FILE" >/dev/null; then
    die "Dump archive failed zip integrity check: ${STAGED_FILE}"
fi
log INFO "Staged dump verified: ${STAGED_FILE} (${dump_size} bytes)."

if (( DRY_RUN )); then
    log INFO "--dry-run specified. Skipping transfer to NAS and retention cleanup."
    send_heartbeat
    exit 0
fi

# ---------------------------------------------------------------------------
# Transfer to NAS via rsync over SSH (bounded retries)
# ---------------------------------------------------------------------------
FAILED_CONTEXT="Transferring dump to NAS via rsync"
transfer_attempt=1
transfer_ok=0
while (( transfer_attempt <= MAX_TRANSFER_ATTEMPTS )); do
    # --protect-args stops rsync from handing the destination path to the
    # remote shell for interpretation. NAS_REMOTE_PATH contains characters
    # ($, !) that are inert with the current placeholder path only by
    # coincidence of what follows them; since that path is explicitly
    # unconfirmed (see CLAUDE.md), do not depend on that coincidence
    # holding for whatever the real path turns out to be.
    # shellcheck disable=SC2086
    if rsync -az --protect-args --partial --timeout="$RSYNC_TIMEOUT" -e "ssh $SSH_OPTS" \
        "$STAGED_FILE" "${NAS_SSH_USER}@${NAS_SSH_HOST}:${NAS_REMOTE_PATH}/"; then
        transfer_ok=1
        break
    fi
    log WARN "rsync attempt ${transfer_attempt}/${MAX_TRANSFER_ATTEMPTS} failed."
    (( transfer_attempt < MAX_TRANSFER_ATTEMPTS )) && sleep $(( transfer_attempt * 10 ))
    (( transfer_attempt++ ))
done
if (( ! transfer_ok )); then
    die "rsync failed after ${MAX_TRANSFER_ATTEMPTS} attempts."
fi
log INFO "Transferred to ${NAS_SSH_HOST}:${NAS_REMOTE_PATH}/${DUMP_NAME}"

# ---------------------------------------------------------------------------
# Independent post-transfer verification (best-effort beyond rsync's own
# transfer-level integrity checking)
# ---------------------------------------------------------------------------
FAILED_CONTEXT="Verifying transferred dump on NAS"
if [[ -n "${REMOTE_SHA256SUM_CMD:-}" ]]; then
    SOURCE_SUM="$(sha256sum "$STAGED_FILE" | awk '{print $1}')"
    # shellcheck disable=SC2086
    REMOTE_SUM="$(timeout 30 ssh $SSH_OPTS "${NAS_SSH_USER}@${NAS_SSH_HOST}" \
        "${REMOTE_SHA256SUM_CMD} '${NAS_REMOTE_PATH}/${DUMP_NAME}' 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)"
    if [[ -z "$REMOTE_SUM" ]]; then
        log WARN "Could not compute remote checksum (command unavailable or failed on NAS). Skipping independent verification for this run; rsync's own transfer integrity still applies."
    elif [[ "$SOURCE_SUM" != "$REMOTE_SUM" ]]; then
        # shellcheck disable=SC2086
        timeout 20 ssh $SSH_OPTS "${NAS_SSH_USER}@${NAS_SSH_HOST}" "rm -f '${NAS_REMOTE_PATH}/${DUMP_NAME}'" || true
        die "Checksum mismatch after transfer (Source=${SOURCE_SUM} Remote=${REMOTE_SUM}). Bad copy removed from NAS."
    else
        log INFO "Remote checksum verified: ${REMOTE_SUM}"
    fi
else
    log INFO "REMOTE_SHA256SUM_CMD is unset; skipping independent remote checksum verification."
fi

# ---------------------------------------------------------------------------
# Retention cleanup (non-fatal by design - see cleanup_* functions above)
# ---------------------------------------------------------------------------
cleanup_nas_retention
cleanup_staging_retention

log INFO "Backup run complete."
send_heartbeat
exit 0
