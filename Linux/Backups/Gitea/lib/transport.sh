#!/usr/bin/env bash
#
# transport.sh
# 2026-08-09
# Version: v1.0.2
#
# PURPOSE:
# NAS transport backend for gitea-backup.sh / gitea-restore.sh, selected by
# TRANSFER_METHOD in gitea-backup.conf ("sftp", "rsync-ssh", or
# "rsync-daemon"). Sourced, not executed. Requires log()/die() and the
# fully-loaded config to already be in scope. Exposes one transport-
# agnostic interface so the two scripts never need their own per-method
# branches - they just call these functions and TRANSFER_METHOD decides
# what actually runs underneath.
#
# INTERFACE (all return 0 on success, non-zero on failure):
#   transport_validate_config         - checks the vars this method needs
#                                        are present/valid; call once,
#                                        right after sourcing the config.
#   transport_required_cmds           - echoes the external commands this
#                                        method needs, one per line, for
#                                        the caller's dependency check.
#   transport_check_write             - connectivity + write access
#                                        (backup pre-flight).
#   transport_check_read              - connectivity + read access
#                                        (restore pre-flight).
#   transport_upload LOCAL NAME       - upload LOCAL as NAME.
#   transport_download NAME LOCAL     - download NAME to LOCAL.
#   transport_list                    - echoes gitea-dump-*.zip filenames
#                                        present remotely, one per line,
#                                        oldest-name-first is NOT
#                                        guaranteed - callers that need
#                                        sorted output pipe through `sort`.
#                                        Never fails just because zero
#                                        files exist - empty output means
#                                        empty, not an error.
#   transport_delete FILE...          - best-effort delete of one or more
#                                        named files. Never treated as a
#                                        hard failure by callers - see
#                                        cleanup_nas_retention in
#                                        gitea-backup.sh for why.
#
# Adding a fourth method later means adding transport_<name>_* functions
# below (name normalized the same way TRANSFER_METHOD_FN is: hyphens to
# underscores) plus one case arm each in transport_validate_config and
# transport_required_cmds - the two calling scripts do not change.

TRANSFER_METHOD="${TRANSFER_METHOD:-sftp}"
# Normalized for use in function names (bash identifiers can't contain
# "-"). Every transport_<method>_* function below is named using this same
# normalization - e.g. TRANSFER_METHOD="rsync-ssh" dispatches to
# transport_rsync_ssh_check_write, not transport_rsyncssh_check_write.
TRANSFER_METHOD_FN="${TRANSFER_METHOD//-/_}"

