#!/usr/bin/env bash
#
# server-maintenance.sh
# 2026-10-18
# Version: v1.0.0
#
# PURPOSE:
# Scheduled maintenance for Linux servers, on premises or in the cloud: OS
# package updates, container image updates with a soak period, approval,
# health checks and rollback, and a controlled reboot followed by a
# post-boot verification. Deployed to /opt/server-maintenance by install.sh
# and run from systemd timers; also the command an admin uses by hand
# (symlinked as /usr/local/sbin/server-maintenance).
#
# CHANGELOG:
#   v1.0.0 - Initial release.
#
# Usage: server-maintenance <command> [options]   (see usage() below)
#
# Exit codes: 0 success (or another run holds the lock), 1 failure,
# 2 invalid command line.

# shellcheck source-path=SCRIPTDIR/..
set -Eeuo pipefail
umask 027
export LC_ALL=C
# Keep apt, debconf and needrestart from waiting on a prompt nobody answers.
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

SM_VERSION="v1.0.0"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
LIB_DIR="$(cd "$(dirname "$SCRIPT_PATH")/../lib" && pwd)"

# Paths can be overridden for testing only; the installed units never do.
CONFIG_FILE="${SM_CONFIG_FILE:-/etc/server-maintenance/config.conf}"
STATE_DIR="${SM_STATE_DIR:-/var/lib/server-maintenance}"
LOG_DIR="${SM_LOG_DIR:-/var/log/server-maintenance}"
LOCK_FILE="${SM_LOCK_FILE:-/run/lock/server-maintenance.lock}"
STATUS_FILE="$STATE_DIR/status.env"
REBOOT_MARKER="$STATE_DIR/reboot-pending"
HOST="$(hostname -f 2>/dev/null || hostname)"

# shellcheck source=lib/common.sh
. "$LIB_DIR/common.sh"
# shellcheck source=lib/distro.sh
. "$LIB_DIR/distro.sh"
# shellcheck source=lib/notify.sh
. "$LIB_DIR/notify.sh"
# shellcheck source=lib/config.sh
. "$LIB_DIR/config.sh"
# shellcheck source=lib/os.sh
. "$LIB_DIR/os.sh"
# shellcheck source=lib/containers.sh
. "$LIB_DIR/containers.sh"

JOB="startup"
HB_URL=""
RUN_LOG=""
FATAL_SENT=0
WORK_DIR=""

usage() {
    cat <<EOF
server-maintenance $SM_VERSION

Usage: server-maintenance <command> [options]

Scheduled (systemd timers):
  check                     Read-only: pending OS updates, reboot state, disk,
                            failed units, container image releases. Alerts
                            only when something needs attention.
  run [options]             Maintenance window: OS updates, approved/eligible
                            image updates, then a reboot if one is required.
      --no-reboot           Never reboot in this run.
      --skip-os             Skip OS package updates.
      --skip-containers     Skip container image updates.
  post-boot                 Runs at boot; verifies a reboot this tool started.

Manual:
  os-update [--no-reboot]   Same as: run --skip-containers
  containers status         Pinned, newest, eligible and approved tags.
  containers approve <image> <tag>
                            Allow 'run' to apply <tag> once it is past the
                            soak period.
  containers revoke <image> Remove an approval.
  containers apply [--now <image> [tag]]
                            Apply now. --now skips the soak period and the
                            approval (for a security advisory) but keeps the
                            health check and rollback.
  status [--oneline]        Last results from the status file (no network).
  validate                  Check the config, compose files and releases.
  test-alert [--heartbeat]  Send a test alert email (and test heartbeats).
  version                   Print the version.
EOF
}

# ---------------------------------------------------------------------------
# Failure handling
# ---------------------------------------------------------------------------

