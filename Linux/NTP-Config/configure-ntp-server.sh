#!/usr/bin/env bash
#
# configure-ntp-server.sh
# 2026-09-18
# Version: v1.6.0
#
# PURPOSE:
# Tool to view and configure a Linux host (Debian, Ubuntu, RHEL, or Fedora
# family) as a chrony-based NTP server, either from an interactive menu or
# unattended from the command line (for use by a larger provisioning
# script). Sets upstream time sources, which subnets may query this host for
# time, and optionally a stratum value so the host still serves reasonable
# time if upstream sources drop. Adding, removing, or replacing an allowed
# subnet automatically creates or revokes the matching firewall rule this
# script created for it, so allow-list and firewall state move together.
#
# Part of the MVTS-Corp/Scripts repo, under Linux/NTP-Config. When run from
# an install created by install.sh (normally /opt/ntp-config), the
# interactive mode checks GitHub for a newer version on every run and
# applies it before doing anything else. No git and no cron entries are
# used or required.
#
# Usage:
#   configure-ntp-server.sh                       interactive menu
#   configure-ntp-server.sh --status              print configuration, change nothing
#   configure-ntp-server.sh [SETTINGS] [OPTIONS]  unattended (never prompts)
#
#   SETTINGS (any combination; at least one selects unattended mode):
#     --sources VALUE   native | usa | preferred, or a comma/space separated
#                       list of hostnames or IPs
#     --allow CIDRS     comma/space separated list of subnets allowed to query
#                       this host, or "none". The list REPLACES the current
#                       one; matching firewall rules are added and removed
#                       to follow. Repeatable (values are combined).
#     --stratum N       local stratum lock, 0-15, or "none" to remove it
#   OPTIONS:
#     --no-firewall     do not create or revoke firewall rules
#     --unattended      never prompt (also -y, --yes); implied by SETTINGS
#     --update          check for a self-update even in unattended mode
#                       (off by default there, so the caller controls the
#                       version that runs)
#     --no-update       skip the self-update check (interactive mode)
#     -h, --help        show this text
#
#   Unattended runs are idempotent: repeating the same command changes
#   nothing and does not restart chrony. The last line printed is
#   "RESULT: changed" or "RESULT: unchanged".
#
#   Example:
#     sudo configure-ntp-server.sh --sources preferred --allow 192.168.1.0/24
#
# Exit codes:
#   0  success (changes applied, or nothing needed changing)
#   1  runtime failure (not root, unsupported OS, chrony would not start...)
#   2  invalid arguments; nothing on the system was touched
#
# CHANGELOG:
#   v1.6.0 - Self-update follows the ref saved by install.sh (a branch or a
#            tag) instead of a fixed branch. The default is the "stable"
#            channel, which only ever points at a tagged release; a host
#            installed with --ref <tag> is pinned and never moves. The
#            saved ref is validated before it is placed in a URL.
#   v1.5.0 - Added unattended mode (--sources, --allow, --stratum,
#            --no-firewall, --unattended) and --status so this tool can be
#            driven by a larger provisioning script: declarative and
#            idempotent, one config backup per run, no prompts, a final
#            RESULT line, and documented exit codes (0, 1, 2). Arguments
#            are fully validated before anything on the system is touched.
#            Self-update is off by default in unattended mode (--update
#            opts in). Fixed: on a host without chrony the "config file
#            must exist" check ran before the chrony install step, so the
#            automatic install was unreachable; it now runs after it. Apt
#            installs now also set NEEDRESTART_MODE and wait for the dpkg
#            lock instead of failing. The interactive menu now exits with an
#            error, instead of looping, if its input closes. Any unexpected
#            failure now exits 1. Example subnet changed to 192.168.1.0/24.
#   v1.4.0 - Moved from a self-hosted Git server to the public
#            MVTS-Corp/Scripts repo on GitHub. Self-update no longer needs
#            git: it fetches this one file over HTTPS, compares versions,
#            verifies the download (shebang and bash -n), then swaps it in
#            with a single atomic rename. A download is never applied if it
#            is not strictly newer than the running version. The TLS choice
#            made at install time is read from the install directory's
#            .ntp-config-state file.
#   v1.3.1 - Last version published from the previous self-hosted repo.

set -euo pipefail
# Disable pathname expansion globally: several places iterate an unquoted,
# space-separated list built from operator input (custom time sources,
# custom subnets), and without -f a token containing *?[ would silently
# glob-expand against the current directory instead of being taken as a
# literal hostname/CIDR. Nothing in this script relies on globbing -
# every bare '*' elsewhere is a case/[[ ]] pattern or a ${arr[*]} expansion,
# neither of which -f affects.
set -f

# --------------------------------------------------------------------------
# Globals
# --------------------------------------------------------------------------
SCRIPT_VERSION="v1.6.0"
SOURCES_TAG="NTP-SCRIPT-SOURCES"
ALLOW_TAG="NTP-SCRIPT-ALLOW"
STRATUM_TAG="NTP-SCRIPT-STRATUM"
SKIP_SELF_UPDATE="${SKIP_SELF_UPDATE:-0}"
LAST_BACKUP=""
BACKUP_TAKEN=0
# Set to 1 by the firewall helpers when they actually add or remove a rule,
# so an unattended run can report "changed" for firewall-only drift repairs.
FW_CHANGED=0

# Where self-update looks for a newer copy of this script. The ref (a branch
# or a tag) comes from the install state file, defaulting to the "stable"
# channel; RAW_BASE is filled in by self_update. The env override exists so
# the update path can be tested against a local file:// tree; it is not
# needed in normal use.
DEFAULT_REF="stable"
RAW_BASE_OVERRIDE="${NTP_CONFIG_RAW_BASE:-}"
RAW_BASE=""
REMOTE_SCRIPT_PATH="Linux/NTP-Config/configure-ntp-server.sh"

# Command-line state (see the Usage block in the header).
UNATTENDED=0
OPT_STATUS=0
OPT_UPDATE=0
OPT_NO_FIREWALL=0
OPT_SOURCES=""
OPT_SOURCES_SET=0
OPT_ALLOW=""
OPT_ALLOW_SET=0
OPT_STRATUM=""
OPT_STRATUM_SET=0
WANT_ALLOW=()

