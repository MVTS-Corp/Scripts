#!/usr/bin/env bash
#
# config.sh
# 2026-10-18
# Version: v1.0.0
#
# PURPOSE:
# Loads and validates /etc/server-maintenance/config.conf for
# server-maintenance. Sourced, not executed. Requires common.sh.
# Defaults are set first, then the config file overrides them, so the file
# only needs the keys that differ from the defaults.

# These variables are read by the other lib files and bin/server-maintenance.sh.
# shellcheck disable=SC2034
config_defaults() {
    ALERT_TO=""
    LOG_RETENTION_DAYS=30
    LOG_ACCESS_GROUP=""
    MIN_FREE_DISK_PERCENT=10
    MAX_LOAD_PER_CORE=2.0
    LOAD_WAIT_SECONDS=600
    HEARTBEAT_URL_CHECK=""
    HEARTBEAT_URL_RUN=""
    HTTP_TIMEOUT_SECONDS=20
    HTTP_RETRIES=3
    PRE_CHANGE_HOOK=""
    PRE_CHANGE_HOOK_TIMEOUT_SECONDS=1800
    DIAG_PUBLIC_RESOLVER="1.1.1.1"

    CHECK_CALENDAR="*-*-* 07:00"
    RUN_CALENDAR="Sun *-*-01..07 03:00"
    RUN_RANDOM_DELAY="10min"

    OS_UPDATES_ENABLED=true
    UPDATE_MODE="all"
    APT_LOCK_TIMEOUT_SECONDS=600
    PKG_NETWORK_TIMEOUT_SECONDS=300
    PKG_INSTALL_TIMEOUT_SECONDS=3600
    AUTOREMOVE=true
    DKMS_CHECK=true
    REBOOT_POLICY="if-required"
    REBOOT_DELAY_MINUTES=2
    POST_BOOT_TIMEOUT_SECONDS=600
    REBOOT_PENDING_ALERT_DAYS=14

    CONTAINER_UPDATES_ENABLED=true
    SOAK_DAYS=7
    REQUIRE_APPROVAL=true
    STALE_ALERT_DAYS=180
    PROJECT_SEARCH_DIRS="/opt"
    HEALTH_TIMEOUT_SECONDS=90
    GITHUB_TOKEN_FILE=""
    KEEP_OLD_IMAGES=1
    MANAGED_IMAGES=""
}

# img_get <id> <KEY> - value of IMAGE_<id>_<KEY>, empty when unset.
img_get() {
    local var="IMAGE_${1}_${2}"
    printf '%s' "${!var-}"
}

# load_config - fails closed: a missing, unsafe or invalid config stops the
# caller (through die) before anything runs.
load_config() {
    config_defaults
    [[ -f "$CONFIG_FILE" ]] || die "Missing config file: $CONFIG_FILE (run install.sh)"
    check_root_file "$CONFIG_FILE" secret || die "Refusing to load an unsafe config file: $CONFIG_FILE"
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
    local errors
    errors="$(validate_config)"
    if [[ -n "$errors" ]]; then
        die "Invalid configuration in $CONFIG_FILE:
$errors"
    fi
}

