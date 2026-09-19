#!/usr/bin/env bash
#
# setup-server.sh
# 2026-09-19
# Version: v1.4.1
#
# CHANGELOG:
#   v1.4.1 - The dialog shown before "Proceed?" is now a numbered plan in
#            run order, tailored to the host: each step says what it will
#            change here (packages for this distro family, the NTP path
#            implied by the flags and what the host uses today, whether a
#            host firewall port gets opened, whether netplan/dracut apply,
#            whether usr_admin already exists), and that nothing reboots
#            the host or applies a network change live. Previously it was a
#            short generic bullet list that did not say what the time
#            synchronization step would do.
#   v1.4.0 - New "Time synchronization (NTP)" step after the timezone. It
#            shows the current time server configuration, asks whether it
#            needs to change (default: no), and if so hands off to
#            Linux/NTP-Config/configure-ntp-server.sh, the same way the
#            usr_admin step hands off to Group-MGMT: the sibling copy when
#            present, else a copy fetched from the NTP-Config "stable"
#            channel. Nothing is installed on the host by this step.
#            Unattended runs (--yes, or no terminal) only show the
#            configuration unless --ntp-sources, --ntp-allow, or
#            --ntp-stratum are given, which are passed through to the
#            tool's own unattended interface; --skip-ntp skips the step.
#            If the step fails, the error is shown, a record (when, on
#            which host, who ran it, what failed, the exit code, and the
#            tail of the run log) is appended to
#            /var/log/server-setup/audit.log, and the operator chooses to
#            exit or to skip NTP and continue. Unattended runs skip. A
#            skipped NTP step is flagged in the final summary, and the run
#            then exits 3 ("completed, items flagged for review") instead
#            of 0. Depends on configure-ntp-server.sh v1.7.0 or later for
#            the interactive menu to offer to apply pending changes on
#            exit.
#   v1.3.0 - After switching netplan to the NetworkManager renderer, also
#            install Ubuntu's dracut "no-network" profile into
#            /etc/dracut.conf.d and rebuild the initramfs (dracut hosts
#            only, skipped if early boot may need the network). Found on
#            Ubuntu 26.04: the default initramfs DHCPs the NIC before the
#            real system starts, NetworkManager adopts that leftover
#            address instead of applying the static netplan profile, and
#            the host boots on a DHCP address until 'netplan apply' is run.
#            Verified on a live host: with the profile in place the static
#            address is applied at boot.
#   v1.2.2 - The netplan renderer insert (awk path) now preserves the
#            original file's mode and owner. It previously replaced the
#            file with a default-umask copy (644), which made netplan warn
#            "Permissions ... are too open" and could expose secrets.
#   v1.2.1 - Every `timeout` call now runs with --foreground (via a
#            wrapper function). Without it, timeout moved apt-get into a
#            new background process group; once apt/dpkg/a hook touched
#            the terminal, the kernel stopped it (state T, ps showed
#            pgid != the terminal's tpgid) and Ctrl+C couldn't reach it,
#            hanging the run at the Cockpit install.
#   v1.2.0 - --admin-user now defaults to the invoking sudo user
#            ($SUDO_USER) instead of prompting, when that is a real,
#            non-root local account. --admin-user still overrides it, and
#            root-with-no-sudo still prompts (or errors if there is no
#            terminal). Note this also lets an unattended run pass --yes
#            alone and act on the invoking user, which previously errored.
#   v1.1.2 - Export DEBIAN_FRONTEND=noninteractive and NEEDRESTART_MODE=a
#            before any apt-get call. bootstrap.sh reattaches /dev/tty so
#            this script's own prompts work over curl|sudo bash, but that
#            also makes apt-listchanges (pulled in by unattended-upgrades)
#            and needrestart think they have a real interactive terminal
#            and block on a pager/whiptail dialog that nothing answers -
#            observed hanging the run past the point Ctrl+C could recover
#            it, requiring a reboot.
#   v1.1.1 - usr_admin group creation is now skippable: if the group does
#            not already exist, the operator is asked to confirm before
#            it's created (skipped under --yes/non-interactive, which
#            create it as before - the up-front provisioning summary
#            already discloses this). Declining leaves the rest of
#            provisioning untouched - no /opt ACLs, no usr_admin log
#            access, but every other step still completes normally. If
#            the group already exists, no prompt is shown - root and
#            --admin-user are just added to it as members, same as
#            before, since nothing new is being created in that case.
#   v1.1.0 - Runs are now logged to a file, not just the terminal - a
#            failure during an unattended/RMM invocation (this script is
#            documented for exactly that use) previously left no record
#            once the terminal session that launched it was gone.
#            LOG_DIR is locked to root:root, mode 750, plus the "adm"
#            group where present, immediately on creation - the same
#            baseline Linux/Updates and Linux/Notifications use - and
#            once usr_admin exists (the last provisioning step), its
#            permissions are reapplied to also grant that group read
#            access, since usr_admin can't be granted anything before
#            this script itself creates it.
#   v1.0.1 - Added -E (errtrace) so the ERR trap fires on function-
#            internal failures too, timeout-wrapped the remaining
#            unbounded external calls (dpkg-reconfigure, systemctl
#            enable --now, firewall-cmd, the Group-MGMT delegate
#            invocation), and fixed a false-success bug where the
#            netplan renderer's awk fallback could report success
#            without actually inserting the renderer line.
#
# PURPOSE:
# Baseline provisioning for a freshly installed Linux server: base
# packages, timezone, time synchronization (via NTP-Config/
# configure-ntp-server.sh), Cockpit, NetworkManager as the netplan
# renderer (where applicable), unattended OS updates, and the usr_admin
# permissions group on /opt (via Group-MGMT/create-usr_admin-group.sh).
# Detects the host distro and adapts package names/mechanisms
# accordingly. Supports Debian/Ubuntu, Fedora, and RHEL-family distros
# (RHEL, CentOS, Rocky, AlmaLinux). Safe to re-run.
#
# USAGE:
#   setup-server.sh --admin-user NAME [--timezone TZ] [--yes]
#                   [--skip-ntp | [--ntp-sources V] [--ntp-allow CIDRS]
#                                 [--ntp-stratum N]]
#   setup-server.sh --check                Dependency/pre-flight checks only
#
# EXIT CODES:
#   0  success
#   1  failure, or the operator chose to exit after an NTP error
#   3  completed, but one or more items are flagged for review (see the
#      final summary and /var/log/server-setup/audit.log)
#
# CONFIG:
#   No config file - everything is a flag or an interactive prompt.