# --------------------------------------------------------------------------
# Input validators (pure functions, defined first so command-line arguments
# can be rejected before anything on the system is touched)
# --------------------------------------------------------------------------

# Restricts a custom time source to characters valid in a hostname or an
# IPv4/IPv6 literal. This is what keeps a stray '#' out of the managed
# block (which would otherwise be indistinguishable from a real "# BEGIN/
# # END" tag line and corrupt later remove_block/get_block_lines parsing)
# and rejects anything else that has no business in a chrony "server" line.
validate_source_token() {
    local tok="$1"
    [[ "${tok}" =~ ^[A-Za-z0-9.:-]+$ ]]
}

# A git ref (branch or tag) as it appears in the install state file.
valid_ref() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$1" != *..* && "$1" != */ ]]
}

validate_cidr() {
    local cidr="$1"
    local octet_re='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
    [[ "${cidr}" =~ ^${octet_re}\.${octet_re}\.${octet_re}\.${octet_re}/(3[0-2]|[12]?[0-9])$ ]]
}

# --------------------------------------------------------------------------
# Command-line parsing and validation
# --------------------------------------------------------------------------
usage() {
    sed -n '/^# Usage:/,/^# CHANGELOG:/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

usage_error() {
    echo "ERROR: $*" >&2
    echo "Run with --help for usage." >&2
    exit 2
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --unattended|--yes|-y) UNATTENDED=1; shift ;;
            --status) OPT_STATUS=1; shift ;;
            --update) OPT_UPDATE=1; shift ;;
            --no-update) SKIP_SELF_UPDATE=1; shift ;;
            --no-firewall) OPT_NO_FIREWALL=1; shift ;;
            --sources|--allow|--stratum)
                (( $# >= 2 )) || usage_error "$1 requires a value."
                case "$1" in
                    --sources) OPT_SOURCES="$2"; OPT_SOURCES_SET=1 ;;
                    --allow) OPT_ALLOW="${OPT_ALLOW:+${OPT_ALLOW},}$2"; OPT_ALLOW_SET=1 ;;
                    --stratum) OPT_STRATUM="$2"; OPT_STRATUM_SET=1 ;;
                esac
                shift 2
                ;;
            -h|--help) usage; exit 0 ;;
            *) usage_error "unknown argument '$1'." ;;
        esac
    done
}

