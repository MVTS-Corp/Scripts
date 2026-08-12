#!/usr/bin/env bash
#
# gitea-restore.sh
# 2026-08-11
# Version: v3.0.7
#
# CHANGELOG:
#   v3.0.7 - Fixed a regression from v3.0.6's own defensive app.ini
#            restoration: confirmed against a real archive that when
#            CustomPath and AppDataPath overlap, data/ already contains
#            a complete, already-installed conf/app.ini (INSTALL_LOCK =
#            true) at exactly the path GITEA_APP_INI expects - and the
#            archive's separate standalone top-level app.ini is NOT
#            necessarily the same file. v3.0.6 copied the standalone one
#            in unconditionally, silently overwriting the good nested
#            config with an incomplete one lacking INSTALL_LOCK, which
#            sent every restored instance to Gitea's install wizard
#            instead of starting normally - a real bug found via a live
#            restore before it could reach the actual production
#            --restore path. The standalone copy is now used only as a
#            fallback when data/ doesn't already have one at that path;
#            an existing nested config is never overwritten.
#   v3.0.6 - Proactive review after live troubleshooting kept surfacing
#            issues in this same code path, found two more before they
#            could bite in production:
#            - "docker cp" preserves the copying process's own uid/gid
#              (root, since this script runs via sudo) on files it writes
#              into the container, not whatever user Gitea actually runs
#              as. Every restored file was very likely landing owned by
#              root instead of the confirmed-required git user, which
#              could prevent Gitea from even reading its own restored
#              data - a real bug in the production --restore path, not
#              just --test-restore. restore_pipeline() now chowns the
#              restored paths back to GITEA_CONTAINER_USER's uid/gid
#              (looked up live inside the target, not hardcoded) right
#              after copying, before starting the container.
#            - That fix needed GITEA_CONTAINER_USER, which this script
#              never previously used (only gitea-backup.sh did) and so
#              never gave a fallback default - would have hard-failed
#              with "unbound variable" under set -u on any conf file
#              that didn't happen to define it explicitly. Added the same
#              "${GITEA_CONTAINER_USER:-git}" fallback gitea-backup.sh
#              already uses.
#            - Also defensively restore the archive's standalone app.ini
#              to its expected path inside the restored data (in addition
#              to whatever data/ already contains), since it's not yet
#              confirmed whether every Gitea configuration includes it in
#              data/ too - harmless no-op if it's already there.
#   v3.0.5 - --test-restore's teardown_test() EXIT trap now dumps the
#            failed container's own log (last 50 lines) before removing
#            it. Previously, a health-check failure told you to run
#            "docker logs <container>" for diagnosis, but the same EXIT
#            trap that printed that advice had already deleted the
#            container by the time you could act on it - the one piece
#            of information needed to actually diagnose the failure was
#            destroyed before it could be read. Only fires on a failed
#            run (checks the script's exit status); a successful
#            test-restore is unaffected.
#   v3.0.4 - Fixed archive integrity check and extraction to match what
#            "gitea dump" actually produces: a real, live archive from
#            a real deployment contains repos/ and data/ as plain
#            directory trees directly in the outer zip, not nested
#            gitea-repo.zip/gitea-data.zip sub-archives as previously
#            assumed - every --test-restore/--restore against a real
#            archive was failing archive verification with "does not
#            contain expected gitea-data.zip". The nested-unzip step is
#            gone entirely; repos/ and data/ are now just renamed to the
#            internal repo-root/app-data-root directories this script
#            already uses downstream.
#   v3.0.3 - send_mail_raw() now checks 'mail' is actually installed
#            before attempting to use it, instead of blindly retrying 3
#            times (up to 15s of backoff sleep, plus raw "timeout: failed
#            to run command 'mail'" spam on stderr) against a command
#            already known to be missing - matches gitea-backup.sh v4.0.3.
#   v3.0.2 - Default config path changed from /etc/gitea-backup to
#            /opt/gitea-backup, matching gitea-backup.sh v4.0.2 - see
#            that script's changelog and README.md for the reasoning.
#            BREAKING for an existing deployment that relied on the old
#            /etc/gitea-backup default without ever setting
#            GITEA_BACKUP_CONF.
#   v3.0.1 - Bounded every "docker inspect/stop/start/cp/run/rm/volume"
#            call with a timeout (an unresponsive docker daemon could
#            previously hang this script indefinitely, including inside
#            the EXIT-trap teardown for --test-restore).
#
# PURPOSE:
# Restores a Gitea instance from an archive produced by gitea-backup.sh
# (repos + data dir + a portable DB dump, bundled by "gitea dump"). Can
# fetch the archive from the NAS or use a local file, and can either
# perform a real restore into the production container or an on-demand
# test-restore into an isolated, throwaway container that never touches
# production data, volumes, or network.
#
# gitea dump has no matching single "gitea restore" command upstream as of
# writing - restoring is a manual, version-dependent process (see Gitea's
# own "Backup and Restore" docs). This script automates everything that is
# safely automatable without guessing at things this project does not
# actually know (database engine, credentials, exact volume topology) and
# stops with clear, actionable instructions for the one step it will not
# guess at: importing gitea-db.sql. Provide DB_RESTORE_CMD / (for
# --test-restore only) TEST_RESTORE_DB_CMD in the config to automate that
# step too - see gitea-backup.conf.
#
# Fetches via the same pluggable transport as gitea-backup.sh
# (TRANSFER_METHOD in the config - "sftp", "rsync-ssh", or "rsync-daemon");
# see lib/transport.sh and README.md's "Transport" section.
#
# WHAT --test-restore DOES AND DOES NOT PROVE:
# --test-restore always runs against a brand-new container on an isolated
# Docker network with its own throwaway volume - never production's
# network, volumes, or DB_RESTORE_CMD. This deliberately means a
# test-restore run cannot corrupt or disrupt production even if invoked
# with a broken config, but it also means that unless TEST_RESTORE_DB_CMD
# is separately configured to point at a real (non-production) test
# database, the database is never actually imported during a test-restore,
# and a Gitea instance normally backed by an external MySQL/Postgres host
# will very likely fail to come fully healthy in isolation simply because
# it cannot reach that host - this is expected and is treated as
# informational, not a failure. What --test-restore DOES always verify
# unattended: the archive is fetchable and intact, it unpacks to the
# expected internal files, and the repository/data files place correctly
# into a real Gitea container layout without operator intervention. That
# is most of what actually goes wrong in a real restore.
#
# USAGE:
#   gitea-restore.sh --check
#       Dependency check + NAS connectivity check only.
#   gitea-restore.sh --list
#       List archives available on the NAS.
#   gitea-restore.sh --dry-run [--archive NAME|latest] [--local-file PATH]
#       Fetch (or use --local-file) and verify an archive's integrity.
#       Touches nothing else.
#   gitea-restore.sh --test-restore [--archive NAME|latest] [--local-file PATH]
#       Full restore into an isolated throwaway container. Safe to run at
#       any time, including on a schedule - see header note above.
#   gitea-restore.sh --restore --confirm [--archive NAME|latest] [--local-file PATH]
#       Real restore into the production container (GITEA_CONTAINER_NAME).
#       Stops that container, moves its existing repo/data directories
#       aside (renamed, not deleted), replaces them with the archive's
#       contents, then restarts it. --confirm is required and is not a
#       synonym for --dry-run - this is the disruptive, production path.
#
# CONFIG:
#   Reads /opt/gitea-backup/gitea-backup.conf by default (same file as
#   gitea-backup.sh - see that file's "Restore" section). Override with
#   GITEA_BACKUP_CONF=/path/to/file.conf gitea-restore.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${GITEA_BACKUP_CONF:-/opt/gitea-backup/gitea-backup.conf}"
MODE=""
ARCHIVE_NAME=""
LOCAL_FILE=""
CONFIRM=0

