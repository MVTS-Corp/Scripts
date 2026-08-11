#!/usr/bin/env bash
#
# notify.sh
# 2026-08-10
# Version: v1.0.1
#
# PURPOSE:
# Email alerting via msmtp, using the relay configured by install.sh.
# Sourced, not executed. Requires common.sh to already be sourced.
#
# CHANGELOG:
#   v1.0.1 - Bounded retries with a per-attempt timeout (matching
#            Notifications/lib/notify.sh), so a hung/unreachable SMTP
#            relay cannot hang an unattended run-updates.sh cron job
#            indefinitely. Previously this call had no timeout at all.

MSMTP_CONFIG="${MSMTP_CONFIG:-/etc/linux-updates/msmtprc}"
NOTIFY_MAX_ATTEMPTS="${NOTIFY_MAX_ATTEMPTS:-3}"
NOTIFY_ATTEMPT_TIMEOUT="${NOTIFY_ATTEMPT_TIMEOUT:-30}"

# send_alert "Subject" "Body text"
# Reads ALERT_TO and SMTP_FROM from the environment/config. Bounded
# retries: a few attempts with a short backoff and a per-attempt timeout,
# never an unbounded retry loop, so a hung or unreachable relay cannot
# hang whatever called this.
send_alert() {
    local subject="$1" body="$2"

    if [[ ! -f "$MSMTP_CONFIG" ]]; then
        log_warn "No SMTP config at $MSMTP_CONFIG; skipping email alert"
        return 1
    fi
    if ! command -v msmtp >/dev/null 2>&1; then
        log_warn "msmtp not installed; skipping email alert"
        return 1
    fi
    if [[ -z "${ALERT_TO:-}" ]]; then
        log_warn "ALERT_TO not set; skipping email alert"
        return 1
    fi

    local from="${SMTP_FROM:-linux-updates@$(hostname -f 2>/dev/null || hostname)}"
    local message
    message="$(printf 'From: %s\nTo: %s\nSubject: %s\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
        "$from" "$ALERT_TO" "$subject" "$body")"

    local attempt=1
    while (( attempt <= NOTIFY_MAX_ATTEMPTS )); do
        if printf '%s' "$message" | timeout "$NOTIFY_ATTEMPT_TIMEOUT" msmtp --file="$MSMTP_CONFIG" -a linux-updates -t; then
            return 0
        fi
        log_warn "  send attempt $attempt/$NOTIFY_MAX_ATTEMPTS failed"
        if (( attempt < NOTIFY_MAX_ATTEMPTS )); then
            sleep $(( attempt * 5 ))
        fi
        (( attempt++ ))
    done

    log_warn "Failed to send email alert via msmtp after $NOTIFY_MAX_ATTEMPTS attempts"
    return 1
}