validate_args() {
    local tok

    if (( OPT_SOURCES_SET == 1 )); then
        # An empty value (typically an unset shell variable in the caller)
        # must be an error, not "no setting": otherwise the run would fall
        # through to the interactive menu.
        [[ -n "${OPT_SOURCES//[[:space:],]/}" ]] || usage_error "--sources needs a value: native, usa, preferred, or a list of hostnames/IPs."
        case "${OPT_SOURCES}" in
            native|usa|preferred) ;;
            *)
                for tok in ${OPT_SOURCES//,/ }; do
                    validate_source_token "${tok}" || usage_error "--sources: '${tok}' is not native, usa, preferred, or a valid hostname/IP."
                done
                ;;
        esac
    fi

    if (( OPT_ALLOW_SET == 1 )); then
        local raw="${OPT_ALLOW//,/ }"
        raw="$(echo ${raw})"
        if [[ "${raw}" == "none" ]]; then
            WANT_ALLOW=()
        else
            local seen=" "
            for tok in ${raw}; do
                [[ "${tok}" == "none" ]] && usage_error "--allow: \"none\" cannot be combined with subnets."
                validate_cidr "${tok}" || usage_error "--allow: '${tok}' is not a valid CIDR (expected A.B.C.D/nn, e.g. 192.168.1.0/24)."
                # Repeats are collapsed so the same subnet can never be
                # written twice into the managed block.
                if [[ "${seen}" != *" ${tok} "* ]]; then
                    WANT_ALLOW+=("${tok}")
                    seen+="${tok} "
                fi
            done
            (( ${#WANT_ALLOW[@]} > 0 )) || usage_error "--allow needs at least one subnet, or \"none\"."
        fi
    fi

    if (( OPT_STRATUM_SET == 1 )); then
        [[ "${OPT_STRATUM}" == "none" || "${OPT_STRATUM}" =~ ^([0-9]|1[0-5])$ ]] || usage_error "--stratum must be a whole number from 0 to 15, or \"none\"."
    fi

    # Settings on the command line ARE the answers, so they imply unattended.
    local has_settings=0
    if (( OPT_SOURCES_SET == 1 || OPT_ALLOW_SET == 1 || OPT_STRATUM_SET == 1 )); then
        has_settings=1
        UNATTENDED=1
    fi
    if (( OPT_STATUS == 1 && has_settings == 1 )); then
        usage_error "--status only reports; it cannot be combined with --sources, --allow, or --stratum."
    fi
    if (( UNATTENDED == 1 && OPT_STATUS == 0 && has_settings == 0 )); then
        usage_error "--unattended needs at least one of --sources, --allow, --stratum (or use --status)."
    fi
    if (( OPT_NO_FIREWALL == 1 && OPT_ALLOW_SET == 0 )); then
        usage_error "--no-firewall only applies together with --allow."
    fi

    # The caller controls which version runs when it drives this tool, so an
    # unattended run does not swap in a newer copy of itself mid-provision
    # unless --update asks for it.
    if (( UNATTENDED == 1 || OPT_STATUS == 1 )) && (( OPT_UPDATE == 0 )); then
        SKIP_SELF_UPDATE=1
    fi
}

parse_args "$@"
validate_args

# --------------------------------------------------------------------------
# Failure trap
# --------------------------------------------------------------------------
fail_trap() {
    # A backup-then-edit sequence (e.g. remove_block then insert_block) is
    # not atomic, so a mid-sequence failure can leave the config file
    # partially edited. Only claim "no changes" when that is actually true
    # (no backup has been taken yet this run); otherwise point at the
    # backup taken just before the change that was in progress.
    if [[ -n "${LAST_BACKUP:-}" ]]; then
        echo "ERROR: script failed at line $1. ${CHRONY_CONF:-the config file} may be partially edited - restore from ${LAST_BACKUP} if it looks wrong." >&2
    else
        echo "ERROR: script failed at line $1. No config changes had been made yet." >&2
    fi
    # Normalize to exit 1 so a caller sees the documented code, not whatever
    # status the failing command happened to return (127, 141, ...).
    exit 1
}
trap 'fail_trap "$LINENO"' ERR

# --------------------------------------------------------------------------
# Root check
# --------------------------------------------------------------------------
if [[ ${EUID} -ne 0 ]]; then
    echo "ERROR: this script must be run as root (sudo)." >&2
    exit 1
fi

# --------------------------------------------------------------------------
# Self-update from GitHub (no git, no cron - runs inline on every invocation)
#
# Flow: fetch the published copy of this one file, read its SCRIPT_VERSION,
# and only if that is strictly newer than the running version, verify it
# and swap it in. Every failure path (network, bad download, syntax error,
# older version) falls back to "keep running the current version" - a
# broken update source must never stop an operator from using the tool.
# --------------------------------------------------------------------------

# Reads one KEY=value line from the install state file. Only the exact key
# asked for is returned, and the file is never sourced, so a malformed or
# tampered state file cannot execute anything.
state_value() {
    local file="$1" key="$2"
    awk -F= -v k="${key}" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "${file}"
}

# Returns 10 if an update was applied, 0 for every other outcome (already
# current, unreachable, rejected). The caller owns cleanup of $tmp.
try_self_update_apply() {
    local real_path="$1" tmp="$2"
    shift 2
    local url="${RAW_BASE}/${REMOTE_SCRIPT_PATH}"

    if ! curl -fsSL --connect-timeout 10 --max-time 30 "$@" -o "${tmp}" "${url}" 2>/dev/null; then
        echo "NOTE: could not reach the update source to check for updates. Continuing with current version." >&2
        return 0
    fi

    # A captive portal or proxy error page can come back as HTTP 200, so the
    # download has to look like this script before anything else is trusted.
    if [[ "$(sed -n '1p' "${tmp}")" != "#!/usr/bin/env bash" ]]; then
        echo "WARNING: downloaded update does not look like a bash script. Continuing with current version." >&2
        return 0
    fi

    local remote_version
    remote_version="$(sed -n 's/^SCRIPT_VERSION="\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)"$/\1/p' "${tmp}" | sed -n '1p')"
    if [[ -z "${remote_version}" ]]; then
        echo "WARNING: could not read a version from the downloaded script. Continuing with current version." >&2
        return 0
    fi
    if [[ "${remote_version}" == "${SCRIPT_VERSION}" ]]; then
        return 0
    fi

    local newest
    newest="$(printf '%s\n%s\n' "${SCRIPT_VERSION#v}" "${remote_version#v}" | sort -V | sed -n '$p')"
    if [[ "${newest}" != "${remote_version#v}" ]]; then
        echo "WARNING: published version (${remote_version}) is older than the running version (${SCRIPT_VERSION}). Skipping to avoid a silent downgrade." >&2
        return 0
    fi

    echo "Update available for ntp-config (${SCRIPT_VERSION} -> ${remote_version}). Verifying before applying..."
    if ! bash -n "${tmp}"; then
        echo "WARNING: downloaded update failed a syntax check. Continuing with current version." >&2
        return 0
    fi

    # tmp lives in the same directory as real_path, so this rename is atomic
    # and never leaves a half-written script behind. The running shell keeps
    # its already-open copy of the old file.
    chmod 0755 "${tmp}"
    mv -f "${tmp}" "${real_path}"
    return 10
}

self_update() {
    if [[ "${SKIP_SELF_UPDATE}" == "1" ]]; then
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        return 0
    fi

    local real_path install_dir state_file
    real_path="$(readlink -f "${BASH_SOURCE[0]}")"
    install_dir="$(dirname "${real_path}")"
    state_file="${install_dir}/.ntp-config-state"
    if [[ ! -f "${state_file}" ]]; then
        # Not running from an install.sh-managed location (for example a
        # copy run straight out of a clone) - nothing to update in place.
        return 0
    fi

    local tls_mode ca_cert
    local curl_tls=()
    tls_mode="$(state_value "${state_file}" TLS_MODE)"
    ca_cert="$(state_value "${state_file}" CA_CERT)"

    # The ref becomes part of a URL, so it is checked before use. An install
    # from before refs existed has none saved and follows the default channel.
    local ref
    ref="$(state_value "${state_file}" REF)"
    ref="${ref:-${DEFAULT_REF}}"
    if ! valid_ref "${ref}"; then
        echo "WARNING: invalid REF '${ref}' in ${state_file}. Skipping update check." >&2
        return 0
    fi
    RAW_BASE="${RAW_BASE_OVERRIDE:-https://raw.githubusercontent.com/MVTS-Corp/Scripts/${ref}}"
    case "${tls_mode}" in
        ""|default) ;;
        insecure) curl_tls=(-k) ;;
        cacert)
            if [[ ! -f "${ca_cert}" ]]; then
                echo "WARNING: CA file '${ca_cert}' from the install state no longer exists. Skipping update check." >&2
                return 0
            fi
            curl_tls=(--cacert "${ca_cert}")
            ;;
        *)
            echo "WARNING: unrecognized TLS_MODE '${tls_mode}' in ${state_file}. Skipping update check." >&2
            return 0
            ;;
    esac

    local tmp rc=0
    tmp="$(mktemp "${install_dir}/.update.XXXXXX")" || return 0
    try_self_update_apply "${real_path}" "${tmp}" ${curl_tls[@]+"${curl_tls[@]}"} || rc=$?
    rm -f "${tmp}"

    if (( rc == 10 )); then
        echo "Update applied. Restarting with the new version..."
        exec "${real_path}" "$@"
    fi
    return 0
}
self_update "$@"

