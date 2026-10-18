#!/usr/bin/env bash
#
# configure-firewall.sh
# 2026-10-17
# Version: v1.0.0
#
# PURPOSE:
# Applies a baseline host firewall to a Linux server (Debian, Ubuntu, RHEL,
# or Fedora family), unattended and idempotent: default-deny for inbound
# traffic, SSH allowed on the port sshd actually uses (rate limited on ufw),
# optionally Cockpit, plus any extra ports the caller names. Debian/Ubuntu
# hosts use ufw; RHEL/Fedora hosts use firewalld. Whichever is already
# active is kept, and the other one is never started alongside it.
#
# It will not lock you out: the SSH allow rules go in BEFORE the firewall is
# switched on, and if the rules would cut off an SSH session that is open
# right now (a restricted --ssh-from that does not include the client), it
# refuses and changes nothing.
#
# Part of the MVTS-Corp/Scripts repo, under Linux/Firewall-Config. Called by
# Linux/Server-Setup/setup-server.sh, and usable on its own.
#
# Usage:
#   configure-firewall.sh [OPTIONS]        apply the baseline (never prompts)
#   configure-firewall.sh --status         show the firewall, change nothing
#
#   OPTIONS:
#     --ssh-port N        SSH port to allow (repeatable). Default: every port
#                         `sshd -T` reports, else 22 when no sshd is found.
#     --ssh-from CIDRS    Limit SSH to these sources (comma separated IPv4 or
#                         IPv6 CIDRs), or "any" (default).
#     --cockpit-from V    Cockpit (TCP 9090): "any", comma separated CIDRs,
#                         "none", or "auto" (default: open to any only when
#                         Cockpit is installed).
#     --allow SPEC        Also allow an inbound port, e.g. 443/tcp or
#                         8000:8100/udp (repeatable).
#     --no-enable         Add the rules but do not switch the firewall on.
#     --skip-lockout-check
#                         Do not refuse when a restricted --ssh-from would cut
#                         off a session that is open now. Use with care.
#     -h, --help          Show this text.
#
#   The last line printed is "RESULT: changed" or "RESULT: unchanged".
#
# Exit codes:
#   0  success (changes applied, or nothing needed changing)
#   1  runtime failure, or refused to avoid locking out an SSH session
#   2  invalid arguments; nothing on the system was touched
#
# CHANGELOG:
#   v1.0.0 - Initial release.

set -Eeuo pipefail
set -f

SCRIPT_VERSION="v1.0.0"
COCKPIT_PORT=9090

OPT_STATUS=0
OPT_NO_ENABLE=0
OPT_SKIP_LOCKOUT=0
OPT_SSH_FROM="any"
OPT_COCKPIT_FROM="auto"
OPT_SSH_PORTS=()
OPT_ALLOW=()

