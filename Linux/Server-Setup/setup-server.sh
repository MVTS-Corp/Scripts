#!/usr/bin/env bash
#
# setup-server.sh
# 2026-10-18
# Version: v1.7.0
#
# CHANGELOG:
#   v1.7.0 - Fixes and a production tool baseline:
#            * usr_admin: an interactive run now shows who is in the group
#              and lets the operator add other local users to it (names, or
#              all), or carry on as is. --usr-admin-user names more members
#              up front. Previously only root and the admin user were ever
#              added, with no way to add anyone else during setup.
#            * curl is installed first when missing (some minimal images
#              ship without it) instead of stopping at pre-flight.
#            * Base packages are now the essentials a daily-use production
#              server needs (curl, ca-certificates, sudo, tar, unzip,
#              openssh-server, acl, net-tools, DNS tools, NetworkManager,
#              iproute, procps) plus best-effort admin tools (wget, vim,
#              nano, less, htop, tmux, git, rsync, jq, lsof, psmisc, ping,
#              traceroute, mtr, tcpdump, pciutils, bash-completion, man
#              pages, logrotate, smartmontools on real hardware).
#              Essentials must install; an extra a repo lacks is skipped
#              with a note. A newly installed SSH server is started; an
#              existing one is left as the admin set it.
#              --skip-extra-tools installs only the essentials.
#   v1.6.0 - Security and operations baselines, each its own step with a
#            --skip-* flag:
#            * Firewall: hands off to Linux/Firewall-Config/
#              configure-firewall.sh (ufw or firewalld): default-deny inbound,
#              SSH allowed on the port sshd uses (rate limited on ufw),
#              Cockpit, optional --mgmt-subnet and --allow-port. Runs before
#              Cockpit and NTP so their rules land in an active firewall.
#            * SSH hardening: a sshd_config.d drop-in (MaxAuthTries 4,
#              LoginGraceTime 30, no X11 forwarding, no empty passwords,
#              keepalives). Root login is turned off only when the admin
#              user can sudo; password logins only with --ssh-disable-
#              passwords and a key already installed. Validated with sshd -t
#              and reverted if rejected.
#            * fail2ban: sshd jail with a 1 hour ban that doubles per repeat
#              offense up to a week, management subnet never banned.
#            * Guest tools for the hypervisor (qemu-guest-agent, open-vm-
#              tools, Hyper-V daemons) detected with systemd-detect-virt.
#            * Logging: persistent journald with a 1G / 3 month cap.
#            * Updates: --updates auto (default, unattended-upgrades or
#              dnf-automatic) or reporting (hands off to Linux/Updates for
#              emailed run reports, instead of the automatic updater); an
#              interactive run can also install Linux/Notifications
#              (send-alert).
#            A failed optional step is flagged in the final summary and the
#            run exits 3; it does not stop the run.
#   v1.5.0 - Fixes from issue #3 (found on Ubuntu Server 2026 LTS):
#            * The admin user is optional. With no --admin-user and no sudo
#              user to default to, an interactive run lets the answer be
#              blank and an unattended run carries on; usr_admin then holds
#              root only. It used to stop with "a user must be specified".
#            * New first step: a full operating system update (apt full-
#              upgrade, or dnf upgrade) before anything else is installed;
#              --skip-os-update skips it. The final summary says when the
#              host needs a reboot afterward.
#            * New step after the base packages: offers to change the host
#              name, entered as one full name including the domain (for
#              example server01.example.com), or pass --hostname.
#            * The time servers now default to NTP-Config's "preferred" set
#              (interactive runs ask first and can decline, and can open
#              the NTP-Config menu to choose something else; unattended runs
#              apply it unless --ntp-sources says otherwise or --skip-ntp is
#              given). Previously --yes alone left the time servers alone.
#            Works with NTP-Config v1.8.0, whose menu now offers a pool for
#            any country or region instead of only the USA.
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
# Baseline provisioning for a freshly installed Linux server: operating
# system update, base packages, host name, timezone, time synchronization
# (via NTP-Config/configure-ntp-server.sh), Cockpit, NetworkManager as the netplan
# renderer (where applicable), unattended OS updates, and the usr_admin
# permissions group on /opt (via Group-MGMT/create-usr_admin-group.sh).
# Detects the host distro and adapts package names/mechanisms
# accordingly. Supports Debian/Ubuntu, Fedora, and RHEL-family distros
# (RHEL, CentOS, Rocky, AlmaLinux). Safe to re-run.
#
# USAGE:
#   setup-server.sh [--admin-user NAME] [--hostname FQDN] [--timezone TZ]
#                   [--yes] [--skip-os-update] [--mgmt-subnet CIDRS]
#                   [--allow-port SPEC] [--updates auto|reporting|skip]
#                   [--skip-firewall] [--skip-fail2ban] [--skip-ssh-hardening]
#                   [--ssh-disable-passwords] [--skip-guest-tools]
#                   [--skip-logging]
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
FW_LOCAL="${SCRIPT_DIR}/../Firewall-Config/configure-firewall.sh"
FW_URL="https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Firewall-Config/configure-firewall.sh"
UPDATES_LOCAL="${SCRIPT_DIR}/../Updates/install.sh"
NOTIFICATIONS_LOCAL="${SCRIPT_DIR}/../Notifications/install.sh"
LOG_DIR="/var/log/server-setup"
AUDIT_LOG="${LOG_DIR}/audit.log"
LOG_RETENTION_DAYS=180
SCRIPT_VERSION="v1.7.0"

# Package sets for a daily-use production server. The essentials must install
# (the run stops if they cannot); the extras are best effort, since a repo may
# not carry every one (htop and a few others need EPEL on RHEL-family hosts).
BASE_ESSENTIAL_DEB=(ca-certificates curl sudo tar unzip acl net-tools dnsutils network-manager iproute2 procps openssh-server)
BASE_ESSENTIAL_RPM=(ca-certificates curl sudo tar unzip acl net-tools bind-utils NetworkManager iproute procps-ng openssh-server)
BASE_EXTRA_DEB=(wget gnupg zip bzip2 xz-utils vim nano less htop tmux git rsync jq lsof psmisc iputils-ping traceroute mtr-tiny tcpdump pciutils bash-completion man-db logrotate)
BASE_EXTRA_RPM=(wget gnupg2 zip bzip2 xz vim-enhanced nano less htop tmux git rsync jq lsof psmisc iputils traceroute mtr tcpdump pciutils bash-completion man-db logrotate)

EXTRA_ADMINS=()
SKIP_EXTRA_TOOLS=0
MGMT_SUBNET=""
ALLOW_PORTS=()
UPDATES_MODE=""
SKIP_FIREWALL=0
SKIP_FAIL2BAN=0
SKIP_SSH_HARDENING=0
SSH_DISABLE_PASSWORDS=0
SKIP_GUEST_TOOLS=0
SKIP_LOGGING=0
# Set to 1 once the firewall step has applied the baseline, so the Cockpit
# step does not open its port again from anywhere (which would undo a
# --mgmt-subnet restriction).
FIREWALL_MANAGED=0
FW_TOOL=""
FW_TMP=""
ADMIN_USER=""
NEW_HOSTNAME=""
TIMEZONE="America/New_York"
ASSUME_YES=0
CHECK_ONLY=0
SKIP_OS_UPDATE=0
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
# What NTP-Config's "preferred" source set contains, for display only (the
# tool owns the real list; this is not passed to it).
NTP_PREFERRED_DESC="time.cloudflare.com, us.pool.ntp.org, time.nist.gov"
NTP_TOOL=""
NTP_TOOL_SRC=""
NTP_TOOL_VERSION=""
NTP_TMP=""
NTP_ERR=""