# --------------------------------------------------------------------------
# OS detection
# --------------------------------------------------------------------------
if [[ ! -f /etc/os-release ]]; then
    echo "ERROR: /etc/os-release not found. Cannot detect OS." >&2
    exit 1
fi
# shellcheck disable=SC1091
source /etc/os-release
OS_ID="${ID:-unknown}"
OS_ID_LIKE="${ID_LIKE:-}"

case "${OS_ID}" in
    debian|ubuntu)
        FAMILY="debian"
        ;;
    rhel|centos|fedora|rocky|almalinux)
        FAMILY="rhel"
        ;;
    *)
        if [[ "${OS_ID_LIKE}" == *debian* ]]; then
            FAMILY="debian"
        elif [[ "${OS_ID_LIKE}" == *"rhel"* || "${OS_ID_LIKE}" == *fedora* ]]; then
            FAMILY="rhel"
        else
            echo "ERROR: unsupported OS (ID=${OS_ID}, ID_LIKE=${OS_ID_LIKE})." >&2
            echo "This script supports Debian, Ubuntu, RHEL, CentOS, Rocky, AlmaLinux, and Fedora." >&2
            exit 1
        fi
        ;;
esac

if [[ "${FAMILY}" == "debian" ]]; then
    PKG_MGR="apt-get"
    CHRONY_CONF="/etc/chrony/chrony.conf"
    CHRONY_SERVICE="chrony"
else
    if command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    else
        PKG_MGR="yum"
    fi
    CHRONY_CONF="/etc/chrony.conf"
    CHRONY_SERVICE="chronyd"
fi

# --------------------------------------------------------------------------
# Dependency check / install (chrony)
# --------------------------------------------------------------------------
ensure_chrony_installed() {
    if command -v chronyd >/dev/null 2>&1; then
        return 0
    fi

    echo "chrony is not installed. Installing now..."
    # NEEDRESTART_MODE=a stops needrestart from opening an interactive
    # dialog on newer Ubuntu; the dpkg lock timeout makes a concurrent apt
    # run (cloud-init, unattended-upgrades) a wait instead of a failure.
    export NEEDRESTART_MODE=a
    case "${PKG_MGR}" in
        apt-get)
            DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 update -qq
            DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y chrony
            ;;
        dnf)
            dnf install -y chrony
            ;;
        yum)
            yum install -y chrony
            ;;
        *)
            echo "ERROR: unrecognized package manager '${PKG_MGR}'." >&2
            exit 1
            ;;
    esac

    if ! command -v chronyd >/dev/null 2>&1; then
        echo "ERROR: chrony install did not result in a working chronyd binary." >&2
        echo "Install it manually and re-run this script." >&2
        exit 1
    fi

    systemctl enable --now "${CHRONY_SERVICE}" >/dev/null 2>&1 || true
    echo "chrony installed."
}

# Checked after ensure_chrony_installed (see the entry point): on a host
# that does not have chrony yet, the config file only exists once the
# install step has run.
require_chrony_conf() {
    if [[ ! -f "${CHRONY_CONF}" ]]; then
        echo "ERROR: expected chrony config at ${CHRONY_CONF} but it does not exist." >&2
        echo "Confirm chrony is the intended NTP daemon on this host." >&2
        exit 1
    fi
}

# --------------------------------------------------------------------------
# Managed-block helpers (idempotent config editing)
# --------------------------------------------------------------------------
backup_conf() {
    local bak
    bak="${CHRONY_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "${CHRONY_CONF}" "${bak}"
    LAST_BACKUP="${bak}"
    echo "Backup saved: ${bak}"
}

remove_block() {
    local tag="$1"
    sed -i "/# BEGIN ${tag}/,/# END ${tag}/d" "${CHRONY_CONF}"
}

insert_block() {
    local tag="$1"
    local content="$2"
    {
        echo "# BEGIN ${tag}"
        echo "${content}"
        echo "# END ${tag}"
    } >> "${CHRONY_CONF}"
}

get_block_lines() {
    local tag="$1"
    sed -n "/# BEGIN ${tag}/,/# END ${tag}/p" "${CHRONY_CONF}" | sed '1d;$d'
}

# Comments out any active server/pool lines outside our managed SOURCES
# block, so native/default entries do not silently keep being used
# alongside whatever the operator selects here.
disable_native_sources() {
    sed -i -E "/# BEGIN ${SOURCES_TAG}/,/# END ${SOURCES_TAG}/!{
        s/^([[:space:]]*)(server|pool)([[:space:]].*)\$/\1# \2\3  # disabled by configure-ntp-server.sh/
    }" "${CHRONY_CONF}"
}

# --------------------------------------------------------------------------
# Pre-programmed source lists
# --------------------------------------------------------------------------
native_sources_for_os() {
    case "${OS_ID}" in
        debian)     echo "0.debian.pool.ntp.org 1.debian.pool.ntp.org 2.debian.pool.ntp.org 3.debian.pool.ntp.org" ;;
        ubuntu)     echo "0.ubuntu.pool.ntp.org 1.ubuntu.pool.ntp.org 2.ubuntu.pool.ntp.org 3.ubuntu.pool.ntp.org" ;;
        rhel)       echo "0.rhel.pool.ntp.org 1.rhel.pool.ntp.org 2.rhel.pool.ntp.org 3.rhel.pool.ntp.org" ;;
        centos)     echo "0.centos.pool.ntp.org 1.centos.pool.ntp.org 2.centos.pool.ntp.org 3.centos.pool.ntp.org" ;;
        fedora)     echo "0.fedora.pool.ntp.org 1.fedora.pool.ntp.org 2.fedora.pool.ntp.org 3.fedora.pool.ntp.org" ;;
        rocky)      echo "0.rocky.pool.ntp.org 1.rocky.pool.ntp.org 2.rocky.pool.ntp.org 3.rocky.pool.ntp.org" ;;
        almalinux)  echo "0.almalinux.pool.ntp.org 1.almalinux.pool.ntp.org 2.almalinux.pool.ntp.org" ;;
        *)          echo "0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org 3.pool.ntp.org" ;;
    esac
}