set -Eeuo pipefail

# bootstrap.sh reattaches /dev/tty so this script's own ask/confirm prompts
# work when run via curl|sudo bash - but that also makes apt/dpkg think
# it has a real interactive terminal. Without these, apt-listchanges
# (pulled in by unattended-upgrades) launches a pager waiting for a
# keypress, and needrestart pops a whiptail dialog asking which services
# to restart - either blocks apt-get indefinitely, deep enough in a dpkg
# postinst hook that Ctrl+C doesn't reliably reach it.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Plain `timeout` runs its command in a new background process group. The
# moment apt-get/dpkg (or a hook under them) touches the terminal, the
# kernel stops that group (state T) and Ctrl+C can't reach it, since it
# isn't the foreground group. --foreground keeps the command in this
# script's group. Tradeoff: on expiry only the direct child gets the
# signal, not its descendants.
timeout() { command timeout --foreground "$@"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GROUP_MGMT_LOCAL="${SCRIPT_DIR}/../Group-MGMT/create-usr_admin-group.sh"
GROUP_MGMT_URL="https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Group-MGMT/create-usr_admin-group.sh"
NTP_LOCAL="${SCRIPT_DIR}/../NTP-Config/configure-ntp-server.sh"
NTP_URL="https://raw.githubusercontent.com/MVTS-Corp/Scripts/stable/Linux/NTP-Config/configure-ntp-server.sh"
LOG_DIR="/var/log/server-setup"
AUDIT_LOG="${LOG_DIR}/audit.log"
LOG_RETENTION_DAYS=180
SCRIPT_VERSION="v1.4.1"

ADMIN_USER=""
TIMEZONE="America/New_York"
ASSUME_YES=0
CHECK_ONLY=0
SKIP_NTP=0
NTP_SOURCES=""
NTP_ALLOW=""
NTP_STRATUM=""
NTP_SOURCES_SET=0
NTP_ALLOW_SET=0
NTP_STRATUM_SET=0

# Outcome of the NTP step for the final summary, and anything that needs a
# human to look at it afterward (which also makes the run exit 3).
NTP_OUTCOME="not run"
FLAGGED_ITEMS=()
NTP_TOOL=""
NTP_TOOL_SRC=""
NTP_TOOL_VERSION=""
NTP_TMP=""
NTP_ERR=""

usage() {
    cat <<EOF
Usage: sudo ${0##*/} --admin-user NAME [--timezone TZ] [--yes]
                     [--skip-ntp | --ntp-sources V --ntp-allow CIDRS --ntp-stratum N]
       sudo ${0##*/} --check

  --admin-user NAME  Existing local username to add (alongside root) to
                     the usr_admin group. If omitted, defaults to the user
                     who ran sudo (\$SUDO_USER); if that isn't available
                     (run directly as root), you are prompted instead, or
                     it is required when no terminal is attached (except
                     with --check). If usr_admin doesn't exist
                     yet, you'll be asked separately to confirm creating
                     it - declining skips that step only, not the rest
                     of provisioning.
  --timezone TZ      IANA timezone name (default: America/New_York).
  --yes              Skip all confirmation prompts, including usr_admin
                     creation if it doesn't already exist. The time
                     synchronization step then only shows the current
                     configuration, unless --ntp-* settings are given.
  --skip-ntp         Skip the time synchronization (NTP) step entirely.
  --ntp-sources V    Set the time sources unattended: native, usa,
                     preferred, or a comma separated list of hostnames/IPs.
  --ntp-allow CIDRS  Set the subnets allowed to query this host for time
                     (comma separated), or "none". Repeatable.
  --ntp-stratum N    Set the local stratum lock (0-15), or "none".
                     The three --ntp-* options are passed to
                     NTP-Config/configure-ntp-server.sh (see its README).
  --check            Dependency and pre-flight checks only, no changes.
  -h, --help         Show this help text.

Exit codes: 0 success, 1 failure, 3 completed with items flagged for
review (for example NTP skipped after an error).

Examples:
  sudo ./${0##*/} --admin-user jsmith
  sudo ./${0##*/} --admin-user jsmith --timezone America/Chicago --yes
  sudo ./${0##*/} --admin-user jsmith --yes --ntp-sources preferred --ntp-allow 192.168.1.0/24
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --admin-user)
            [[ $# -ge 2 ]] || { echo "ERROR: --admin-user requires a value." >&2; exit 1; }
            ADMIN_USER="$2"; shift 2 ;;
        --timezone)
            [[ $# -ge 2 ]] || { echo "ERROR: --timezone requires a value." >&2; exit 1; }
            TIMEZONE="$2"; shift 2 ;;
        --yes)
            ASSUME_YES=1; shift ;;
        --check)
            CHECK_ONLY=1; shift ;;
        --skip-ntp)
            SKIP_NTP=1; shift ;;
        --ntp-sources)
            [[ $# -ge 2 ]] || { echo "ERROR: --ntp-sources requires a value." >&2; exit 1; }
            NTP_SOURCES="$2"; NTP_SOURCES_SET=1; shift 2 ;;
        --ntp-allow)
            [[ $# -ge 2 ]] || { echo "ERROR: --ntp-allow requires a value." >&2; exit 1; }
            NTP_ALLOW="${NTP_ALLOW:+${NTP_ALLOW},}$2"; NTP_ALLOW_SET=1; shift 2 ;;
        --ntp-stratum)
            [[ $# -ge 2 ]] || { echo "ERROR: --ntp-stratum requires a value." >&2; exit 1; }
            NTP_STRATUM="$2"; NTP_STRATUM_SET=1; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage
            exit 1 ;;
    esac
done

NTP_HAS_SETTINGS=$(( NTP_SOURCES_SET || NTP_ALLOW_SET || NTP_STRATUM_SET ))
if (( SKIP_NTP && NTP_HAS_SETTINGS )); then
    echo "ERROR: --skip-ntp cannot be combined with --ntp-sources, --ntp-allow, or --ntp-stratum." >&2
    exit 1
fi
if (( NTP_STRATUM_SET )) && [[ ! "$NTP_STRATUM" =~ ^([0-9]|1[0-5]|none)$ ]]; then
    echo "ERROR: --ntp-stratum must be a whole number from 0 to 15, or \"none\"." >&2
    exit 1
fi
# An empty value (usually an unset variable in the caller) must not silently
# mean "no setting", or the run would fall through to the interactive path.
if (( NTP_SOURCES_SET )) && [[ -z "${NTP_SOURCES//[[:space:],]/}" ]]; then
    echo "ERROR: --ntp-sources needs a value: native, usa, preferred, or a list of hostnames/IPs." >&2
    exit 1
fi
if (( NTP_ALLOW_SET )) && [[ -z "${NTP_ALLOW//[[:space:],]/}" ]]; then
    echo "ERROR: --ntp-allow needs a value: one or more CIDRs, or \"none\"." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Logging + fail-loud
# ---------------------------------------------------------------------------
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/distro.sh
. "${SCRIPT_DIR}/lib/distro.sh"

fail_trap() {
    local lineno="$1"
    log_error "${0##*/} failed at line ${lineno}. No further changes were made past this point."
    exit 1
}
# -E (errtrace, set above) is required for this trap to fire when the
# failing command is inside a function - without it bash silently skips
# the ERR trap for function-internal failures.
trap 'fail_trap "$LINENO"' ERR

require_root

# ---------------------------------------------------------------------------
# Logging: capture this run to a file, not just the terminal, so a failure
# during an unattended/RMM invocation (see README "Quick Start") leaves a
# record instead of vanishing with the terminal session. Started this
# early - right after require_root, before anything that can actually
# fail - so a failure at any later step is captured. LOG_DIR is locked
# down immediately after creation; usr_admin can't be granted access yet
# since setup_usr_admin_group() (the step that creates it) hasn't run -
# permissions are reapplied there once the group exists.
# ---------------------------------------------------------------------------
mkdir -p "$LOG_DIR" || die "Cannot create log directory: $LOG_DIR"
apply_log_permissions "$LOG_DIR"
SETUP_LOG="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$SETUP_LOG") 2>&1
log_info "Logging this run to $SETUP_LOG"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
log_info "Detecting Linux distribution..."
detect_distro
if [[ -z "$PKG_MANAGER" ]]; then
    die "Could not determine a supported package manager for '$DISTRO_NAME' (ID=$DISTRO_ID, ID_LIKE=$DISTRO_ID_LIKE). Supported: Debian/Ubuntu-family, Fedora, RHEL-family."
fi
log_info "Detected: $DISTRO_NAME  (family=$DISTRO_FAMILY, package manager=$PKG_MANAGER)"

for cmd in timedatectl systemctl awk id curl; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: ${cmd}. This is not a standard Linux environment."
done

# No --admin-user given: default to the person who ran sudo, since that is
# almost always the account being set up. Not used when SUDO_USER is unset
# (run directly as root) or is root itself; those fall through to the prompt.
if [[ -z "$ADMIN_USER" && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] \
    && id -u "$SUDO_USER" >/dev/null 2>&1; then
    ADMIN_USER="$SUDO_USER"
    log_info "No --admin-user given; using the invoking sudo user: ${ADMIN_USER} (pass --admin-user NAME to use someone else)."
fi

if [[ -z "$ADMIN_USER" ]]; then
    if [[ -t 0 ]]; then
        ADMIN_USER="$(ask "Existing local username to add (alongside root) to usr_admin")"
    fi
    if [[ -z "$ADMIN_USER" && "$CHECK_ONLY" -ne 1 ]]; then
        die "--admin-user is required (existing local username to add to usr_admin, alongside root)."
    fi
fi
if [[ -n "$ADMIN_USER" ]] && ! id -u "$ADMIN_USER" >/dev/null 2>&1; then
    die "User '${ADMIN_USER}' does not exist on this system. Create the account first, then re-run."
fi

if (( CHECK_ONLY )); then
    log_info "Checks passed. --check specified, exiting without making changes."
    exit 0
fi

# Prints the numbered plan shown before the "Proceed?" prompt: every step in
# the order it runs, and what it will change on THIS host (distro family,
# netplan/dracut/firewall presence, whether usr_admin exists, and any NTP
# flags), so the operator is agreeing to what will actually happen and not to
# a generic list. Detection here mirrors the checks the steps themselves make.
plan_step() {   # plan_step N "Title" "what it does"
    printf '  %s. %s\n' "$1" "$2"
    printf '%s\n' "$3" | fold -s -w 68 | sed 's/[[:space:]]*$//; s/^/       /'
}

print_provisioning_plan() {
    local pkgs updates ntp cockpit_fw netplan_txt usr_admin_txt
    local netplan_files=(/etc/netplan/*.yaml)

    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        pkgs="net-tools, dnsutils, network-manager, acl, unzip"
        updates="Install and enable unattended-upgrades (with apt-listchanges) so security and OS updates apply automatically."
    else
        pkgs="net-tools, bind-utils, NetworkManager, acl, unzip"
        updates="Install and enable dnf-automatic with apply_updates = yes so OS updates apply automatically."
    fi

    if (( SKIP_NTP )); then
        ntp="Skipped (--skip-ntp). The time configuration is left exactly as it is."
    elif (( NTP_HAS_SETTINGS )); then
        ntp="Configure time synchronization (chrony) from the command line:"
        (( NTP_SOURCES_SET )) && ntp+=" sources = ${NTP_SOURCES};"
        (( NTP_ALLOW_SET )) && ntp+=" allowed subnets = ${NTP_ALLOW};"
        (( NTP_STRATUM_SET )) && ntp+=" stratum lock = ${NTP_STRATUM};"
        ntp="${ntp%;}. Installs chrony if it is missing, via NTP-Config."
    else
        ntp="Show the current time server configuration, then ask whether it needs to change (default: no). If you answer yes, NTP-Config's menu opens: it installs chrony if it is missing, and lets you set the time sources, the subnets allowed to query this host, and a stratum lock."
        if systemctl is-active --quiet systemd-timesyncd 2>/dev/null && ! command -v chronyd >/dev/null 2>&1; then
            ntp+=" Installing chrony replaces systemd-timesyncd, which is what this host uses now."
        fi
        ntp+=" If you answer no, nothing about time is changed."
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        cockpit_fw="Opens TCP 9090 in firewalld."
    elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        cockpit_fw="Opens TCP 9090 in ufw."
    else
        cockpit_fw="No active host firewall (firewalld/ufw) was detected, so no port is opened."
    fi

    if command -v netplan >/dev/null 2>&1 && [[ -e "${netplan_files[0]}" ]]; then
        netplan_txt="Set the netplan renderer to NetworkManager in /etc/netplan (a timestamped backup of each edited file is kept). It is validated but NOT applied live; it takes effect on 'sudo netplan apply' or the next reboot."
        if command -v dracut >/dev/null 2>&1 && command -v update-initramfs >/dev/null 2>&1; then
            netplan_txt+=" This host builds its initramfs with dracut, so networking is also kept out of the initramfs so the static address is used at boot; that rebuilds the initramfs now and applies from the next boot."
        fi
    else
        netplan_txt="Not applicable: netplan is not in use on this host, so nothing is changed."
    fi

    local members="root and ${ADMIN_USER}" member_verb="are members"
    if [[ "$ADMIN_USER" == "root" ]]; then
        members="root"
        member_verb="is a member"
    fi

    if getent group usr_admin >/dev/null 2>&1; then
        usr_admin_txt="The usr_admin group already exists. Make sure ${members} ${member_verb}, and (re)apply its read/write/execute ACLs on /opt (recursive, plus a default ACL so new files inherit it) and read access to the logs in ${LOG_DIR}."
    else
        usr_admin_txt="Create the usr_admin group (GID 3000); you will be asked to confirm this step separately, and declining skips only this step. Add ${members} to it, give it read/write/execute ACLs on /opt (recursive, plus a default ACL so new files inherit it) and read access to the logs in ${LOG_DIR}."
    fi

    echo
    echo "About to provision this host (${DISTRO_NAME}) as a baseline MVTS server."
    echo "The steps below run in this order:"
    echo
    plan_step 1 "Base packages" "Install ${pkgs}."
    plan_step 2 "Timezone" "Set the system timezone to ${TIMEZONE}."
    plan_step 3 "Time synchronization (NTP)" "$ntp"
    plan_step 4 "Cockpit" "Install and enable Cockpit, the web management console (https://<host>:9090). ${cockpit_fw}"
    plan_step 5 "Network renderer (netplan)" "$netplan_txt"
    plan_step 6 "Unattended updates" "$updates"
    plan_step 7 "usr_admin group and /opt permissions" "$usr_admin_txt"
    echo
    echo "The host is not rebooted and no network change is applied live."
    echo "Every step is safe to re-run."
    echo "Log for this run: ${SETUP_LOG}"
    echo
}

if [[ "$ASSUME_YES" -ne 1 && -t 0 ]]; then
    print_provisioning_plan
    confirm "Proceed?" "y" || { log_info "Aborted, no changes made."; exit 0; }
fi

# ---------------------------------------------------------------------------
# 1. Base packages
# ---------------------------------------------------------------------------
install_base_packages() {
    log_info "== Base packages =="
    case "$DISTRO_FAMILY" in
        debian)
            timeout 300 apt-get update -y
            timeout 300 apt-get install -y net-tools dnsutils network-manager acl unzip
            ;;
        fedora|rhel)
            timeout 300 "$PKG_MANAGER" install -y net-tools bind-utils NetworkManager acl unzip
            ;;
    esac
    for cmd in setfacl nmcli unzip; do
        command -v "$cmd" >/dev/null 2>&1 || die "Base package install did not provide the expected command: ${cmd}."
    done
    log_info "Base packages installed and verified."
}

# ---------------------------------------------------------------------------
# 2. Timezone
# ---------------------------------------------------------------------------
set_timezone() {
    log_info "== Timezone =="
    timedatectl set-timezone "$TIMEZONE" || die "Failed to set timezone to '${TIMEZONE}'. Is it a valid IANA timezone name? (timedatectl list-timezones)"
    local actual
    actual="$(timedatectl show --property=Timezone --value)"
    [[ "$actual" == "$TIMEZONE" ]] || die "Timezone set to ${TIMEZONE} but timedatectl now reports ${actual}."
    log_info "Timezone set to ${TIMEZONE}."
}

# ---------------------------------------------------------------------------
# 2a. Time synchronization (NTP) - delegates to NTP-Config's
#     configure-ntp-server.sh, the same way the usr_admin step delegates to
#     Group-MGMT: the sibling copy when present, else a copy fetched from the
#     NTP-Config "stable" channel. The tool is run from where it is found and
#     never installed on the host by this script.
#
#     Any failure here is shown to the operator, recorded in audit.log, and
#     then the operator decides: exit, or skip NTP and continue with the
#     step flagged for review in the final summary (and exit code 3).
#     Unattended runs have nobody to ask and always skip.
# ---------------------------------------------------------------------------

# True when a person can be asked a question (same test the other prompts use).
is_interactive() { [[ "$ASSUME_YES" -ne 1 && -t 0 ]]; }

# Sets NTP_TOOL / NTP_TOOL_SRC / NTP_TOOL_VERSION, or NTP_ERR and returns 1.
# Does not die: the caller decides whether a missing tool is an error (the
# operator asked to change the configuration) or just a degraded display.
resolve_ntp_tool() {
    [[ -z "$NTP_TOOL" ]] || return 0
    NTP_ERR=""

    if [[ -f "$NTP_LOCAL" ]]; then
        NTP_TOOL="$NTP_LOCAL"
        NTP_TOOL_SRC="local copy, ${NTP_LOCAL}"
    else
        log_info "Local NTP-Config script not found (standalone run); fetching from ${NTP_URL}..."
        NTP_TMP="$(mktemp)" || { NTP_ERR="mktemp failed; cannot stage the NTP-Config script."; return 1; }
        if ! timeout 30 curl --connect-timeout 10 -fsSL "$NTP_URL" -o "$NTP_TMP"; then
            NTP_ERR="Failed to fetch configure-ntp-server.sh from ${NTP_URL}."
        # A captive portal or proxy error page can come back as HTTP 200.
        elif [[ "$(sed -n '1p' "$NTP_TMP")" != "#!/usr/bin/env bash" ]] || ! bash -n "$NTP_TMP"; then
            NTP_ERR="The file fetched from ${NTP_URL} is not a valid bash script."
        fi
        if [[ -n "$NTP_ERR" ]]; then
            rm -f "$NTP_TMP"; NTP_TMP=""
            return 1
        fi
        NTP_TOOL="$NTP_TMP"
        NTP_TOOL_SRC="fetched from the NTP-Config stable channel"
    fi

    NTP_TOOL_VERSION="$(sed -n 's/^SCRIPT_VERSION="\(v[0-9][0-9.]*\)"$/\1/p' "$NTP_TOOL" | sed -n '1p')"
    NTP_TOOL_VERSION="${NTP_TOOL_VERSION:-unknown}"
    log_info "Using NTP-Config configure-ntp-server.sh ${NTP_TOOL_VERSION} (${NTP_TOOL_SRC})."
    return 0
}

ntp_cleanup() {
    [[ -z "$NTP_TMP" ]] || rm -f "$NTP_TMP"
    NTP_TMP=""
}

active_time_daemon() {
    local svc
    for svc in chrony chronyd systemd-timesyncd ntpd ntp ntpsec ntpd-rs; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo "$svc"
            return 0
        fi
    done
    echo "none detected"
}

show_time_sync_status() {
    local sync
    sync="$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)"
    echo
    echo "  Active time daemon:  $(active_time_daemon)"
    echo "  Clock synchronized:  ${sync:-unknown}"

    if command -v chronyd >/dev/null 2>&1; then
        if resolve_ntp_tool; then
            # Read-only. A failure here is not a configuration failure (nothing
            # has been attempted yet), so it is a warning, not an audit item.
            timeout 60 bash "$NTP_TOOL" --status \
                || log_warn "The NTP-Config status report failed (see above); continuing."
        else
            log_warn "${NTP_ERR} Showing basic chrony output instead."
            timeout 15 chronyc sources 2>/dev/null || true
        fi
    else
        echo "  chrony is not installed on this host."
        timedatectl show-timesync --property=SystemNTPServers --property=FallbackNTPServers \
            --property=ServerName 2>/dev/null | sed 's/^/  /' || true
    fi
    echo
}

# audit_record <decision> <what> <exit code> <detail>
# Appends one block to AUDIT_LOG: when, on which host, who ran it, what
# failed, and the tail of this run's log (which already holds the tool's
# output). Never fails the caller; an unwritable audit log is a warning.
audit_record() {
    local decision="$1" what="$2" rc="$3" detail="$4"
    {
        echo "==== $(date '+%Y-%m-%d %H:%M:%S %z') ===="
        echo "event:        NTP step failed"
        echo "status:       ${decision}"
        echo "host:         $(hostname -f 2>/dev/null || hostname) (${DISTRO_NAME})"
        echo "run by:       ${SUDO_USER:-$(id -un)} (login: $(logname 2>/dev/null || echo unknown)); admin user: ${ADMIN_USER}"
        echo "script:       ${0##*/} ${SCRIPT_VERSION}"
        echo "step:         Time synchronization (NTP)"
        echo "what failed:  ${what}"
        echo "exit code:    ${rc}"
        echo "detail:       ${detail}"
        echo "ntp tool:     ${NTP_TOOL_VERSION:-not loaded} (${NTP_TOOL_SRC:-not loaded})"
        echo "run log:      ${SETUP_LOG}"
        echo "---- last 20 lines of the run log ----"
        sleep 0.3   # the run log is written through tee; let it catch up
        tail -n 20 "$SETUP_LOG" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
        echo "==== end ===="
        echo
    } >> "$AUDIT_LOG" 2>/dev/null \
        && chmod 640 "$AUDIT_LOG" 2>/dev/null \
        && log_info "Recorded in ${AUDIT_LOG}." \
        || log_warn "Could not write the audit record to ${AUDIT_LOG}."
}

# ntp_failed <what> <exit code> <detail>
# Returns 0 if the operator (or an unattended run) chose to skip NTP and
# continue; exits the script if the operator chose to exit.
ntp_failed() {
    local what="$1" rc="$2" detail="$3" choice="" decision
    echo
    log_error "NTP configuration failed: ${what}"
    log_error "  exit code ${rc}: ${detail}"

    if is_interactive; then
        while :; do
            choice="$(ask "Exit setup now (E), or skip NTP configuration and continue (S)?")"
            case "$choice" in
                [Ee]|[Ee]xit) decision="operator chose to exit"; break ;;
                [Ss]|[Ss]kip) decision="skipped, flagged for review"; break ;;
                *) echo "Please answer E or S." ;;
            esac
        done
    else
        decision="skipped automatically (no operator to ask), flagged for review"
        log_warn "No terminal to ask on; skipping NTP and continuing."
    fi

    audit_record "$decision" "$what" "$rc" "$detail"
    ntp_cleanup

    if [[ "$decision" == "operator chose to exit" ]]; then
        log_error "Exiting at the operator's request. Time synchronization was not configured; nothing after this step was run."
        exit 1
    fi
    NTP_OUTCOME="SKIPPED AFTER ERROR - flagged for review"
    FLAGGED_ITEMS+=("Time synchronization (NTP): ${what} (exit code ${rc}). Skipped; see ${AUDIT_LOG}.")
    log_warn "Skipping NTP configuration. It is flagged for review in the final summary."
    return 0
}

configure_ntp() {
    log_info "== Time synchronization (NTP) =="

    if (( SKIP_NTP )); then
        log_info "Skipped (--skip-ntp)."
        NTP_OUTCOME="skipped (--skip-ntp)"
        return 0
    fi

    log_info "Current time server configuration:"
    show_time_sync_status

    local rc=0 args=() out

    if (( NTP_HAS_SETTINGS )); then
        # Settings on the command line are the answers: pass them to the
        # tool's own unattended interface, which validates before touching
        # anything and reports "RESULT: changed" or "RESULT: unchanged".
        (( NTP_SOURCES_SET )) && args+=(--sources "$NTP_SOURCES")
        (( NTP_ALLOW_SET )) && args+=(--allow "$NTP_ALLOW")
        (( NTP_STRATUM_SET )) && args+=(--stratum "$NTP_STRATUM")
        if ! resolve_ntp_tool; then
            ntp_failed "could not load the NTP-Config script" 1 "$NTP_ERR"
            return 0
        fi
        log_info "Applying the NTP settings given on the command line..."
        out="$(timeout 600 bash "$NTP_TOOL" "${args[@]}" </dev/null 2>&1)" || rc=$?
        printf '%s\n' "$out"
        if (( rc != 0 )); then
            local why="configure-ntp-server.sh exited non-zero (see the output above)."
            (( rc == 2 )) && why="configure-ntp-server.sh rejected the --ntp-* arguments as invalid; nothing was changed."
            ntp_failed "configure-ntp-server.sh ${args[*]}" "$rc" "$why"
            return 0
        fi
        NTP_OUTCOME="configured from command-line settings ($(tail -n1 <<<"$out" | sed 's/^RESULT: //'))"
        ntp_cleanup
        return 0
    fi

    if ! is_interactive; then
        log_info "No terminal to ask on and no --ntp-* settings given; leaving the time configuration as it is."
        NTP_OUTCOME="unchanged (unattended, no --ntp-* settings)"
        ntp_cleanup
        return 0
    fi

    if ! confirm "Do you need to change the time server configuration?" "n"; then
        log_info "Leaving the time configuration as it is."
        NTP_OUTCOME="unchanged (operator declined)"
        ntp_cleanup
        return 0
    fi

    if ! resolve_ntp_tool; then
        ntp_failed "could not load the NTP-Config script" 1 "$NTP_ERR"
        return 0
    fi

    log_info "Starting the NTP-Config menu. When you are done, choose 7 (Exit); it will offer to apply any changes that are still pending."
    wait_for_tty_foreground
    # No timeout: an operator is driving this menu.
    bash "$NTP_TOOL" --no-update || rc=$?
    if (( rc != 0 )); then
        ntp_failed "configure-ntp-server.sh interactive session" "$rc" "configure-ntp-server.sh exited non-zero (see the output above; the tool restores its last backup if chrony would not start)."
        return 0
    fi

    NTP_OUTCOME="configured with configure-ntp-server.sh ${NTP_TOOL_VERSION} (${NTP_TOOL_SRC})"
    log_info "NTP-Config was run from a temporary or repo copy and is not installed on this host. To keep it installed with self-updates, see Linux/NTP-Config/README.md (Quick Start)."
    ntp_cleanup
}

# ---------------------------------------------------------------------------
# 3. Cockpit
# ---------------------------------------------------------------------------
open_cockpit_firewall_port() {
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        timeout 30 firewall-cmd --add-service=cockpit --permanent >/dev/null
        timeout 30 firewall-cmd --reload >/dev/null
        log_info "  firewalld: opened the cockpit service (TCP 9090)."
    elif command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow 9090/tcp >/dev/null
        log_info "  ufw: allowed TCP 9090 for Cockpit."
    else
        log_info "  No active host firewall (firewalld/ufw) detected; nothing to open. If one is enabled later, allow TCP 9090 for Cockpit."
    fi
}

install_cockpit() {
    log_info "== Cockpit =="
    case "$DISTRO_FAMILY" in
        debian)
            local codename="$DISTRO_VERSION_CODENAME"
            [[ -n "$codename" ]] || die "Could not determine VERSION_CODENAME from /etc/os-release; cannot install Cockpit from backports."
            if [[ "$DISTRO_ID" == "debian" ]] \
                && ! grep -rq "${codename}-backports" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
                log_info "  Adding ${codename}-backports apt source (Debian does not enable it by default; Ubuntu already does)."
                echo "deb http://deb.debian.org/debian ${codename}-backports main" > /etc/apt/sources.list.d/backports.list
            fi
            timeout 300 apt-get update -y
            timeout 300 apt-get install -y -t "${codename}-backports" cockpit
            ;;
        fedora|rhel)
            timeout 300 "$PKG_MANAGER" install -y cockpit
            ;;
    esac
    timeout 60 systemctl enable --now cockpit.socket
    systemctl is-active --quiet cockpit.socket || die "cockpit.socket did not become active after enabling it."
    log_info "Cockpit installed and listening (cockpit.socket active)."
    open_cockpit_firewall_port
}

# ---------------------------------------------------------------------------
# 4a. Keep dracut's initramfs from bringing the NIC up (called from
#     configure_netplan_renderer, so only runs where netplan is in use)
#
# Ubuntu releases that build the initramfs with dracut ship an image that
# contains systemd-networkd plus a DHCP-everything default .network file. It
# DHCPs the NIC before the real system starts, and the address survives the
# switch-root. With the NetworkManager renderer nothing in netplan overrides
# it, so NetworkManager adopts that leftover address ("connection-assumed")
# and never applies the static netplan profile: the host boots on a DHCP
# address until someone runs 'netplan apply'. Ubuntu ships a dracut profile
# that omits the networking modules, but only as an opt-in subdirectory.
# ---------------------------------------------------------------------------
configure_initramfs_no_network() {
    local src="/usr/lib/dracut/dracut.conf.d/no-network/10-no-network.conf"
    local dest="/etc/dracut.conf.d/10-no-network.conf"

    if ! command -v dracut >/dev/null 2>&1 \
        || ! command -v update-initramfs >/dev/null 2>&1 \
        || [[ ! -f "$src" ]]; then
        log_info "  initramfs: dracut's no-network profile is not available on this host; nothing to do."
        return 0
    fi
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
        log_info "  initramfs: dracut no-network profile already installed, skipping."
        return 0
    fi
    if [[ -e "$dest" ]]; then
        log_warn "  initramfs: $dest already exists with different content; leaving it alone. If this host boots on a DHCP address until 'netplan apply', make sure it omits net-lib and systemd-networkd."
        return 0
    fi

    # Only safe when nothing in early boot needs the network (network root,
    # iSCSI, NFS): skip, and say so, if anything suggests otherwise.
    local dracut_conf
    dracut_conf="$(grep -hsvE '^[[:space:]]*#' /etc/dracut.conf /etc/dracut.conf.d/*.conf || true)"
    if grep -qE '(^| )(netroot=|nfsroot=|ip=|rd\.neednet|root=(nfs|iscsi|cifs|nbd))' /proc/cmdline \
        || [[ "$(findmnt -no FSTYPE / 2>/dev/null || true)" =~ ^(nfs|nfs4|cifs|9p|fuse.*)$ ]] \
        || grep -qE 'network|nfs|iscsi|livenet|netroot' <<<"$dracut_conf"; then
        log_warn "  initramfs: this host may need the network in early boot (network root, iSCSI/NFS, or dracut network settings); not removing networking from the initramfs. If it boots on a DHCP address until 'netplan apply', see this script's notes on the dracut default network file."
        return 0
    fi

    log_info "  initramfs: installing dracut's no-network profile and rebuilding the initramfs (takes a minute)..."
    install -m 644 "$src" "$dest"
    if ! timeout 600 update-initramfs -u; then
        rm -f "$dest"
        die "update-initramfs failed. Removed $dest so future initramfs builds are unaffected; check /boot before rebooting."
    fi

    if command -v lsinitrd >/dev/null 2>&1; then
        local leftover
        leftover="$(lsinitrd 2>/dev/null | grep -ciE 'systemd-networkd|net-lib' || true)"
        if [[ "${leftover:-0}" -ne 0 ]]; then
            log_warn "  initramfs: still lists ${leftover} networking entries after the rebuild (lsinitrd checks the running kernel's image, which may not be the one just rebuilt if a newer kernel is installed)."
            return 0
        fi
    fi
    log_info "  initramfs: rebuilt without networking; takes effect on the next boot."
}

# ---------------------------------------------------------------------------
# 4. netplan renderer (Debian/Ubuntu with netplan only - no-op elsewhere,
#    including all of Fedora/RHEL which do not use netplan)
# ---------------------------------------------------------------------------
configure_netplan_renderer() {
    log_info "== netplan renderer =="
    if ! command -v netplan >/dev/null 2>&1; then
        log_info "netplan not present on this host; skipping (expected on Fedora/RHEL and on Debian hosts not using netplan)."
        return 0
    fi
    local yaml_files=(/etc/netplan/*.yaml)
    if [[ ! -e "${yaml_files[0]}" ]]; then
        log_info "No netplan YAML files found under /etc/netplan; skipping."
        return 0
    fi

    local f
    for f in "${yaml_files[@]}"; do
        if grep -Eq '^[[:space:]]*renderer:[[:space:]]*NetworkManager[[:space:]]*$' "$f"; then
            log_info "  ${f}: renderer already set to NetworkManager, skipping."
            continue
        fi
        cp -a "$f" "${f}.bak-$(date '+%Y%m%d-%H%M%S')"
        if grep -Eq '^[[:space:]]*renderer:[[:space:]]*' "$f"; then
            sed -i -E 's/^([[:space:]]*renderer:[[:space:]]*).*/\1NetworkManager/' "$f"
            log_info "  ${f}: updated existing renderer to NetworkManager (backup saved alongside it)."
        else
            # Netplan configs can hold secrets (wifi passwords) and netplan
            # warns unless they're 600: create the temp file private, then
            # copy the original's mode/owner before it replaces the original.
            ( umask 077; awk '
                { print }
                /^network:[[:space:]]*$/ && !done { print "  renderer: NetworkManager"; done=1 }
            ' "$f" > "${f}.tmp" ) \
                && chmod --reference="$f" "${f}.tmp" \
                && chown --reference="$f" "${f}.tmp" \
                && mv "${f}.tmp" "$f"
            grep -Eq '^[[:space:]]*renderer:[[:space:]]*NetworkManager[[:space:]]*$' "$f" \
                || die "Failed to insert 'renderer: NetworkManager' into ${f} - its 'network:' line was not in the expected format (expected a bare 'network:' key with no trailing content on that line). Edit it manually (a backup was saved alongside it)."
            log_info "  ${f}: added renderer: NetworkManager (backup saved alongside it)."
        fi
    done

    netplan generate || die "netplan generate failed after editing renderer config - check the files under /etc/netplan for a syntax error (backups were saved alongside each edited file)."
    log_info "netplan config validated. NOT applied automatically (avoids disrupting an active remote session) - run 'sudo netplan apply' or reboot when ready."

    configure_initramfs_no_network
}

# ---------------------------------------------------------------------------
# 5. Unattended OS updates
# ---------------------------------------------------------------------------
configure_unattended_updates() {
    log_info "== Unattended updates =="
    case "$DISTRO_FAMILY" in
        debian)
            timeout 300 apt-get install -y unattended-upgrades apt-listchanges
            echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
            timeout 300 dpkg-reconfigure -f noninteractive unattended-upgrades
            log_info "unattended-upgrades installed and enabled."
            ;;
        fedora|rhel)
            timeout 300 "$PKG_MANAGER" install -y dnf-automatic
            local conf="/etc/dnf/automatic.conf"
            [[ -f "$conf" ]] || die "Expected config file not found after installing dnf-automatic: ${conf}"
            if grep -Eq '^[[:space:]]*apply_updates[[:space:]]*=[[:space:]]*yes[[:space:]]*$' "$conf"; then
                log_info "  dnf-automatic: apply_updates already enabled."
            else
                cp -a "$conf" "${conf}.bak-$(date '+%Y%m%d-%H%M%S')"
                if grep -Eq '^[[:space:]]*apply_updates[[:space:]]*=' "$conf"; then
                    sed -i -E 's/^[[:space:]]*apply_updates[[:space:]]*=.*/apply_updates = yes/' "$conf"
                else
                    printf '\napply_updates = yes\n' >> "$conf"
                fi
                log_info "  dnf-automatic: set apply_updates = yes (backup saved)."
            fi
            timeout 60 systemctl enable --now dnf-automatic.timer
            systemctl is-active --quiet dnf-automatic.timer || die "dnf-automatic.timer did not become active after enabling it."
            log_info "dnf-automatic installed and enabled."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 6. usr_admin group + /opt ACLs (delegates to Group-MGMT's own script -
#    single source of truth, not duplicated logic)
# ---------------------------------------------------------------------------
USR_ADMIN_CONFIGURED=0

setup_usr_admin_group() {
    log_info "== usr_admin group and /opt permissions =="

    if getent group usr_admin >/dev/null 2>&1; then
        log_info "usr_admin group already exists; ensuring root and ${ADMIN_USER} are members..."
    else
        if [[ "$ASSUME_YES" -ne 1 && -t 0 ]]; then
            echo
            if ! confirm "usr_admin does not exist on this host yet. Create it (GID 3000) and add root + ${ADMIN_USER}?" "y"; then
                log_info "Declined - skipping usr_admin group creation, /opt ACLs, and log access for it. Continuing with the rest of setup."
                return 0
            fi
        fi
        log_info "Creating usr_admin group..."
    fi

    if [[ -f "$GROUP_MGMT_LOCAL" ]]; then
        log_info "Using local Group-MGMT/create-usr_admin-group.sh..."
        timeout 300 bash "$GROUP_MGMT_LOCAL" --users "root,${ADMIN_USER}" --yes
    else
        log_info "Local Group-MGMT script not found (standalone run); fetching from ${GROUP_MGMT_URL}..."
        local tmp
        tmp="$(mktemp)"
        # shellcheck disable=SC2064
        trap "rm -f '${tmp}'" RETURN
        timeout 30 curl -fsSL "$GROUP_MGMT_URL" -o "$tmp" || die "Failed to fetch create-usr_admin-group.sh from ${GROUP_MGMT_URL}."
        timeout 300 bash "$tmp" --users "root,${ADMIN_USER}" --yes
    fi

    log_info "Granting usr_admin read/write/execute on /opt (with default ACL for future files)..."
    setfacl -R -m g:usr_admin:rwX /opt
    setfacl -R -d -m g:usr_admin:rwX /opt
    log_info "usr_admin group and /opt ACLs configured."

    # usr_admin may not have existed when LOG_DIR was first locked down
    # (this is, on a fresh host, the step that creates it) - reapply now
    # to also grant it read access to this and future runs' logs,
    # alongside the "adm" group already granted at startup.
    apply_log_permissions "$LOG_DIR" "usr_admin"
    log_info "usr_admin also granted read access to $LOG_DIR."

    USR_ADMIN_CONFIGURED=1
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
install_base_packages
set_timezone
configure_ntp
install_cockpit
configure_netplan_renderer
configure_unattended_updates
setup_usr_admin_group

# Retention cleanup: non-fatal by design - a failure here must not flip an
# otherwise-successful provisioning run into a reported failure.
find "$LOG_DIR" -name 'setup-*.log' -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true

echo
if (( ${#FLAGGED_ITEMS[@]} )); then
    log_warn "Server setup complete, with ${#FLAGGED_ITEMS[@]} item(s) flagged for review."
else
    log_info "Server setup complete."
fi
echo "  Timezone:    $(timedatectl show --property=Timezone --value)"
echo "  Time sync:   ${NTP_OUTCOME}"
echo "  Time daemon: $(active_time_daemon), clock synchronized: $(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo unknown)"
echo "  Cockpit:     https://$(hostname -f 2>/dev/null || hostname):9090"
if (( USR_ADMIN_CONFIGURED )); then
    echo "  usr_admin:   root, ${ADMIN_USER}  (GID 3000, rwX on /opt, read access on $LOG_DIR)"
else
    echo "  usr_admin:   not configured (declined when prompted - re-run to set it up later)"
fi
echo "  Log:         $SETUP_LOG"
if command -v netplan >/dev/null 2>&1; then
    netplan_files=(/etc/netplan/*.yaml)
    if [[ -e "${netplan_files[0]}" ]]; then
        echo "  netplan:     renderer set to NetworkManager - run 'sudo netplan apply' or reboot to activate"
    fi
fi
if [[ "$(active_time_daemon)" == "none detected" ]]; then
    echo
    log_warn "No active time synchronization daemon was detected on this host. Re-run this script and answer yes to the time server question, or pass --ntp-sources."
fi
echo
echo "Re-run this script any time; every step is safe to repeat."

if (( ${#FLAGGED_ITEMS[@]} )); then
    echo
    log_warn "FLAGGED FOR REVIEW:"
    for _item in "${FLAGGED_ITEMS[@]}"; do
        log_warn "  - ${_item}"
    done
    log_warn "Exiting with code 3 (completed, items flagged for review)."
    exit 3
fi
