#!/usr/bin/env bash
#
# os.sh
# 2026-10-18
# Version: v1.0.0
#
# PURPOSE:
# OS package update, reboot-required and DKMS checks for
# server-maintenance. Sourced, not executed. Requires common.sh, distro.sh
# and a loaded config. The apt and dnf handling follows
# Linux/Updates/bin/run-updates.sh v1.1.1 (full-upgrade so kernels are not
# kept back, conffile prompts answered with the existing file, every call
# bounded by a timeout).

APT_CONF_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# os_init - call once after load_config. APT is an array, not a function,
# because `timeout` executes a real binary and cannot run a shell function.
# DPkg::Lock::Timeout makes apt wait for unattended-upgrades or another apt
# run to finish instead of failing at once on a held lock.
os_init() {
    APT=(apt-get -o "DPkg::Lock::Timeout=$APT_LOCK_TIMEOUT_SECONDS")
}

# os_refresh - refreshes the package index (dnf/yum refresh as part of
# check-update, so this is apt-only).
os_refresh() {
    case "$PKG_MANAGER" in
        apt-get) timeout "$PKG_NETWORK_TIMEOUT_SECONDS" "${APT[@]}" update -q ;;
        *) return 0 ;;
    esac
}

# os_pending_list - prints "package version" lines for pending upgrades,
# without changing anything. Returns non-zero when the query itself fails.
os_pending_list() {
    case "$PKG_MANAGER" in
        apt-get)
            local out
            out="$(timeout "$PKG_NETWORK_TIMEOUT_SECONDS" "${APT[@]}" -s -q full-upgrade 2>/dev/null)" || return 1
            awk '/^Inst / { v=$3; if (v ~ /^\[/) v=$4; gsub(/[()]/, "", v); print $2, v }' <<< "$out"
            ;;
        dnf|yum)
            local out rc=0
            out="$(timeout "$PKG_NETWORK_TIMEOUT_SECONDS" "$PKG_MANAGER" -q check-update 2>/dev/null)" || rc=$?
            # check-update exits 100 when updates are available, 0 when none.
            [[ $rc -eq 0 || $rc -eq 100 ]] || return 1
            awk 'NF==3 && $1 ~ /\./ { print $1, $2 }' <<< "$out"
            ;;
        *) return 1 ;;
    esac
}

# os_security_count - best-effort count of pending security updates.
os_security_count() {
    case "$PKG_MANAGER" in
        apt-get)
            timeout "$PKG_NETWORK_TIMEOUT_SECONDS" "${APT[@]}" -s -q full-upgrade 2>/dev/null \
                | grep '^Inst ' | grep -ci 'security' || true
            ;;
        dnf|yum)
            timeout "$PKG_NETWORK_TIMEOUT_SECONDS" "$PKG_MANAGER" -q updateinfo list --security 2>/dev/null \
                | grep -c . || true
            ;;
        *) echo 0 ;;
    esac
}

# _debian_security_packages - packages whose candidate version comes from a
# repo with "security" in its name. Matches only the candidate's own source
# lines (the block after apt-cache policy's "***" marker), not older
# version-table entries, which would misclassify plain updates.
_debian_security_packages() {
    local pkg
    while read -r pkg; do
        [[ -z "$pkg" ]] && continue
        if timeout "$PKG_NETWORK_TIMEOUT_SECONDS" apt-cache policy "$pkg" 2>/dev/null | awk '
                /\*\*\*/ { incand=1; next }
                {
                    if (incand && $0 ~ /^[[:space:]]+[0-9]+[[:space:]]/) { print } else { incand=0 }
                }' | grep -qi 'security'; then
            printf '%s\n' "$pkg"
        fi
    done < <(timeout "$PKG_NETWORK_TIMEOUT_SECONDS" "${APT[@]}" -s -q full-upgrade 2>/dev/null | awk '/^Inst / {print $2}')
}

