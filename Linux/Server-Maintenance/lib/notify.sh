#!/usr/bin/env bash
#
# notify.sh
# 2026-10-18
# Version: v1.0.0
#
# PURPOSE:
# Alert email (through the host-wide `send-alert` command from
# Linux/Notifications) and Uptime Kuma push heartbeats for
# server-maintenance. Sourced, not executed. Requires common.sh.
#
# This tool deliberately has no SMTP settings of its own: one relay per host,
# configured once by Linux/Notifications, shared by every tool.

ALERT_TIMEOUT_SECONDS="${ALERT_TIMEOUT_SECONDS:-180}"

# alert "Subject" "Body" - never fatal. send-alert already retries with a
# per-attempt timeout; the outer timeout is a backstop.
alert() {
    local subject="$1" body="$2"
    if ! command -v send-alert >/dev/null 2>&1; then
        log_warn "send-alert not installed; alert not emailed: $subject"
        return 1
    fi
    local args=()
    [[ -n "${ALERT_TO:-}" ]] && args+=(-t "$ALERT_TO")
    if printf '%s\n' "$body" | timeout "$ALERT_TIMEOUT_SECONDS" send-alert "${args[@]}" "$subject" >/dev/null 2>&1; then
        log_info "Alert sent: $subject"
        return 0
    fi
    log_warn "Alert could not be sent: $subject"
    return 1
}

# heartbeat <url> <up|down> <message> - never fatal, never logs the URL
# (the token in its path is the only thing authenticating the ping).
heartbeat() {
    local url="$1" status="$2" msg="$3"
    if [[ -z "$url" ]]; then
        log_warn "No heartbeat URL configured for this job; a run that silently stops will not be noticed."
        return 0
    fi
    local full out
    full="${url%%\?*}?status=${status}&msg=$(url_encode "${msg:0:200}")&ping="
    out="$(mktemp)"
    if http_get "$full" "$out"; then
        log_info "Heartbeat sent ($status)"
    else
        log_warn "Heartbeat ping failed ($status); check the monitor URL and outbound HTTPS"
    fi
    rm -f "$out"
    return 0
}