usage() {
    sed -n '/^# Usage:/,/^# CHANGELOG:/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

usage_error() {
    echo "ERROR: $*" >&2
    echo "Run with --help for usage." >&2
    exit 2
}

# One CIDR, IPv4 or a plain IPv6 form. Loose on purpose for IPv6: the
# firewall rejects anything malformed, and nothing here is placed in a shell
# context unquoted.
valid_cidr() {
    local c="$1" octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
    [[ "$c" =~ ^${octet}\.${octet}\.${octet}\.${octet}/(3[0-2]|[12]?[0-9])$ ]] && return 0
    [[ "$c" =~ ^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*/(12[0-8]|1[01][0-9]|[1-9]?[0-9])$ ]]
}

# validate_cidr_list NAME VALUE - exits 2 on a bad entry; echoes the list
# with commas turned into spaces.
cidr_list() {
    local name="$1" raw="${2//,/ }" tok out=()
    for tok in $raw; do
        valid_cidr "$tok" || usage_error "${name}: '${tok}' is not a valid CIDR (for example 192.168.1.0/24)."
        out+=("$tok")
    done
    (( ${#out[@]} > 0 )) || usage_error "${name} needs at least one CIDR."
    echo "${out[*]}"
}

valid_port_spec() {
    [[ "$1" =~ ^[0-9]{1,5}(:[0-9]{1,5})?/(tcp|udp)$ ]] || return 1
    local ports="${1%/*}" lo hi
    lo="${ports%%:*}"; hi="${ports##*:}"
    (( 10#$lo >= 1 && 10#$lo <= 65535 && 10#$hi >= 1 && 10#$hi <= 65535 && 10#$lo <= 10#$hi ))
}

while (( $# > 0 )); do
    case "$1" in
        --status) OPT_STATUS=1; shift ;;
        --no-enable) OPT_NO_ENABLE=1; shift ;;
        --skip-lockout-check) OPT_SKIP_LOCKOUT=1; shift ;;
        --ssh-port)
            (( $# >= 2 )) || usage_error "--ssh-port requires a value."
            [[ "$2" =~ ^[0-9]{1,5}$ ]] && (( 10#$2 >= 1 && 10#$2 <= 65535 )) || usage_error "--ssh-port must be a port number from 1 to 65535."
            OPT_SSH_PORTS+=("$((10#$2))"); shift 2 ;;
        --ssh-from)
            (( $# >= 2 )) || usage_error "--ssh-from requires a value."
            OPT_SSH_FROM="$2"; shift 2 ;;
        --cockpit-from)
            (( $# >= 2 )) || usage_error "--cockpit-from requires a value."
            OPT_COCKPIT_FROM="$2"; shift 2 ;;
        --allow)
            (( $# >= 2 )) || usage_error "--allow requires a value."
            valid_port_spec "$2" || usage_error "--allow: '$2' is not a port spec like 443/tcp or 8000:8100/udp."
            OPT_ALLOW+=("$2"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage_error "unknown argument '$1'." ;;
    esac
done

if [[ "$OPT_SSH_FROM" != "any" ]]; then
    SSH_FROM="$(cidr_list --ssh-from "$OPT_SSH_FROM")"
else
    SSH_FROM="any"
fi
case "$OPT_COCKPIT_FROM" in
    any|none|auto) COCKPIT_FROM="$OPT_COCKPIT_FROM" ;;
    *) COCKPIT_FROM="$(cidr_list --cockpit-from "$OPT_COCKPIT_FROM")" ;;
esac
if (( OPT_STATUS )) && { (( ${#OPT_ALLOW[@]} )) || (( ${#OPT_SSH_PORTS[@]} )) || (( OPT_NO_ENABLE )) \
    || [[ "$OPT_SSH_FROM" != "any" || "$OPT_COCKPIT_FROM" != "auto" ]]; }; then
    usage_error "--status only reports; it cannot be combined with settings."
fi

fail_trap() {
    echo "ERROR: script failed at line $1. Rules added so far (if any) are listed by --status; the firewall is only switched on after every SSH allow rule is in." >&2
    exit 1
}
trap 'fail_trap "$LINENO"' ERR

if [[ ${EUID} -ne 0 ]]; then
    echo "ERROR: this script must be run as root (sudo)." >&2
    exit 1
fi

timeout() { command timeout --foreground "$@"; }

# --------------------------------------------------------------------------
# OS and backend detection
# --------------------------------------------------------------------------
[[ -f /etc/os-release ]] || { echo "ERROR: /etc/os-release not found. Cannot detect OS." >&2; exit 1; }
# shellcheck disable=SC1091
source /etc/os-release
OS_ID="${ID:-unknown}"
OS_ID_LIKE="${ID_LIKE:-}"
case "$OS_ID" in
    debian|ubuntu) FAMILY="debian" ;;
    rhel|centos|fedora|rocky|almalinux) FAMILY="rhel" ;;
    *)
        if [[ "$OS_ID_LIKE" == *debian* ]]; then
            FAMILY="debian"
        elif [[ "$OS_ID_LIKE" == *rhel* || "$OS_ID_LIKE" == *fedora* ]]; then
            FAMILY="rhel"
        else
            echo "ERROR: unsupported OS (ID=${OS_ID}, ID_LIKE=${OS_ID_LIKE})." >&2
            exit 1
        fi
        ;;
esac

if [[ "$FAMILY" == "debian" ]]; then
    PKG_MGR="apt-get"
    BACKEND="ufw"
    # An already-active firewalld is kept; ufw is never started beside it.
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        BACKEND="firewalld"
    fi
else
    command -v dnf >/dev/null 2>&1 && PKG_MGR="dnf" || PKG_MGR="yum"
    BACKEND="firewalld"
    if command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null || true)" == *"Status: active"* ]]; then
        echo "ERROR: ufw is active on this ${OS_ID} host. Disable it first, or manage that firewall directly; this tool will not run firewalld beside it." >&2
        exit 1
    fi
fi

ensure_backend() {
    command -v "$BACKEND" >/dev/null 2>&1 && return 0
    [[ "$BACKEND" == "firewalld" ]] && command -v firewall-cmd >/dev/null 2>&1 && return 0
    echo "${BACKEND} is not installed. Installing now..."
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    if [[ "$PKG_MGR" == "apt-get" ]]; then
        timeout 300 apt-get -o DPkg::Lock::Timeout=180 update -qq
        timeout 600 apt-get -o DPkg::Lock::Timeout=180 install -y "$BACKEND"
    else
        timeout 600 "$PKG_MGR" install -y "$BACKEND"
    fi
    if [[ "$BACKEND" == "firewalld" ]]; then
        command -v firewall-cmd >/dev/null 2>&1 || { echo "ERROR: firewalld installed but firewall-cmd was not found." >&2; exit 1; }
    else
        command -v ufw >/dev/null 2>&1 || { echo "ERROR: ufw installed but the ufw command was not found." >&2; exit 1; }
    fi
}

# --------------------------------------------------------------------------
# Status
# --------------------------------------------------------------------------
show_status() {
    echo "Firewall backend: ${BACKEND} (${OS_ID}, ${FAMILY} family)"
    if [[ "$BACKEND" == "ufw" ]]; then
        if command -v ufw >/dev/null 2>&1; then
            ufw status verbose || true
        else
            echo "ufw is not installed."
        fi
    else
        if command -v firewall-cmd >/dev/null 2>&1; then
            if systemctl is-active --quiet firewalld 2>/dev/null; then
                firewall-cmd --list-all || true
            else
                echo "firewalld is installed but not running."
            fi
        else
            echo "firewalld is not installed."
        fi
    fi
}

if (( OPT_STATUS )); then
    show_status
    exit 0
fi

# --------------------------------------------------------------------------
# What to open
# --------------------------------------------------------------------------
SSH_PORTS=()
if (( ${#OPT_SSH_PORTS[@]} )); then
    SSH_PORTS=("${OPT_SSH_PORTS[@]}")
elif command -v sshd >/dev/null 2>&1; then
    while IFS= read -r p; do
        [[ "$p" =~ ^[0-9]+$ ]] && SSH_PORTS+=("$p")
    done < <({ sshd -T 2>/dev/null || true; } | awk '$1 == "port" { print $2 }' | sort -un)
    (( ${#SSH_PORTS[@]} )) || SSH_PORTS=(22)
else
    echo "NOTE: no sshd found on this host and no --ssh-port given, so no SSH rule is added."
fi

case "$COCKPIT_FROM" in
    auto)
        if [[ -n "$(systemctl list-unit-files cockpit.socket --no-legend 2>/dev/null || true)" ]]; then
            COCKPIT_FROM="any"
        else
            COCKPIT_FROM="none"
        fi
        ;;
esac

# --------------------------------------------------------------------------
# Lockout protection
# --------------------------------------------------------------------------
ip2int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

ip_in_cidr() {
    local ip="$1" net="${2%/*}" bits="${2#*/}" mask
    mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    (( ($(ip2int "$ip") & mask) == ($(ip2int "$net") & mask) ))
}

# Refuses when a restricted --ssh-from would not include a client that has an
# SSH session open right now. Reads established connections to the SSH
# ports, so it works through sudo (which drops SSH_CONNECTION) too.
check_lockout() {
    [[ "$SSH_FROM" == "any" ]] && return 0
    (( OPT_SKIP_LOCKOUT )) && return 0
    command -v ss >/dev/null 2>&1 || { echo "NOTE: 'ss' not found; cannot check open SSH sessions against --ssh-from."; return 0; }

    local p peer cidr covered bad=()
    for p in "${SSH_PORTS[@]}"; do
        while IFS= read -r peer; do
            [[ -n "$peer" ]] || continue
            peer="${peer%:*}"; peer="${peer#[}"; peer="${peer%]}"; peer="${peer#::ffff:}"
            [[ "$peer" == 127.* || "$peer" == "::1" ]] && continue
            if [[ "$peer" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                covered=0
                for cidr in $SSH_FROM; do
                    [[ "$cidr" == *:* ]] && continue
                    if ip_in_cidr "$peer" "$cidr"; then covered=1; break; fi
                done
                (( covered )) || bad+=("$peer")
            else
                echo "NOTE: an SSH session from IPv6 address ${peer} is open; it cannot be checked against --ssh-from."
            fi
        done < <(ss -Htn state established "( sport = :${p} )" 2>/dev/null | awk '{ print $4 }')
    done
    if (( ${#bad[@]} )); then
        echo "ERROR: refusing to continue: SSH is restricted to ${SSH_FROM}, but a session is open from ${bad[*]}, which is outside it. Applying this would cut you off. Add that address to --ssh-from, or pass --skip-lockout-check if you are sure." >&2
        exit 1
    fi
}

# --------------------------------------------------------------------------
# ufw
# --------------------------------------------------------------------------
ufw_snapshot() {
    { ufw status verbose 2>/dev/null; ufw show added 2>/dev/null; } || true
}

ufw_active() {
    local s
    s="$(ufw status 2>/dev/null || true)"
    [[ "$s" == *"Status: active"* ]]
}

apply_ufw() {
    local p src spec
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null

    # SSH first, so that nothing below can leave the host without it.
    for p in ${SSH_PORTS[@]+"${SSH_PORTS[@]}"}; do
        if [[ "$SSH_FROM" == "any" ]]; then
            ufw limit "${p}/tcp" comment 'SSH' >/dev/null
        else
            for src in $SSH_FROM; do
                ufw limit proto tcp from "$src" to any port "$p" comment 'SSH' >/dev/null
            done
        fi
    done

    case "$COCKPIT_FROM" in
        none) ;;
        any) ufw allow "${COCKPIT_PORT}/tcp" comment 'Cockpit' >/dev/null ;;
        *)
            for src in $COCKPIT_FROM; do
                ufw allow proto tcp from "$src" to any port "$COCKPIT_PORT" comment 'Cockpit' >/dev/null
            done
            ;;
    esac

    for spec in ${OPT_ALLOW[@]+"${OPT_ALLOW[@]}"}; do
        ufw allow "$spec" comment 'MVTS baseline' >/dev/null
    done

    if (( OPT_NO_ENABLE )); then
        echo "NOTE: --no-enable given; rules are added but ufw is not switched on."
    elif ! ufw_active; then
        # --force: ufw otherwise asks "may disrupt existing ssh connections".
        # Safe here: every SSH allow rule above is already in.
        ufw --force enable >/dev/null
        echo "ufw enabled."
    fi
    ufw_active || (( OPT_NO_ENABLE )) || { echo "ERROR: ufw did not report active after enabling it." >&2; exit 1; }
}

# --------------------------------------------------------------------------
# firewalld
# --------------------------------------------------------------------------
fw() { timeout 60 firewall-cmd --permanent --zone="$ZONE" "$@" >/dev/null; }

fwd_snapshot() {
    { systemctl is-active firewalld 2>/dev/null; firewall-cmd --permanent --zone="${ZONE:-$(firewall-cmd --get-default-zone 2>/dev/null)}" --list-all 2>/dev/null; } || true
}

rich_rule() {   # rich_rule SRC PORT[-PORT] PROTO
    local fam="ipv4"
    [[ "$1" == *:* ]] && fam="ipv6"
    echo "rule family=\"${fam}\" source address=\"$1\" port port=\"$2\" protocol=\"$3\" accept"
}

apply_firewalld() {
    local p src spec ports proto
    if ! systemctl is-active --quiet firewalld; then
        timeout 60 systemctl enable --now firewalld
        echo "firewalld started."
    fi
    ZONE="$(firewall-cmd --get-default-zone)"

    for p in ${SSH_PORTS[@]+"${SSH_PORTS[@]}"}; do
        if [[ "$SSH_FROM" == "any" ]]; then
            fw --add-port="${p}/tcp"
        else
            for src in $SSH_FROM; do
                fw --add-rich-rule="$(rich_rule "$src" "$p" tcp)"
            done
        fi
    done
    # The default zone allows the ssh service (port 22) from anywhere; once
    # SSH is restricted, that open door has to go (only after the restricted
    # rules above are in).
    if [[ "$SSH_FROM" != "any" ]]; then
        fw --remove-service=ssh || true
    fi

    case "$COCKPIT_FROM" in
        none) ;;
        any) fw --add-service=cockpit ;;
        *)
            for src in $COCKPIT_FROM; do
                fw --add-rich-rule="$(rich_rule "$src" "$COCKPIT_PORT" tcp)"
            done
            fw --remove-service=cockpit || true
            ;;
    esac

    for spec in ${OPT_ALLOW[@]+"${OPT_ALLOW[@]}"}; do
        ports="${spec%/*}"; proto="${spec#*/}"
        fw --add-port="${ports/:/-}/${proto}"
    done

    timeout 60 firewall-cmd --reload >/dev/null
}

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------
echo "configure-firewall.sh ${SCRIPT_VERSION}  |  ${OS_ID} (${FAMILY} family)  |  backend: ${BACKEND}"
ensure_backend
check_lockout

echo "SSH ports: ${SSH_PORTS[*]:-(none)}  from: ${SSH_FROM}"
echo "Cockpit:   ${COCKPIT_FROM}"
echo "Extra:     ${OPT_ALLOW[*]:-(none)}"

before=""
if [[ "$BACKEND" == "ufw" ]]; then
    before="$(ufw_snapshot)"
    apply_ufw
    after="$(ufw_snapshot)"
else
    ZONE=""
    if systemctl is-active --quiet firewalld; then
        before="$(fwd_snapshot)"
    else
        before="inactive"
    fi
    apply_firewalld
    after="$(fwd_snapshot)"
fi

echo
show_status
echo
if [[ "$before" == "$after" ]]; then
    echo "RESULT: unchanged"
else
    echo "RESULT: changed"
fi