# os_apply - installs updates per UPDATE_MODE. Output goes to stdout so the
# caller can tee it into the run log. Returns the package manager's status.
os_apply() {
    local status=0
    case "$PKG_MANAGER" in
        apt-get)
            if [[ "$UPDATE_MODE" == "security" ]]; then
                local -a pkgs=()
                mapfile -t pkgs < <(_debian_security_packages)
                if (( ${#pkgs[@]} )); then
                    timeout "$PKG_INSTALL_TIMEOUT_SECONDS" "${APT[@]}" install -y -q "${APT_CONF_OPTS[@]}" --only-upgrade "${pkgs[@]}" || status=$?
                else
                    echo "No security updates available"
                fi
            else
                timeout "$PKG_INSTALL_TIMEOUT_SECONDS" "${APT[@]}" full-upgrade -y -q "${APT_CONF_OPTS[@]}" || status=$?
            fi
            if (( status == 0 )) && is_true "$AUTOREMOVE"; then
                timeout "$PKG_NETWORK_TIMEOUT_SECONDS" "${APT[@]}" autoremove -y -q "${APT_CONF_OPTS[@]}" || echo "autoremove failed (ignored)"
            fi
            ;;
        dnf|yum)
            local -a sec=()
            [[ "$UPDATE_MODE" == "security" ]] && sec=(--security)
            timeout "$PKG_INSTALL_TIMEOUT_SECONDS" "$PKG_MANAGER" upgrade -y "${sec[@]}" || status=$?
            if (( status == 0 )) && is_true "$AUTOREMOVE"; then
                timeout "$PKG_NETWORK_TIMEOUT_SECONDS" "$PKG_MANAGER" autoremove -y || echo "autoremove failed (ignored)"
            fi
            ;;
        *) echo "Unsupported package manager: $PKG_MANAGER"; status=1 ;;
    esac
    return "$status"
}

# os_reboot_required - prints yes, no, or "unknown (<reason>)". Unknown is
# never reported as no: they mean different things to an operator.
os_reboot_required() {
    case "$DISTRO_FAMILY" in
        debian)
            if [[ -f /var/run/reboot-required ]]; then
                echo "yes"
            elif ! dpkg -s update-notifier-common >/dev/null 2>&1; then
                echo "unknown (update-notifier-common not installed)"
            else
                echo "no"
            fi
            ;;
        fedora|rhel)
            if command -v needs-restarting >/dev/null 2>&1; then
                if needs-restarting -r >/dev/null 2>&1; then echo "no"; else echo "yes"; fi
            else
                echo "unknown (needs-restarting not installed)"
            fi
            ;;
        *) echo "unknown (no detection method for this distro family)" ;;
    esac
}

# newest_installed_kernel - release string of the newest kernel in /boot.
newest_installed_kernel() {
    local k
    k="$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null \
        | sed 's/^vmlinuz-//' | grep -v -e rescue -e '\.old$' | sort -V | tail -n 1)" || true
    printf '%s' "$k"
}

# dkms_check - succeeds when every DKMS module on the host is installed for
# the newest kernel (so rebooting into it will not lose a driver). Prints
# the problem on failure. Succeeds trivially without dkms.
dkms_check() {
    is_true "$DKMS_CHECK" || return 0
    command -v dkms >/dev/null 2>&1 || return 0
    local kernel modules mod missing=()
    kernel="$(newest_installed_kernel)"
    [[ -n "$kernel" ]] || { echo "Could not determine the newest installed kernel in /boot"; return 1; }
    # "name/version, kernel, arch: state" (older dkms: "name, version, ...").
    modules="$(timeout 60 dkms status 2>/dev/null | sed -E 's/^([^/,]+).*/\1/' | sort -u)" || true
    for mod in $modules; do
        if ! timeout 60 dkms status -m "$mod" -k "$kernel" 2>/dev/null | grep -q ': installed'; then
            missing+=("$mod")
        fi
    done
    if (( ${#missing[@]} )); then
        echo "DKMS module(s) not installed for kernel $kernel: ${missing[*]}. Rebooting now would boot without them."
        return 1
    fi
    return 0
}
