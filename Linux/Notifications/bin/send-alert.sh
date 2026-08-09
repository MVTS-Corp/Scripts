#!/usr/bin/env bash
#
# send-alert.sh
# 2026-08-09
# Version: v1.0.0
#
# PURPOSE:
# CLI entry point for sending an alert email through the SMTP relay
# configured by install.sh. Deployed to /opt/linux-notifications/bin and
# symlinked onto PATH as `send-alert`, so any other script or cron job on
# the host can send an alert with a single command instead of having to
# know msmtp or this tool's internal paths.
#
# Usage:
#   send-alert "Subject" "Body text"
#   send-alert -t ops@example.com,alerts@example.com "Subject" "Body text"
#   some-command || send-alert "some-command failed" "$(tail -n 40 /var/log/some-command.log)"
#   echo "Body text piped in" | send-alert "Subject"
#   send-alert --self-test
#
# Exit codes: 0 on success, 1 on any failure (bad usage, send failure).

set -euo pipefail

INSTALL_DIR="/opt/linux-notifications"
CONFIG_FILE="/etc/linux-notifications/config.conf"

fail_trap() {
    local lineno="$1"
    echo "ERROR: ${0##*/} failed at line ${lineno}." >&2
    exit 1
}
trap 'fail_trap "$LINENO"' ERR

usage() {
    cat <<EOF
Usage: ${0##*/} [-t recipient1,recipient2] "Subject" ["Body text"]
       echo "Body text" | ${0##*/} "Subject"
       ${0##*/} --self-test

  -t          Override the configured default recipient(s) for this message.
  --self-test Send a clearly-marked test email to the configured default
              recipient, exercising the exact same send path as a real
              alert, then exit. Safe to run any time; does not affect any
              deduplication/rate-limit state (this tool has none).
  -h, --help  Show this help text.
EOF
}

# shellcheck source=lib/common.sh
. "$INSTALL_DIR/lib/common.sh"
# shellcheck source=lib/notify.sh
. "$INSTALL_DIR/lib/notify.sh"

[[ -f "$CONFIG_FILE" ]] || die "Missing config file: $CONFIG_FILE (run install.sh first)"
# shellcheck source=/dev/null
. "$CONFIG_FILE"
ALERT_TO="${DEFAULT_ALERT_TO:-}"

TO_OVERRIDE=""
SELF_TEST=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t)
            [[ $# -ge 2 ]] || { echo "ERROR: -t requires a value." >&2; exit 1; }
            TO_OVERRIDE="$2"; shift 2 ;;
        --self-test)
            SELF_TEST=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        --)
            shift; break ;;
        -*)
            echo "ERROR: unknown option: $1" >&2
            usage
            exit 1 ;;
        *)
            break ;;
    esac
done

if (( SELF_TEST )); then
    HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
    if send_alert "[linux-notifications] TEST from $HOSTNAME_FQDN" \
        "This is a self-test message from send-alert --self-test on $HOSTNAME_FQDN. It exercises the real send path; no action is needed." \
        "$TO_OVERRIDE"; then
        log_info "Self-test email sent."
        exit 0
    else
        log_error "Self-test email failed to send. Check /var/log/linux-notifications/msmtp.log."
        exit 1
    fi
fi

SUBJECT="${1:-}"
[[ -n "$SUBJECT" ]] || { echo "ERROR: a subject is required." >&2; usage; exit 1; }
shift || true

BODY="${1:-}"
if [[ -z "$BODY" && ! -t 0 ]]; then
    BODY="$(cat)"
fi

if send_alert "$SUBJECT" "$BODY" "$TO_OVERRIDE"; then
    exit 0
else
    exit 1
fi
