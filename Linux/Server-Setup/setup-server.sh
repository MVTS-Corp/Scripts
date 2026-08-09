#!/usr/bin/env bash
#
# setup-server.sh
# 2026-08-09
# Version: v1.0.0
#
# PURPOSE:
# Baseline provisioning for a freshly installed Linux server: base
# packages, timezone, Cockpit, NetworkManager as the netplan renderer
# (where applicable), unattended OS updates, and the usr_admin
# permissions group on /opt (via Group-MGMT/create-usr_admin-group.sh).
# Detects the host distro and adapts package names/mechanisms
# accordingly. Supports Debian/Ubuntu, Fedora, and RHEL-family distros
# (RHEL, CentOS, Rocky, AlmaLinux). Safe to re-run.
#
# USAGE:
#   setup-server.sh --admin-user NAME [--timezone TZ] [--yes]
#   setup-server.sh --check                Dependency/pre-flight checks only
#
# CONFIG:
#   No config file - everything is a flag or an interactive prompt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GROUP_MGMT_LOCAL="${SCRIPT_DIR}/../Group-MGMT/create-usr_admin-group.sh"
GROUP_MGMT_URL="https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Group-MGMT/create-usr_admin-group.sh"

ADMIN_USER=""
TIMEZONE="America/New_York"
ASSUME_YES=0
CHECK_ONLY=0

usage() {
    cat <<EOF
Usage: sudo ${0##*/} --admin-user NAME [--timezone TZ] [--yes]
       sudo ${0##*/} --check

  --admin-user NAME  Existing local username to add (alongside root) to
                     the usr_admin group. Required, except with --check.
                     If omitted on an interactive terminal, you will be
                     prompted for it instead.
  --timezone TZ      IANA timezone name (default: America/New_York).
  --yes              Skip the confirmation prompt before making changes.
  --check            Dependency and pre-flight checks only, no changes.
  -h, --help         Show this help text.

Examples:
  sudo ./${0##*/} --admin-user jsmith
  sudo ./${0##*/} --admin-user jsmith --timezone America/Chicago --yes
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
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage
            exit 1 ;;
    esac
done

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
trap 'fail_trap "$LINENO"' ERR

require_root

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

if [[ "$ASSUME_YES" -ne 1 && -t 0 ]]; then
    echo
    echo "About to provision this host ($DISTRO_NAME) as a baseline MVTS server:"
    echo "  - Install net-tools, dnsutils/bind-utils, NetworkManager, acl, unzip"
    echo "  - Set timezone to ${TIMEZONE}"
    echo "  - Install and enable Cockpit"
    echo "  - Set netplan's renderer to NetworkManager, if netplan is in use (not applied live)"
    echo "  - Enable unattended OS updates"
    echo "  - Create the usr_admin group (GID 3000) and add root + ${ADMIN_USER}, with rwX ACLs on /opt"
    echo
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
# 3. Cockpit
# ---------------------------------------------------------------------------
open_cockpit_firewall_port() {
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --add-service=cockpit --permanent >/dev/null
        firewall-cmd --reload >/dev/null
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
    systemctl enable --now cockpit.socket
    systemctl is-active --quiet cockpit.socket || die "cockpit.socket did not become active after enabling it."
    log_info "Cockpit installed and listening (cockpit.socket active)."
    open_cockpit_firewall_port
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
            awk '
                { print }
                /^network:[[:space:]]*$/ && !done { print "  renderer: NetworkManager"; done=1 }
            ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
            log_info "  ${f}: added renderer: NetworkManager (backup saved alongside it)."
        fi
    done

    netplan generate || die "netplan generate failed after editing renderer config - check the files under /etc/netplan for a syntax error (backups were saved alongside each edited file)."
    log_info "netplan config validated. NOT applied automatically (avoids disrupting an active remote session) - run 'sudo netplan apply' or reboot when ready."
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
            dpkg-reconfigure -f noninteractive unattended-upgrades
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
            systemctl enable --now dnf-automatic.timer
            systemctl is-active --quiet dnf-automatic.timer || die "dnf-automatic.timer did not become active after enabling it."
            log_info "dnf-automatic installed and enabled."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 6. usr_admin group + /opt ACLs (delegates to Group-MGMT's own script -
#    single source of truth, not duplicated logic)
# ---------------------------------------------------------------------------
setup_usr_admin_group() {
    log_info "== usr_admin group and /opt permissions =="
    if [[ -f "$GROUP_MGMT_LOCAL" ]]; then
        log_info "Using local Group-MGMT/create-usr_admin-group.sh..."
        bash "$GROUP_MGMT_LOCAL" --users "root,${ADMIN_USER}" --yes
    else
        log_info "Local Group-MGMT script not found (standalone run); fetching from ${GROUP_MGMT_URL}..."
        local tmp
        tmp="$(mktemp)"
        # shellcheck disable=SC2064
        trap "rm -f '${tmp}'" RETURN
        timeout 30 curl -fsSL "$GROUP_MGMT_URL" -o "$tmp" || die "Failed to fetch create-usr_admin-group.sh from ${GROUP_MGMT_URL}."
        bash "$tmp" --users "root,${ADMIN_USER}" --yes
    fi

    log_info "Granting usr_admin read/write/execute on /opt (with default ACL for future files)..."
    setfacl -R -m g:usr_admin:rwX /opt
    setfacl -R -d -m g:usr_admin:rwX /opt
    log_info "usr_admin group and /opt ACLs configured."
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
install_base_packages
set_timezone
install_cockpit
configure_netplan_renderer
configure_unattended_updates
setup_usr_admin_group

echo
log_info "Server setup complete."
echo "  Timezone:    $(timedatectl show --property=Timezone --value)"
echo "  Cockpit:     https://$(hostname -f 2>/dev/null || hostname):9090"
echo "  usr_admin:   root, ${ADMIN_USER}  (GID 3000, rwX on /opt)"
if command -v netplan >/dev/null 2>&1; then
    netplan_files=(/etc/netplan/*.yaml)
    if [[ -e "${netplan_files[0]}" ]]; then
        echo "  netplan:     renderer set to NetworkManager - run 'sudo netplan apply' or reboot to activate"
    fi
fi
echo
echo "Re-run this script any time; every step is safe to repeat."
