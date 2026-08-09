#!/usr/bin/env bash
#
# notify.sh
# 2026-08-09
# Version: v1.0.0
#
# PURPOSE:
# Email alerting via msmtp, using the relay configured by install.sh.
# Sourced, not executed. Requires common.sh to already be sourced.

MSMTP_CONFIG="${MSMTP_CONFIG:-/etc/linux-updates/msmtprc}"

# send_alert "Subject" "Body text"
# Reads ALERT_TO and SMTP_FROM from the environment/config.
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

    if printf 'From: %s\nTo: %s\nSubject: %s\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
        "$from" "$ALERT_TO" "$subject" "$body" \
        | msmtp --file="$MSMTP_CONFIG" -a linux-updates -t; then
        return 0
    else
        log_warn "Failed to send email alert via msmtp"
        return 1
    fi
}