USA_POOL_SOURCES="0.us.pool.ntp.org 1.us.pool.ntp.org 2.us.pool.ntp.org 3.us.pool.ntp.org"
PREFERRED_SOURCES="time.cloudflare.com us.pool.ntp.org time.nist.gov"

# --------------------------------------------------------------------------
# Source selection menu
# --------------------------------------------------------------------------

select_time_sources() {
    local native_default
    native_default="$(native_sources_for_os)"

    echo ""
    echo "Select upstream time source set:"
    echo "  1) OS / Native / Default   (${native_default})"
    echo "  2) NTP Pool for USA        (${USA_POOL_SOURCES})"
    echo "  3) Preferred servers       (${PREFERRED_SOURCES})"
    echo "  4) Custom"
    read -rp "Choice [1]: " choice
    choice="${choice:-1}"

    case "${choice}" in
        1) CHOSEN_SOURCES="${native_default}" ;;
        2) CHOSEN_SOURCES="${USA_POOL_SOURCES}" ;;
        3) CHOSEN_SOURCES="${PREFERRED_SOURCES}" ;;
        4)
            read -rp "Enter custom server(s), space separated: " custom
            custom="$(echo "${custom}" | xargs)"
            if [[ -z "${custom}" ]]; then
                echo "ERROR: no servers entered." >&2
                return 1
            fi
            local tok
            for tok in ${custom}; do
                if ! validate_source_token "${tok}"; then
                    echo "ERROR: '${tok}' is not a valid hostname/IP (letters, digits, '.', ':', '-' only)." >&2
                    return 1
                fi
            done
            CHOSEN_SOURCES="${custom}"
            ;;
        *)
            echo "ERROR: invalid choice." >&2
            return 1
            ;;
    esac
}

apply_time_sources() {
    select_time_sources || return 1

    backup_conf
    remove_block "${SOURCES_TAG}"
    disable_native_sources

    local block=""
    for s in ${CHOSEN_SOURCES}; do
        block+="server ${s} iburst"$'\n'
    done
    block="${block%$'\n'}"
    insert_block "${SOURCES_TAG}" "${block}"

    echo "Time source(s) set to: ${CHOSEN_SOURCES}"
}

# --------------------------------------------------------------------------
# Allowed subnet management
# --------------------------------------------------------------------------
current_allowed_subnets() {
    get_block_lines "${ALLOW_TAG}" | awk '{print $2}'
}

