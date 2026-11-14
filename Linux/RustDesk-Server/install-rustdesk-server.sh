#!/usr/bin/env bash
#
# install-rustdesk-server.sh
# 2026-11-14
# Version: v1.0.0
#
# PURPOSE:
# Installs, verifies, and upgrades the open source RustDesk server (hbbs ID
# server + hbbr relay) under Docker Compose, the same way on every host:
#   * image pinned by exact tag AND digest, never "latest", no auto-update;
#   * host networking, so the host firewall stays authoritative;
#   * only TCP 21115-21117 and UDP 21116 opened (web client ports 21118 and
#     21119 stay closed even though hbbs and hbbr listen on them);
#   * key enforced on BOTH hbbs and hbbr ("-k _"), checked from their logs;
#   * the private key is never printed, mode 600, flagged for off-host backup.
# Every step is idempotent: a second run with the same inputs changes
# nothing and says so. Templates live in templates/ so they can move into a
# configuration management role unchanged.
#
# Modes:
#   install (default)       install or re-apply the current version
#   status                  verify only, change nothing (cron or monitor safe)
#   upgrade --version TAG   back up data/, switch tags, verify, roll back on failure
#   print-client-config     print the relay host and public key for clients
#
# Exit codes: 0 success, 1 failure, 3 completed with items flagged for review.
#
# CHANGELOG:
#   v1.0.0 - First release. Built from a design handoff and the RustDesk
#            server 1.1.16 source. Differences from that handoff, and why:
#            * "-k _" is always passed to hbbs AND hbbr; no --enforce-key
#              flag. In 1.1.16 hbbs enforces the key by default, but hbbr
#              only checks it when given one (default empty = open relay).
#              Preflight stops if the pinned image's --help lacks -k.
#            * The image digest is pinned next to the tag (--digest, or
#              recorded on first install and flagged for confirmation).
#            * On a fresh data/ the installer starts hbbs alone and waits
#              for the key before starting hbbr. Whichever starts first
#              without a key file generates one, so starting both together
#              can leave them with different keys.
#            * upgrade backs up data/ (keys and the hbbs database) before
#              switching tags and restores it on rollback.

set -Eeuo pipefail

SCRIPT_VERSION="v1.0.0"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Settings. Every flag has a matching environment variable; flags win.
# ---------------------------------------------------------------------------
MODE="install"
RELAY_HOST="${RD_RELAY_HOST:-}"
VERSION_TAG="${RD_VERSION:-}"
DIGEST="${RD_DIGEST:-}"
INSTALL_DIR="${RD_INSTALL_DIR:-/opt/RustDesk}"
FIREWALL="${RD_FIREWALL:-auto}"
ASSUME_YES="${RD_ASSUME_YES:-0}"
DRY_RUN="${RD_DRY_RUN:-0}"
ALERT="${RD_ALERT:-0}"
LOG_DIR="${RD_LOG_DIR:-/var/log/rustdesk-server}"
WAIT_SECS="${RD_WAIT_SECS:-90}"

# nftables backend: a host table with named port sets, persisted by a file
# that a systemd unit loads. Names are conventions, not site values.
NFT_TABLE="${RD_NFT_TABLE:-vps_filter}"
NFT_CHAIN="${RD_NFT_CHAIN:-input}"
NFT_FILE="${RD_NFT_FILE:-/etc/nftables.d/vps-filter.nft}"
NFT_TCP_SET="${RD_NFT_TCP_SET:-public_tcp_ports}"
NFT_UDP_SET="${RD_NFT_UDP_SET:-public_udp_ports}"
FIREWALLD_ZONE="${RD_FIREWALLD_ZONE:-}"

IMAGE_REPO="rustdesk/rustdesk-server"
OPEN_TCP=(21115 21116 21117)
OPEN_UDP=(21116)
CLOSED_PORTS=(21118 21119)
# Everything hbbs/hbbr bind, so preflight can spot another owner.
BOUND_TCP=(21115 21116 21117 21118 21119)
BOUND_UDP=(21116)
OPTIONAL_ENV_KEYS="TOTAL_BANDWIDTH|SINGLE_BANDWIDTH|LIMIT_SPEED"

FLAGGED_ITEMS=()
CHANGES=()
FAILED_CHECKS=()
RUN_LOG=""
BACKEND=""
IMAGE_REF=""
PINNED=""
ROLLBACK_NOTE=""

usage() {
    cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION} - RustDesk OSS server installer

Usage:
  ${SCRIPT_NAME} [install] --relay-host HOST --version TAG [options]
  ${SCRIPT_NAME} status [options]
  ${SCRIPT_NAME} upgrade --version TAG [--digest sha256:...] [options]
  ${SCRIPT_NAME} print-client-config [--install-dir DIR]

Options (environment variable in brackets):
  --relay-host HOST   Public DNS name clients use [RD_RELAY_HOST]. Required
                      on first install.
  --version TAG       Exact image tag, X.Y.Z form [RD_VERSION]. "latest" and
                      floating tags such as "1" are rejected.
  --digest DIGEST     sha256:... image digest for TAG [RD_DIGEST]. If omitted
                      on first install, the pulled digest is recorded and
                      flagged for you to confirm.
  --install-dir DIR   Default /opt/RustDesk [RD_INSTALL_DIR].
  --firewall MODE     auto|nft|ufw|firewalld|none, default auto [RD_FIREWALL].
  --alert             On failure or flagged items, send the log tail with
                      send-alert (Linux/Notifications) [RD_ALERT=1].
  --yes               Do not prompt [RD_ASSUME_YES=1].
  --dry-run           Print the plan and change nothing [RD_DRY_RUN=1].
  -h, --help          This help.

nftables backend settings (environment only): RD_NFT_TABLE (vps_filter),
RD_NFT_CHAIN (input), RD_NFT_FILE (/etc/nftables.d/vps-filter.nft),
RD_NFT_TCP_SET (public_tcp_ports), RD_NFT_UDP_SET (public_udp_ports).
firewalld: RD_FIREWALLD_ZONE (default zone if unset).
Other: RD_LOG_DIR (/var/log/rustdesk-server), RD_WAIT_SECS (90).

Exit codes: 0 success, 1 failure, 3 completed with items flagged.
EOF
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
is_true() { [[ "${1,,}" =~ ^(1|y|yes|true|on)$ ]]; }

flag() {
    log_warn "FLAGGED: $*"
    FLAGGED_ITEMS+=("$*")
}

changed() {
    log_info "Changed: $*"
    CHANGES+=("$*")
}

check_pass() { log_info "PASS  $*"; }
check_fail() { log_error "FAIL  $*"; FAILED_CHECKS+=("$*"); }

# check "pass message" "fail message" CMD... - records the result of CMD.
check() {
    local pass="$1" fail="$2"
    shift 2
    if "$@"; then check_pass "$pass"; else check_fail "$fail"; fi
}