usage() {
    cat <<'EOF'
Usage:
  gitea-restore.sh --check
  gitea-restore.sh --list
  gitea-restore.sh --dry-run       [--archive NAME|latest] [--local-file PATH]
  gitea-restore.sh --test-restore  [--archive NAME|latest] [--local-file PATH]
  gitea-restore.sh --restore --confirm [--archive NAME|latest] [--local-file PATH]
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) MODE="check"; shift ;;
        --list) MODE="list"; shift ;;
        --dry-run) MODE="dry-run"; shift ;;
        --test-restore) MODE="test-restore"; shift ;;
        --restore) MODE="restore"; shift ;;
        --archive) ARCHIVE_NAME="${2:-}"; shift 2 ;;
        --local-file) LOCAL_FILE="${2:-}"; shift 2 ;;
        --confirm) CONFIRM=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z "$MODE" ]]; then
    usage >&2
    exit 2
fi
if [[ "$MODE" == "restore" && "$CONFIRM" -ne 1 ]]; then
    echo "ERROR: --restore requires --confirm. This stops the production container and replaces its data. Run --dry-run or --test-restore first." >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [RESTORE][${level}] $*"
    echo "$line"
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "$line" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

FAILED_CONTEXT=""
fail_trap() {
    local lineno="$1"
    log ERROR "gitea-restore.sh failed at line ${lineno}. ${FAILED_CONTEXT}"
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
    if ! command -v mail >/dev/null 2>&1; then
        log WARN "NOTIFY_EMAIL is set but 'mail' command is not installed; skipping email alert (not retrying - it cannot succeed without the command)."
        return 1
    fi
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
    send_mail_raw "Gitea RESTORE FAILED on $(hostname)" "$(printf 'Gitea restore failed.\n\nMode: %s\nDetail: %s\n\nLast log lines:\n%s\n' "$MODE" "$detail" "$tail_log")"
}