on_fatal() {
    local msg="$1"
    (( FATAL_SENT )) && return 0
    # die() inside a subshell must not alert; the parent reports the outcome.
    [[ "$BASHPID" == "$$" ]] || return 0
    FATAL_SENT=1
    [[ "$JOB" == "startup" || "$JOB" == "manual" ]] && return 0
    local tail_txt=""
    [[ -n "$RUN_LOG" && -f "$RUN_LOG" ]] && tail_txt="$(tail -n 40 "$RUN_LOG" 2>/dev/null)"
    alert "[server-maintenance] FAILED on $HOST: $JOB" "The $JOB job on $HOST stopped with an error:

$msg

Log: ${RUN_LOG:-none}

--- Log tail ---
$tail_txt"
    heartbeat "$HB_URL" down "$JOB failed: $msg"
    local key="${JOB//-/_}"
    status_update "LAST_${key^^}_RESULT" "failed" "LAST_${key^^}_AT" "$(now_stamp)" 2>/dev/null || true
}

fail_trap() {
    local line="$1" cmd="$2"
    # errtrace (-E) also runs this trap inside subshells ($(...), <(...),
    # pipelines). A non-zero status there is the parent's to judge (it is
    # usually checked with || or if), so only the main shell treats it as fatal.
    [[ "$BASHPID" == "$$" ]] || return 0
    trap - ERR
    die "Unexpected error at line $line: $cmd"
}
trap 'fail_trap "$LINENO" "$BASH_COMMAND"' ERR