manage_allowed_subnets() {
    echo ""
    echo "Current allowed subnets:"
    local existing
    existing="$(current_allowed_subnets)"
    if [[ -z "${existing}" ]]; then
        echo "  (none configured yet)"
    else
        echo "${existing}" | sed 's/^/  /'
    fi

    echo ""
    echo "  1) Add a subnet"
    echo "  2) Remove a subnet"
    echo "  3) Replace all subnets"
    echo "  4) Back / done"
    read -rp "Choice [4]: " choice
    choice="${choice:-4}"

    local subnets=()
    while IFS= read -r line; do
        [[ -n "${line}" ]] && subnets+=("${line}")
    done <<< "${existing}"

    local removed=()
    local added=()

    case "${choice}" in
        1)
            read -rp "Subnet to allow (CIDR, e.g. 192.168.1.0/24): " new_subnet
            if ! validate_cidr "${new_subnet}"; then
                echo "ERROR: '${new_subnet}' is not a valid CIDR (expected format A.B.C.D/nn)." >&2
                return 1
            fi
            subnets+=("${new_subnet}")
            added=("${new_subnet}")
            ;;
        2)
            if [[ ${#subnets[@]} -eq 0 ]]; then
                echo "No subnets to remove."
                return 0
            fi
            local i=1
            for s in "${subnets[@]}"; do
                echo "  ${i}) ${s}"
                ((i++))
            done
            read -rp "Number to remove: " idx
            if ! [[ "${idx}" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#subnets[@]} )); then
                echo "ERROR: invalid selection." >&2
                return 1
            fi
            removed=("${subnets[idx-1]}")
            unset 'subnets[idx-1]'
            subnets=("${subnets[@]}")
            ;;
        3)
            read -rp "Enter all subnets to allow, space separated: " all
            local new_subnets=()
            for s in ${all}; do
                if ! validate_cidr "${s}"; then
                    echo "ERROR: '${s}' is not a valid CIDR. Aborting, no changes made." >&2
                    return 1
                fi
                new_subnets+=("${s}")
            done
            for old in "${subnets[@]}"; do
                local kept=0
                for n in "${new_subnets[@]}"; do
                    [[ "${old}" == "${n}" ]] && kept=1 && break
                done
                [[ ${kept} -eq 0 ]] && removed+=("${old}")
            done
            for n in "${new_subnets[@]}"; do
                local already=0
                for old in "${subnets[@]}"; do
                    [[ "${old}" == "${n}" ]] && already=1 && break
                done
                [[ ${already} -eq 0 ]] && added+=("${n}")
            done
            subnets=("${new_subnets[@]}")
            ;;
        4)
            return 0
            ;;
        *)
            echo "ERROR: invalid choice." >&2
            return 1
            ;;
    esac

    backup_conf
    remove_block "${ALLOW_TAG}"
    local block=""
    for s in "${subnets[@]}"; do
        block+="allow ${s}"$'\n'
    done
    block="${block%$'\n'}"
    if [[ -n "${block}" ]]; then
        insert_block "${ALLOW_TAG}" "${block}"
    fi

    echo "Allowed subnets updated:"
    if [[ ${#subnets[@]} -eq 0 ]]; then
        echo "  (none - this host will not answer NTP queries from any subnet)"
    else
        printf '  %s\n' "${subnets[@]}"
    fi

    if [[ ${#removed[@]} -gt 0 ]]; then
        revoke_firewall_access "${removed[@]}"
    fi
    if [[ ${#added[@]} -gt 0 ]]; then
        # Symmetric with the auto-revoke above: a subnet newly allowed here
        # gets its firewall rule created automatically too, instead of
        # silently being allowed at the chrony level but still firewalled
        # off until the operator separately runs menu option 4.
        configure_firewall "${added[@]}" || true
    fi
}

# --------------------------------------------------------------------------
# Firewall configuration
# --------------------------------------------------------------------------
detect_firewall_manager() {
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        echo "firewalld"
    elif command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        echo "ufw"
    elif command -v iptables >/dev/null 2>&1; then
        echo "iptables"
    fi
}

configure_firewall() {
    local subnets=("$@")
    if [[ ${#subnets[@]} -eq 0 ]]; then
        mapfile -t subnets < <(current_allowed_subnets)
    fi
    if [[ ${#subnets[@]} -eq 0 ]]; then
        echo "No allowed subnets configured yet. Configure allowed subnets first." >&2
        return 1
    fi

    local mgr rules_added=0
    mgr="$(detect_firewall_manager)"

    case "${mgr}" in
        firewalld)
            for s in "${subnets[@]}"; do
                local rule="rule family='ipv4' source address='${s}' port protocol='udp' port='123' accept"
                if ! firewall-cmd --permanent --zone=public --query-rich-rule="${rule}" >/dev/null 2>&1; then
                    firewall-cmd --permanent --zone=public --add-rich-rule="${rule}" >/dev/null
                    rules_added=1
                fi
            done
            # Reload only when a rule was actually added, so re-asserting
            # rules that are already in place does not bounce the firewall.
            if (( rules_added == 1 )); then
                firewall-cmd --reload >/dev/null
                FW_CHANGED=1
            fi
            echo "firewalld: NTP (UDP 123) allowed from: ${subnets[*]}"
            ;;

        ufw)
            for s in "${subnets[@]}"; do
                # 'ufw show added' echoes back each user rule in the exact
                # syntax used to add it, so this is an exact match on this
                # specific rule - not a substring match against the whole
                # ruleset, which could false-positive on an unrelated rule
                # (e.g. SSH access) that happens to mention the same subnet.
                if ! ufw show added | grep -qF "ufw allow from ${s} to any port 123 proto udp"; then
                    ufw allow from "${s}" to any port 123 proto udp >/dev/null
                    FW_CHANGED=1
                fi
            done
            echo "ufw: NTP (UDP 123) allowed from: ${subnets[*]}"
            ;;

        iptables)
            for s in "${subnets[@]}"; do
                if ! iptables -C INPUT -p udp -s "${s}" --dport 123 -j ACCEPT 2>/dev/null; then
                    iptables -I INPUT -p udp -s "${s}" --dport 123 -j ACCEPT
                    rules_added=1
                fi
            done
            if (( rules_added == 1 )); then
                FW_CHANGED=1
                if command -v netfilter-persistent >/dev/null 2>&1; then
                    netfilter-persistent save >/dev/null 2>&1 || true
                    echo "iptables: rules applied and saved via netfilter-persistent."
                elif [[ -f /etc/sysconfig/iptables ]] && command -v service >/dev/null 2>&1; then
                    service iptables save >/dev/null 2>&1 || true
                    echo "iptables: rules applied and saved via /etc/sysconfig/iptables."
                else
                    echo "WARNING: iptables rules applied but NOT persisted across reboot."
                    echo "Install iptables-persistent (Debian/Ubuntu) or switch to firewalld to persist."
                fi
            else
                echo "iptables: NTP (UDP 123) already allowed from: ${subnets[*]}"
            fi
            ;;

        *)
            echo "WARNING: no active supported firewall manager found (firewalld, ufw, iptables)."
            echo "Open UDP 123 to ${subnets[*]} manually if this host is otherwise firewalled."
            return 1
            ;;
    esac
}

# Revokes previously auto-created NTP firewall access for subnets that were
# just removed from the allow list. Only acts on the same firewalld/ufw/
# iptables rule shape configure_firewall creates; a no-op if no rule for
# that subnet exists (e.g. option 4 was never run for it).
revoke_firewall_access() {
    local subnets=("$@")
    if [[ ${#subnets[@]} -eq 0 ]]; then
        return 0
    fi

    local mgr
    mgr="$(detect_firewall_manager)"
    if [[ -z "${mgr}" ]]; then
        return 0
    fi

    case "${mgr}" in
        firewalld)
            local changed=0
            for s in "${subnets[@]}"; do
                local rule="rule family='ipv4' source address='${s}' port protocol='udp' port='123' accept"
                if firewall-cmd --permanent --zone=public --query-rich-rule="${rule}" >/dev/null 2>&1; then
                    firewall-cmd --permanent --zone=public --remove-rich-rule="${rule}" >/dev/null
                    changed=1
                fi
            done
            if [[ ${changed} -eq 1 ]]; then
                firewall-cmd --reload >/dev/null
                FW_CHANGED=1
                echo "firewalld: NTP (UDP 123) access revoked for: ${subnets[*]}"
            fi
            ;;

        ufw)
            for s in "${subnets[@]}"; do
                if ufw delete allow from "${s}" to any port 123 proto udp >/dev/null 2>&1; then FW_CHANGED=1; fi
            done
            echo "ufw: NTP (UDP 123) access revoked for: ${subnets[*]} (if a matching rule existed)"
            ;;

        iptables)
            local changed=0
            for s in "${subnets[@]}"; do
                while iptables -C INPUT -p udp -s "${s}" --dport 123 -j ACCEPT 2>/dev/null; do
                    iptables -D INPUT -p udp -s "${s}" --dport 123 -j ACCEPT
                    changed=1
                done
            done
            if [[ ${changed} -eq 1 ]]; then
                if command -v netfilter-persistent >/dev/null 2>&1; then
                    netfilter-persistent save >/dev/null 2>&1 || true
                elif [[ -f /etc/sysconfig/iptables ]] && command -v service >/dev/null 2>&1; then
                    service iptables save >/dev/null 2>&1 || true
                fi
                FW_CHANGED=1
                echo "iptables: NTP (UDP 123) access revoked for: ${subnets[*]}"
            fi
            ;;
    esac
}

# --------------------------------------------------------------------------
# Stratum lock
# --------------------------------------------------------------------------
manage_stratum_lock() {
    local current
    current="$(get_block_lines "${STRATUM_TAG}" | awk '{print $3}')"

    echo ""
    if [[ -n "${current}" ]]; then
        echo "Local stratum lock is currently set to: ${current}"
    else
        echo "Local stratum lock is not currently set."
    fi

    read -rp "Enable/update local stratum lock? (y/N): " ans
    ans="${ans:-N}"
    if [[ ! "${ans}" =~ ^[Yy]$ ]]; then
        read -rp "Remove existing stratum lock instead? (y/N): " rm_ans
        rm_ans="${rm_ans:-N}"
        if [[ "${rm_ans}" =~ ^[Yy]$ ]]; then
            backup_conf
            remove_block "${STRATUM_TAG}"
            echo "Stratum lock removed."
        fi
        return 0
    fi

    read -rp "Stratum value to lock to when upstream sources are unreachable [10]: " val
    val="${val:-10}"
    if ! [[ "${val}" =~ ^([0-9]|1[0-5])$ ]]; then
        echo "ERROR: stratum must be a whole number from 0 to 15." >&2
        return 1
    fi

    backup_conf
    remove_block "${STRATUM_TAG}"
    insert_block "${STRATUM_TAG}" "local stratum ${val}"
    echo "Local stratum lock set to ${val}."
}

# --------------------------------------------------------------------------
# Apply / restart
# --------------------------------------------------------------------------
apply_and_restart() {
    # Guarded (not a bare command) so a failing restart itself does not
    # trip the ERR trap and skip the recovery logic below.
    systemctl restart "${CHRONY_SERVICE}" || true
    sleep 1
    if systemctl is-active --quiet "${CHRONY_SERVICE}"; then
        echo "${CHRONY_SERVICE} restarted successfully."
        return 0
    fi

    echo "ERROR: ${CHRONY_SERVICE} failed to start after configuration change." >&2
    echo "Check: journalctl -u ${CHRONY_SERVICE} -n 50 --no-pager" >&2

    if [[ -z "${LAST_BACKUP}" || ! -f "${LAST_BACKUP}" ]]; then
        echo "ERROR: no backup from this session to restore automatically." >&2
        exit 1
    fi

    echo "Restoring last-known-good config from ${LAST_BACKUP} and retrying..." >&2
    cp -p "${LAST_BACKUP}" "${CHRONY_CONF}"
    systemctl restart "${CHRONY_SERVICE}" || true
    sleep 1
    if systemctl is-active --quiet "${CHRONY_SERVICE}"; then
        echo "WARNING: the last change was reverted because ${CHRONY_SERVICE} would not start with it. ${CHRONY_SERVICE} is back up on the previous config." >&2
        exit 1
    fi

    echo "ERROR: ${CHRONY_SERVICE} still will not start even after restoring ${LAST_BACKUP}." >&2
    echo "This config change is likely not the cause. Manual intervention required." >&2
    exit 1
}

# --------------------------------------------------------------------------
# View current configuration
# --------------------------------------------------------------------------
view_configuration() {
    echo ""
    echo "===================================================================="
    echo " Current NTP Server Configuration (${CHRONY_CONF})"
    echo "===================================================================="

    echo ""
    echo "-- Configured upstream sources --"
    local src
    src="$(get_block_lines "${SOURCES_TAG}")"
    if [[ -n "${src}" ]]; then
        echo "${src}"
    else
        echo "(none set by this script yet - showing active config file entries)"
        grep -E '^[[:space:]]*(server|pool)[[:space:]]' "${CHRONY_CONF}" || echo "(no active source lines found)"
    fi

    echo ""
    echo "-- Allowed subnets --"
    local allow
    allow="$(current_allowed_subnets)"
    if [[ -n "${allow}" ]]; then
        echo "${allow}" | sed 's/^/  /'
    else
        echo "  (none configured)"
    fi

    echo ""
    echo "-- Stratum lock --"
    local strat
    strat="$(get_block_lines "${STRATUM_TAG}")"
    if [[ -n "${strat}" ]]; then
        echo "  ${strat}"
    else
        echo "  (not set)"
    fi

    echo ""
    echo "-- Service status --"
    systemctl is-active --quiet "${CHRONY_SERVICE}" && echo "  ${CHRONY_SERVICE}: active" || echo "  ${CHRONY_SERVICE}: NOT active"

    if command -v chronyc >/dev/null 2>&1 && systemctl is-active --quiet "${CHRONY_SERVICE}"; then
        echo ""
        echo "-- chronyc tracking --"
        chronyc tracking 2>/dev/null || echo "  (unable to query chronyd)"
        echo ""
        echo "-- chronyc sources --"
        chronyc sources 2>/dev/null || true
        echo ""
        echo "-- Recent NTP clients (if any have queried yet) --"
        chronyc clients 2>/dev/null || true
    fi
    echo "===================================================================="
}

# --------------------------------------------------------------------------
# Unattended mode (driven by --sources / --allow / --stratum)
#
# Declarative: each setting given on the command line is compared with what
# the config already holds and only written if it differs, so running the
# same command twice changes nothing and does not restart chrony. One
# backup is taken, before the first write, so the automatic restore in
# apply_and_restart always returns to the state this run started from.
# --------------------------------------------------------------------------
backup_once() {
    if (( BACKUP_TAKEN == 0 )); then
        backup_conf
        BACKUP_TAKEN=1
    fi
}

run_unattended() {
    local changed=0

    if [[ -n "${OPT_SOURCES}" ]]; then
        local want_list
        case "${OPT_SOURCES}" in
            native) want_list="$(native_sources_for_os)" ;;
            usa) want_list="${USA_POOL_SOURCES}" ;;
            preferred) want_list="${PREFERRED_SOURCES}" ;;
            *) want_list="${OPT_SOURCES//,/ }" ;;
        esac
        local want_block="" s
        for s in ${want_list}; do
            want_block+="server ${s} iburst"$'\n'
        done
        want_block="${want_block%$'\n'}"

        if [[ "$(get_block_lines "${SOURCES_TAG}")" == "${want_block}" ]]; then
            echo "Time sources already set: ${want_list}"
        else
            backup_once
            remove_block "${SOURCES_TAG}"
            disable_native_sources
            insert_block "${SOURCES_TAG}" "${want_block}"
            echo "Time source(s) set to: ${want_list}"
            changed=1
        fi
    fi

    if (( OPT_ALLOW_SET == 1 )); then
        local current=() line
        while IFS= read -r line; do
            [[ -n "${line}" ]] && current+=("${line}")
        done < <(current_allowed_subnets)

        local added=() removed=() s2 found
        for s2 in ${WANT_ALLOW[@]+"${WANT_ALLOW[@]}"}; do
            found=0
            for line in ${current[@]+"${current[@]}"}; do
                [[ "${line}" == "${s2}" ]] && { found=1; break; }
            done
            (( found == 1 )) || added+=("${s2}")
        done
        for line in ${current[@]+"${current[@]}"}; do
            found=0
            for s2 in ${WANT_ALLOW[@]+"${WANT_ALLOW[@]}"}; do
                [[ "${line}" == "${s2}" ]] && { found=1; break; }
            done
            (( found == 1 )) || removed+=("${line}")
        done

        if (( ${#added[@]} == 0 && ${#removed[@]} == 0 )); then
            echo "Allowed subnets already set: ${WANT_ALLOW[*]:-(none)}"
        else
            backup_once
            remove_block "${ALLOW_TAG}"
            if (( ${#WANT_ALLOW[@]} > 0 )); then
                local block=""
                for s2 in "${WANT_ALLOW[@]}"; do
                    block+="allow ${s2}"$'\n'
                done
                insert_block "${ALLOW_TAG}" "${block%$'\n'}"
            fi
            echo "Allowed subnets set to: ${WANT_ALLOW[*]:-(none)}"
            changed=1

            if (( OPT_NO_FIREWALL == 0 && ${#removed[@]} > 0 )); then
                revoke_firewall_access "${removed[@]}"
            fi
        fi

        # Firewall rules are (re)asserted for the full list on every run, not
        # only for newly added subnets: configure_firewall skips rules that
        # already exist, so this is a no-op when nothing has drifted and
        # repairs a rule that was removed outside this tool.
        if (( OPT_NO_FIREWALL == 0 && ${#WANT_ALLOW[@]} > 0 )); then
            configure_firewall "${WANT_ALLOW[@]}" || echo "WARNING: firewall rule(s) could not be created; see the message above." >&2
        fi
    fi

    if (( OPT_STRATUM_SET == 1 )); then
        local cur_stratum
        cur_stratum="$(get_block_lines "${STRATUM_TAG}" | awk '{print $3}')"
        if [[ "${OPT_STRATUM}" == "none" ]]; then
            if [[ -n "${cur_stratum}" ]]; then
                backup_once
                remove_block "${STRATUM_TAG}"
                echo "Stratum lock removed."
                changed=1
            else
                echo "Stratum lock already not set."
            fi
        elif [[ "${cur_stratum}" == "${OPT_STRATUM}" ]]; then
            echo "Stratum lock already set to ${OPT_STRATUM}."
        else
            backup_once
            remove_block "${STRATUM_TAG}"
            insert_block "${STRATUM_TAG}" "local stratum ${OPT_STRATUM}"
            echo "Stratum lock set to ${OPT_STRATUM}."
            changed=1
        fi
    fi

    # Restart only when the config changed, or when chrony is not running at
    # all (then a start is needed whether or not anything was edited).
    if (( changed == 1 )) || ! systemctl is-active --quiet "${CHRONY_SERVICE}"; then
        apply_and_restart
    fi

    if (( changed == 1 || FW_CHANGED == 1 )); then
        echo "RESULT: changed"
    else
        echo "RESULT: unchanged"
    fi
}

# --------------------------------------------------------------------------
# Main menu
# --------------------------------------------------------------------------
main_menu() {
    while true; do
        echo ""
        echo "configure-ntp-server.sh ${SCRIPT_VERSION}  |  Host family: ${FAMILY} (${OS_ID})  |  Daemon: ${CHRONY_SERVICE}"
        echo "  1) View current configuration"
        echo "  2) Configure upstream time source(s)"
        echo "  3) Configure allowed subnets"
        echo "  4) Auto-create firewall rule(s) for allowed subnets"
        echo "  5) Set / update local stratum lock"
        echo "  6) Apply changes and restart ${CHRONY_SERVICE}"
        echo "  7) Exit"
        # If input closes (no terminal, closed stdin) there is nobody to
        # answer the menu; stop with a pointer to the unattended flags
        # instead of spinning or dying on a bare read error.
        read -rp "Choice: " opt || {
            echo "" >&2
            echo "ERROR: input closed before a menu choice was made. For scripted use, pass --sources, --allow, and/or --stratum (see --help)." >&2
            exit 1
        }

        case "${opt}" in
            1) view_configuration ;;
            2) apply_time_sources || true ;;
            3) manage_allowed_subnets || true ;;
            4) configure_firewall || true ;;
            5) manage_stratum_lock || true ;;
            6) apply_and_restart ;;
            7) echo "Exiting."; exit 0 ;;
            *) echo "Invalid choice." ;;
        esac
    done
}

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------
if (( OPT_STATUS == 1 )); then
    # Read-only: report on what is there, never install or edit anything.
    if ! command -v chronyd >/dev/null 2>&1; then
        echo "ERROR: chrony is not installed on this host." >&2
        exit 1
    fi
    require_chrony_conf
    view_configuration
    exit 0
fi

if (( UNATTENDED == 1 )); then
    # Nothing here may block on a prompt.
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
fi

ensure_chrony_installed
require_chrony_conf
echo "Detected: ${OS_ID} (${FAMILY} family), config file: ${CHRONY_CONF}, service: ${CHRONY_SERVICE}"
if (( UNATTENDED == 1 )); then
    run_unattended
else
    main_menu
fi