# validate_config - prints one line per problem, nothing when valid.
validate_config() {
    local key
    for key in LOG_RETENTION_DAYS MIN_FREE_DISK_PERCENT LOAD_WAIT_SECONDS HTTP_TIMEOUT_SECONDS \
               HTTP_RETRIES PRE_CHANGE_HOOK_TIMEOUT_SECONDS APT_LOCK_TIMEOUT_SECONDS \
               PKG_NETWORK_TIMEOUT_SECONDS PKG_INSTALL_TIMEOUT_SECONDS REBOOT_DELAY_MINUTES \
               POST_BOOT_TIMEOUT_SECONDS REBOOT_PENDING_ALERT_DAYS SOAK_DAYS STALE_ALERT_DAYS \
               HEALTH_TIMEOUT_SECONDS KEEP_OLD_IMAGES; do
        is_uint "${!key}" || echo "$key must be a whole number (got '${!key}')"
    done
    (( HTTP_RETRIES >= 1 )) 2>/dev/null || echo "HTTP_RETRIES must be at least 1"
    [[ "$MAX_LOAD_PER_CORE" =~ ^[0-9]+(\.[0-9]+)?$ ]] || echo "MAX_LOAD_PER_CORE must be a number (got '$MAX_LOAD_PER_CORE')"
    for key in OS_UPDATES_ENABLED AUTOREMOVE DKMS_CHECK CONTAINER_UPDATES_ENABLED REQUIRE_APPROVAL; do
        [[ "${!key,,}" =~ ^(true|false|yes|no|1|0|on|off)$ ]] || echo "$key must be true or false (got '${!key}')"
    done
    [[ "$UPDATE_MODE" =~ ^(all|security)$ ]] || echo "UPDATE_MODE must be 'all' or 'security' (got '$UPDATE_MODE')"
    [[ "$RUN_RANDOM_DELAY" =~ ^[0-9]+(s|min|h)?$ ]] || echo "RUN_RANDOM_DELAY must look like 10min, 30s or 1h (got '$RUN_RANDOM_DELAY')"
    for key in CHECK_CALENDAR RUN_CALENDAR; do
        [[ "${!key}" =~ ^[A-Za-z0-9\ *.,:/~-]+$ ]] || echo "$key must be a plain systemd OnCalendar expression (got '${!key}')"
    done
    [[ "$REBOOT_POLICY" =~ ^(never|if-required)$ ]] || echo "REBOOT_POLICY must be 'never' or 'if-required' (got '$REBOOT_POLICY')"
    for key in HEARTBEAT_URL_CHECK HEARTBEAT_URL_RUN; do
        [[ -z "${!key}" || "${!key}" =~ ^https?://[^[:space:]]+$ ]] || echo "$key must be an http(s) URL"
    done
    if [[ -n "$GITHUB_TOKEN_FILE" ]] && ! check_root_file "$GITHUB_TOKEN_FILE" secret 2>/dev/null; then
        echo "GITHUB_TOKEN_FILE ($GITHUB_TOKEN_FILE) must exist, be owned by root and be mode 600"
    fi

    local id regex health projects dir
    for id in $MANAGED_IMAGES; do
        if [[ ! "$id" =~ ^[A-Za-z0-9_]+$ ]]; then
            echo "MANAGED_IMAGES: '$id' is not a valid ID (letters, digits, underscore)"
            continue
        fi
        for key in REPO REGISTRY FILE HEALTH; do
            [[ -n "$(img_get "$id" "$key")" ]] || echo "IMAGE_${id}_${key} is required"
        done
        [[ -z "$(img_get "$id" REPO)" || "$(img_get "$id" REPO)" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
            || echo "IMAGE_${id}_REPO must look like owner/repo"
        [[ -z "$(img_get "$id" REGISTRY)" || "$(img_get "$id" REGISTRY)" =~ ^[a-z0-9][a-z0-9._/:-]*$ ]] \
            || echo "IMAGE_${id}_REGISTRY must be an image name without a tag"
        [[ "$(img_get "$id" REGISTRY)" == *@* ]] && echo "IMAGE_${id}_REGISTRY must not contain a digest"
        local file
        file="$(img_get "$id" FILE)"
        if [[ -n "$file" ]]; then
            [[ "$file" == /* ]] || echo "IMAGE_${id}_FILE must be an absolute path"
            [[ -f "$file" ]] || echo "IMAGE_${id}_FILE not found: $file"
        fi
        regex="$(img_get "$id" TAG_REGEX)"
        if [[ -n "$regex" ]]; then
            # grep returns 2 on a malformed pattern.
            local rc=0
            printf 'x\n' | grep -Eq -- "$regex" 2>/dev/null || rc=$?
            (( rc == 2 )) && echo "IMAGE_${id}_TAG_REGEX is not a valid extended regex"
        fi
        health="$(img_get "$id" HEALTH)"
        case "$health" in
            log-match:*)
                [[ "$health" =~ ^log-match:[1-9][0-9]*:.+$ ]] || echo "IMAGE_${id}_HEALTH: use log-match:<count>:<text>" ;;
            docker-health) ;;
            http:http://*|http:https://*) ;;
            running:*)
                [[ "$health" =~ ^running:[1-9][0-9]*$ ]] || echo "IMAGE_${id}_HEALTH: use running:<seconds>" ;;
            "") ;;
            *) echo "IMAGE_${id}_HEALTH: unknown check '$health'" ;;
        esac
        projects="$(img_get "$id" PROJECTS)"
        for dir in $projects; do
            [[ -d "$dir" ]] || echo "IMAGE_${id}_PROJECTS: directory not found: $dir"
        done
    done
    return 0
}