cleanup() {
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
    return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Job plumbing
# ---------------------------------------------------------------------------

# start_job <name> <heartbeat_url_setting_name> - per-run log file, config, private
# temp directory.
start_job() {
    JOB="$1"
    require_root
    load_config
    # By name: the URL is only known once the config is loaded.
    [[ -n "$2" ]] && HB_URL="${!2}"
    mkdir -p "$LOG_DIR" "$STATE_DIR"
    chmod 750 "$STATE_DIR"
    apply_log_permissions "$LOG_DIR" "${LOG_ACCESS_GROUP:-}"
    RUN_LOG="$LOG_DIR/$JOB-$(date +%Y%m%d-%H%M%S).log"
    # shellcheck disable=SC2034 # read by the log_* helpers in lib/common.sh
    LOG_FILE="$RUN_LOG"
    WORK_DIR="$(mktemp -d)"
    chmod 700 "$WORK_DIR"
    detect_distro
    os_init
    log_info "server-maintenance $SM_VERSION: $JOB on $HOST ($DISTRO_NAME)"
}

# acquire_lock [wait_seconds] - a second run exits cleanly instead of
# overlapping (exit 0, so a timer does not mark itself failed).
acquire_lock() {
    local wait="${1:-0}"
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9> "$LOCK_FILE"
    if ! flock -w "$wait" 9; then
        log_info "Another server-maintenance job holds $LOCK_FILE; exiting without changes."
        JOB="manual"
        exit 0
    fi
}

finish_job() {
    find "$LOG_DIR" -maxdepth 1 -name '*.log' -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

# status_update KEY VALUE [KEY VALUE ...] - merges values into the status
# file read by `status` (and by an RMM such as Action1 through
# `status --oneline`).
STATUS_KEYS=(SM_VERSION LAST_CHECK_AT LAST_CHECK_RESULT LAST_RUN_AT LAST_RUN_RESULT
             LAST_POST_BOOT_AT LAST_POST_BOOT_RESULT OS_PENDING OS_SECURITY_PENDING
             REBOOT_REQUIRED REBOOT_REQUIRED_SINCE IMAGES LAST_MESSAGE)
status_update() {
    local k ver="$SM_VERSION"
    for k in "${STATUS_KEYS[@]}"; do local "$k"=""; done
    if [[ -f "$STATUS_FILE" ]]; then
        # shellcheck source=/dev/null
        . "$STATUS_FILE"
    fi
    SM_VERSION="$ver"
    while (( $# >= 2 )); do
        printf -v "$1" '%s' "$2"
        shift 2
    done
    mkdir -p "$STATE_DIR"
    write_kv_file "$STATUS_FILE" "${STATUS_KEYS[@]}"
}

# ---------------------------------------------------------------------------
# Shared checks
# ---------------------------------------------------------------------------

# disk_report - prints one line per filesystem below MIN_FREE_DISK_PERCENT.
disk_report() {
    local path free
    for path in / /var/lib/docker; do
        [[ -d "$path" ]] || continue
        free="$(df -P "$path" 2>/dev/null | awk 'NR==2 { gsub(/%/, "", $5); print 100 - $5 }')" || continue
        [[ -n "$free" ]] || continue
        if (( free < MIN_FREE_DISK_PERCENT )); then
            echo "$path has ${free}% free (minimum ${MIN_FREE_DISK_PERCENT}%)"
        fi
    done
    return 0
}

# wait_for_load - polls instead of a single hard check, so a short burst
# does not abort a maintenance window.
wait_for_load() {
    local cores deadline load
    cores="$(nproc 2>/dev/null || echo 1)"
    deadline=$(( $(date +%s) + LOAD_WAIT_SECONDS ))
    while :; do
        load="$(awk '{print $1}' /proc/loadavg)"
        if awk -v l="$load" -v c="$cores" -v m="$MAX_LOAD_PER_CORE" 'BEGIN { exit !(l / c <= m) }'; then
            return 0
        fi
        (( $(date +%s) >= deadline )) && { log_error "Load average $load on $cores core(s) stayed above $MAX_LOAD_PER_CORE per core for ${LOAD_WAIT_SECONDS}s"; return 1; }
        log_info "Load average $load is high; waiting"
        sleep 30
    done
}

# running_container_names - names of running containers, one per line.
running_container_names() {
    timeout 60 docker ps --format '{{.Names}}' 2>/dev/null | sort
}

# wait_for_containers <timeout> <name>... - prints names still not running
# (or unhealthy) after the timeout. Prints nothing when all are back.
wait_for_containers() {
    local tmo="$1"; shift
    local deadline=$(( $(date +%s) + tmo )) name state missing
    while :; do
        missing=""
        for name in "$@"; do
            state="$(timeout 20 docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null || echo "missing")"
            case "$state" in
                "running "|"running healthy") ;;
                *) missing+="$name ($state) " ;;
            esac
        done
        [[ -z "$missing" ]] && return 0
        if (( $(date +%s) >= deadline )); then
            printf '%s' "$missing"
            return 0
        fi
        sleep 5
    done
}

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------

cmd_check() {
    start_job check HEARTBEAT_URL_CHECK
    acquire_lock
    CHECK_REPORT="" CHECK_ALERTS="" CHECK_NOTICES="" STATUS_IMAGES=""
    local errors=0 pending="" npending="" nsec="" reboot since="" now
    now="$(date +%s)"

    if is_true "$OS_UPDATES_ENABLED"; then
        if os_refresh >> "$RUN_LOG" 2>&1 && pending="$(os_pending_list)"; then
            npending="$(grep -c . <<< "$pending" || true)"
            nsec="$(os_security_count)"
            CHECK_REPORT+="OS: $npending update(s) pending ($nsec security)
"
        else
            errors=1
            CHECK_ALERTS+="OS: could not query pending updates (package index refresh or dry run failed; see log).
"
        fi
    fi

    reboot="$(os_reboot_required)"
    since="$(state_get reboot_required_since)"
    if [[ "$reboot" == "yes" ]]; then
        [[ -n "$since" ]] || { since="$now"; state_set reboot_required_since "$since"; }
        CHECK_REPORT+="Reboot required since $(fmt_date "$since")
"
        if [[ "$REBOOT_POLICY" == "never" ]] && (( REBOOT_PENDING_ALERT_DAYS > 0 )) \
            && (( now - since > REBOOT_PENDING_ALERT_DAYS * 86400 )); then
            CHECK_ALERTS+="A reboot has been required since $(fmt_date "$since") and REBOOT_POLICY is 'never'. Schedule one.
"
        fi
    else
        state_del reboot_required_since
        since=""
        CHECK_REPORT+="Reboot required: $reboot
"
    fi

    local disk
    disk="$(disk_report)"
    [[ -n "$disk" ]] && CHECK_ALERTS+="Low disk space: $disk
"

    local failed=""
    if command -v systemctl >/dev/null 2>&1; then
        failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | sort | tr '\n' ' ')" || true
    fi
    if [[ "$failed" != "$(state_get failed_units)" ]]; then
        [[ -n "$failed" ]] && CHECK_ALERTS+="Failed systemd units: $failed
"
        state_set failed_units "$failed"
    fi
    [[ -n "$failed" ]] && CHECK_REPORT+="Failed units: $failed
"

    if is_true "$CONTAINER_UPDATES_ENABLED" && [[ -n "$MANAGED_IMAGES" ]]; then
        if docker_ok; then
            containers_check || errors=1
        else
            errors=1
            CHECK_ALERTS+="Docker or the compose plugin is not reachable; container images were not checked.
"
        fi
    fi

    log_info "Check results:"
    while IFS= read -r line; do [[ -n "$line" ]] && log_info "  $line"; done <<< "$CHECK_REPORT"

    local result="ok"
    (( errors )) && result="failed"
    status_update LAST_CHECK_AT "$(now_stamp)" LAST_CHECK_RESULT "$result" \
        OS_PENDING "$npending" OS_SECURITY_PENDING "$nsec" REBOOT_REQUIRED "$reboot" \
        REBOOT_REQUIRED_SINCE "$( [[ -n "$since" ]] && fmt_date "$since" )" IMAGES "${STATUS_IMAGES% }"

    if [[ -n "$CHECK_ALERTS" ]]; then
        alert "[server-maintenance] Attention Needed on $HOST" "$CHECK_ALERTS
--- Current State ---
$CHECK_REPORT
Log: $RUN_LOG"
    elif [[ -n "$CHECK_NOTICES" ]]; then
        alert "[server-maintenance] Update Pending on $HOST" "$CHECK_NOTICES
--- Current State ---
$CHECK_REPORT"
    fi
    finish_job
    if (( errors )); then
        heartbeat "$HB_URL" down "check failed on $HOST"
        exit 1
    fi
    heartbeat "$HB_URL" up "OK: ${npending:-0} OS update(s) pending, reboot $reboot"
    exit 0
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

cmd_run() {
    local no_reboot=0 skip_os=0 skip_ctr=0
    while (( $# )); do
        case "$1" in
            --no-reboot) no_reboot=1 ;;
            --skip-os) skip_os=1 ;;
            --skip-containers) skip_ctr=1 ;;
            *) echo "Unknown option for run: $1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done
    start_job run HEARTBEAT_URL_RUN
    acquire_lock

    local failures="" changes="" disk use_docker=0
    local -a before=()

    disk="$(disk_report)"
    [[ -z "$disk" ]] || die "Pre-flight failed, nothing changed: $disk"
    wait_for_load || die "Pre-flight failed, nothing changed: system load too high"
    if command -v docker >/dev/null 2>&1 && docker_ok; then
        use_docker=1
        mapfile -t before < <(running_container_names)
        log_info "Running containers before maintenance: ${#before[@]}"
    fi

    # --- OS updates --------------------------------------------------------
    if is_true "$OS_UPDATES_ENABLED" && (( ! skip_os )); then
        local pending="" os_status=0
        if ! os_refresh >> "$RUN_LOG" 2>&1; then
            failures+="OS: package index refresh failed; no packages changed.
"
        else
            pending="$(os_pending_list)" || { failures+="OS: could not list pending updates.
"; pending=""; }
            if [[ -z "$failures" && -n "$pending" ]]; then
                run_pre_change_hook || die "Pre-change hook failed; nothing changed"
                log_info "Installing $(grep -c . <<< "$pending") OS update(s) (mode: $UPDATE_MODE)"
                os_apply 2>&1 | tee -a "$RUN_LOG" || os_status=$?
                if (( os_status == 0 )); then
                    changes+="OS packages updated:
  ${pending//$'\n'/$'\n'  }
"
                else
                    failures+="OS: package update failed (exit $os_status); see log.
"
                fi
            else
                log_info "No OS updates pending"
            fi
        fi
        # A Docker engine upgrade restarts the daemon; make sure everything
        # that was running came back before touching images.
        if (( use_docker && ${#before[@]} )); then
            local missing
            missing="$(wait_for_containers 300 "${before[@]}")"
            if [[ -n "$missing" ]]; then
                failures+="Containers not running after OS updates: $missing
"
            fi
        fi
    fi

    # --- Container images --------------------------------------------------
    if is_true "$CONTAINER_UPDATES_ENABLED" && (( ! skip_ctr )) && [[ -n "$MANAGED_IMAGES" ]]; then
        APPLY_CHANGES="" APPLY_FAILURES="" APPLY_CRITICAL=0
        if [[ -n "$failures" ]]; then
            log_warn "Skipping container image updates because of earlier failures"
        elif (( ! use_docker )); then
            failures+="Docker is not reachable; container images were not updated.
"
        else
            containers_apply || true
            changes+="$APPLY_CHANGES"
            failures+="$APPLY_FAILURES"
        fi
    fi

    # --- Reboot decision ---------------------------------------------------
    local reboot do_reboot=0 reboot_note=""
    reboot="$(os_reboot_required)"
    if [[ "$reboot" == "yes" ]]; then
        local dkms_msg=""
        if ! dkms_msg="$(dkms_check)"; then
            failures+="$dkms_msg
"
        fi
        if [[ "$REBOOT_POLICY" != "if-required" ]]; then
            reboot_note="Reboot required; REBOOT_POLICY is '$REBOOT_POLICY', so not rebooting."
        elif (( no_reboot )); then
            reboot_note="Reboot required; --no-reboot given, so not rebooting."
        elif [[ -n "$failures" ]]; then
            reboot_note="Reboot required but skipped because of the failures above."
        else
            do_reboot=1
            reboot_note="Rebooting in $REBOOT_DELAY_MINUTES minute(s) to finish updates; a post-boot check will report back."
        fi
    else
        reboot_note="Reboot required: $reboot"
    fi
    log_info "$reboot_note"

    if (( use_docker )); then
        timeout 300 docker image prune -f >> "$RUN_LOG" 2>&1 || log_warn "docker image prune failed (ignored)"
    fi
    finish_job

    local result="ok" subject
    [[ -n "$failures" ]] && result="failed"
    [[ "$reboot" == "yes" && -z "$(state_get reboot_required_since)" ]] && state_set reboot_required_since "$(date +%s)"
    status_update LAST_RUN_AT "$(now_stamp)" LAST_RUN_RESULT "$result" REBOOT_REQUIRED "$reboot" \
        LAST_MESSAGE "$(head -n 1 <<< "${failures:-${changes:-no changes}}")"

    if [[ -n "$failures" ]]; then
        subject="[server-maintenance] Run FAILED on $HOST"
        (( ${APPLY_CRITICAL:-0} )) && subject="[server-maintenance] Run FAILED, Rollback FAILED on $HOST"
    else
        subject="[server-maintenance] Run Completed on $HOST"
    fi
    local body="${failures:+Failures:
$failures
}${changes:+Changes:
$changes
}$reboot_note

Log: $RUN_LOG"
    # Routine windows with nothing to do send no email (heartbeat only).
    if [[ -n "$failures" || -n "$changes" ]] || (( do_reboot )); then
        alert "$subject" "$body"
    fi

    if [[ -n "$failures" ]]; then
        heartbeat "$HB_URL" down "run failed on $HOST"
        exit 1
    fi
    if (( do_reboot )); then
        schedule_reboot "${before[@]}"
    fi
    heartbeat "$HB_URL" up "OK: $(grep -c . <<< "$changes" || true) change line(s), reboot $reboot"
    exit 0
}

# schedule_reboot <container names...> - writes the marker the post-boot
# check reads, then hands over to shutdown. The run heartbeat is sent by
# post-boot once the host is verified, not before the reboot.
schedule_reboot() {
    local REBOOT_AT KERNEL_BEFORE CONTAINERS RUN_LOG_BEFORE
    REBOOT_AT="$(now_stamp)"
    KERNEL_BEFORE="$(uname -r)"
    CONTAINERS="$*"
    RUN_LOG_BEFORE="$RUN_LOG"
    write_kv_file "$REBOOT_MARKER" REBOOT_AT KERNEL_BEFORE CONTAINERS RUN_LOG_BEFORE
    flock -u 9 || true
    trap - ERR
    if shutdown -r +"$REBOOT_DELAY_MINUTES" "server-maintenance: rebooting to finish updates" >> "$RUN_LOG" 2>&1; then
        log_info "Reboot scheduled in $REBOOT_DELAY_MINUTES minute(s)"
        exit 0
    fi
    rm -f "$REBOOT_MARKER"
    die "shutdown -r failed; the host was NOT rebooted"
}

# ---------------------------------------------------------------------------
# post-boot
# ---------------------------------------------------------------------------

cmd_post_boot() {
    [[ -f "$REBOOT_MARKER" ]] || exit 0
    start_job post-boot HEARTBEAT_URL_RUN
    acquire_lock 120
    local REBOOT_AT="" KERNEL_BEFORE="" CONTAINERS="" RUN_LOG_BEFORE=""
    check_root_file "$REBOOT_MARKER" writable || die "Unsafe reboot marker $REBOOT_MARKER"
    # shellcheck source=/dev/null
    . "$REBOOT_MARKER"
    # Removed up front so a crash here cannot cause an alert loop on every
    # later boot; the result is reported either way.
    rm -f "$REBOOT_MARKER"

    local problems="" deadline boot_epoch id dir
    deadline=$(( $(date +%s) + POST_BOOT_TIMEOUT_SECONDS ))
    boot_epoch="$(date -d "$(uptime -s)" +%s 2>/dev/null || date +%s)"
    log_info "Rebooted at $REBOOT_AT; kernel $KERNEL_BEFORE -> $(uname -r)"

    if [[ -n "$CONTAINERS" ]]; then
        while ! docker_ok; do
            if (( $(date +%s) >= deadline )); then
                problems+="Docker did not become reachable within ${POST_BOOT_TIMEOUT_SECONDS}s.
"
                break
            fi
            sleep 5
        done
        if [[ -z "$problems" ]]; then
            local -a names=()
            read -r -a names <<< "$CONTAINERS"
            local remaining=$(( deadline - $(date +%s) ))
            (( remaining < 30 )) && remaining=30
            local missing
            missing="$(wait_for_containers "$remaining" "${names[@]}")"
            [[ -n "$missing" ]] && problems+="Containers not back after reboot: $missing
"
            if is_true "$CONTAINER_UPDATES_ENABLED"; then
                for id in $MANAGED_IMAGES; do
                    while IFS= read -r dir; do
                        [[ -n "$dir" ]] || continue
                        HEALTH_DETAIL=""
                        if ! health_check "$id" "$dir" "$boot_epoch"; then
                            problems+="$id in $dir: $HEALTH_DETAIL
$(diagnostics_for "$id")
"
                        fi
                    done < <(image_projects "$id")
                done
            fi
        fi
    fi

    local reboot
    reboot="$(os_reboot_required)"
    [[ "$reboot" == "yes" ]] && problems+="The OS still reports a reboot is required.
"
    [[ "$reboot" != "yes" ]] && state_del reboot_required_since
    finish_job
    if [[ -n "$problems" ]]; then
        status_update LAST_POST_BOOT_AT "$(now_stamp)" LAST_POST_BOOT_RESULT failed REBOOT_REQUIRED "$reboot"
        alert "[server-maintenance] Post-Boot Check FAILED on $HOST" "The reboot at $REBOOT_AT finished, but:

$problems
Kernel: $KERNEL_BEFORE -> $(uname -r)
Maintenance log: $RUN_LOG_BEFORE
Post-boot log: $RUN_LOG"
        heartbeat "$HB_URL" down "post-boot check failed on $HOST"
        exit 1
    fi
    status_update LAST_POST_BOOT_AT "$(now_stamp)" LAST_POST_BOOT_RESULT ok REBOOT_REQUIRED "$reboot"
    alert "[server-maintenance] Reboot Completed on $HOST" "The maintenance reboot at $REBOOT_AT completed and the host checks out.
Kernel: $KERNEL_BEFORE -> $(uname -r)
Containers verified: ${CONTAINERS:-none}
Post-boot log: $RUN_LOG"
    heartbeat "$HB_URL" up "OK: rebooted, kernel $(uname -r)"
    exit 0
}

# ---------------------------------------------------------------------------
# Manual commands
# ---------------------------------------------------------------------------

cmd_containers() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        status)
            start_job manual ""
            JOB="manual"
            containers_status
            ;;
        approve)
            [[ $# -eq 2 ]] || { echo "Usage: server-maintenance containers approve <image> <tag>" >&2; exit 2; }
            start_job manual ""
            JOB="manual"
            containers_approve "$1" "$2"
            ;;
        revoke)
            [[ $# -eq 1 ]] || { echo "Usage: server-maintenance containers revoke <image>" >&2; exit 2; }
            start_job manual ""
            JOB="manual"
            state_del "approval_$1"
            log_info "Approval for $1 removed"
            ;;
        apply)
            start_job apply ""
            acquire_lock
            docker_ok || die "Docker or the compose plugin is not reachable"
            APPLY_CHANGES="" APPLY_FAILURES="" APPLY_CRITICAL=0
            local rc=0
            containers_apply "$@" || rc=1
            finish_job
            if (( rc )) || [[ -n "$APPLY_FAILURES" ]]; then
                alert "[server-maintenance] Image Update FAILED on $HOST" "$APPLY_FAILURES
Log: $RUN_LOG"
                log_error "Image update failed:"
                printf '%s' "$APPLY_FAILURES" >&2
                exit 1
            fi
            if [[ -n "$APPLY_CHANGES" ]]; then
                alert "[server-maintenance] Image Updated on $HOST" "$APPLY_CHANGES
Log: $RUN_LOG"
                printf '%s' "$APPLY_CHANGES"
            else
                log_info "Nothing to apply"
            fi
            ;;
        *)
            usage >&2; exit 2 ;;
    esac
}

cmd_status() {
    local k
    for k in "${STATUS_KEYS[@]}"; do local "$k"=""; done
    if [[ ! -r "$STATUS_FILE" ]]; then
        echo "server-maintenance: no status yet (no job has run, or $STATUS_FILE is not readable)"
        exit 1
    fi
    # shellcheck source=/dev/null
    . "$STATUS_FILE"
    if [[ "${1:-}" == "--oneline" ]]; then
        local overall="OK"
        [[ "$LAST_RUN_RESULT" == "failed" || "$LAST_CHECK_RESULT" == "failed" || "$LAST_POST_BOOT_RESULT" == "failed" ]] && overall="ATTENTION"
        printf '%s | server-maintenance %s | check %s %s | run %s %s | OS pending %s (%s security) | reboot %s | images %s\n' \
            "$overall" "$SM_VERSION" "${LAST_CHECK_RESULT:-never}" "${LAST_CHECK_AT:-}" \
            "${LAST_RUN_RESULT:-never}" "${LAST_RUN_AT:-}" "${OS_PENDING:-?}" "${OS_SECURITY_PENDING:-?}" \
            "${REBOOT_REQUIRED:-?}" "${IMAGES:-none}"
        [[ "$overall" == "OK" ]] && exit 0 || exit 1
    fi
    cat <<EOF
server-maintenance $SM_VERSION on $HOST
  Last check:      ${LAST_CHECK_RESULT:-never} ${LAST_CHECK_AT:-}
  Last run:        ${LAST_RUN_RESULT:-never} ${LAST_RUN_AT:-}
  Last post-boot:  ${LAST_POST_BOOT_RESULT:-never} ${LAST_POST_BOOT_AT:-}
  OS pending:      ${OS_PENDING:-?} (${OS_SECURITY_PENDING:-?} security)
  Reboot required: ${REBOOT_REQUIRED:-?}${REBOOT_REQUIRED_SINCE:+ (since $REBOOT_REQUIRED_SINCE)}
  Images:          ${IMAGES:-none}
  Last message:    ${LAST_MESSAGE:-}
EOF
}

cmd_validate() {
    start_job manual ""
    JOB="manual"
    local bad=0 id dir tag
    log_info "Config file OK: $CONFIG_FILE"
    command -v send-alert >/dev/null 2>&1 || { log_warn "send-alert is not installed: failures will not be emailed (install Linux/Notifications)"; }
    [[ -n "$HEARTBEAT_URL_CHECK" ]] || log_warn "HEARTBEAT_URL_CHECK is empty"
    [[ -n "$HEARTBEAT_URL_RUN" ]] || log_warn "HEARTBEAT_URL_RUN is empty"
    for k in jq curl flock timeout; do
        command -v "$k" >/dev/null 2>&1 || { log_error "Missing command: $k"; bad=1; }
    done
    if is_true "$CONTAINER_UPDATES_ENABLED" && [[ -n "$MANAGED_IMAGES" ]]; then
        docker_ok || { log_error "Docker or the compose plugin is not reachable"; bad=1; }
        for id in $MANAGED_IMAGES; do
            if tag="$(image_pinned_tag "$id")"; then
                log_info "$id: pinned $tag in $(img_get "$id" FILE)"
            else
                bad=1; continue
            fi
            if fetch_releases "$id"; then
                log_info "$id: $(grep -c . "$WORK_DIR/rel_${id}.tsv") usable release(s) from $(img_get "$id" REPO)"
                [[ -n "$(release_date "$id" "$tag")" ]] || log_warn "$id: pinned $tag is not among the recent releases (stale alerts cannot date it)"
            else
                bad=1
            fi
            local -a projects=()
            mapfile -t projects < <(image_projects "$id")
            for dir in "${projects[@]}"; do log_info "$id: project $dir"; done
            validate_projects "${projects[@]}" || bad=1
        done
    fi
    if command -v systemctl >/dev/null 2>&1; then
        for k in server-maintenance-check.timer server-maintenance-run.timer server-maintenance-post-boot.service; do
            systemctl is-enabled --quiet "$k" 2>/dev/null || log_warn "$k is not enabled"
        done
    fi
    (( bad )) && { log_error "Validation found problems"; exit 1; }
    log_info "Validation passed"
}

cmd_test_alert() {
    start_job manual ""
    JOB="manual"
    alert "[server-maintenance] TEST from $HOST" "This is a test from 'server-maintenance test-alert' on $HOST. It used the real alert path; no action is needed." \
        || die "Test alert failed to send"
    if [[ "${1:-}" == "--heartbeat" ]]; then
        heartbeat "$HEARTBEAT_URL_CHECK" up "TEST from test-alert"
        heartbeat "$HEARTBEAT_URL_RUN" up "TEST from test-alert"
    fi
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

main() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        check) cmd_check "$@" ;;
        run) cmd_run "$@" ;;
        os-update) cmd_run --skip-containers "$@" ;;
        post-boot) cmd_post_boot ;;
        containers) cmd_containers "$@" ;;
        status) cmd_status "$@" ;;
        validate) cmd_validate ;;
        test-alert) cmd_test_alert "$@" ;;
        version|--version|-V) echo "server-maintenance $SM_VERSION" ;;
        -h|--help|help) usage ;;
        *) usage >&2; exit 2 ;;
    esac
}

main "$@"