ts_file() { date '+%Y%m%d-%H%M%S'; }
ts_log()  { date '+%Y-%m-%d %H:%M:%S %Z'; }

# join_by SEP ITEM... - joins items with a separator of any length.
join_by() {
    local sep="$1" out="" item
    shift
    for item in "$@"; do out+="${out:+$sep}${item}"; done
    echo "$out"
}

# env_get FILE KEY - value of KEY=... from a .env file, without sourcing it.
env_get() {
    [[ -f "$1" ]] || return 0
    awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$1"
}

# write_if_changed DEST MODE - writes stdin to DEST only if different.
# Returns 0 when it wrote the file, 10 when it was already identical, 1 on error.
write_if_changed() {
    local dest="$1" mode="$2" tmp
    tmp="$(mktemp)" || return 1
    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
        chmod "$mode" "$dest"
        rm -f "$tmp"
        return 10
    fi
    install -o root -g root -m "$mode" "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    return 0
}

# wait_until SECONDS DESCRIPTION CMD... - polls CMD every 2s, bounded.
wait_until() {
    local secs="$1" what="$2" waited=0
    shift 2
    until "$@"; do
        if (( waited >= secs )); then
            log_warn "Timed out after ${secs}s waiting for: ${what}"
            return 1
        fi
        sleep 2
        (( waited += 2 ))
    done
}

dc() { docker compose --project-directory "$INSTALL_DIR" -f "${INSTALL_DIR}/compose.yaml" "$@"; }

# listener_procs tcp|udp PORT - process names listening on that port.
listener_procs() {
    local proto_flag="-t"
    [[ "$1" == "udp" ]] && proto_flag="-u"
    ss -Hlnp "$proto_flag" "( sport = :$2 )" 2>/dev/null \
        | grep -oE 'users:\(\("[^"]+"' | sed -E 's/users:\(\("//; s/"$//' | sort -u || true
}

is_listening() { [[ -n "$(listener_procs "$1" "$2")" ]]; }

# ---------------------------------------------------------------------------
# Argument parsing and validation
# ---------------------------------------------------------------------------
need_value() { [[ -n "${2:-}" && "${2:0:2}" != "--" ]] || die "Option $1 needs a value."; }

parse_args() {
    local mode_seen=0
    while (( $# )); do
        case "$1" in
            install|status|upgrade|print-client-config)
                (( mode_seen == 0 )) || die "Only one mode may be given (got '$MODE' and '$1')."
                MODE="$1"; mode_seen=1 ;;
            --relay-host)   need_value "$1" "${2:-}"; RELAY_HOST="$2"; shift ;;
            --relay-host=*) RELAY_HOST="${1#*=}" ;;
            --version)      need_value "$1" "${2:-}"; VERSION_TAG="$2"; shift ;;
            --version=*)    VERSION_TAG="${1#*=}" ;;
            --digest)       need_value "$1" "${2:-}"; DIGEST="$2"; shift ;;
            --digest=*)     DIGEST="${1#*=}" ;;
            --install-dir)  need_value "$1" "${2:-}"; INSTALL_DIR="$2"; shift ;;
            --install-dir=*) INSTALL_DIR="${1#*=}" ;;
            --firewall)     need_value "$1" "${2:-}"; FIREWALL="$2"; shift ;;
            --firewall=*)   FIREWALL="${1#*=}" ;;
            --alert)        ALERT=1 ;;
            --yes|-y)       ASSUME_YES=1 ;;
            --dry-run)      DRY_RUN=1 ;;
            -h|--help)      usage; exit 0 ;;
            *) usage >&2; die "Unknown argument: $1" ;;
        esac
        shift
    done
    is_true "$ASSUME_YES" && ASSUME_YES=1 || ASSUME_YES=0
    is_true "$DRY_RUN" && DRY_RUN=1 || DRY_RUN=0
    is_true "$ALERT" && ALERT=1 || ALERT=0
}

validate_tag() {
    local tag="$1"
    [[ -n "$tag" ]] || die "--version is required (an exact image tag such as 1.2.3)."
    [[ "${tag,,}" != "latest" ]] || die "--version latest is not allowed: pin an exact release tag."
    [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] \
        || die "--version '$tag' is not an exact X.Y.Z tag. Floating tags (for example '1') are not allowed."
}

validate_digest() {
    [[ -z "$1" || "$1" =~ ^sha256:[0-9a-f]{64}$ ]] || die "--digest must look like sha256:<64 hex characters>."
}

validate_host() {
    local h="$1"
    [[ -n "$h" ]] || die "--relay-host is required (the public DNS name clients will use)."
    [[ "${h,,}" != *change-me* ]] || die "--relay-host is still a CHANGE-ME placeholder."
    [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] \
        || die "--relay-host '$h' is not a valid DNS name (no scheme, port, or path)."
}