# See gitea-backup.sh for why this exists: a bare `exit 1` does NOT trigger
# the ERR trap in bash (only a command that itself fails does), so every
# deliberate failure exit must go through this function or it silently
# never notifies despite logging and exiting non-zero.
die() {
    local msg="$1"
    log ERROR "$msg"
    send_failure_notification "$msg"
    exit 1
}

# ---------------------------------------------------------------------------
# Load config (shared with gitea-backup.sh)
# ---------------------------------------------------------------------------
if [[ ! -f "$CONF_FILE" ]]; then
    die "Config file not found: ${CONF_FILE}"
fi
# shellcheck disable=SC1090
source "$CONF_FILE"

for required_var in GITEA_CONTAINER_NAME GITEA_APP_INI GITEA_REPO_ROOT \
                     STAGING_DIR NAS_SSH_HOST NAS_REMOTE_PATH \
                     TRANSFER_TIMEOUT MAX_TRANSFER_ATTEMPTS MIN_DUMP_SIZE_BYTES; do
    if [[ -z "${!required_var:-}" ]]; then
        die "${required_var} is not set in ${CONF_FILE}"
    fi
done

for numeric_var in TRANSFER_TIMEOUT MAX_TRANSFER_ATTEMPTS MIN_DUMP_SIZE_BYTES; do
    if ! [[ "${!numeric_var}" =~ ^[0-9]+$ ]]; then
        die "${numeric_var}='${!numeric_var}' in ${CONF_FILE} is not a positive integer."
    fi
done

RESTORE_STAGING_DIR="${RESTORE_STAGING_DIR:-${STAGING_DIR}/restore}"
RESTORE_TIMEOUT="${RESTORE_TIMEOUT:-21600}"
# Not previously used by this script (only gitea-backup.sh needed it to
# run "gitea dump" as the right user) - now also needed to fix ownership
# of restored files, so it needs the same fallback default gitea-backup.sh
# uses, in case an older or hand-trimmed conf file predates this variable.
GITEA_CONTAINER_USER="${GITEA_CONTAINER_USER:-git}"
RESTORE_TEST_CONTAINER_PREFIX="${RESTORE_TEST_CONTAINER_PREFIX:-gitea-test-restore}"
RESTORE_TEST_PORT="${RESTORE_TEST_PORT:-3080}"
RESTORE_TEST_DATA_MOUNT="${RESTORE_TEST_DATA_MOUNT:-/data}"
RESTORE_TEST_HEALTH_GRACE_SECONDS="${RESTORE_TEST_HEALTH_GRACE_SECONDS:-60}"
for numeric_var in RESTORE_TIMEOUT RESTORE_TEST_PORT RESTORE_TEST_HEALTH_GRACE_SECONDS; do
    if ! [[ "${!numeric_var}" =~ ^[0-9]+$ ]]; then
        die "${numeric_var}='${!numeric_var}' in ${CONF_FILE} is not a positive integer."
    fi
done

APP_DATA_ROOT="$(dirname "$(dirname "$GITEA_APP_INI")")"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/transport.sh"
transport_validate_config