transport_validate_config() {
    case "$TRANSFER_METHOD" in
        sftp|rsync-ssh)
            local v
            for v in NAS_SSH_PORT NAS_SSH_USER NAS_SSH_KEY NAS_KNOWN_HOSTS; do
                [[ -n "${!v:-}" ]] || die "${v} is required when TRANSFER_METHOD=${TRANSFER_METHOD} (in ${CONF_FILE})."
            done
            [[ "$NAS_SSH_PORT" =~ ^[0-9]+$ ]] || die "NAS_SSH_PORT='${NAS_SSH_PORT}' in ${CONF_FILE} is not a positive integer."
            [[ -f "$NAS_SSH_KEY" ]] || die "SSH key not found: ${NAS_SSH_KEY}"
            local key_perm
            key_perm="$(stat -c '%a' "$NAS_SSH_KEY")"
            if [[ "$key_perm" != "600" && "$key_perm" != "400" ]]; then
                die "SSH key ${NAS_SSH_KEY} has permissions ${key_perm}, expected 600 or 400. Refusing to use it: 'chmod 600 ${NAS_SSH_KEY}'."
            fi
            [[ -f "$NAS_KNOWN_HOSTS" ]] || die "known_hosts file not found: ${NAS_KNOWN_HOSTS}. Pre-seed it with: ssh-keyscan -p ${NAS_SSH_PORT} ${NAS_SSH_HOST} > ${NAS_KNOWN_HOSTS}"
            ;;
        rsync-daemon)
            local v
            for v in RSYNC_DAEMON_USER RSYNC_DAEMON_PASSWORD_FILE RSYNC_DAEMON_MODULE; do
                [[ -n "${!v:-}" ]] || die "${v} is required when TRANSFER_METHOD=rsync-daemon (in ${CONF_FILE})."
            done
            RSYNC_DAEMON_PORT="${RSYNC_DAEMON_PORT:-873}"
            [[ "$RSYNC_DAEMON_PORT" =~ ^[0-9]+$ ]] || die "RSYNC_DAEMON_PORT='${RSYNC_DAEMON_PORT}' in ${CONF_FILE} is not a positive integer."
            [[ -f "$RSYNC_DAEMON_PASSWORD_FILE" ]] || die "RSYNC_DAEMON_PASSWORD_FILE not found: ${RSYNC_DAEMON_PASSWORD_FILE}"
            local pw_perm
            pw_perm="$(stat -c '%a' "$RSYNC_DAEMON_PASSWORD_FILE")"
            if [[ "$pw_perm" != "600" && "$pw_perm" != "400" ]]; then
                die "RSYNC_DAEMON_PASSWORD_FILE ${RSYNC_DAEMON_PASSWORD_FILE} has permissions ${pw_perm}, expected 600 or 400. Refusing to use it: 'chmod 600 ${RSYNC_DAEMON_PASSWORD_FILE}'."
            fi
            # NAS_REMOTE_PATH means something different here than for
            # sftp/rsync-ssh: a path INSIDE RSYNC_DAEMON_MODULE, not an
            # absolute filesystem path. A leading "/" (left over from
            # switching TRANSFER_METHOD from sftp/rsync-ssh without
            # updating this value) would silently produce a doubled slash
            # in the constructed rsync:// URL - catch it here with a clear
            # error instead of sending a malformed URL and hoping rsync's
            # own path normalization papers over it.
            if [[ "${NAS_REMOTE_PATH:-}" == /* ]]; then
                die "NAS_REMOTE_PATH ('${NAS_REMOTE_PATH}') must not start with '/' when TRANSFER_METHOD=rsync-daemon - it is a path inside RSYNC_DAEMON_MODULE, not an absolute filesystem path. Remove the leading '/', or leave NAS_REMOTE_PATH blank to use the module's root."
            fi
            ;;
        *)
            die "Unsupported TRANSFER_METHOD '${TRANSFER_METHOD}' in ${CONF_FILE}. Supported: sftp, rsync-ssh, rsync-daemon."
            ;;
    esac
}

transport_required_cmds() {
    case "$TRANSFER_METHOD" in
        sftp) printf 'sftp\nssh\n' ;;
        rsync-ssh) printf 'rsync\nssh\n' ;;
        rsync-daemon) printf 'rsync\n' ;;
    esac
}

# Dispatchers - thin wrappers that call the active method's implementation.
transport_check_write()   { "transport_${TRANSFER_METHOD_FN}_check_write"; }
transport_check_read()    { "transport_${TRANSFER_METHOD_FN}_check_read"; }
transport_upload()        { "transport_${TRANSFER_METHOD_FN}_upload" "$1" "$2"; }
transport_download()      { "transport_${TRANSFER_METHOD_FN}_download" "$1" "$2"; }
transport_list()          { "transport_${TRANSFER_METHOD_FN}_list"; }
transport_delete()        { "transport_${TRANSFER_METHOD_FN}_delete" "$@"; }

# =============================================================================
# sftp
# =============================================================================
# Reuses the SSH connection details (NAS_SSH_HOST/PORT/USER/KEY/KNOWN_HOSTS)
# but needs no remote command execution capability at all - works on
# accounts restricted to SFTP-only access (see README.md "Transport").

transport_sftp_opts() {
    SFTP_OPTS=(-i "$NAS_SSH_KEY" -P "$NAS_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$NAS_KNOWN_HOSTS")
}

# sftp aborts a batch on the first failing command (get/put/rm/ls/cd/...)
# unless that line is prefixed with "-" - see sftp(1) "BATCH FILES".
transport_sftp_batch() {
    timeout "$TRANSFER_TIMEOUT" sftp -b - "${SFTP_OPTS[@]}" "${NAS_SSH_USER}@${NAS_SSH_HOST}"
}

transport_sftp_check_write() {
    transport_sftp_opts
    local probe
    probe="$(mktemp)"
    : > "$probe"
    if transport_sftp_batch <<SFTPEOF >/dev/null 2>&1
cd "${NAS_REMOTE_PATH}"
put "${probe}" .gitea-backup-write-test
rm .gitea-backup-write-test
SFTPEOF
    then
        rm -f "$probe"
        return 0
    fi
    rm -f "$probe"
    return 1
}

transport_sftp_check_read() {
    transport_sftp_opts
    transport_sftp_batch <<SFTPEOF >/dev/null 2>&1
cd "${NAS_REMOTE_PATH}"
ls
SFTPEOF
}

transport_sftp_upload() {
    local local_file="$1" remote_name="$2"
    transport_sftp_opts
    transport_sftp_batch <<SFTPEOF
cd "${NAS_REMOTE_PATH}"
put "${local_file}" "${remote_name}"
SFTPEOF
}

transport_sftp_download() {
    local remote_name="$1" local_file="$2"
    transport_sftp_opts
    transport_sftp_batch <<SFTPEOF
cd "${NAS_REMOTE_PATH}"
get "${remote_name}" "${local_file}"
SFTPEOF
}

transport_sftp_list() {
    transport_sftp_opts
    transport_sftp_batch <<SFTPEOF 2>/dev/null | grep -E '^gitea-dump-[0-9]{8}-[0-9]{6}\.zip$' || true
cd "${NAS_REMOTE_PATH}"
ls -1 gitea-dump-*.zip
SFTPEOF
}

transport_sftp_delete() {
    transport_sftp_opts
    local f
    {
        printf 'cd "%s"\n' "$NAS_REMOTE_PATH"
        for f in "$@"; do
            printf -- '-rm "%s"\n' "$f"
        done
    } | timeout "$TRANSFER_TIMEOUT" sftp -b - "${SFTP_OPTS[@]}" "${NAS_SSH_USER}@${NAS_SSH_HOST}" 2>&1
    return 0
}

# =============================================================================
# rsync-ssh
# =============================================================================
# Full rsync-over-SSH. Needs an account with real interactive/command-
# execution SSH access, unlike sftp above - see README.md "Transport" for
# when this is (and is not) available.

transport_rsync_ssh_ssh_opts() {
    # rsync's -e re-splits this string on whitespace itself (does not pass
    # through a shell), so it must never contain a path with spaces.
    SSH_OPTS="-i ${NAS_SSH_KEY} -p ${NAS_SSH_PORT} -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${NAS_KNOWN_HOSTS}"
}

transport_rsync_ssh_extra_args() {
    # Some NAS platforms (Synology DSM confirmed) don't put rsync on the
    # PATH an SSH session gets, so rsync-over-SSH authenticates fine but
    # fails with "Permission denied" on the actual transfer unless the
    # remote binary's full path is given explicitly via --rsync-path.
    RSYNC_EXTRA_ARGS=()
    [[ -n "${RSYNC_REMOTE_BIN:-}" ]] && RSYNC_EXTRA_ARGS+=(--rsync-path="$RSYNC_REMOTE_BIN")
}

transport_rsync_ssh_check_write() {
    transport_rsync_ssh_ssh_opts
    # shellcheck disable=SC2086
    timeout 20 ssh $SSH_OPTS "${NAS_SSH_USER}@${NAS_SSH_HOST}" \
        "test -d '${NAS_REMOTE_PATH}' && test -w '${NAS_REMOTE_PATH}'"
}

transport_rsync_ssh_check_read() {
    transport_rsync_ssh_ssh_opts
    # shellcheck disable=SC2086
    timeout 20 ssh $SSH_OPTS "${NAS_SSH_USER}@${NAS_SSH_HOST}" \
        "test -d '${NAS_REMOTE_PATH}' && test -r '${NAS_REMOTE_PATH}'"
}

transport_rsync_ssh_upload() {
    local local_file="$1" remote_name="$2"
    transport_rsync_ssh_ssh_opts
    transport_rsync_ssh_extra_args
    # --protect-args stops rsync from handing the destination path to the
    # remote shell for interpretation - required since NAS_REMOTE_PATH
    # commonly contains characters like $ or ! (e.g. a path under a share
    # named admin$) that a remote shell could otherwise try to interpret.
    # shellcheck disable=SC2086
    rsync -az --protect-args --partial --timeout="$TRANSFER_TIMEOUT" "${RSYNC_EXTRA_ARGS[@]}" -e "ssh $SSH_OPTS" \
        "$local_file" "${NAS_SSH_USER}@${NAS_SSH_HOST}:${NAS_REMOTE_PATH}/${remote_name}"
}

transport_rsync_ssh_download() {
    local remote_name="$1" local_file="$2"
    transport_rsync_ssh_ssh_opts
    transport_rsync_ssh_extra_args
    # shellcheck disable=SC2086
    rsync -az --protect-args --partial --timeout="$TRANSFER_TIMEOUT" "${RSYNC_EXTRA_ARGS[@]}" -e "ssh $SSH_OPTS" \
        "${NAS_SSH_USER}@${NAS_SSH_HOST}:${NAS_REMOTE_PATH}/${remote_name}" "$local_file"
}

transport_rsync_ssh_list() {
    transport_rsync_ssh_ssh_opts
    # shellcheck disable=SC2086
    timeout 20 ssh $SSH_OPTS "${NAS_SSH_USER}@${NAS_SSH_HOST}" \
        "cd '${NAS_REMOTE_PATH}' && ls -1 gitea-dump-*.zip 2>/dev/null" || true
}

transport_rsync_ssh_delete() {
    transport_rsync_ssh_ssh_opts
    local f quoted_files=""
    for f in "$@"; do
        quoted_files+=" '${NAS_REMOTE_PATH}/${f}'"
    done
    # shellcheck disable=SC2086
    timeout 20 ssh $SSH_OPTS "${NAS_SSH_USER}@${NAS_SSH_HOST}" "rm -f${quoted_files}" 2>&1
    return 0
}

# =============================================================================
# rsync-daemon
# =============================================================================
# The NAS's native rsync service (default port 873), authenticated with a
# daemon-specific username/password rather than an SSH key or account -
# no SSH involved at all. Deliberately not the default: this protocol
# transmits file data unencrypted unless separately tunneled (the
# authentication handshake itself is not sent in plaintext, but the
# transferred archive is). Only use this where that is an accepted
# tradeoff (e.g. staying entirely on a trusted internal network) - see
# README.md "Transport".

transport_rsync_daemon_target_path() {
    if [[ -n "${NAS_REMOTE_PATH:-}" ]]; then
        printf '%s/%s' "$RSYNC_DAEMON_MODULE" "$NAS_REMOTE_PATH"
    else
        printf '%s' "$RSYNC_DAEMON_MODULE"
    fi
}

# Always ends in exactly one trailing slash (whether or not a filename is
# given) - callers should NOT append another "/" themselves.
transport_rsync_daemon_url() {
    printf 'rsync://%s@%s:%s/%s/%s' \
        "$RSYNC_DAEMON_USER" "$NAS_SSH_HOST" "$RSYNC_DAEMON_PORT" \
        "$(transport_rsync_daemon_target_path)" "${1:-}"
}

transport_rsync_daemon_check_write() {
    local probe
    probe="$(mktemp)"
    : > "$probe"
    if transport_rsync_daemon_upload "$probe" ".gitea-backup-write-test"; then
        transport_rsync_daemon_delete ".gitea-backup-write-test" >/dev/null 2>&1 || true
        rm -f "$probe"
        return 0
    fi
    rm -f "$probe"
    return 1
}

transport_rsync_daemon_check_read() {
    timeout "$TRANSFER_TIMEOUT" rsync --list-only --contimeout=10 --password-file="$RSYNC_DAEMON_PASSWORD_FILE" --port="$RSYNC_DAEMON_PORT" \
        "$(transport_rsync_daemon_url)" >/dev/null 2>&1
}

transport_rsync_daemon_upload() {
    local local_file="$1" remote_name="$2"
    timeout "$TRANSFER_TIMEOUT" rsync -az --partial --timeout="$TRANSFER_TIMEOUT" --contimeout=10 --password-file="$RSYNC_DAEMON_PASSWORD_FILE" --port="$RSYNC_DAEMON_PORT" \
        "$local_file" "$(transport_rsync_daemon_url "$remote_name")"
}

transport_rsync_daemon_download() {
    local remote_name="$1" local_file="$2"
    timeout "$TRANSFER_TIMEOUT" rsync -az --partial --timeout="$TRANSFER_TIMEOUT" --contimeout=10 --password-file="$RSYNC_DAEMON_PASSWORD_FILE" --port="$RSYNC_DAEMON_PORT" \
        "$(transport_rsync_daemon_url "$remote_name")" "$local_file"
}

transport_rsync_daemon_list() {
    # --list-only prints one line per remote entry in "ls -l"-ish form
    # (permissions, size, date, time, name); our filenames never contain
    # spaces (we generate them), so the last field is reliably the name.
    timeout "$TRANSFER_TIMEOUT" rsync --list-only --contimeout=10 --password-file="$RSYNC_DAEMON_PASSWORD_FILE" --port="$RSYNC_DAEMON_PORT" \
        "$(transport_rsync_daemon_url)" 2>/dev/null \
        | awk '{print $NF}' | grep -E '^gitea-dump-[0-9]{8}-[0-9]{6}\.zip$' || true
}

transport_rsync_daemon_delete() {
    # The rsync daemon protocol has no native "delete this one file"
    # command. The standard trick: sync an empty local directory with
    # --delete plus one --include per target filename and a trailing
    # --exclude='*' - the include marks each named file as "in scope" for
    # deletion consideration, the exclude leaves everything else alone,
    # and --delete removes anything in scope that isn't in the (empty)
    # source.
    local f empty_dir rc
    empty_dir="$(mktemp -d)"
    local -a include_args=()
    for f in "$@"; do
        include_args+=(--include="$f")
    done
    timeout "$TRANSFER_TIMEOUT" rsync -a --delete --contimeout=10 "${include_args[@]}" --exclude='*' --password-file="$RSYNC_DAEMON_PASSWORD_FILE" --port="$RSYNC_DAEMON_PORT" \
        "${empty_dir}/" "$(transport_rsync_daemon_url)" 2>&1
    rc=$?
    rmdir "$empty_dir" 2>/dev/null || true
    return $rc
}