usage() {
    cat <<EOF
Usage: sudo ${0##*/} [--admin-user NAME] [--hostname FQDN] [--timezone TZ] [--yes]
                     [--skip-os-update]
                     [--skip-ntp | --ntp-sources V --ntp-allow CIDRS --ntp-stratum N]
       sudo ${0##*/} --check

  --admin-user NAME  Existing local username to add (alongside root) to
                     the usr_admin group. Optional. If omitted, defaults to
                     the user who ran sudo (\$SUDO_USER); if that isn't
                     available (run directly as root), you are prompted and
                     can leave the answer blank, or with no terminal the
                     group simply holds root only. If usr_admin doesn't
                     exist yet, you'll be asked separately to confirm
                     creating it - declining skips that step only, not the
                     rest of provisioning.
  --hostname FQDN    Set the host name, as one full name including the
                     domain (for example server01.example.com). Without it,
                     an interactive run asks whether to change the host
                     name; an unattended run leaves it alone.
  --timezone TZ      IANA timezone name (default: America/New_York).
  --yes              Skip all confirmation prompts, including usr_admin
                     creation if it doesn't already exist. The time servers
                     are then set to the preferred set unless --ntp-sources
                     or --skip-ntp says otherwise.
  --usr-admin-user NAMES
                     More existing local users to add to usr_admin (comma
                     separated; repeatable). An interactive run also asks
                     whether to add others.
  --skip-os-update   Skip the full operating system update that runs first.
  --skip-extra-tools Install only the essential packages, not the usual
                     admin tools (htop, tmux, git, vim, ...).
  --mgmt-subnet CIDRS
                     Management subnet(s), comma separated. SSH and Cockpit
                     are then reachable only from there, and fail2ban never
                     bans it. Without it SSH and Cockpit are open to any
                     address (SSH rate limited, fail2ban watching). An
                     interactive run asks.
  --allow-port SPEC  Also open an inbound port, such as 443/tcp or
                     8000:8100/udp. Repeatable.
  --updates MODE     auto (default): unattended-upgrades or dnf-automatic.
                     reporting: install Linux/Updates instead (scheduled
                     updates with an emailed report; interactive only).
                     skip: leave automatic updates alone.
  --skip-firewall    Do not configure the host firewall.
  --skip-fail2ban    Do not install or configure fail2ban.
  --skip-ssh-hardening
                     Leave the SSH server configuration alone.
  --ssh-disable-passwords
                     Also turn off SSH password logins. Only applied when the
                     admin user already has an SSH key installed.
  --skip-guest-tools Do not install hypervisor guest tools.
  --skip-logging     Do not set up persistent journald logging.
  --skip-ntp         Skip the time synchronization (NTP) step entirely.
  --ntp-sources V    Set the time sources unattended: native, preferred
                     (the default), pool:ZONE (a country code such as
                     pool:de, or a continent such as pool:europe), or a
                     comma separated list of hostnames/IPs.
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
  sudo ./${0##*/} --yes --hostname web01.example.com --ntp-sources pool:de
  sudo ./${0##*/} --admin-user jsmith --yes --ntp-allow 192.168.1.0/24
  sudo ./${0##*/} --yes --mgmt-subnet 10.0.0.0/24 --allow-port 443/tcp
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --admin-user)
            [[ $# -ge 2 ]] || { echo "ERROR: --admin-user requires a value." >&2; exit 1; }
            ADMIN_USER="$2"; shift 2 ;;
        --hostname)
            [[ $# -ge 2 ]] || { echo "ERROR: --hostname requires a value." >&2; exit 1; }
            NEW_HOSTNAME="$2"; shift 2 ;;
        --timezone)
            [[ $# -ge 2 ]] || { echo "ERROR: --timezone requires a value." >&2; exit 1; }
            TIMEZONE="$2"; shift 2 ;;
        --skip-os-update)
            SKIP_OS_UPDATE=1; shift ;;
        --skip-extra-tools)
            SKIP_EXTRA_TOOLS=1; shift ;;
        --usr-admin-user)
            [[ $# -ge 2 ]] || { echo "ERROR: --usr-admin-user requires a value." >&2; exit 1; }
            for _name in ${2//,/ }; do EXTRA_ADMINS+=("$_name"); done
            shift 2 ;;
        --mgmt-subnet)
            [[ $# -ge 2 ]] || { echo "ERROR: --mgmt-subnet requires a value." >&2; exit 1; }
            MGMT_SUBNET="${MGMT_SUBNET:+${MGMT_SUBNET},}$2"; shift 2 ;;
        --allow-port)
            [[ $# -ge 2 ]] || { echo "ERROR: --allow-port requires a value." >&2; exit 1; }
            ALLOW_PORTS+=("$2"); shift 2 ;;
        --updates)
            [[ $# -ge 2 ]] || { echo "ERROR: --updates requires a value." >&2; exit 1; }
            UPDATES_MODE="$2"; shift 2 ;;
        --skip-firewall)
            SKIP_FIREWALL=1; shift ;;
        --skip-fail2ban)
            SKIP_FAIL2BAN=1; shift ;;
        --skip-ssh-hardening)
            SKIP_SSH_HARDENING=1; shift ;;
        --ssh-disable-passwords)
            SSH_DISABLE_PASSWORDS=1; shift ;;
        --skip-guest-tools)
            SKIP_GUEST_TOOLS=1; shift ;;
        --skip-logging)
            SKIP_LOGGING=1; shift ;;
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

# valid_hostname NAME - a host name or full domain name (RFC 1123): labels of
# letters, digits and hyphens, 1-63 characters each, not starting or ending
# with a hyphen, 253 characters in all.
valid_hostname() {
    local name="$1" label
    [[ -n "$name" && ${#name} -le 253 ]] || return 1
    local IFS=.
    for label in $name; do
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done
    [[ "$name" != *..* && "$name" != .* ]]
}

if [[ -n "$NEW_HOSTNAME" ]]; then
    NEW_HOSTNAME="${NEW_HOSTNAME%.}"
    NEW_HOSTNAME="${NEW_HOSTNAME,,}"
    valid_hostname "$NEW_HOSTNAME" || { echo "ERROR: --hostname '${NEW_HOSTNAME}' is not a valid host name. Use letters, digits and hyphens in each part, for example server01.example.com." >&2; exit 1; }
fi

# True when something the operator typed on the command line is an NTP answer
# (as opposed to the "preferred" default applied when nothing was said).
NTP_HAS_SETTINGS=$(( NTP_SOURCES_SET || NTP_ALLOW_SET || NTP_STRATUM_SET ))

# True when a person can be asked a question (same test the other prompts use).
is_interactive() { [[ "$ASSUME_YES" -ne 1 && -t 0 ]]; }

# Everyone who ends up in usr_admin besides root: the admin user plus any
# extras (--usr-admin-user, or named at the prompt). Sets ADMIN_MEMBERS (comma
# separated, root first) and ADMIN_MEMBERS_TEXT (for messages), de-duplicated.
refresh_admin_members() {
    local u list=("root") text seen=" root "
    for u in "$ADMIN_USER" ${EXTRA_ADMINS[@]+"${EXTRA_ADMINS[@]}"}; do
        [[ -n "$u" && "$seen" != *" ${u} "* ]] || continue
        list+=("$u"); seen+="${u} "
    done
    ADMIN_MEMBERS="$(IFS=,; echo "${list[*]}")"
    case ${#list[@]} in
        1) text="root" ;;
        2) text="root and ${list[1]}" ;;
        *) text="$(IFS=,; echo "${list[*]:0:${#list[@]}-1}" | sed 's/,/, /g'), and ${list[${#list[@]}-1]}" ;;
    esac
    ADMIN_MEMBERS_TEXT="$text"
}

# valid_cidr CIDR - IPv4 or IPv6. The firewall tool does the strict check; this
# catches typos before anything on the host is touched.
valid_cidr() {
    local c="$1" octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
    [[ "$c" =~ ^${octet}\.${octet}\.${octet}\.${octet}/(3[0-2]|[12]?[0-9])$ ]] && return 0
    [[ "$c" =~ ^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*/(12[0-8]|1[01][0-9]|[1-9]?[0-9])$ ]]
}

# Used by the plan dialog and the SSH hardening step.
admin_can_sudo() {
    [[ -n "$ADMIN_USER" ]] || return 1
    local g
    g="$(id -nG "$ADMIN_USER" 2>/dev/null)" || return 1
    [[ " $g " == *" sudo "* || " $g " == *" wheel "* ]]
}

admin_has_ssh_key() {
    [[ -n "$ADMIN_USER" ]] || return 1
    local home
    home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
    [[ -n "$home" && -s "${home}/.ssh/authorized_keys" ]] \
        && grep -qvE '^[[:space:]]*(#|$)' "${home}/.ssh/authorized_keys"
}

# Checks a comma separated CIDR list; sets MGMT_SUBNET to it, normalized.
set_mgmt_subnet() {
    local raw="${1//,/ }" tok out=()
    for tok in $raw; do
        valid_cidr "$tok" || return 1
        out+=("$tok")
    done
    (( ${#out[@]} )) || return 1
    MGMT_SUBNET="${out[*]}"
    MGMT_SUBNET="${MGMT_SUBNET// /,}"
}

if [[ -n "$MGMT_SUBNET" ]]; then
    set_mgmt_subnet "$MGMT_SUBNET" || { echo "ERROR: --mgmt-subnet needs one or more CIDRs such as 10.0.0.0/24." >&2; exit 1; }
fi
for _spec in ${ALLOW_PORTS[@]+"${ALLOW_PORTS[@]}"}; do
    [[ "$_spec" =~ ^[0-9]{1,5}(:[0-9]{1,5})?/(tcp|udp)$ ]] \
        || { echo "ERROR: --allow-port '${_spec}' is not a port spec like 443/tcp or 8000:8100/udp." >&2; exit 1; }
done
case "$UPDATES_MODE" in
    ""|auto|skip) ;;
    reporting)
        is_interactive || { echo "ERROR: --updates reporting installs Linux/Updates, which asks its own questions; it needs a terminal and cannot be combined with --yes." >&2; exit 1; } ;;
    *) echo "ERROR: --updates must be auto, reporting, or skip." >&2; exit 1 ;;
esac
if (( SKIP_FIREWALL )) && { [[ -n "$MGMT_SUBNET" ]] || (( ${#ALLOW_PORTS[@]} )); }; then
    echo "ERROR: --skip-firewall cannot be combined with --mgmt-subnet or --allow-port." >&2
    exit 1
fi

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

for cmd in timedatectl systemctl awk id; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: ${cmd}. This is not a standard Linux environment."
done

# curl is used to fetch sibling tools and is missing from some minimal
# installs. Everything else this script needs comes with the base system, so
# curl is the one thing installed here, before the "Proceed?" prompt, rather
# than stopping. (--check only reports it.)
if ! command -v curl >/dev/null 2>&1; then
    if (( CHECK_ONLY )); then
        log_warn "curl is not installed. A real run installs it first."
    else
        log_info "curl is not installed; installing it (with ca-certificates) before anything else..."
        case "$DISTRO_FAMILY" in
            debian)
                timeout 300 apt-get -o DPkg::Lock::Timeout=180 update -y
                timeout 300 apt-get -o DPkg::Lock::Timeout=180 install -y ca-certificates curl
                ;;
            fedora|rhel)
                timeout 300 "$PKG_MANAGER" install -y ca-certificates curl
                ;;
        esac
        command -v curl >/dev/null 2>&1 || die "Installed curl but the 'curl' command still cannot be found. Install it by hand and re-run."
        log_info "curl installed."
    fi
fi

# No --admin-user given: default to the person who ran sudo, since that is
# almost always the account being set up. Not used when SUDO_USER is unset
# (run directly as root) or is root itself; those fall through to the prompt.
if [[ -z "$ADMIN_USER" && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] \
    && id -u "$SUDO_USER" >/dev/null 2>&1; then
    ADMIN_USER="$SUDO_USER"
    log_info "No --admin-user given; using the invoking sudo user: ${ADMIN_USER} (pass --admin-user NAME to use someone else)."
fi

# The admin user is optional. A blank answer (or none, with no terminal)
# means usr_admin holds root only; root is always a member.
if [[ -z "$ADMIN_USER" && "$CHECK_ONLY" -ne 1 && "$ASSUME_YES" -ne 1 && -t 0 ]]; then
    ADMIN_USER="$(ask "Existing local username to add (alongside root) to usr_admin, or press Enter for root only")"
fi
if [[ "$ADMIN_USER" == "root" ]]; then
    ADMIN_USER=""
fi
if [[ -n "$ADMIN_USER" ]] && ! id -u "$ADMIN_USER" >/dev/null 2>&1; then
    die "User '${ADMIN_USER}' does not exist on this system. Create the account first, then re-run."
fi
if [[ -z "$ADMIN_USER" && "$CHECK_ONLY" -ne 1 ]]; then
    log_info "No admin user given; the usr_admin group will hold root only (pass --admin-user NAME to add someone)."
fi
# What goes into usr_admin, as a comma separated list and as prose.
# Extra members named with --usr-admin-user must exist too.
for _u in ${EXTRA_ADMINS[@]+"${EXTRA_ADMINS[@]}"}; do
    id -u "$_u" >/dev/null 2>&1 || die "User '${_u}' (from --usr-admin-user) does not exist on this system. Create the account first, then re-run."
done
refresh_admin_members

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
    local pkgs pkgs_extra updates ntp cockpit_fw netplan_txt usr_admin_txt
    local netplan_files=(/etc/netplan/*.yaml)

    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        pkgs="${BASE_ESSENTIAL_DEB[*]}"
        pkgs_extra="${BASE_EXTRA_DEB[*]}"
        updates="Install and enable unattended-upgrades (with apt-listchanges) so security and OS updates apply automatically."
    else
        pkgs="${BASE_ESSENTIAL_RPM[*]}"
        pkgs_extra="${BASE_EXTRA_RPM[*]}"
        updates="Install and enable dnf-automatic with apply_updates = yes so OS updates apply automatically."
    fi

    local timesyncd_note=""
    if systemctl is-active --quiet systemd-timesyncd 2>/dev/null && ! command -v chronyd >/dev/null 2>&1; then
        timesyncd_note=" Installing chrony replaces systemd-timesyncd, which is what this host uses now."
    fi
    if (( SKIP_NTP )); then
        ntp="Skipped (--skip-ntp). The time configuration is left exactly as it is."
    elif (( NTP_HAS_SETTINGS )) || ! is_interactive; then
        ntp="Configure time synchronization (chrony) from the command line:"
        ntp+=" sources = ${NTP_SOURCES:-preferred ($NTP_PREFERRED_DESC, the default)};"
        (( NTP_ALLOW_SET )) && ntp+=" allowed subnets = ${NTP_ALLOW};"
        (( NTP_STRATUM_SET )) && ntp+=" stratum lock = ${NTP_STRATUM};"
        ntp="${ntp%;}. Installs chrony if it is missing, via NTP-Config.${timesyncd_note}"
    else
        ntp="Show the current time server configuration, then offer to set the time servers to the preferred set (${NTP_PREFERRED_DESC}); you can decline, and then choose to open NTP-Config's menu to pick a country or region pool, your own servers, allowed subnets or a stratum lock instead.${timesyncd_note}"
    fi

    local os_update host_txt
    if (( SKIP_OS_UPDATE )); then
        os_update="Skipped (--skip-os-update)."
    elif [[ "$DISTRO_FAMILY" == "debian" ]]; then
        os_update="Refresh the package lists and install every available update (apt full-upgrade). This can take several minutes on a fresh install; the host is not rebooted, and you are told at the end if it needs one."
    else
        os_update="Install every available update (${PKG_MANAGER} upgrade). This can take several minutes on a fresh install; the host is not rebooted, and you are told at the end if it needs one."
    fi
    if [[ -n "$NEW_HOSTNAME" ]]; then
        host_txt="Change the host name from $(hostname) to ${NEW_HOSTNAME} (--hostname)."
    elif is_interactive; then
        host_txt="Show the current host name ($(hostname -f 2>/dev/null || hostname)) and ask whether to change it. If you do, enter the full name including the domain, in one line (for example server01.example.com)."
    else
        host_txt="Not changed (no --hostname given)."
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        cockpit_fw="Opens TCP 9090 in firewalld."
    elif command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null || true)" == *"Status: active"* ]]; then
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

    local members="$ADMIN_MEMBERS_TEXT" member_verb="are members"
    if [[ "$ADMIN_MEMBERS" == "root" ]]; then
        member_verb="is a member"
    fi

    if getent group usr_admin >/dev/null 2>&1; then
        usr_admin_txt="The usr_admin group already exists. Make sure ${members} ${member_verb}, and (re)apply its read/write/execute ACLs on /opt (recursive, plus a default ACL so new files inherit it) and read access to the logs in ${LOG_DIR}."
    else
        usr_admin_txt="Create the usr_admin group (GID 3000); you will be asked to confirm this step separately, and declining skips only this step. Add ${members} to it, give it read/write/execute ACLs on /opt (recursive, plus a default ACL so new files inherit it) and read access to the logs in ${LOG_DIR}."
    fi
    if is_interactive; then
        usr_admin_txt+=" You are also asked whether to add other local users to it."
    fi

    echo
    echo "About to provision this host (${DISTRO_NAME}) as a baseline MVTS server."
    echo "The steps below run in this order:"
    echo
    local fw_txt ssh_txt f2b_txt guest_txt log_txt updates_txt backend="ufw"
    [[ "$DISTRO_FAMILY" != "debian" ]] && backend="firewalld"
    if systemctl is-active --quiet firewalld 2>/dev/null; then backend="firewalld"; fi

    if (( SKIP_FIREWALL )); then
        fw_txt="Skipped (--skip-firewall). The host firewall is left as it is."
    else
        fw_txt="Apply a baseline ${backend} firewall: block all inbound traffic except SSH (the port sshd uses, rate limited on ufw) and Cockpit (TCP 9090)"
        if [[ -n "$MGMT_SUBNET" ]]; then
            fw_txt+=", both only from ${MGMT_SUBNET}"
        elif is_interactive; then
            fw_txt+=". You will be asked whether to limit SSH and Cockpit to a management subnet; by default they are reachable from anywhere"
        else
            fw_txt+=", both reachable from any address (pass --mgmt-subnet to limit them)"
        fi
        (( ${#ALLOW_PORTS[@]} )) && fw_txt+=". Also opens: ${ALLOW_PORTS[*]}"
        fw_txt+=". The SSH rules go in before the firewall is switched on, and it refuses to apply anything that would cut off a session that is open now."
    fi

    local virt="unknown"
    command -v systemd-detect-virt >/dev/null 2>&1 && virt="$(systemd-detect-virt 2>/dev/null || true)"
    case "$virt" in
        kvm|qemu) guest_txt="This host is a ${virt} virtual machine: install qemu-guest-agent." ;;
        vmware) guest_txt="This host is a VMware virtual machine: install open-vm-tools." ;;
        microsoft) guest_txt="This host is a Hyper-V virtual machine: install the Hyper-V guest daemons." ;;
        none|"") guest_txt="Not a virtual machine, so nothing is installed." ;;
        *) guest_txt="Detected '${virt}'; no guest tools are installed for it." ;;
    esac
    (( SKIP_GUEST_TOOLS )) && guest_txt="Skipped (--skip-guest-tools)."

    if (( SKIP_LOGGING )); then
        log_txt="Skipped (--skip-logging)."
    else
        log_txt="Keep the systemd journal across reboots, capped at 1G and 3 months of history."
    fi

    if (( SKIP_SSH_HARDENING )); then
        ssh_txt="Skipped (--skip-ssh-hardening). The SSH configuration is left as it is."
    else
        ssh_txt="Add a drop-in under /etc/ssh/sshd_config.d (never an edit of sshd_config): 4 authentication attempts, 30 second login grace, no X11 forwarding, no empty passwords, keepalives. It is checked with sshd -t first and reverted if rejected."
        if admin_can_sudo; then
            ssh_txt+=" Root SSH login is turned off, since ${ADMIN_USER} can use sudo."
        else
            ssh_txt+=" Root SSH login is left as it is, because there is no sudo-capable admin user to fall back on."
        fi
        ssh_txt+=" Password logins stay on unless --ssh-disable-passwords is given (or you say yes when asked) and the admin user already has an SSH key."
    fi

    if (( SKIP_FAIL2BAN )); then
        f2b_txt="Skipped (--skip-fail2ban)."
    else
        f2b_txt="Install fail2ban with an sshd jail: 5 failures in 10 minutes bans the address for 1 hour, doubling for each repeat offense up to 1 week."
        [[ -n "$MGMT_SUBNET" ]] && f2b_txt+=" ${MGMT_SUBNET} is never banned."
    fi

    case "${UPDATES_MODE:-}" in
        skip) updates_txt="Skipped (--updates skip)." ;;
        reporting) updates_txt="Run the Linux/Updates installer (scheduled updates with an emailed report). It asks its own questions." ;;
        auto) updates_txt="$updates" ;;
        *)
            if is_interactive; then
                updates_txt="You choose: automatic updates (no email) or Linux/Updates with an emailed report. Then you are offered the Linux/Notifications send-alert email command (default: no)."
            else
                updates_txt="$updates"
            fi
            ;;
    esac
    if (( ! SKIP_FIREWALL )); then cockpit_fw="Its port is handled in the firewall step."; fi

    plan_step 1 "Operating system update" "$os_update"
    if (( SKIP_EXTRA_TOOLS )); then
        plan_step 2 "Base packages" "Install the essentials: ${pkgs}. A new SSH server is started; one already installed is left as it is. Extra admin tools are skipped (--skip-extra-tools)."
    else
        plan_step 2 "Base packages" "Install the essentials: ${pkgs}. A new SSH server is started; one already installed is left as it is. Then the usual admin tools, best effort (any a repository does not carry is skipped): ${pkgs_extra}$(command -v systemd-detect-virt >/dev/null 2>&1 && ! systemd-detect-virt --quiet 2>/dev/null && echo ", smartmontools")."
    fi
    plan_step 3 "Host name" "$host_txt"
    plan_step 4 "Timezone" "Set the system timezone to ${TIMEZONE}."
    plan_step 5 "Firewall" "$fw_txt"
    plan_step 6 "Time synchronization (NTP)" "$ntp"
    plan_step 7 "Hypervisor guest tools" "$guest_txt"
    plan_step 8 "Cockpit" "Install and enable Cockpit, the web management console (https://<host>:9090). ${cockpit_fw}"
    plan_step 9 "Network renderer (netplan)" "$netplan_txt"
    plan_step 10 "Logging" "$log_txt"
    plan_step 11 "SSH hardening" "$ssh_txt"
    plan_step 12 "fail2ban" "$f2b_txt"
    plan_step 13 "Scheduled updates" "$updates_txt"
    plan_step 14 "usr_admin group and /opt permissions" "$usr_admin_txt"
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
# 0. Operating system update. First, so everything after it installs against
#    current package lists and a current base system. Non-interactive: keep
#    the local version of any config file the host already customized, and
#    wait for the package lock instead of failing if another updater (for
#    example cloud-init or unattended-upgrades on first boot) holds it.
# ---------------------------------------------------------------------------
update_operating_system() {
    log_info "== Operating system update =="
    if (( SKIP_OS_UPDATE )); then
        log_info "Skipped (--skip-os-update)."
        return 0
    fi
    case "$DISTRO_FAMILY" in
        debian)
            timeout 600 apt-get -o DPkg::Lock::Timeout=300 update -y
            timeout 3600 apt-get -o DPkg::Lock::Timeout=300 \
                -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
                full-upgrade -y
            ;;
        fedora|rhel)
            timeout 3600 "$PKG_MANAGER" upgrade -y --refresh
            ;;
    esac
    log_info "Operating system is up to date."
}

# True when the host should be rebooted to finish applying updates.
reboot_required() {
    if [[ -e /var/run/reboot-required ]]; then
        return 0
    fi
    # dnf-utils' needs-restarting -r exits 1 when a reboot is needed.
    if command -v needs-restarting >/dev/null 2>&1; then
        needs-restarting -r >/dev/null 2>&1 || [[ $? -ne 1 ]] || return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# 1. Base packages
# ---------------------------------------------------------------------------
install_base_packages() {
    log_info "== Base packages =="
    local essential=() extra=() p missing=() had_sshd=0
    command -v sshd >/dev/null 2>&1 && had_sshd=1
    case "$DISTRO_FAMILY" in
        debian)
            timeout 300 apt-get -o DPkg::Lock::Timeout=180 update -y
            essential=("${BASE_ESSENTIAL_DEB[@]}"); extra=("${BASE_EXTRA_DEB[@]}")
            ;;
        fedora|rhel)
            essential=("${BASE_ESSENTIAL_RPM[@]}"); extra=("${BASE_EXTRA_RPM[@]}")
            ;;
    esac

    log_info "Installing essential packages: ${essential[*]}"
    pkg_install "${essential[@]}" || die "Could not install the essential packages (${essential[*]}). Check the package manager output above and the host's repositories, then re-run."
    # Never trust the package manager's exit code alone.
    for p in curl tar unzip sudo setfacl nmcli ps ss; do
        command -v "$p" >/dev/null 2>&1 || die "Base package install did not provide the expected command: ${p}."
    done
    command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]] || die "openssh-server installed but sshd was not found."

    # A newly installed SSH server is switched on so the host can be managed
    # remotely. One that was already there is left exactly as the admin set it
    # (they may have disabled it on purpose).
    if (( ! had_sshd )); then
        local unit="sshd"
        [[ "$DISTRO_FAMILY" == "debian" ]] && unit="ssh"
        timeout 60 systemctl enable --now "$unit" >/dev/null 2>&1 \
            && log_info "SSH server installed and started (${unit})." \
            || log_warn "SSH server installed but ${unit} could not be started; check 'systemctl status ${unit}'."
    fi

    if (( SKIP_EXTRA_TOOLS )); then
        log_info "Skipping the extra admin tools (--skip-extra-tools)."
    else
        # Disk health tools only make sense on real hardware.
        if command -v systemd-detect-virt >/dev/null 2>&1 && ! systemd-detect-virt --quiet 2>/dev/null; then
            extra+=(smartmontools)
        fi
        log_info "Installing admin tools: ${extra[*]}"
        if ! pkg_install "${extra[@]}"; then
            log_warn "Installing the admin tools together failed; retrying one at a time so one missing package does not block the rest."
            for p in "${extra[@]}"; do
                pkg_install "$p" >/dev/null 2>&1 || missing+=("$p")
            done
            if (( ${#missing[@]} )); then
                log_warn "Not available from this host's repositories, skipped: ${missing[*]}"
            fi
        fi
    fi
    log_info "Base packages installed and verified."
}


# ---------------------------------------------------------------------------
# 1a. Host name. The name is set as one full name including the domain (the
#     static host name becomes the FQDN), so the operator types it once. On
#     hosts that carry a 127.0.1.1 line in /etc/hosts (Debian/Ubuntu), that
#     line is kept in step so the new name still resolves locally.
# ---------------------------------------------------------------------------
update_hosts_file() {
    local fqdn="$1" short="${1%%.*}" hosts="/etc/hosts" entry new
    if [[ "$fqdn" == "$short" ]]; then
        entry="127.0.1.1 ${fqdn}"
    else
        entry="127.0.1.1 ${fqdn} ${short}"
    fi
    if grep -Eq '^[[:space:]]*127\.0\.1\.1[[:space:]]' "$hosts"; then
        cp -a "$hosts" "${hosts}.bak-$(date '+%Y%m%d-%H%M%S')"
        # Rewritten in place (not sed -i, which renames a new file over it):
        # /etc/hosts can be a bind mount, and this keeps its owner and mode.
        new="$(sed -E "s/^[[:space:]]*127\.0\.1\.1[[:space:]].*/${entry}/" "$hosts")"
        printf '%s\n' "$new" > "$hosts"
        log_info "  ${hosts}: updated the 127.0.1.1 entry (backup saved alongside it)."
    elif [[ "$DISTRO_FAMILY" == "debian" ]]; then
        cp -a "$hosts" "${hosts}.bak-$(date '+%Y%m%d-%H%M%S')"
        printf '%s\n' "$entry" >> "$hosts"
        log_info "  ${hosts}: added a 127.0.1.1 entry (backup saved alongside it)."
    fi
}

configure_hostname() {
    log_info "== Host name =="
    local current new="$NEW_HOSTNAME"
    current="$(hostnamectl --static 2>/dev/null || hostname)"
    log_info "Current host name: ${current:-unset} (fully qualified: $(hostname -f 2>/dev/null || echo unknown))"

    if [[ -z "$new" ]]; then
        if ! is_interactive; then
            log_info "No --hostname given; leaving the host name as it is."
            return 0
        fi
        if ! confirm "Do you want to change the host name of this server?" "n"; then
            log_info "Leaving the host name as it is."
            return 0
        fi
        while :; do
            new="$(ask "New host name, including the domain, in one line (for example server01.example.com; blank to keep ${current})")"
            if [[ -z "$new" ]]; then
                log_info "No name entered; leaving the host name as it is."
                return 0
            fi
            new="${new%.}"
            new="${new,,}"
            valid_hostname "$new" && break
            echo "'${new}' is not a valid host name. Use letters, digits and hyphens in each part, parts separated by dots."
        done
    fi

    if [[ "$new" == "$current" ]]; then
        log_info "Host name is already ${new}; nothing to change."
        return 0
    fi
    timeout 30 hostnamectl set-hostname "$new" || die "Failed to set the host name to '${new}'."
    local actual
    actual="$(hostnamectl --static 2>/dev/null || true)"
    [[ "$actual" == "$new" ]] || die "Host name set to ${new} but hostnamectl now reports '${actual}'."
    update_hosts_file "$new"
    log_info "Host name changed from ${current} to ${new}. Open shell sessions show the new name after the next login."
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
        echo "run by:       ${SUDO_USER:-$(id -un)} (login: $(logname 2>/dev/null || echo unknown)); admin user: ${ADMIN_USER:-none (root only)}"
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

    # The time servers default to NTP-Config's "preferred" set. Settings on
    # the command line are the answers and are applied as given; with none
    # given, an interactive run asks first, and an unattended run applies the
    # default.
    local sources="${NTP_SOURCES:-preferred}"
    local apply=1
    if (( ! NTP_HAS_SETTINGS )) && is_interactive; then
        apply=0
        if confirm "Set the time servers to the preferred set (${NTP_PREFERRED_DESC})?" "y"; then
            apply=1
        elif confirm "Change the time server configuration yourself (pick a country or region pool, your own servers, allowed subnets, stratum lock)?" "y"; then
            :   # fall through to the NTP-Config menu below
        else
            log_info "Leaving the time configuration as it is."
            NTP_OUTCOME="unchanged (operator declined)"
            ntp_cleanup
            return 0
        fi
    fi

    if (( apply )); then
        # Pass the answers to the tool's own unattended interface, which
        # validates before touching anything and reports "RESULT: changed"
        # or "RESULT: unchanged".
        args+=(--sources "$sources")
        (( NTP_ALLOW_SET )) && args+=(--allow "$NTP_ALLOW")
        (( NTP_STRATUM_SET )) && args+=(--stratum "$NTP_STRATUM")
        if ! resolve_ntp_tool; then
            ntp_failed "could not load the NTP-Config script" 1 "$NTP_ERR"
            return 0
        fi
        if (( NTP_SOURCES_SET )); then
            log_info "Applying the NTP settings given on the command line..."
        else
            log_info "Applying the preferred time servers (the default; pass --ntp-sources or --skip-ntp to change this)..."
        fi
        out="$(timeout 600 bash "$NTP_TOOL" "${args[@]}" </dev/null 2>&1)" || rc=$?
        printf '%s\n' "$out"
        if (( rc != 0 )); then
            local why="configure-ntp-server.sh exited non-zero (see the output above)."
            (( rc == 2 )) && why="configure-ntp-server.sh rejected the --ntp-* arguments as invalid; nothing was changed."
            ntp_failed "configure-ntp-server.sh ${args[*]}" "$rc" "$why"
            return 0
        fi
        local how="preferred servers by default"
        (( NTP_HAS_SETTINGS )) && how="command-line settings"
        NTP_OUTCOME="configured from ${how} ($(tail -n1 <<<"$out" | sed 's/^RESULT: //'))"
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
    elif command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null || true)" == *"Status: active"* ]]; then
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
    if (( FIREWALL_MANAGED )); then
        log_info "  Firewall: Cockpit's port was handled in the firewall step."
    else
        open_cockpit_firewall_port
    fi
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

# Interactive only: shows who is in usr_admin and which other local users
# could be, and lets the operator add more of them or carry on as is. Names
# are checked against the system before anything is changed; a bad name is
# asked about again rather than skipped. Whatever is chosen is merged with the
# admin user and --usr-admin-user into ADMIN_MEMBERS.
offer_extra_admin_members() {
    is_interactive || return 0

    local current="" line u cands=() ans tok picked ok
    current="$(getent group usr_admin 2>/dev/null | cut -d: -f4 || true)"
    while IFS= read -r line; do
        u="${line%%:*}"
        [[ " ${ADMIN_MEMBERS//,/ } " == *" ${u} "* ]] && continue
        [[ ",${current}," == *",${u},"* ]] && continue
        cands+=("$u")
    done < <(awk -F: '($3 >= 1000) && ($3 != 65534) { print }' /etc/passwd | sort)

    echo
    echo "usr_admin will contain: ${ADMIN_MEMBERS//,/, }${current:+ (already in the group: ${current//,/, })}"
    if (( ${#cands[@]} )); then
        echo "Other local users on this host: ${cands[*]}"
    else
        echo "There are no other local user accounts on this host to add."
    fi
    while :; do
        ans="$(ask "Add other users to usr_admin? Enter usernames (comma or space separated), 'all', or press Enter to continue as is")"
        ans="${ans//,/ }"
        [[ -z "${ans// /}" ]] && return 0
        picked=(); ok=1
        if [[ "${ans,,}" == "all" ]]; then
            picked=(${cands[@]+"${cands[@]}"})
        else
            for tok in $ans; do
                if id -u "$tok" >/dev/null 2>&1; then
                    picked+=("$tok")
                else
                    echo "No such user: ${tok}. Nothing was added; try again, or press Enter to continue as is."
                    ok=0
                fi
            done
        fi
        (( ok )) || continue
        EXTRA_ADMINS+=(${picked[@]+"${picked[@]}"})
        refresh_admin_members
        log_info "usr_admin will now contain: ${ADMIN_MEMBERS//,/, }"
        return 0
    done
}

setup_usr_admin_group() {
    log_info "== usr_admin group and /opt permissions =="

    if getent group usr_admin >/dev/null 2>&1; then
        log_info "usr_admin group already exists; ensuring ${ADMIN_MEMBERS_TEXT} $([[ "$ADMIN_MEMBERS" == "root" ]] && echo is || echo are) in it..."
    else
        if [[ "$ASSUME_YES" -ne 1 && -t 0 ]]; then
            echo
            if ! confirm "usr_admin does not exist on this host yet. Create it (GID 3000) and add ${ADMIN_MEMBERS_TEXT}?" "y"; then
                log_info "Declined - skipping usr_admin group creation, /opt ACLs, and log access for it. Continuing with the rest of setup."
                return 0
            fi
        fi
        log_info "Creating usr_admin group..."
    fi

    offer_extra_admin_members

    if [[ -f "$GROUP_MGMT_LOCAL" ]]; then
        log_info "Using local Group-MGMT/create-usr_admin-group.sh..."
        timeout 300 bash "$GROUP_MGMT_LOCAL" --users "$ADMIN_MEMBERS" --yes
    else
        log_info "Local Group-MGMT script not found (standalone run); fetching from ${GROUP_MGMT_URL}..."
        local tmp
        tmp="$(mktemp)"
        # shellcheck disable=SC2064
        trap "rm -f '${tmp}'" RETURN
        timeout 30 curl -fsSL "$GROUP_MGMT_URL" -o "$tmp" || die "Failed to fetch create-usr_admin-group.sh from ${GROUP_MGMT_URL}."
        timeout 300 bash "$tmp" --users "$ADMIN_MEMBERS" --yes
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
# Plumbing shared by the optional baseline steps below.
#
# These steps run from inside `if` conditions elsewhere, where bash ignores
# set -e, so each command that matters here is checked explicitly (|| return)
# instead of relying on errexit. A failure is flagged for review (final
# summary, exit code 3) and the run carries on.
# ---------------------------------------------------------------------------
FW_OUTCOME="not run"
SSH_OUTCOME="not run"
F2B_OUTCOME="not run"
GUEST_OUTCOME="not run"
LOGGING_OUTCOME="not run"
UPDATES_OUTCOME="not run"
ALERTS_OUTCOME="not offered"

# flag_step "Step name" "what went wrong"
flag_step() {
    log_warn "$1: $2 Continuing; this is flagged for review in the final summary."
    FLAGGED_ITEMS+=("$1: $2")
}

pkg_install() {
    case "$DISTRO_FAMILY" in
        debian) timeout 600 apt-get -o DPkg::Lock::Timeout=180 install -y "$@" ;;
        fedora|rhel) timeout 600 "$PKG_MANAGER" install -y "$@" ;;
    esac
}

# write_if_changed DEST MODE - writes stdin to DEST only if different.
# Returns 0 when it wrote the file, 10 when it was already identical, 1 on error.
write_if_changed() {
    local dest="$1" mode="$2" tmp
    tmp="$(mktemp)" || return 1
    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        return 10
    fi
    install -m "$mode" "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    return 0
}

# SSH ports sshd is configured for, one per line (22 if it cannot tell).
ssh_ports() {
    local out
    out="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -un || true)"
    echo "${out:-22}"
}

# ---------------------------------------------------------------------------
# Firewall - delegates to Firewall-Config's configure-firewall.sh, the same
# way the NTP and usr_admin steps delegate: the sibling copy when present,
# else a copy fetched from the repo.
# ---------------------------------------------------------------------------
resolve_fw_tool() {
    [[ -z "$FW_TOOL" ]] || return 0
    if [[ -f "$FW_LOCAL" ]]; then
        FW_TOOL="$FW_LOCAL"
        return 0
    fi
    log_info "Local Firewall-Config script not found (standalone run); fetching from ${FW_URL}..."
    FW_TMP="$(mktemp)" || return 1
    if ! timeout 30 curl --connect-timeout 10 -fsSL "$FW_URL" -o "$FW_TMP" \
        || [[ "$(sed -n '1p' "$FW_TMP")" != "#!/usr/bin/env bash" ]] \
        || ! bash -n "$FW_TMP"; then
        rm -f "$FW_TMP"; FW_TMP=""
        return 1
    fi
    FW_TOOL="$FW_TMP"
}

configure_firewall() {
    log_info "== Firewall =="
    if (( SKIP_FIREWALL )); then
        log_info "Skipped (--skip-firewall)."
        FW_OUTCOME="skipped (--skip-firewall)"
        return 0
    fi

    if [[ -z "$MGMT_SUBNET" ]] && is_interactive; then
        local ans
        while :; do
            ans="$(ask "Limit SSH and Cockpit to a management subnet? Enter CIDR(s) such as 10.0.0.0/24, or press Enter for no restriction")"
            [[ -z "$ans" ]] && break
            set_mgmt_subnet "$ans" && break
            echo "'${ans}' is not a valid CIDR list. Example: 10.0.0.0/24 or 10.0.0.0/24,192.168.1.0/24"
        done
    fi

    if ! resolve_fw_tool; then
        flag_step "Firewall" "could not load configure-firewall.sh from ${FW_URL}; no firewall was configured."
        FW_OUTCOME="NOT CONFIGURED (tool unavailable) - flagged for review"
        return 0
    fi

    local from="${MGMT_SUBNET:-any}" args=() out rc=0 p
    args+=(--ssh-from "$from" --cockpit-from "$from")
    for p in ${ALLOW_PORTS[@]+"${ALLOW_PORTS[@]}"}; do
        args+=(--allow "$p")
    done
    out="$(timeout 300 bash "$FW_TOOL" "${args[@]}" </dev/null 2>&1)" || rc=$?
    printf '%s\n' "$out"
    [[ -z "$FW_TMP" ]] || { rm -f "$FW_TMP"; FW_TMP=""; }
    if (( rc != 0 )); then
        flag_step "Firewall" "configure-firewall.sh failed (exit code ${rc}); see the output above. The firewall was left as it was, or only partly configured."
        FW_OUTCOME="FAILED - flagged for review"
        return 0
    fi

    FIREWALL_MANAGED=1
    FW_OUTCOME="baseline applied ($(tail -n1 <<<"$out" | sed 's/^RESULT: //'); SSH and Cockpit from ${from})"
    if command -v docker >/dev/null 2>&1; then
        log_warn "Docker is installed. Docker publishes container ports around ufw/firewalld rules, so published ports stay reachable regardless of this firewall; restrict them in Docker (publish to 127.0.0.1) or with the DOCKER-USER chain."
    fi
}

# ---------------------------------------------------------------------------
# Hypervisor guest tools
# ---------------------------------------------------------------------------
install_guest_tools() {
    log_info "== Guest tools =="
    if (( SKIP_GUEST_TOOLS )); then
        log_info "Skipped (--skip-guest-tools)."
        GUEST_OUTCOME="skipped (--skip-guest-tools)"
        return 0
    fi
    if ! command -v systemd-detect-virt >/dev/null 2>&1; then
        log_info "systemd-detect-virt not available; cannot tell if this is a virtual machine. Skipping."
        GUEST_OUTCOME="not applicable (cannot detect)"
        return 0
    fi

    local virt pkgs=() svc=""
    virt="$(systemd-detect-virt 2>/dev/null || true)"
    case "$virt" in
        kvm|qemu)
            pkgs=(qemu-guest-agent); svc="qemu-guest-agent" ;;
        vmware)
            pkgs=(open-vm-tools)
            [[ "$DISTRO_FAMILY" == "debian" ]] && svc="open-vm-tools" || svc="vmtoolsd" ;;
        microsoft)
            if [[ "$DISTRO_ID" == "ubuntu" ]]; then
                pkgs=(linux-tools-virtual linux-cloud-tools-virtual)
            else
                pkgs=(hyperv-daemons)
            fi ;;
        none|"")
            log_info "Not a virtual machine (or not detected); no guest tools needed."
            GUEST_OUTCOME="not applicable (physical or undetected)"
            return 0 ;;
        *)
            log_info "Detected '${virt}': this baseline has no guest tools for it. Skipping."
            GUEST_OUTCOME="not applicable (${virt})"
            return 0 ;;
    esac

    log_info "Detected virtualization: ${virt}. Installing ${pkgs[*]}..."
    if ! pkg_install "${pkgs[@]}"; then
        flag_step "Guest tools" "could not install ${pkgs[*]}."
        GUEST_OUTCOME="FAILED - flagged for review"
        return 0
    fi
    if [[ -n "$svc" ]]; then
        timeout 60 systemctl enable --now "$svc" >/dev/null 2>&1 \
            || timeout 60 systemctl start "$svc" >/dev/null 2>&1 \
            || log_info "  ${svc} is installed; it starts on its own once the hypervisor exposes its agent channel."
    fi
    GUEST_OUTCOME="${pkgs[*]} installed (${virt})"
}

# ---------------------------------------------------------------------------
# Logging baseline: keep the journal across reboots, with a size and age cap
# so it can never fill the disk.
# ---------------------------------------------------------------------------
configure_logging() {
    log_info "== Logging =="
    if (( SKIP_LOGGING )); then
        log_info "Skipped (--skip-logging)."
        LOGGING_OUTCOME="skipped (--skip-logging)"
        return 0
    fi
    if ! command -v journalctl >/dev/null 2>&1; then
        log_info "systemd-journald not present; nothing to configure."
        LOGGING_OUTCOME="not applicable (no journald)"
        return 0
    fi
    local conf_dir="/etc/systemd/journald.conf.d" rc=0
    mkdir -p "$conf_dir" || { flag_step "Logging" "could not create ${conf_dir}."; LOGGING_OUTCOME="FAILED - flagged for review"; return 0; }
    write_if_changed "${conf_dir}/50-mvts-baseline.conf" 644 <<'EOF' || rc=$?
# Managed by MVTS Server-Setup. Re-running Server-Setup rewrites this file.
[Journal]
Storage=persistent
SystemMaxUse=1G
MaxRetentionSec=3month
EOF
    if (( rc == 1 )); then
        flag_step "Logging" "could not write ${conf_dir}/50-mvts-baseline.conf."
        LOGGING_OUTCOME="FAILED - flagged for review"
        return 0
    fi
    if (( rc == 0 )) || [[ ! -d /var/log/journal ]]; then
        mkdir -p /var/log/journal
        systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true
        if ! timeout 30 systemctl restart systemd-journald; then
            flag_step "Logging" "systemd-journald did not restart on the new settings."
            LOGGING_OUTCOME="FAILED - flagged for review"
            return 0
        fi
        log_info "Persistent journal enabled (1G cap, 3 month retention)."
    else
        log_info "Persistent journal settings already in place."
    fi
    LOGGING_OUTCOME="persistent, capped at 1G / 3 months"
}

# ---------------------------------------------------------------------------
# SSH hardening: a drop-in, never an edit of sshd_config. Named 00- because
# sshd keeps the FIRST value it reads for a setting, so this must sort before
# files such as cloud-init's 50-cloud-init.conf that set PasswordAuthentication.
#
# Lockout rules: root login is only turned off when ADMIN_USER can sudo, and
# password logins only when asked for AND a key is already installed.
# ---------------------------------------------------------------------------
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN="${SSHD_DROPIN_DIR}/00-mvts-hardening.conf"

sshd_has() {   # sshd_has "key value" - against the effective config in $SSHD_EFFECTIVE
    [[ $'\n'"$SSHD_EFFECTIVE"$'\n' == *$'\n'"$1"$'\n'* ]]
}

harden_ssh() {
    log_info "== SSH hardening =="
    if (( SKIP_SSH_HARDENING )); then
        log_info "Skipped (--skip-ssh-hardening)."
        SSH_OUTCOME="skipped (--skip-ssh-hardening)"
        return 0
    fi
    if ! command -v sshd >/dev/null 2>&1; then
        log_info "No SSH server installed; nothing to harden."
        SSH_OUTCOME="not applicable (no sshd)"
        return 0
    fi
    if ! grep -Eqi '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
        flag_step "SSH hardening" "/etc/ssh/sshd_config does not include ${SSHD_DROPIN_DIR}, so a drop-in would have no effect. The SSH configuration was left unchanged."
        SSH_OUTCOME="not applied (no Include) - flagged for review"
        return 0
    fi

    local root_off=0 pw_off=0 want_pw="$SSH_DISABLE_PASSWORDS"
    if admin_can_sudo; then
        root_off=1
    else
        log_info "  Root SSH login is left as it is: ${ADMIN_USER:-no admin user} is not a sudo user, so turning it off could lock everyone out."
    fi
    if (( ! want_pw )) && is_interactive && admin_has_ssh_key; then
        if confirm "${ADMIN_USER} has an SSH key installed. Turn off SSH password logins (keys only)? Only say yes if you have confirmed the key works." "n"; then
            want_pw=1
        fi
    fi
    if (( want_pw )); then
        if admin_has_ssh_key; then
            pw_off=1
        else
            log_warn "  Not turning off SSH password logins: ${ADMIN_USER:-no admin user} has no SSH key installed, so nobody could log in."
        fi
    fi

    local body="# Managed by MVTS Server-Setup ${SCRIPT_VERSION}. Re-running Server-Setup rewrites this file.
# Named 00- so it is read first: sshd keeps the FIRST value it sees for a setting.
LoginGraceTime 30
MaxAuthTries 4
PermitEmptyPasswords no
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2"
    (( root_off )) && body+=$'\nPermitRootLogin no'
    (( pw_off )) && body+=$'\nPasswordAuthentication no'

    local prev="" had_prev=0 rc=0
    if [[ -f "$SSHD_DROPIN" ]]; then
        prev="$(cat "$SSHD_DROPIN")"
        had_prev=1
    fi
    mkdir -p "$SSHD_DROPIN_DIR" || { flag_step "SSH hardening" "could not create ${SSHD_DROPIN_DIR}."; SSH_OUTCOME="FAILED - flagged for review"; return 0; }
    printf '%s\n' "$body" | write_if_changed "$SSHD_DROPIN" 644 || rc=$?
    if (( rc == 1 )); then
        flag_step "SSH hardening" "could not write ${SSHD_DROPIN}."
        SSH_OUTCOME="FAILED - flagged for review"
        return 0
    fi

    if (( rc == 0 )); then
        if ! sshd -t 2>/dev/null; then
            if (( had_prev )); then printf '%s\n' "$prev" > "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
            flag_step "SSH hardening" "sshd rejected the new configuration (sshd -t); it was reverted and SSH is unchanged."
            SSH_OUTCOME="REVERTED (sshd -t failed) - flagged for review"
            return 0
        fi
        local unit="" u
        for u in ssh sshd; do
            if systemctl is-active --quiet "$u" 2>/dev/null; then unit="$u"; break; fi
        done
        if [[ -n "$unit" ]]; then
            if ! timeout 30 systemctl reload "$unit"; then
                flag_step "SSH hardening" "${unit} did not reload; the new settings apply at its next restart."
            else
                log_info "  ${unit} reloaded; existing sessions are not interrupted."
            fi
        else
            log_info "  sshd is not running as a service (socket activated); new connections use the new settings."
        fi
    else
        log_info "  ${SSHD_DROPIN} already up to date."
    fi

    SSHD_EFFECTIVE="$(sshd -T 2>/dev/null || true)"
    local bad=()
    sshd_has "maxauthtries 4" || bad+=("MaxAuthTries")
    (( root_off )) && { sshd_has "permitrootlogin no" || bad+=("PermitRootLogin"); }
    (( pw_off )) && { sshd_has "passwordauthentication no" || bad+=("PasswordAuthentication"); }
    if (( ${#bad[@]} )); then
        flag_step "SSH hardening" "these settings are overridden by another SSH config file and are not in effect: ${bad[*]}. Check 'sshd -T' and the files under ${SSHD_DROPIN_DIR}."
        SSH_OUTCOME="partly in effect - flagged for review"
        return 0
    fi
    SSH_OUTCOME="hardened (root login $( (( root_off )) && echo off || echo unchanged ), passwords $( (( pw_off )) && echo off || echo unchanged ))"
}

# ---------------------------------------------------------------------------
# fail2ban: bans an address that keeps failing SSH logins. The ban time
# doubles for each repeat offense (1h, 2h, 4h ... up to a week) and the
# management subnet is never banned.
# ---------------------------------------------------------------------------
install_fail2ban_packages() {
    case "$DISTRO_FAMILY" in
        debian)
            pkg_install fail2ban || return 1
            # Lets fail2ban read the journal on hosts with no auth.log.
            pkg_install python3-systemd || log_warn "  python3-systemd did not install; fail2ban may not read the journal on this host."
            ;;
        fedora)
            pkg_install fail2ban fail2ban-firewalld || return 1
            ;;
        rhel)
            if ! pkg_install fail2ban fail2ban-firewalld; then
                log_info "  fail2ban is not in the default repositories; trying EPEL..."
                pkg_install epel-release || return 1
                pkg_install fail2ban fail2ban-firewalld || return 1
            fi
            ;;
    esac
    command -v fail2ban-client >/dev/null 2>&1
}

configure_fail2ban() {
    log_info "== fail2ban =="
    if (( SKIP_FAIL2BAN )); then
        log_info "Skipped (--skip-fail2ban)."
        F2B_OUTCOME="skipped (--skip-fail2ban)"
        return 0
    fi
    if ! install_fail2ban_packages; then
        flag_step "fail2ban" "could not install fail2ban (on RHEL it needs the EPEL repository)."
        F2B_OUTCOME="NOT INSTALLED - flagged for review"
        return 0
    fi

    local ports ignore banaction="" conf="/etc/fail2ban/jail.d/50-mvts-baseline.local" rc=0
    if command -v sshd >/dev/null 2>&1; then
        ports="$(ssh_ports | paste -sd, -)"
    else
        ports="22"
    fi
    ignore="127.0.0.1/8 ::1${MGMT_SUBNET:+ ${MGMT_SUBNET//,/ }}"
    # With ufw, ban through ufw so the rules sit with the rest of the
    # firewall. With firewalld the fail2ban-firewalld package already does it.
    if command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null || true)" == *"Status: active"* ]]; then
        banaction="banaction = ufw"
    fi

    mkdir -p /etc/fail2ban/jail.d || { flag_step "fail2ban" "could not create /etc/fail2ban/jail.d."; F2B_OUTCOME="FAILED - flagged for review"; return 0; }
    write_if_changed "$conf" 644 <<EOF || rc=$?
# Managed by MVTS Server-Setup ${SCRIPT_VERSION}. Re-running Server-Setup rewrites this file.
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w
ignoreip = ${ignore}
${banaction}

[sshd]
enabled = true
port = ${ports}
backend = systemd
EOF
    if (( rc == 1 )); then
        flag_step "fail2ban" "could not write ${conf}."
        F2B_OUTCOME="FAILED - flagged for review"
        return 0
    fi

    if ! timeout 60 fail2ban-client -t >/dev/null 2>&1; then
        rm -f "$conf"
        flag_step "fail2ban" "fail2ban rejected the baseline configuration (fail2ban-client -t); it was removed."
        F2B_OUTCOME="REJECTED CONFIG - flagged for review"
        return 0
    fi

    if (( rc == 0 )) || ! systemctl is-active --quiet fail2ban; then
        timeout 60 systemctl enable fail2ban >/dev/null 2>&1 || true
        if ! timeout 90 systemctl restart fail2ban; then
            flag_step "fail2ban" "the fail2ban service did not start."
            F2B_OUTCOME="NOT RUNNING - flagged for review"
            return 0
        fi
    fi

    # The jail takes a few seconds to come up after a restart.
    local i status=""
    for i in 1 2 3 4 5 6 7 8; do
        status="$(timeout 10 fail2ban-client status sshd 2>/dev/null || true)"
        [[ "$status" == *"Status for the jail"* ]] && break
        sleep 2
    done
    if [[ "$status" != *"Status for the jail"* ]]; then
        flag_step "fail2ban" "the sshd jail is not running; check 'fail2ban-client status' and the fail2ban log."
        F2B_OUTCOME="JAIL NOT RUNNING - flagged for review"
        return 0
    fi
    log_info "fail2ban running: sshd jail on port(s) ${ports}, 1h ban doubling per repeat offense up to 1 week."
    F2B_OUTCOME="sshd jail active (1h bans, doubling to 1 week)"
}

# ---------------------------------------------------------------------------
# Hand-off to sibling installers (Updates, Notifications). They are
# interactive, so these only run with a terminal attached.
# ---------------------------------------------------------------------------
run_sibling_installer() {   # run_sibling_installer "Name" /path/to/install.sh
    local name="$1" path="$2" rc=0
    if [[ ! -f "$path" ]]; then
        log_warn "${name} installer not found at ${path} (standalone run; use the 1-click install or a full clone)."
        return 1
    fi
    log_info "Starting the ${name} installer. It asks its own questions."
    wait_for_tty_foreground
    # No timeout: an operator is driving it.
    bash "$path" || rc=$?
    return "$rc"
}

configure_updates() {
    local mode="${UPDATES_MODE:-auto}" choice
    if [[ -z "$UPDATES_MODE" ]] && is_interactive; then
        echo
        echo "Scheduled operating system updates:"
        echo "  1) Automatic (unattended-upgrades or dnf-automatic). No email."
        echo "  2) Linux/Updates: scheduled run with an emailed report of what happened."
        choice="$(ask "Choose an option" "1")"
        [[ "$choice" == "2" ]] && mode="reporting"
    fi

    case "$mode" in
        skip)
            log_info "== Scheduled updates =="
            log_info "Skipped (--updates skip)."
            UPDATES_OUTCOME="skipped (--updates skip)"
            ;;
        reporting)
            log_info "== Scheduled updates (Linux/Updates) =="
            if run_sibling_installer "Linux/Updates" "$UPDATES_LOCAL"; then
                UPDATES_OUTCOME="Linux/Updates installed (emailed reports)"
                if dpkg -s unattended-upgrades >/dev/null 2>&1; then
                    log_warn "unattended-upgrades is also installed on this host and will update on its own schedule alongside Linux/Updates. Remove it ('apt-get remove unattended-upgrades') to leave Linux/Updates in charge."
                fi
            else
                flag_step "Updates" "the Linux/Updates installer failed or was not available; automatic updates were set up instead."
                configure_unattended_updates
                UPDATES_OUTCOME="automatic (Linux/Updates did not complete) - flagged for review"
            fi
            ;;
        *)
            configure_unattended_updates
            UPDATES_OUTCOME="automatic (unattended-upgrades or dnf-automatic, no email)"
            ;;
    esac
}

offer_notifications() {
    if ! is_interactive; then
        ALERTS_OUTCOME="not offered (unattended)"
        return 0
    fi
    if command -v send-alert >/dev/null 2>&1; then
        ALERTS_OUTCOME="already installed (send-alert)"
        return 0
    fi
    echo
    if confirm "Install the send-alert email command (Linux/Notifications) so scripts and cron jobs on this host can send mail?" "n"; then
        if run_sibling_installer "Linux/Notifications" "$NOTIFICATIONS_LOCAL"; then
            ALERTS_OUTCOME="installed (send-alert)"
        else
            flag_step "Notifications" "the Linux/Notifications installer failed or was not available."
            ALERTS_OUTCOME="FAILED - flagged for review"
        fi
    else
        ALERTS_OUTCOME="not installed (declined)"
    fi
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
update_operating_system
install_base_packages
configure_hostname
set_timezone
configure_firewall
configure_ntp
install_guest_tools
install_cockpit
configure_netplan_renderer
configure_logging
harden_ssh
configure_fail2ban
configure_updates
offer_notifications
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
echo "  Host name:   $(hostname -f 2>/dev/null || hostname)"
echo "  Timezone:    $(timedatectl show --property=Timezone --value)"
echo "  Time sync:   ${NTP_OUTCOME}"
echo "  Time daemon: $(active_time_daemon), clock synchronized: $(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo unknown)"
echo "  Firewall:    ${FW_OUTCOME}"
echo "  SSH:         ${SSH_OUTCOME}"
echo "  fail2ban:    ${F2B_OUTCOME}"
echo "  Guest tools: ${GUEST_OUTCOME}"
echo "  Logging:     ${LOGGING_OUTCOME}"
echo "  Updates:     ${UPDATES_OUTCOME}"
echo "  Alerts:      ${ALERTS_OUTCOME}"
echo "  Cockpit:     https://$(hostname -f 2>/dev/null || hostname):9090"
if (( USR_ADMIN_CONFIGURED )); then
    echo "  usr_admin:   ${ADMIN_MEMBERS//,/, }  (GID 3000, rwX on /opt, read access on $LOG_DIR)"
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
if reboot_required; then
    echo
    log_warn "A reboot is needed to finish applying updates. Reboot this host when it is convenient (for example: sudo reboot)."
fi
if [[ "$(active_time_daemon)" == "none detected" ]]; then
    echo
    log_warn "No active time synchronization daemon was detected on this host. Re-run this script and accept the preferred time servers, or pass --ntp-sources."
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