# ---------------------------------------------------------------------------
# Dependency check (all up front, one pass)
# ---------------------------------------------------------------------------
FAILED_CONTEXT="Dependency check"
declare -A REQUIRED_PKGS=(
    [docker]="docker.io"
    [unzip]="unzip"
    [curl]="curl"
    [flock]="util-linux"
    [timeout]="coreutils"
)
while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    case "$cmd" in
        rsync) REQUIRED_PKGS[rsync]="rsync" ;;
        ssh|sftp) REQUIRED_PKGS[$cmd]="openssh-client" ;;
    esac
done < <(transport_required_cmds)
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
if [[ -n "${NOTIFY_EMAIL:-}" ]] && ! command -v mail >/dev/null 2>&1; then
    log WARN "NOTIFY_EMAIL is set but 'mail' command is not installed (mailutils/bsd-mailx). Alerts will not be sent."
fi

# ---------------------------------------------------------------------------
# Pre-flight: NAS connectivity (not required for a --local-file run, but
# cheap and worth doing before the disruptive modes)
# ---------------------------------------------------------------------------
FAILED_CONTEXT="Pre-flight: NAS connectivity and remote path check (TRANSFER_METHOD=${TRANSFER_METHOD})"
if ! transport_check_read; then
    die "Cannot reach ${NAS_SSH_HOST} over ${TRANSFER_METHOD}, or ${NAS_REMOTE_PATH} does not exist / is not readable."
fi
log INFO "Confirmed ${TRANSFER_METHOD} access to ${NAS_SSH_HOST}:${NAS_REMOTE_PATH}"

FAILED_CONTEXT="Pre-flight: docker reachability"
# Unlike gitea-backup.sh, restore does NOT require GITEA_CONTAINER_NAME to
# already be running - the most common reason to restore is that it isn't.
if ! timeout 10 docker info >/dev/null 2>&1; then
    die "Cannot reach the docker daemon."
fi

FAILED_CONTEXT="Pre-flight: staging directory"
mkdir -p "$RESTORE_STAGING_DIR"

if [[ "$MODE" == "check" ]]; then
    log INFO "Checks passed. --check specified, exiting without further action."
    exit 0
fi

# ---------------------------------------------------------------------------
# List available archives
# ---------------------------------------------------------------------------
list_archives() {
    transport_list | sort
}