validate_settings() {
    case "$FIREWALL" in auto|nft|ufw|firewalld|none) ;; *) die "--firewall must be auto, nft, ufw, firewalld, or none." ;; esac
    [[ "$INSTALL_DIR" == /* && "$INSTALL_DIR" != "/" ]] || die "--install-dir must be an absolute path other than /."
    INSTALL_DIR="${INSTALL_DIR%/}"
    [[ "$WAIT_SECS" =~ ^[0-9]+$ ]] || die "RD_WAIT_SECS must be a whole number of seconds."
    local n
    for n in "$NFT_TABLE" "$NFT_CHAIN" "$NFT_TCP_SET" "$NFT_UDP_SET"; do
        [[ "$n" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid nftables name: '$n'."
    done
}

# ---------------------------------------------------------------------------
# Logging and exit handling
# ---------------------------------------------------------------------------
start_logging() {
    mkdir -p "$LOG_DIR" || die "Cannot create log directory: $LOG_DIR"
    apply_log_permissions "$LOG_DIR"
    if [[ "$MODE" == "status" ]]; then
        RUN_LOG="${LOG_DIR}/status-$(date +%Y%m).log"   # one file a month for frequent checks
    else
        RUN_LOG="${LOG_DIR}/${MODE}-$(ts_file).log"
    fi
    exec > >(tee -a "$RUN_LOG") 2>&1
    log_info "${SCRIPT_NAME} ${SCRIPT_VERSION} mode=${MODE} started $(ts_log). Log: ${RUN_LOG}"
}

send_failure_alert() {
    local rc="$1"
    (( ALERT == 1 )) || return 0
    (( rc != 0 )) || return 0
    if ! command -v send-alert >/dev/null 2>&1; then
        log_warn "--alert was given but send-alert is not installed (Linux/Notifications); no alert sent."
        return 0
    fi
    sleep 1   # let the async tee catch up before reading the log back
    local subject host
    host="$(hostname -s 2>/dev/null || echo host)"
    subject="RustDesk server ${MODE}: exit ${rc} on ${host}"
    if [[ -n "$RUN_LOG" && -f "$RUN_LOG" ]]; then
        tail -n 80 "$RUN_LOG" | sed -E 's/\x1B\[[0-9;]*m//g' | send-alert "$subject" || log_warn "send-alert failed."
    else
        send-alert "$subject" "No run log was available." || log_warn "send-alert failed."
    fi
}

on_exit() {
    local rc=$?
    [[ -n "$NFT_NEW_FILE" ]] && rm -f "$NFT_NEW_FILE"
    send_failure_alert "$rc"
    exit "$rc"
}

fail_trap() {
    log_error "Unexpected error at line $1 (exit code $2). See ${RUN_LOG:-the output above}."
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight_tools() {
    local c
    for c in docker ss getent awk sed grep cmp install tar mktemp; do
        command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"
    done
    docker info >/dev/null 2>&1 || die "Docker is installed but the daemon is not reachable (is the docker service running?)."
    docker compose version >/dev/null 2>&1 || die "The Docker Compose plugin ('docker compose') is not available."
    if [[ "$MODE" == "install" || "$MODE" == "upgrade" ]]; then
        [[ -f "${TEMPLATE_DIR}/compose.yaml" && -f "${TEMPLATE_DIR}/env.example" ]] \
            || die "Templates not found in ${TEMPLATE_DIR}. Run from a full copy of this tool's folder."
    fi
    log_info "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'), Compose $(docker compose version --short 2>/dev/null || echo '?')."
}

# Containers named hbbs/hbbr that this install directory does not own.
preflight_container_names() {
    local n wd
    for n in hbbs hbbr; do
        docker container inspect "$n" >/dev/null 2>&1 || continue
        wd="$(docker container inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$n" 2>/dev/null || true)"
        [[ "$wd" == "$INSTALL_DIR" ]] \
            || die "A container named '$n' already exists and is not managed from ${INSTALL_DIR} (working dir: '${wd:-none}'). Remove it or use its install dir."
    done
}

preflight_ports() {
    local p procs proc
    for p in "${BOUND_TCP[@]}"; do
        procs="$(listener_procs tcp "$p")"
        for proc in $procs; do
            [[ "$proc" == "hbbs" || "$proc" == "hbbr" ]] || die "TCP port $p is in use by '$proc'. RustDesk needs it."
        done
    done
    for p in "${BOUND_UDP[@]}"; do
        procs="$(listener_procs udp "$p")"
        for proc in $procs; do
            [[ "$proc" == "hbbs" ]] || die "UDP port $p is in use by '$proc'. RustDesk needs it."
        done
    done
    log_info "Ports ${BOUND_TCP[*]}/tcp and ${BOUND_UDP[*]}/udp are free or already owned by hbbs/hbbr."
}

check_dns() {
    if getent ahosts "$RELAY_HOST" >/dev/null 2>&1; then
        log_info "Relay host ${RELAY_HOST} resolves: $(getent ahosts "$RELAY_HOST" | awk '{print $1}' | sort -u | tr '\n' ' ')"
    else
        flag "Relay host ${RELAY_HOST} does not resolve yet. Clients cannot connect until its DNS record exists (DNS only, not proxied)."
    fi
}

# ---------------------------------------------------------------------------
# Firewall detection. Two active host firewalls is a hard stop.
# ---------------------------------------------------------------------------
HAVE_NFT=0; HAVE_UFW=0; HAVE_FIREWALLD=0

detect_firewalls() {
    if command -v nft >/dev/null 2>&1 && nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then HAVE_NFT=1; fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then HAVE_UFW=1; fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then HAVE_FIREWALLD=1; fi

    local active=() count
    (( HAVE_NFT ))       && active+=("nftables table inet ${NFT_TABLE}")
    (( HAVE_UFW ))       && active+=("ufw")
    (( HAVE_FIREWALLD )) && active+=("firewalld")
    count=${#active[@]}

    if (( count > 1 )); then
        log_error "More than one host firewall is active: $(join_by ', ' "${active[@]}")."
        if (( HAVE_NFT && HAVE_UFW )); then
            log_error "This is the known Server-Setup conflict: its firewall step enables ufw on hosts that already filter with an nftables table."
            log_error "Decide which one is authoritative and disable the other (for an nftables host: 'ufw disable', remove ufw, restart docker,"
            log_error "then confirm 'nft list tables' still shows inet ${NFT_TABLE}). Run Server-Setup with --skip-firewall on such hosts."
        fi
        die "Refusing to configure two firewalls. Nothing was changed."
    fi

    case "$FIREWALL" in
        auto)
            if (( count == 0 )); then
                die "No active host firewall found (nftables table inet ${NFT_TABLE}, ufw, or firewalld). Without one, web client ports 21118/21119 are reachable. Enable a firewall, or pass --firewall none if a firewall outside this host blocks them."
            fi
            (( HAVE_NFT )) && BACKEND="nft"
            (( HAVE_UFW )) && BACKEND="ufw"
            (( HAVE_FIREWALLD )) && BACKEND="firewalld"
            ;;
        nft)       (( HAVE_NFT )) || die "--firewall nft: table inet ${NFT_TABLE} does not exist."; BACKEND="nft" ;;
        ufw)       (( HAVE_UFW )) || die "--firewall ufw: ufw is not active."; BACKEND="ufw" ;;
        firewalld) (( HAVE_FIREWALLD )) || die "--firewall firewalld: firewalld is not running."; BACKEND="firewalld" ;;
        none)
            (( count == 0 )) || die "--firewall none, but ${active[0]} is active and would block RustDesk. Use --firewall auto."
            BACKEND="none"
            ;;
    esac
    log_info "Firewall backend: ${BACKEND}."
}

# ---------------------------------------------------------------------------
# nftables backend
# ---------------------------------------------------------------------------
# nft_rewrite_set FILE SET PORT... - prints FILE with PORTs merged into the
# single-line definition of SET. Only a line shaped like
#   set NAME { type inet_service; [elements = { ... }] }
# is edited; anything else (multi-line sets, flags) stops the run, because
# guessing at a firewall file is how hosts get locked out.
nft_rewrite_set() {
    local file="$1" set="$2"; shift 2
    local start_re="^[[:space:]]*set[[:space:]]+${set}[[:space:]]*\\{"
    local full_re="^([[:space:]]*set[[:space:]]+${set}[[:space:]]*\\{[[:space:]]*type[[:space:]]+inet_service[[:space:]]*;)(.*)\\}[[:space:]]*$"
    local elems_re='^[[:space:]]*elements[[:space:]]*=[[:space:]]*\{([^}]*)\}[[:space:]]*$'
    local count lineno line prefix middle elems=() raw e p found newline

    count="$(grep -cE "$start_re" "$file" || true)"
    [[ "$count" == "1" ]] || { log_error "${file}: expected exactly one 'set ${set}' line, found ${count}."; return 1; }
    lineno="$(grep -nE "$start_re" "$file" | cut -d: -f1)"
    line="$(sed -n "${lineno}p" "$file")"

    [[ "$line" =~ $full_re ]] || { log_error "${file}:${lineno}: 'set ${set}' is not a single-line inet_service set. Edit it by hand."; return 1; }
    prefix="${BASH_REMATCH[1]}"
    middle="${BASH_REMATCH[2]}"

    if [[ "$middle" =~ ^[[:space:]]*$ ]]; then
        raw=""
    elif [[ "$middle" =~ $elems_re ]]; then
        raw="${BASH_REMATCH[1]}"
    else
        log_error "${file}:${lineno}: unexpected content in 'set ${set}' (flags or other options). Edit it by hand."
        return 1
    fi

    local IFS=','
    for e in $raw; do
        e="${e//[[:space:]]/}"
        [[ -n "$e" ]] && elems+=("$e")
    done
    unset IFS

    local added=0
    for p in "$@"; do
        found=0
        for e in "${elems[@]}"; do [[ "$e" == "$p" ]] && { found=1; break; }; done
        (( found )) || { elems+=("$p"); added=1; }
    done

    if (( added )); then
        newline="${prefix}  elements = { $(join_by ', ' "${elems[@]}") } }"
        awk -v n="$lineno" -v l="$newline" 'NR == n { print l; next } { print }' "$file"
    else
        cat "$file"
    fi
}

NFT_NEW_FILE=""

nft_prepare() {
    [[ -f "$NFT_FILE" ]] || die "nftables backend: persist file ${NFT_FILE} not found (set RD_NFT_FILE)."
    local tmp1
    [[ -n "$NFT_NEW_FILE" ]] && rm -f "$NFT_NEW_FILE"
    tmp1="$(mktemp)"; NFT_NEW_FILE="$(mktemp)"
    nft_rewrite_set "$NFT_FILE" "$NFT_TCP_SET" "${OPEN_TCP[@]}" > "$tmp1" || { rm -f "$tmp1"; die "Cannot safely edit ${NFT_FILE}. Nothing was changed."; }
    nft_rewrite_set "$tmp1" "$NFT_UDP_SET" "${OPEN_UDP[@]}" > "$NFT_NEW_FILE" || { rm -f "$tmp1"; die "Cannot safely edit ${NFT_FILE}. Nothing was changed."; }
    rm -f "$tmp1"
    nft -c -f "$NFT_NEW_FILE" || die "The edited ruleset fails 'nft -c'. Nothing was changed."
}

nft_live_has() { nft get element inet "$NFT_TABLE" "$1" "{ $2 }" >/dev/null 2>&1; }

nft_plan() {
    nft_prepare
    if cmp -s "$NFT_FILE" "$NFT_NEW_FILE"; then
        echo "  - ${NFT_FILE}: already lists the RustDesk ports"
    else
        echo "  - ${NFT_FILE}: edit only the ${NFT_TCP_SET} and ${NFT_UDP_SET} lines (dated backup kept):"
        diff -u "$NFT_FILE" "$NFT_NEW_FILE" | sed -n '3,$p' | grep -E '^[-+]' | sed 's/^/        /' || true
    fi
    local p missing=()
    for p in "${OPEN_TCP[@]}"; do nft_live_has "$NFT_TCP_SET" "$p" || missing+=("${p}/tcp"); done
    for p in "${OPEN_UDP[@]}"; do nft_live_has "$NFT_UDP_SET" "$p" || missing+=("${p}/udp"); done
    if (( ${#missing[@]} )); then
        echo "  - live ruleset: add ${missing[*]}"
    else
        echo "  - live ruleset: already allows the RustDesk ports"
    fi
}

nft_apply() {
    nft_prepare
    local p
    for p in "${OPEN_TCP[@]}"; do
        nft_live_has "$NFT_TCP_SET" "$p" || { nft add element inet "$NFT_TABLE" "$NFT_TCP_SET" "{ $p }"; changed "nft live: ${NFT_TCP_SET} += ${p}"; }
    done
    for p in "${OPEN_UDP[@]}"; do
        nft_live_has "$NFT_UDP_SET" "$p" || { nft add element inet "$NFT_TABLE" "$NFT_UDP_SET" "{ $p }"; changed "nft live: ${NFT_UDP_SET} += ${p}"; }
    done
    if ! cmp -s "$NFT_FILE" "$NFT_NEW_FILE"; then
        local bak
        bak="${NFT_FILE}.bak-$(ts_file)"
        cp -p "$NFT_FILE" "$bak"
        cat "$NFT_NEW_FILE" > "$NFT_FILE"   # keeps the file's owner and mode
        changed "${NFT_FILE} updated (backup: ${bak})"
    fi
    rm -f "$NFT_NEW_FILE"; NFT_NEW_FILE=""
}

nft_verify() {
    local p table
    for p in "${OPEN_TCP[@]}"; do
        check "nft live allows ${p}/tcp" "nft live does not allow ${p}/tcp" nft_live_has "$NFT_TCP_SET" "$p"
    done
    for p in "${OPEN_UDP[@]}"; do
        check "nft live allows ${p}/udp" "nft live does not allow ${p}/udp" nft_live_has "$NFT_UDP_SET" "$p"
    done
    table="$(nft list table inet "$NFT_TABLE" 2>/dev/null || true)"
    for p in "${CLOSED_PORTS[@]}"; do
        if grep -qw "$p" <<<"$table"; then check_fail "nft table ${NFT_TABLE} mentions port ${p} (must stay closed)"
        else check_pass "nft table does not open ${p}"; fi
    done
    if nft list chain inet "$NFT_TABLE" "$NFT_CHAIN" 2>/dev/null | grep -q 'policy drop'; then
        check_pass "nft chain ${NFT_CHAIN} policy is drop"
    else
        check_fail "nft chain ${NFT_TABLE}/${NFT_CHAIN} is missing or its policy is not drop"
    fi
    # The persisted file must match the live sets, or a reboot undoes this.
    local tmp
    tmp="$(mktemp)"
    if nft_rewrite_set "$NFT_FILE" "$NFT_TCP_SET" "${OPEN_TCP[@]}" > "$tmp" 2>/dev/null && cmp -s "$tmp" "$NFT_FILE" \
       && nft_rewrite_set "$NFT_FILE" "$NFT_UDP_SET" "${OPEN_UDP[@]}" > "$tmp" 2>/dev/null && cmp -s "$tmp" "$NFT_FILE"; then
        check_pass "${NFT_FILE} persists the RustDesk ports"
    else
        check_fail "${NFT_FILE} does not persist the RustDesk ports (a reboot would close them)"
    fi
    rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# ufw backend
# ---------------------------------------------------------------------------
UFW_TCP_RULE="21115:21117/tcp"
UFW_UDP_RULE="21116/udp"

ufw_has() { ufw status 2>/dev/null | grep -qE "^${1}[[:space:]]+ALLOW"; }

ufw_plan() {
    ufw_has "$UFW_TCP_RULE" && echo "  - ufw: ${UFW_TCP_RULE} already allowed" || echo "  - ufw: allow ${UFW_TCP_RULE} (comment RustDesk)"
    ufw_has "$UFW_UDP_RULE" && echo "  - ufw: ${UFW_UDP_RULE} already allowed" || echo "  - ufw: allow ${UFW_UDP_RULE} (comment RustDesk)"
}

ufw_apply() {
    ufw_has "$UFW_TCP_RULE" || { ufw allow "$UFW_TCP_RULE" comment 'RustDesk hbbs/hbbr' >/dev/null; changed "ufw allow ${UFW_TCP_RULE}"; }
    ufw_has "$UFW_UDP_RULE" || { ufw allow "$UFW_UDP_RULE" comment 'RustDesk hbbs' >/dev/null; changed "ufw allow ${UFW_UDP_RULE}"; }
}

ufw_verify() {
    check "ufw allows ${UFW_TCP_RULE}" "ufw does not allow ${UFW_TCP_RULE}" ufw_has "$UFW_TCP_RULE"
    check "ufw allows ${UFW_UDP_RULE}" "ufw does not allow ${UFW_UDP_RULE}" ufw_has "$UFW_UDP_RULE"
    local p status
    status="$(ufw status verbose 2>/dev/null || true)"
    for p in "${CLOSED_PORTS[@]}"; do
        if grep -E 'ALLOW' <<<"$status" | grep -qw "$p"; then check_fail "ufw allows port ${p} (must stay closed)"
        else check_pass "ufw does not open ${p}"; fi
    done
    check "ufw default incoming policy is deny/reject" "ufw default incoming policy is not deny/reject" \
        grep -qE 'Default: (deny|reject) \(incoming\)' <<<"$status"
}

# ---------------------------------------------------------------------------
# firewalld backend: a "rustdesk" service definition added to one zone
# ---------------------------------------------------------------------------
fwd_zone() {
    if [[ -n "$FIREWALLD_ZONE" ]]; then echo "$FIREWALLD_ZONE"; else firewall-cmd --get-default-zone; fi
}

fwd_plan() {
    local z; z="$(fwd_zone)"
    if firewall-cmd --zone="$z" --query-service=rustdesk >/dev/null 2>&1; then
        echo "  - firewalld: service rustdesk already enabled in zone ${z}"
    else
        echo "  - firewalld: define service rustdesk (21115-21117/tcp, 21116/udp) and enable it in zone ${z} (permanent + runtime)"
    fi
}

fwd_apply() {
    local z; z="$(fwd_zone)"
    if ! firewall-cmd --permanent --info-service=rustdesk >/dev/null 2>&1; then
        firewall-cmd --permanent --new-service=rustdesk >/dev/null
        firewall-cmd --permanent --service=rustdesk --set-description="RustDesk OSS server: hbbs 21115-21116, hbbr 21117. Web ports 21118/21119 deliberately excluded." >/dev/null
        changed "firewalld service rustdesk defined"
    fi
    firewall-cmd --permanent --service=rustdesk --add-port=21115-21117/tcp >/dev/null 2>&1 || true
    firewall-cmd --permanent --service=rustdesk --add-port=21116/udp >/dev/null 2>&1 || true
    if ! firewall-cmd --permanent --zone="$z" --query-service=rustdesk >/dev/null 2>&1; then
        firewall-cmd --permanent --zone="$z" --add-service=rustdesk >/dev/null
        changed "firewalld zone ${z}: service rustdesk enabled"
    fi
    if ! firewall-cmd --zone="$z" --query-service=rustdesk >/dev/null 2>&1; then
        firewall-cmd --reload >/dev/null
        changed "firewalld reloaded"
    fi
}

fwd_verify() {
    local z all p ports; z="$(fwd_zone)"
    check "firewalld zone ${z} has service rustdesk" "firewalld zone ${z} does not have service rustdesk" \
        firewall-cmd --zone="$z" --query-service=rustdesk
    ports="$(firewall-cmd --info-service=rustdesk 2>/dev/null | awk -F': ' '/^ *ports:/ {print $2}' | tr ' ' '\n' | sort | tr '\n' ' ')"
    check "firewalld service rustdesk ports are exactly 21115-21117/tcp 21116/udp" \
        "firewalld service rustdesk ports are '${ports}', expected 21115-21117/tcp 21116/udp" \
        test "$ports" = "21115-21117/tcp 21116/udp "
    all="$(firewall-cmd --zone="$z" --list-ports 2>/dev/null || true)"
    for p in "${CLOSED_PORTS[@]}"; do
        if grep -qw "$p" <<<"$all"; then check_fail "firewalld zone ${z} opens port ${p} (must stay closed)"
        else check_pass "firewalld zone ${z} does not open ${p}"; fi
    done
    check "firewalld zone ${z} target is not ACCEPT" "firewalld zone ${z} target is ACCEPT (everything is open)" \
        test "$(firewall-cmd --permanent --zone="$z" --get-target 2>/dev/null)" != "ACCEPT"
}

firewall_plan() {
    case "$BACKEND" in
        nft) nft_plan ;; ufw) ufw_plan ;; firewalld) fwd_plan ;;
        none) echo "  - firewall: not managed (--firewall none)" ;;
    esac
}

firewall_apply() {
    case "$BACKEND" in
        nft) nft_apply ;; ufw) ufw_apply ;; firewalld) fwd_apply ;;
        none) flag "Host firewall not managed (--firewall none). Confirm that only 21115-21117/tcp and 21116/udp are reachable from outside, and that 21118/21119 are blocked." ;;
    esac
}

firewall_verify() {
    case "$BACKEND" in
        nft) nft_verify ;; ufw) ufw_verify ;; firewalld) fwd_verify ;;
        none) log_warn "Firewall checks skipped (--firewall none)." ;;
    esac
}

# ---------------------------------------------------------------------------
# Image handling
# ---------------------------------------------------------------------------
# resolve_image - makes sure IMAGE_REPO@DIGEST is present locally and sets
# IMAGE_REF. With no digest given, pulls the tag and records its digest.
resolve_image() {
    if [[ -n "$DIGEST" ]]; then
        if ! docker image inspect "${IMAGE_REPO}@${DIGEST}" >/dev/null 2>&1; then
            log_info "Pulling ${IMAGE_REPO}@${DIGEST} (tag ${VERSION_TAG})..."
            docker pull -q "${IMAGE_REPO}@${DIGEST}" >/dev/null || die "Could not pull ${IMAGE_REPO}@${DIGEST}."
        fi
    else
        log_info "Pulling ${IMAGE_REPO}:${VERSION_TAG} to record its digest..."
        docker pull -q "${IMAGE_REPO}:${VERSION_TAG}" >/dev/null || die "Could not pull ${IMAGE_REPO}:${VERSION_TAG}. Check the tag exists."
        DIGEST="$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "${IMAGE_REPO}:${VERSION_TAG}" \
                  | grep -E "(^|/)${IMAGE_REPO}@sha256:" | head -n1 | sed 's/.*@//' || true)"
        validate_digest "$DIGEST"
        [[ -n "$DIGEST" ]] || die "Pulled ${IMAGE_REPO}:${VERSION_TAG} but could not read its digest."
        flag "Image digest recorded on first use: ${DIGEST}. Confirm it matches tag ${VERSION_TAG} on Docker Hub, then pass --digest on other hosts."
    fi
    IMAGE_REF="${IMAGE_REPO}:${VERSION_TAG}@${DIGEST}"
    PINNED="${IMAGE_REPO}@${DIGEST}"
}

# check_key_flag - both binaries in the pinned image must support -k.
check_key_flag() {
    local bin help
    for bin in hbbs hbbr; do
        help="$(docker run --rm --pull never --network none "$PINNED" "$bin" --help 2>&1 || true)"
        grep -qE -- '-k, --key' <<<"$help" \
            || die "${bin} in ${IMAGE_REF} does not list '-k, --key' in --help. Key enforcement cannot be confirmed for this tag; refusing to deploy."
    done
    log_info "hbbs and hbbr in ${VERSION_TAG} both support -k (key enforcement)."
}

image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------
render_env() {
    local old="${INSTALL_DIR}/.env" kept=""
    [[ -f "$old" ]] && kept="$(grep -E "^[[:space:]]*#?[[:space:]]*(${OPTIONAL_ENV_KEYS})=" "$old" || true)"
    cat <<EOF
# .env - RustDesk server settings, written by ${SCRIPT_NAME}.
# Mode 600, root owned. Change versions with "upgrade", not by hand.
RD_VERSION=${VERSION_TAG}
RD_DIGEST=${DIGEST}
RD_RELAY_HOST=${RELAY_HOST}

# Optional hbbr bandwidth limits in Mb/s (kept when this file is rewritten).
EOF
    if [[ -n "$kept" ]]; then
        printf '%s\n' "$kept"
    else
        printf '#TOTAL_BANDWIDTH=1024\n#SINGLE_BANDWIDTH=128\n#LIMIT_SPEED=32\n'
    fi
}

write_files() {
    local rc
    install -d -o root -g root -m 755 "$INSTALL_DIR"
    if [[ ! -d "${INSTALL_DIR}/data" ]]; then
        install -d -o root -g root -m 700 "${INSTALL_DIR}/data"
        changed "${INSTALL_DIR}/data created"
    fi
    chmod 700 "${INSTALL_DIR}/data"

    rc=0; write_if_changed "${INSTALL_DIR}/compose.yaml" 644 < "${TEMPLATE_DIR}/compose.yaml" || rc=$?
    case "$rc" in 0) changed "${INSTALL_DIR}/compose.yaml written" ;; 10) ;; *) die "Could not write compose.yaml." ;; esac

    rc=0; write_if_changed "${INSTALL_DIR}/.env.example" 644 < "${TEMPLATE_DIR}/env.example" || rc=$?
    case "$rc" in 0) changed "${INSTALL_DIR}/.env.example written" ;; 10) ;; *) die "Could not write .env.example." ;; esac

    rc=0; render_env | write_if_changed "${INSTALL_DIR}/.env" 600 || rc=$?
    case "$rc" in 0) changed "${INSTALL_DIR}/.env written (RD_VERSION=${VERSION_TAG})" ;; 10) ;; *) die "Could not write .env." ;; esac

    dc config -q || die "docker compose rejects the generated configuration."
}

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
key_files_exist() { [[ -s "${INSTALL_DIR}/data/id_ed25519" && -s "${INSTALL_DIR}/data/id_ed25519.pub" ]]; }

deploy() {
    local before_hbbs before_hbbr
    before_hbbs="$(docker container inspect -f '{{.Id}}' hbbs 2>/dev/null || true)"
    before_hbbr="$(docker container inspect -f '{{.Id}}' hbbr 2>/dev/null || true)"

    # resolve_image already pulled the pinned image, so no "compose pull":
    # re-runs then work without reaching the registry.
    if ! key_files_exist; then
        log_info "No key yet: starting hbbs alone so it generates the key before hbbr starts."
        dc up -d hbbs
        wait_until "$WAIT_SECS" "hbbs to write data/id_ed25519" key_files_exist \
            || die "hbbs did not create data/id_ed25519 within ${WAIT_SECS}s. Check: docker logs hbbs"
        changed "Server key pair generated in ${INSTALL_DIR}/data"
    fi
    dc up -d

    [[ "$(docker container inspect -f '{{.Id}}' hbbs 2>/dev/null)" == "$before_hbbs" ]] || changed "hbbs container (re)created"
    [[ "$(docker container inspect -f '{{.Id}}' hbbr 2>/dev/null)" == "$before_hbbr" ]] || changed "hbbr container (re)created"

    chmod 600 "${INSTALL_DIR}/data/id_ed25519"
    chmod 644 "${INSTALL_DIR}/data/id_ed25519.pub"
}

# ---------------------------------------------------------------------------
# Verify. STRICT=1 (install/upgrade) also requires the key log lines.
# ---------------------------------------------------------------------------
logged_key() { { docker logs "$1" 2>&1 | grep -oE 'Key: [A-Za-z0-9+/=]+' | tail -n1 | sed 's/^Key: //'; } || true; }

both_keys_logged() { [[ -n "$(logged_key hbbs)" && -n "$(logged_key hbbr)" ]]; }

all_ports_listening() {
    local p
    for p in "${OPEN_TCP[@]}"; do is_listening tcp "$p" || return 1; done
    for p in "${OPEN_UDP[@]}"; do is_listening udp "$p" || return 1; done
}

verify_all() {
    local strict="$1" n want cmd pub k p
    FAILED_CHECKS=()
    log_info "Verifying..."

    want="$(image_id "${IMAGE_REPO}@${DIGEST}")"
    for n in hbbs hbbr; do
        if [[ "$(docker container inspect -f '{{.State.Running}}' "$n" 2>/dev/null)" == "true" ]]; then
            check_pass "container ${n} running"
        else
            check_fail "container ${n} not running"; continue
        fi
        if [[ -n "$want" && "$(docker container inspect -f '{{.Image}}' "$n")" == "$want" ]]; then
            check_pass "${n} runs ${VERSION_TAG} (${DIGEST:0:19}...)"
        else
            check_fail "${n} is not running the pinned image ${IMAGE_REF}"
        fi
        cmd="$(docker container inspect -f '{{json .Config.Cmd}}' "$n")"
        if [[ "$cmd" == *'"-k","_"'* ]]; then check_pass "${n} started with -k _"
        else check_fail "${n} was not started with -k _ (cmd: ${cmd})"; fi
    done

    wait_until "$WAIT_SECS" "RustDesk ports to listen" all_ports_listening || true
    for p in "${OPEN_TCP[@]}"; do
        check "listening ${p}/tcp ($(listener_procs tcp "$p" | tr '\n' ' '))" "nothing listening on ${p}/tcp" is_listening tcp "$p"
    done
    for p in "${OPEN_UDP[@]}"; do
        check "listening ${p}/udp ($(listener_procs udp "$p" | tr '\n' ' '))" "nothing listening on ${p}/udp" is_listening udp "$p"
    done

    if key_files_exist; then
        pub="$(tr -d '[:space:]' < "${INSTALL_DIR}/data/id_ed25519.pub")"
        check "private key mode 600" "private key ${INSTALL_DIR}/data/id_ed25519 is not mode 600" \
            test "$(stat -c '%a' "${INSTALL_DIR}/data/id_ed25519")" = "600"
        (( strict )) && { wait_until "$WAIT_SECS" "hbbs and hbbr to log their key" both_keys_logged || true; }
        for n in hbbs hbbr; do
            k="$(logged_key "$n")"
            if [[ -z "$k" ]]; then
                if (( strict )); then check_fail "${n} has not logged a key: enforcement is not confirmed"
                else log_warn "NOTE  ${n} key log line not found (logs may have rotated); relying on the -k _ check above."; fi
            elif [[ "$k" == "$pub" ]]; then
                check_pass "${n} enforces the server key (matches id_ed25519.pub)"
            else
                check_fail "${n} logged a different key than id_ed25519.pub: clients would be refused or unverified"
            fi
        done
    else
        check_fail "key files missing in ${INSTALL_DIR}/data"
    fi

    firewall_verify

    if (( ${#FAILED_CHECKS[@]} )); then
        log_error "${#FAILED_CHECKS[@]} check(s) failed."
        return 1
    fi
    log_info "All checks passed."
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
print_report() {
    local pub=""
    key_files_exist && pub="$(tr -d '[:space:]' < "${INSTALL_DIR}/data/id_ed25519.pub")"
    echo
    log_info "==================== RustDesk Server Summary ===================="
    echo "  Mode:           ${MODE}"
    echo "  Relay host:     ${RELAY_HOST}  (ID server and relay server in clients)"
    echo "  Public key:     ${pub:-<missing>}"
    echo "  Version:        ${VERSION_TAG}"
    echo "  Image:          ${IMAGE_REF}"
    echo "  Firewall:       ${BACKEND}"
    echo "  Key enforced:   hbbs and hbbr (-k _)"
    echo "  Install dir:    ${INSTALL_DIR}"
    echo "  Private key:    ${INSTALL_DIR}/data/id_ed25519 (mode 600, never printed)."
    echo "                  BACK IT UP OFF THIS HOST. Losing it means re-configuring every client."
    [[ -n "$ROLLBACK_NOTE" ]] && echo "  Rollback:       ${ROLLBACK_NOTE}"
    if [[ "$MODE" != "status" ]]; then
        if (( ${#CHANGES[@]} )); then
            echo "  Changes:        ${#CHANGES[@]}"
            printf '                  - %s\n' "${CHANGES[@]}"
        else
            echo "  Changes:        none (already in the desired state)"
        fi
    fi
    if (( ${#FLAGGED_ITEMS[@]} )); then
        log_warn "FLAGGED FOR REVIEW:"
        printf '    - %s\n' "${FLAGGED_ITEMS[@]}" >&2
    fi
    [[ -n "$RUN_LOG" ]] && echo "  Log:            ${RUN_LOG}"
    echo "  Finished:       $(ts_log)"
}

finish() {
    print_report
    if (( ${#FLAGGED_ITEMS[@]} )); then exit 3; fi
    exit 0
}

confirm_or_exit() {
    (( ASSUME_YES == 1 )) && return 0
    [[ -t 0 ]] || die "No terminal to confirm on. Re-run with --yes for an unattended run."
    confirm "Proceed?" n || { log_warn "Cancelled. Nothing was changed."; exit 1; }
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
load_existing() {
    local envf="${INSTALL_DIR}/.env"
    EXISTING_VERSION="$(env_get "$envf" RD_VERSION)"
    EXISTING_DIGEST="$(env_get "$envf" RD_DIGEST)"
    EXISTING_HOST="$(env_get "$envf" RD_RELAY_HOST)"
}

mode_install() {
    load_existing
    if [[ -n "$EXISTING_VERSION" ]]; then
        log_info "Existing install found: ${EXISTING_VERSION} for ${EXISTING_HOST}."
        [[ -n "$VERSION_TAG" ]] || VERSION_TAG="$EXISTING_VERSION"
        [[ -n "$RELAY_HOST" ]] || RELAY_HOST="$EXISTING_HOST"
        [[ "$VERSION_TAG" == "$EXISTING_VERSION" ]] \
            || die "Installed version is ${EXISTING_VERSION}; --version ${VERSION_TAG} differs. Use: ${SCRIPT_NAME} upgrade --version ${VERSION_TAG}"
        if [[ -z "$DIGEST" ]]; then
            DIGEST="$EXISTING_DIGEST"
        elif [[ -n "$EXISTING_DIGEST" && "$DIGEST" != "$EXISTING_DIGEST" ]]; then
            die "--digest differs from the recorded digest for ${VERSION_TAG} (${EXISTING_DIGEST}). The tag may have been re-pushed; investigate before changing it."
        fi
    fi
    validate_tag "$VERSION_TAG"
    validate_host "$RELAY_HOST"
    validate_digest "$DIGEST"

    preflight_container_names
    preflight_ports
    check_dns
    detect_firewalls

    echo
    log_info "Plan (install ${VERSION_TAG} for ${RELAY_HOST} in ${INSTALL_DIR}):"
    echo "  - image: ${IMAGE_REPO}:${VERSION_TAG}@${DIGEST:-<digest recorded at pull>}"
    echo "  - confirm hbbs and hbbr in that image support -k"
    firewall_plan
    echo "  - write compose.yaml, .env (600), .env.example in ${INSTALL_DIR} (only if changed)"
    echo "  - docker compose up -d (hbbs first if no key exists yet)"
    echo "  - verify containers, ports, key enforcement, firewall"
    if (( DRY_RUN )); then
        log_info "Dry run: nothing was changed."
        exit 0
    fi
    confirm_or_exit

    resolve_image
    check_key_flag
    firewall_apply
    write_files
    deploy
    verify_all 1 || { print_report; die "Verification failed. The install is in place but not trustworthy; fix the failed checks above."; }
    finish
}

mode_status() {
    [[ -f "${INSTALL_DIR}/.env" ]] || die "No install found at ${INSTALL_DIR} (missing .env)."
    load_existing
    VERSION_TAG="$EXISTING_VERSION"; DIGEST="$EXISTING_DIGEST"; RELAY_HOST="$EXISTING_HOST"
    IMAGE_REF="${IMAGE_REPO}:${VERSION_TAG}@${DIGEST}"; PINNED="${IMAGE_REPO}@${DIGEST}"
    check_dns
    detect_firewalls
    verify_all 0 || { print_report; exit 1; }
    finish
}

backup_data() {
    local dest_dir="${INSTALL_DIR}/backups" f
    install -d -o root -g root -m 700 "$dest_dir"
    f="${dest_dir}/data-$(ts_file)-${EXISTING_VERSION}.tar.gz"
    ( umask 077; tar -C "$INSTALL_DIR" -czf "$f" data )
    echo "$f"
}

rollback() {
    local backup="$1" old_env="$2"
    log_warn "Rolling back to ${EXISTING_VERSION}..."
    dc stop || true
    local failed_dir
    failed_dir="${INSTALL_DIR}/data.failed-$(ts_file)"
    mv "${INSTALL_DIR}/data" "$failed_dir"
    tar -C "$INSTALL_DIR" -xzf "$backup"
    install -o root -g root -m 600 "$old_env" "${INSTALL_DIR}/.env"
    VERSION_TAG="$EXISTING_VERSION"; DIGEST="$EXISTING_DIGEST"
    IMAGE_REF="${IMAGE_REPO}:${VERSION_TAG}@${DIGEST}"; PINNED="${IMAGE_REPO}@${DIGEST}"
    dc up -d
    if verify_all 1; then
        ROLLBACK_NOTE="upgrade failed; restored ${EXISTING_VERSION} and its data. Failed data kept in ${failed_dir}."
    else
        ROLLBACK_NOTE="upgrade failed AND the rollback did not verify. Investigate now. Backup: ${backup}"
    fi
}

mode_upgrade() {
    [[ -f "${INSTALL_DIR}/.env" ]] || die "No install found at ${INSTALL_DIR}. Run install first."
    load_existing
    [[ -n "$EXISTING_VERSION" && -n "$EXISTING_DIGEST" ]] || die "${INSTALL_DIR}/.env lacks RD_VERSION or RD_DIGEST."
    validate_tag "$VERSION_TAG"
    validate_digest "$DIGEST"
    if [[ -n "$RELAY_HOST" && "$RELAY_HOST" != "$EXISTING_HOST" ]]; then
        die "upgrade does not change the relay host (installed: ${EXISTING_HOST}). Drop --relay-host."
    fi
    RELAY_HOST="$EXISTING_HOST"
    if [[ "$VERSION_TAG" == "$EXISTING_VERSION" && ( -z "$DIGEST" || "$DIGEST" == "$EXISTING_DIGEST" ) ]]; then
        log_info "Already at ${VERSION_TAG}. Nothing to upgrade; running status instead."
        mode_status
    fi
    detect_firewalls

    echo
    log_info "Plan (upgrade ${EXISTING_VERSION} -> ${VERSION_TAG} in ${INSTALL_DIR}):"
    echo "  - pull ${IMAGE_REPO}:${VERSION_TAG}${DIGEST:+@${DIGEST}} and confirm -k support (stop here if that fails)"
    echo "  - stop hbbs/hbbr, back up data/ to ${INSTALL_DIR}/backups/ (keys and database)"
    echo "  - update .env, up -d, verify"
    echo "  - on failure: restore data/ and .env, start ${EXISTING_VERSION} again, verify"
    if (( DRY_RUN )); then
        log_info "Dry run: nothing was changed."
        exit 0
    fi
    confirm_or_exit

    resolve_image      # a bad tag dies here, before anything changes
    check_key_flag

    local old_env backup
    old_env="$(mktemp)"
    cp -p "${INSTALL_DIR}/.env" "$old_env"
    dc stop
    backup="$(backup_data)"
    changed "data/ backed up to ${backup}"

    write_files
    # Run deploy + verify in a subshell as a plain command (not inside "if"
    # or "||", which would switch off set -e inside it), so any failure,
    # including a die, lands in rc and triggers the rollback.
    local rc
    set +e
    ( set -e; deploy; verify_all 1 )
    rc=$?
    set -e
    if (( rc == 0 )); then
        changed "upgraded ${EXISTING_VERSION} -> ${VERSION_TAG}"
        rm -f "$old_env"
        finish
    fi
    log_error "Upgrade to ${VERSION_TAG} failed (exit ${rc})."
    rollback "$backup" "$old_env"
    rm -f "$old_env"
    print_report
    exit 1
}

mode_print_client_config() {
    local envf="${INSTALL_DIR}/.env" pubf="${INSTALL_DIR}/data/id_ed25519.pub" host
    [[ -r "$envf" ]] || die "Cannot read ${envf} (run as root, or check --install-dir)."
    [[ -s "$pubf" ]] || die "No public key at ${pubf}. Is the server installed?"
    host="$(env_get "$envf" RD_RELAY_HOST)"
    cat <<EOF
RustDesk client settings (Settings > Network > ID/Relay server):
  ID server:     ${host}
  Relay server:  ${host}
  API server:    (leave blank; OSS server has no API)
  Key:           $(tr -d '[:space:]' < "$pubf")

The key above is the PUBLIC key. It is safe to give to clients. It proves
the server's identity; it is not a password.
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    validate_settings
    require_root

    if [[ "$MODE" == "print-client-config" ]]; then
        mode_print_client_config
        exit 0
    fi

    # Reject bad input before logging or touching anything. Missing values
    # may still come from an existing .env, so those are checked per mode,
    # except on a first install where there is nothing to fall back on.
    [[ -z "$VERSION_TAG" ]] || validate_tag "$VERSION_TAG"
    [[ -z "$RELAY_HOST" ]] || validate_host "$RELAY_HOST"
    validate_digest "$DIGEST"
    if [[ "$MODE" == "install" && ! -f "${INSTALL_DIR}/.env" ]]; then
        validate_host "$RELAY_HOST"
        validate_tag "$VERSION_TAG"
    fi
    [[ "$MODE" != "upgrade" ]] || validate_tag "$VERSION_TAG"

    trap on_exit EXIT
    trap 'fail_trap "$LINENO" "$?"' ERR
    (( DRY_RUN )) || start_logging
    preflight_tools

    case "$MODE" in
        install) mode_install ;;
        status)  mode_status ;;
        upgrade) mode_upgrade ;;
    esac
}

main "$@"
