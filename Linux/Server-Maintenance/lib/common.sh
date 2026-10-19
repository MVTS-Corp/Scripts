#!/usr/bin/env bash
#
# common.sh
# 2026-10-18
# Version: v1.0.0
#
# PURPOSE:
# Shared logging, prompt, file-safety, state and HTTP helpers for
# server-maintenance. Sourced, not executed.

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_RESET='\033[0m'

# Only color output on a terminal, so journald and log files stay plain.
if [[ ! -t 1 ]]; then
    COLOR_RED='' COLOR_GREEN='' COLOR_YELLOW='' COLOR_RESET=''
fi

# 24-hour local time, labeled with the zone.
now_stamp() { date '+%Y-%m-%d %H:%M:%S %Z'; }

# Internal: mirrors a plain-text copy of a log line to $LOG_FILE when the
# caller has set one. A failure here (disk full) never aborts the caller.
_log_to_file() {
    [[ -n "${LOG_FILE:-}" ]] || return 0
    printf '%s %s\n' "$(now_stamp)" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

log_info()  { printf '%b[*]%b %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"; _log_to_file "[*] $*"; }
log_warn()  { printf '%b[!]%b %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2; _log_to_file "[!] $*"; }
log_error() { printf '%b[x]%b %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2; _log_to_file "[x] $*"; }

# die "message" - logs the error, gives the caller's on_fatal hook (if it
# defines one) a chance to alert, then exits 1.
die() {
    log_error "$*"
    if declare -f on_fatal >/dev/null 2>&1; then
        on_fatal "$*" || true
    fi
    exit 1
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "This must be run as root (try: sudo ${0##*/})"
    fi
}

is_true() {
    case "${1,,}" in
        true|yes|y|1|on) return 0 ;;
        *) return 1 ;;
    esac
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# confirm "Prompt text" [default y|n]
confirm() {
    local prompt="$1" default="${2:-y}" reply hint="y/N"
    [[ "$default" == "y" ]] && hint="Y/n"
    read -r -p "$prompt [$hint] " reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ask "Prompt text" [default value] -> echoes the answer
ask() {
    local prompt="$1" default="${2:-}" reply
    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " reply
        echo "${reply:-$default}"
    else
        read -r -p "$prompt: " reply
        echo "$reply"
    fi
}

# check_root_file <path> <writable|secret>
# Refuses a file root sources or trusts unless root owns it and nobody else
# can change it. "secret" additionally refuses group/other read access.
check_root_file() {
    local path="$1" kind="$2" owner mode
    [[ -f "$path" ]] || { log_error "Not found: $path"; return 1; }
    owner="$(stat -c '%u' "$path")"
    mode="$(stat -c '%a' "$path")"
    if [[ "$owner" != "0" ]]; then
        log_error "$path must be owned by root (owner uid is $owner)"
        return 1
    fi
    # Last two octal digits are group and other.
    local go="${mode: -2}"
    if (( (8#$go & 8#22) != 0 )); then
        log_error "$path is writable by group or other (mode $mode); run: chmod 600 $path"
        return 1
    fi
    if [[ "$kind" == "secret" ]] && (( 8#$go != 0 )); then
        log_error "$path is readable by group or other (mode $mode); run: chmod 600 $path"
        return 1
    fi
    return 0
}

# write_kv_file <path> NAME... - atomically writes NAME=value lines (values
# %q-escaped so the file is safe to source) for the named variables.
write_kv_file() {
    local path="$1"; shift
    local tmp name
    tmp="$(mktemp "${path}.XXXXXX")"
    for name in "$@"; do
        printf '%s=%q\n' "$name" "${!name-}" >> "$tmp"
    done
    chmod 640 "$tmp"
    mv -f "$tmp" "$path"
}

# state_get <key> / state_set <key> <value> / state_del <key>
# One small file per key under $STATE_DIR/kv, so a crash mid-write can never
# corrupt unrelated state.
state_get() { local f="$STATE_DIR/kv/$1"; [[ -f "$f" ]] && cat "$f" || true; }
state_set() {
    mkdir -p "$STATE_DIR/kv"
    local tmp
    tmp="$(mktemp "$STATE_DIR/kv/.$1.XXXXXX")"
    printf '%s' "$2" > "$tmp"
    mv -f "$tmp" "$STATE_DIR/kv/$1"
}
state_del() { rm -f "$STATE_DIR/kv/$1"; }

# url_encode <string>
url_encode() { jq -rn --arg s "$1" '$s|@uri'; }

# http_get <url> <out_file> [header_file]
# Bounded: a per-attempt timeout and HTTP_RETRIES attempts with a short
# backoff. Headers come from a file (curl -H @file) so a token never shows
# up in the process list. Returns curl's last exit code on failure.
http_get() {
    local url="$1" out="$2" hdr="${3:-}"
    local attempts="${HTTP_RETRIES:-3}" tmo="${HTTP_TIMEOUT_SECONDS:-20}"
    local attempt=1 rc=0
    local args=(-fsS --connect-timeout 10 --max-time "$tmo" -o "$out")
    [[ -n "$hdr" ]] && args+=(-H "@$hdr")
    while (( attempt <= attempts )); do
        if curl "${args[@]}" "$url"; then
            return 0
        else
            rc=$?
        fi
        (( attempt < attempts )) && sleep $(( attempt * 3 ))
        attempt=$(( attempt + 1 ))
    done
    return "$rc"
}

# version_gt <a> <b> - true when version a sorts after version b.
version_gt() {
    [[ "$1" != "$2" ]] || return 1
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

# diagnose_host <hostname> - prints a short, human-readable explanation of
# why a host may be unreachable. Tells a local resolver that answers
# differently from a public one (DNS filtering) apart from a TCP connection
# that fails (network blocked). Informational only; never fails.
diagnose_host() {
    local host="$1" sys pub
    sys="$(timeout 10 getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')" || true
    if [[ -z "$sys" ]]; then
        echo "$host: the system resolver returned no address (DNS failure or block)."
        return 0
    fi
    if command -v dig >/dev/null 2>&1; then
        pub="$(timeout 10 dig +short +time=3 +tries=1 A "$host" "@${DIAG_PUBLIC_RESOLVER:-1.1.1.1}" 2>/dev/null \
            | grep -E '^[0-9.]+$' | sort -u | tr '\n' ' ')" || true
        if [[ -n "$pub" ]]; then
            local overlap=0 ip
            for ip in $sys; do
                [[ " $pub " == *" $ip "* ]] && overlap=1
            done
            if (( ! overlap )); then
                echo "$host: system resolver answers ($sys) share nothing with ${DIAG_PUBLIC_RESOLVER:-1.1.1.1} ($pub). The local DNS filter may be rewriting this name; check its allow list."
            fi
        fi
    fi
    local first="${sys%% *}"
    if timeout 5 bash -c "exec 3<>/dev/tcp/$first/443" 2>/dev/null; then
        echo "$host: DNS resolves ($sys) and TCP 443 to $first connects."
    else
        echo "$host: DNS resolves ($sys) but TCP 443 to $first fails (network or firewall block)."
    fi
}

# apply_log_permissions <log_dir> [extra_group]
# Locks the log directory down to root (750) plus, where available, the
# "adm" group (the standard Debian/Ubuntu convention for log-reading
# access) and one additional caller-supplied group via a POSIX ACL, so
# multiple admin groups can read logs without needing root or a shared
# Unix group. Every step degrades to a warning rather than failing the
# caller, since this is a hardening step, not a required one.
apply_log_permissions() {
    local log_dir="$1" extra_group="${2:-}"

    chown root:root "$log_dir" 2>/dev/null || true
    chmod 750 "$log_dir" 2>/dev/null || true

    if getent group adm >/dev/null 2>&1; then
        chown root:adm "$log_dir" 2>/dev/null || true
    fi

    if ! command -v setfacl >/dev/null 2>&1; then
        [[ -n "$extra_group" ]] && log_warn "setfacl not available; cannot grant group '$extra_group' read access to $log_dir. Install the 'acl' package and re-run install.sh."
        return 0
    fi

    # Reset extended ACL entries first so a group removed/changed between
    # re-runs doesn't linger with stale access.
    setfacl -b "$log_dir" 2>/dev/null || true

    if getent group adm >/dev/null 2>&1; then
        setfacl -m g:adm:rx "$log_dir" 2>/dev/null || true
        setfacl -d -m g:adm:rx "$log_dir" 2>/dev/null || true
    fi

    if [[ -n "$extra_group" ]]; then
        if getent group "$extra_group" >/dev/null 2>&1; then
            setfacl -m g:"$extra_group":rx "$log_dir" 2>/dev/null || true
            setfacl -d -m g:"$extra_group":rx "$log_dir" 2>/dev/null || true
        else
            log_warn "Group '$extra_group' does not exist on this host; skipping log access grant. Create the group and re-run install.sh to apply it."
        fi
    fi
}