if [[ "$MODE" == "list" ]]; then
    listing="$(list_archives)"
    if [[ -z "$listing" ]]; then
        log INFO "No gitea-dump-*.zip archives found on NAS at ${NAS_REMOTE_PATH}."
    else
        echo "$listing"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Exclusive lock (same rationale as gitea-backup.sh: prevents two restores,
# or a restore and a test-restore, racing on the same staging dir/container.
# Held via fd, so it can never go stale.)
# ---------------------------------------------------------------------------
LOCK_FILE="${RESTORE_STAGING_DIR}/.gitea-restore.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log WARN "Another gitea-restore.sh run appears to be in progress (lock: ${LOCK_FILE}). Exiting without action."
    exit 0
fi

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"

# ---------------------------------------------------------------------------
# Resolve and fetch the archive. Nothing disruptive has happened yet -
# nothing below this point touches the production container until the
# archive is confirmed present and has passed integrity verification.
# ---------------------------------------------------------------------------
FAILED_CONTEXT="Resolving archive"
if [[ -n "$LOCAL_FILE" ]]; then
    [[ -f "$LOCAL_FILE" ]] || die "--local-file not found: ${LOCAL_FILE}"
    ARCHIVE_LOCAL_PATH="$LOCAL_FILE"
    ARCHIVE_NAME="$(basename "$LOCAL_FILE")"
    log INFO "Using local archive: ${ARCHIVE_LOCAL_PATH}"
else
    if [[ -z "$ARCHIVE_NAME" || "$ARCHIVE_NAME" == "latest" ]]; then
        listing="$(list_archives)"
        [[ -z "$listing" ]] && die "No gitea-dump-*.zip archives found on NAS at ${NAS_REMOTE_PATH}."
        ARCHIVE_NAME="$(echo "$listing" | tail -n1)"
        log INFO "Resolved 'latest' to: ${ARCHIVE_NAME}"
    fi
    ARCHIVE_LOCAL_PATH="${RESTORE_STAGING_DIR}/${ARCHIVE_NAME}"

    # Each retry re-fetches the whole file from scratch - only rsync-ssh's
    # --partial gives real mid-transfer resume. See gitea-backup.sh's
    # transfer step / README.md "Transport" for why this tradeoff was
    # accepted.
    FAILED_CONTEXT="Fetching archive from NAS"
    fetch_attempt=1
    fetch_ok=0
    while (( fetch_attempt <= MAX_TRANSFER_ATTEMPTS )); do
        if transport_download "$ARCHIVE_NAME" "$ARCHIVE_LOCAL_PATH"; then
            fetch_ok=1
            break
        fi
        log WARN "Fetch attempt ${fetch_attempt}/${MAX_TRANSFER_ATTEMPTS} failed."
        (( fetch_attempt < MAX_TRANSFER_ATTEMPTS )) && sleep $(( fetch_attempt * 10 ))
        (( fetch_attempt++ ))
    done
    (( fetch_ok )) || die "Failed to fetch ${ARCHIVE_NAME} from NAS after ${MAX_TRANSFER_ATTEMPTS} attempts."
    log INFO "Fetched ${ARCHIVE_NAME} to ${ARCHIVE_LOCAL_PATH}"
fi

# ---------------------------------------------------------------------------
# Verify archive integrity before trusting it with anything
# ---------------------------------------------------------------------------
FAILED_CONTEXT="Verifying archive"
if [[ ! -s "$ARCHIVE_LOCAL_PATH" ]]; then
    die "Archive is missing or empty: ${ARCHIVE_LOCAL_PATH}"
fi
archive_size="$(stat -c '%s' "$ARCHIVE_LOCAL_PATH")"
if (( archive_size < MIN_DUMP_SIZE_BYTES )); then
    die "Archive is suspiciously small (${archive_size} bytes, minimum ${MIN_DUMP_SIZE_BYTES}). Not trusting it."
fi
if ! unzip -tq "$ARCHIVE_LOCAL_PATH" >/dev/null; then
    die "Archive failed zip integrity check: ${ARCHIVE_LOCAL_PATH}"
fi
archive_listing="$(unzip -l "$ARCHIVE_LOCAL_PATH")"
for inner in gitea-db.sql data/; do
    if ! grep -q "$inner" <<< "$archive_listing"; then
        die "Archive ${ARCHIVE_NAME} does not contain expected ${inner}. This does not look like a gitea dump archive."
    fi
done
if ! grep -q "repos/" <<< "$archive_listing"; then
    log WARN "Archive does not contain a repos/ directory (expected for an instance with zero repositories; otherwise this is unexpected)."
fi
if ! grep -q "app.ini" <<< "$archive_listing"; then
    log WARN "Archive does not contain a standalone app.ini. GITEA_APP_INI's config file will only be restored if data/ already contains one at that path - if the restored instance shows Gitea's install wizard instead of starting normally, check for a missing or incomplete config file first."
fi
log INFO "Archive verified: ${ARCHIVE_LOCAL_PATH} (${archive_size} bytes)."

if [[ "$MODE" == "dry-run" ]]; then
    log INFO "--dry-run specified. Archive fetched and verified; no container was touched."
    exit 0
fi

# ---------------------------------------------------------------------------
# Extract on the host (not inside the container - the official Gitea image
# is not guaranteed to ship unzip, and unzip is already a confirmed
# dependency here).
# ---------------------------------------------------------------------------
FAILED_CONTEXT="Extracting archive"
EXTRACT_DIR="${RESTORE_STAGING_DIR}/work-${TIMESTAMP}"
mkdir -p "$EXTRACT_DIR"
if ! timeout "$RESTORE_TIMEOUT" unzip -q "$ARCHIVE_LOCAL_PATH" -d "$EXTRACT_DIR"; then
    die "Failed to extract ${ARCHIVE_LOCAL_PATH} to ${EXTRACT_DIR}."
fi
# This dump format stores repos/ and data/ as plain directory trees
# directly in the archive (not nested zips inside it, as an earlier
# version of this script assumed) - the outer unzip above already fully
# extracted them, so just rename them to the internal names the rest of
# this script uses. See README.md's "Restore" section.
if [[ -d "${EXTRACT_DIR}/repos" ]]; then
    mv "${EXTRACT_DIR}/repos" "${EXTRACT_DIR}/repo-root"
else
    mkdir -p "${EXTRACT_DIR}/repo-root"
fi
[[ -d "${EXTRACT_DIR}/data" ]] || die "Archive ${ARCHIVE_NAME} does not contain the expected data/ directory."
mv "${EXTRACT_DIR}/data" "${EXTRACT_DIR}/app-data-root"

# gitea dump also writes a standalone top-level app.ini, separate from
# data/. Confirmed against a real archive: when CustomPath and
# AppDataPath are configured the same (as here), data/ already contains
# its own complete, already-installed conf/app.ini (with
# INSTALL_LOCK = true) at the exact path GITEA_APP_INI expects - and the
# standalone top-level copy is NOT necessarily the same file (do not
# assume it is safe to overwrite with). Use it only as a fallback for a
# deployment where data/ genuinely lacks one; never clobber an existing
# nested config with it.
if [[ -f "${EXTRACT_DIR}/app.ini" ]]; then
    app_ini_rel="${GITEA_APP_INI#"${APP_DATA_ROOT}"/}"
    if [[ ! -f "${EXTRACT_DIR}/app-data-root/${app_ini_rel}" ]]; then
        mkdir -p "${EXTRACT_DIR}/app-data-root/$(dirname "$app_ini_rel")"
        cp "${EXTRACT_DIR}/app.ini" "${EXTRACT_DIR}/app-data-root/${app_ini_rel}"
        log INFO "Restored app.ini from the archive's standalone copy (data/ did not already contain one at ${app_ini_rel})."
    fi
fi
log INFO "Archive extracted to ${EXTRACT_DIR}."

# ---------------------------------------------------------------------------
# Health check: one authoritative signal (still running after a grace
# period - proves the restored data did not crash Gitea outright), the
# rest informational only, per the tiered health check pattern.
# ---------------------------------------------------------------------------
health_check() {
    local target="$1" http_port="${2:-}"
    log INFO "Waiting up to ${RESTORE_TEST_HEALTH_GRACE_SECONDS}s for ${target} to come up..."
    local waited=0
    while (( waited < RESTORE_TEST_HEALTH_GRACE_SECONDS )); do
        sleep 5
        waited=$(( waited + 5 ))
        local state
        state="$(timeout 15 docker inspect -f '{{.State.Running}}' "$target" 2>/dev/null || echo false)"
        if [[ "$state" != "true" ]]; then
            die "${target} is not running after restore (crashed or exited). Check: docker logs ${target}"
        fi
    done
    log INFO "${target} is still running ${RESTORE_TEST_HEALTH_GRACE_SECONDS}s after restart (authoritative health signal)."
    if [[ -n "$http_port" ]]; then
        if timeout 10 curl -fsS "http://127.0.0.1:${http_port}/api/healthz" >/dev/null 2>&1; then
            log INFO "HTTP health endpoint responded (informational)."
        else
            log WARN "HTTP health endpoint did not respond within 10s (informational only - expected for an isolated test-restore container that cannot reach an external DB it is normally configured to use; not treated as a failure)."
        fi
    fi
}

# ---------------------------------------------------------------------------
# Core restore: stop -> move existing data aside (never deleted) -> copy in
# restored data -> DB restore hook (if configured) -> start -> health check.
# Moving-aside is done via a short-lived helper container that shares the
# target's volumes via --volumes-from, because "docker exec" (needed to
# run mv) requires a RUNNING container, and the target is deliberately
# stopped before its data is touched.
# ---------------------------------------------------------------------------
restore_pipeline() {
    local target="$1" db_hook="$2" http_port="${3:-}"

    local image
    image="$(timeout 15 docker inspect -f '{{.Config.Image}}' "$target" 2>/dev/null || echo "")"
    [[ -z "$image" ]] && die "Could not determine the image in use by container '${target}'."

    FAILED_CONTEXT="Stopping ${target} before restore"
    log INFO "Stopping ${target}..."
    timeout "$RESTORE_TIMEOUT" docker stop "$target" >/dev/null || die "Failed to stop container '${target}'."

    FAILED_CONTEXT="Moving aside existing data in ${target}"
    local suffix="pre-restore-${TIMESTAMP}"
    if ! timeout "$RESTORE_TIMEOUT" docker run --rm --volumes-from "$target" "$image" sh -c "
        set -e
        [ -d '${GITEA_REPO_ROOT}' ] && mv '${GITEA_REPO_ROOT}' '${GITEA_REPO_ROOT}.${suffix}'
        [ -d '${APP_DATA_ROOT}' ] && mv '${APP_DATA_ROOT}' '${APP_DATA_ROOT}.${suffix}'
        mkdir -p '${GITEA_REPO_ROOT}' '${APP_DATA_ROOT}'
    "; then
        die "Failed to move aside existing data in ${target}. Container is stopped, not yet started - safe to investigate before retrying. Nothing has been overwritten."
    fi
    log INFO "Existing data in ${target} preserved as *.${suffix} (not deleted)."

    FAILED_CONTEXT="Copying restored data into ${target}"
    if [[ -d "${EXTRACT_DIR}/repo-root" ]] && [[ -n "$(ls -A "${EXTRACT_DIR}/repo-root" 2>/dev/null)" ]]; then
        timeout "$RESTORE_TIMEOUT" docker cp "${EXTRACT_DIR}/repo-root/." "${target}:${GITEA_REPO_ROOT}/" \
            || die "Failed to copy restored repositories into ${target}. It is stopped with the pre-restore data preserved as *.${suffix} - safe to investigate."
    fi
    timeout "$RESTORE_TIMEOUT" docker cp "${EXTRACT_DIR}/app-data-root/." "${target}:${APP_DATA_ROOT}/" \
        || die "Failed to copy restored app data into ${target}. It is stopped with the pre-restore data preserved as *.${suffix} - safe to investigate."
    log INFO "Restored repository and app data copied into ${target}."

    # "docker cp" preserves the copying process's own uid/gid on the files
    # it writes (root, since this script runs via sudo) - not whatever
    # user Gitea actually runs as inside the container. If that user can't
    # read/write its own just-restored data, it can fail to start
    # entirely, which would otherwise look like an unrelated crash. Fix
    # ownership back to match before starting the container.
    FAILED_CONTEXT="Fixing ownership of restored data in ${target}"
    local restore_uid restore_gid
    restore_uid="$(timeout 15 docker exec "$target" id -u "$GITEA_CONTAINER_USER" 2>/dev/null)"
    restore_gid="$(timeout 15 docker exec "$target" id -g "$GITEA_CONTAINER_USER" 2>/dev/null)"
    if [[ -n "$restore_uid" && -n "$restore_gid" ]]; then
        timeout "$RESTORE_TIMEOUT" docker exec -u root "$target" chown -R "${restore_uid}:${restore_gid}" "$GITEA_REPO_ROOT" "$APP_DATA_ROOT" \
            || die "Failed to fix ownership of restored data in ${target}. Container is stopped with restored files in place, owned by root instead of ${GITEA_CONTAINER_USER} - safe to investigate, or fix manually: docker exec -u root ${target} chown -R ${GITEA_CONTAINER_USER}:${GITEA_CONTAINER_USER} ${GITEA_REPO_ROOT} ${APP_DATA_ROOT}"
        log INFO "Restored data ownership set to ${GITEA_CONTAINER_USER} (uid=${restore_uid}, gid=${restore_gid}) in ${target}."
    else
        log WARN "Could not resolve uid/gid for ${GITEA_CONTAINER_USER} inside ${target}; skipping ownership fix. Restored files are likely owned by root instead of ${GITEA_CONTAINER_USER}, which can prevent Gitea from starting - fix manually if needed: docker exec -u root ${target} chown -R ${GITEA_CONTAINER_USER}:${GITEA_CONTAINER_USER} ${GITEA_REPO_ROOT} ${APP_DATA_ROOT}"
    fi

    if [[ -n "$db_hook" ]]; then
        FAILED_CONTEXT="Restoring database via configured hook"
        if ! RESTORE_SQL_HOST_PATH="${EXTRACT_DIR}/gitea-db.sql" bash -c "$db_hook"; then
            die "Configured DB restore command failed. Container is stopped with restored files in place; the SQL dump is still at ${EXTRACT_DIR}/gitea-db.sql for manual restoration."
        fi
        log INFO "Database restore hook completed."
    else
        log WARN "No DB restore hook configured. Database was NOT restored. Extracted dump SQL is at: ${EXTRACT_DIR}/gitea-db.sql - restore it manually with your DB engine's client before this instance will serve correct data."
    fi

    FAILED_CONTEXT="Starting ${target} after restore"
    timeout "$RESTORE_TIMEOUT" docker start "$target" >/dev/null \
        || die "Failed to start container '${target}' after restore. It is currently stopped with restored files in place - investigate before retrying."

    health_check "$target" "$http_port"
}

if [[ "$MODE" == "restore" ]]; then
    log INFO "Starting REAL restore of ${ARCHIVE_NAME} into production container ${GITEA_CONTAINER_NAME}."
    restore_pipeline "$GITEA_CONTAINER_NAME" "${DB_RESTORE_CMD:-}" ""
    rm -rf "$EXTRACT_DIR"
    log INFO "Restore complete. Manually verify: web UI reachable, SSO login works, a known repo clones, and the CI runner can still authenticate - see README.md."
    send_mail_raw "Gitea restore completed on $(hostname)" "$(printf 'Restored %s into %s.\n\nManual verification still needed: web UI, SSO login, a test clone, and CI runner auth.\n' "$ARCHIVE_NAME" "$GITEA_CONTAINER_NAME")"
    exit 0
fi

if [[ "$MODE" == "test-restore" ]]; then
    TEST_NAME="${RESTORE_TEST_CONTAINER_PREFIX}-${TIMESTAMP}"
    TEST_VOLUME="${TEST_NAME}-data"

    teardown_test() {
        local exit_code=$?
        # On failure, the container's own log is the most useful diagnostic
        # there is - and it's about to be deleted below, so capture it here
        # or it's gone. $? above is the script's exit status at the moment
        # this EXIT trap fired, not this function's own (unset) status yet.
        if (( exit_code != 0 )); then
            log WARN "Test-restore failed - ${TEST_NAME}'s container log (last 50 lines) before teardown:"
            timeout 15 docker logs --tail 50 "$TEST_NAME" 2>&1 | sed 's/^/  /' || true
        fi
        log INFO "Tearing down test-restore container and volume..."
        timeout 15 docker rm -f "$TEST_NAME" >/dev/null 2>&1 || true
        timeout 15 docker volume rm "$TEST_VOLUME" >/dev/null 2>&1 || true
        rm -rf "$EXTRACT_DIR"
    }
    trap teardown_test EXIT

    FAILED_CONTEXT="Resolving image for test-restore"
    PROD_IMAGE="$(timeout 15 docker inspect -f '{{.Config.Image}}' "$GITEA_CONTAINER_NAME" 2>/dev/null || echo "")"
    TEST_IMAGE="${RESTORE_TEST_IMAGE:-$PROD_IMAGE}"
    [[ -z "$TEST_IMAGE" ]] && die "Could not resolve an image for the test-restore container. Set RESTORE_TEST_IMAGE explicitly, or ensure ${GITEA_CONTAINER_NAME} exists so its image can be reused."

    FAILED_CONTEXT="Creating isolated test-restore container"
    log INFO "Creating isolated test-restore container ${TEST_NAME} from ${TEST_IMAGE} (own volume, own network - never production's)."
    timeout 15 docker volume create "$TEST_VOLUME" >/dev/null
    timeout 30 docker run -d --name "$TEST_NAME" \
        -v "${TEST_VOLUME}:${RESTORE_TEST_DATA_MOUNT}" \
        -p "${RESTORE_TEST_PORT}:3000" \
        "$TEST_IMAGE" >/dev/null \
        || die "Failed to start the isolated test-restore container from ${TEST_IMAGE}."

    # Let it boot once on a clean volume so Gitea creates its default
    # directory structure at GITEA_REPO_ROOT/APP_DATA_ROOT before those
    # paths are overwritten below.
    sleep 15
    timeout "$RESTORE_TIMEOUT" docker stop "$TEST_NAME" >/dev/null \
        || die "Test-restore container ${TEST_NAME} did not stop cleanly after its initial boot."

    restore_pipeline "$TEST_NAME" "${TEST_RESTORE_DB_CMD:-}" "$RESTORE_TEST_PORT"

    log INFO "Test-restore of ${ARCHIVE_NAME} PASSED mechanical checks (fetch, integrity, extraction, file placement, container health)."
    send_mail_raw "Gitea test-restore PASSED on $(hostname)" "$(printf 'Test-restore of %s completed and the container stayed healthy.\n\nDB restore hook configured: %s\n(If not configured, this run did not validate the database import step - see script header.)\n' "$ARCHIVE_NAME" "$( [[ -n "${TEST_RESTORE_DB_CMD:-}" ]] && echo yes || echo no )")"
    exit 0
fi
