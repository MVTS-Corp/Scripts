#!/usr/bin/env bash
#
# containers.sh
# 2026-10-18
# Version: v1.0.0
#
# PURPOSE:
# Container image update logic for server-maintenance: release lookup with
# a soak period, approval records, compose file tag edits with backups,
# one-project-at-a-time updates with health checks, and rollback. Sourced,
# not executed. Requires common.sh, notify.sh and a loaded config, plus
# WORK_DIR (a private temp directory) and STATE_DIR from the caller.
#
# Hard rules this file keeps:
#   - Never reads .env files. Only compose files are parsed here; secrets
#     stay with Docker Compose.
#   - Never prints `docker compose config` output (it contains interpolated
#     secrets). Validation uses `config -q` only, and any Docker error text
#     that is logged goes through redact() first.

COMPOSE_NAMES=(compose.yaml compose.yml docker-compose.yaml docker-compose.yml)
TAG_CHARSET_RE='^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$'
DOCKER_PULL_TIMEOUT=900
DOCKER_UP_TIMEOUT=300

# redact - masks long token-like strings (40+ base64/url-safe characters)
# in Docker output before it is logged or emailed. A match may not start
# right after "/", so file paths stay readable.
redact() { sed -E 's#(^|[^/A-Za-z0-9+=_-])[A-Za-z0-9+=_-][A-Za-z0-9+/=_-]{39,}#\1[redacted]#g'; }

docker_ok() {
    command -v docker >/dev/null 2>&1 || return 1
    timeout 30 docker info >/dev/null 2>&1 || return 1
    timeout 30 docker compose version >/dev/null 2>&1
}

compose_file_in() {
    local dir="$1" name
    for name in "${COMPOSE_NAMES[@]}"; do
        [[ -f "$dir/$name" ]] && { printf '%s' "$dir/$name"; return 0; }
    done
    return 1
}

# dc_set <dir> - sets the DC array to a docker compose command for that
# project. An array (not a function) so it works under `timeout`.
dc_set() {
    local dir="$1" cf
    cf="$(compose_file_in "$dir")" || { log_error "No compose file in $dir"; return 1; }
    DC=(docker compose --project-directory "$dir" -f "$cf")
}

_ere_escape() { printf '%s' "$1" | sed -E 's/[][\\.*^$+?(){}|]/\\&/g'; }

# image_line_re <id> - ERE matching the pinned image line in FILE.
image_line_re() {
    local reg
    reg="$(_ere_escape "$(img_get "$1" REGISTRY)")"
    printf '%s' "^[[:space:]]*image:[[:space:]]*[\"']?${reg}:([^\"'[:space:]#]+)[\"']?[[:space:]]*(#.*)?\$"
}

# image_pinned_tag <id> - prints the tag pinned in FILE. Fails when the
# image line is missing, uses a variable, or pins different tags.
image_pinned_tag() {
    local id="$1" file re tags
    file="$(img_get "$id" FILE)"
    re="$(image_line_re "$id")"
    tags="$(grep -E -- "$re" "$file" | sed -E "s|$re|\\1|" | sort -u)" || true
    if [[ -z "$tags" ]]; then
        log_error "$id: no line 'image: $(img_get "$id" REGISTRY):<tag>' found in $file"
        return 1
    fi
    if [[ "$tags" == *'$'* ]]; then
        log_error "$id: the tag in $file is set through a variable. Pin it literally (image: $(img_get "$id" REGISTRY):<tag>); this tool never reads .env files."
        return 1
    fi
    if [[ "$(wc -l <<< "$tags")" -gt 1 ]]; then
        log_error "$id: $file pins more than one tag ($(tr '\n' ' ' <<< "$tags")); make them the same first"
        return 1
    fi
    if [[ ! "$tags" =~ $TAG_CHARSET_RE ]]; then
        log_error "$id: unsupported tag '$tags' in $file"
        return 1
    fi
    printf '%s' "$tags"
}

# image_projects <id> - prints project directories, one per line, in the
# order they will be updated.
image_projects() {
    local id="$1" explicit file real cf val dir
    explicit="$(img_get "$id" PROJECTS)"
    if [[ -n "$explicit" ]]; then
        # shellcheck disable=SC2086 # splitting the list into words is intended
        printf '%s\n' $explicit
        return 0
    fi
    file="$(img_get "$id" FILE)"
    real="$(readlink -f "$file")"
    local -a refs=() search=()
    read -r -a search <<< "$PROJECT_SEARCH_DIRS"
    while IFS= read -r -d '' cf; do
        [[ "$(readlink -f "$cf")" == "$real" ]] && continue
        while IFS= read -r val; do
            [[ -z "$val" ]] && continue
            [[ "$val" != /* ]] && val="$(dirname "$cf")/$val"
            if [[ "$(readlink -f "$val" 2>/dev/null)" == "$real" ]]; then
                refs+=("$(dirname "$cf")")
                break
            fi
        done < <(grep -E '^[[:space:]]*file:[[:space:]]*' "$cf" \
                 | sed -E "s/^[[:space:]]*file:[[:space:]]*//; s/[[:space:]]+#.*\$//; s/^[\"']//; s/[\"'][[:space:]]*\$//")
    done < <(find "${search[@]}" -maxdepth 3 -type f \
                \( -name compose.yaml -o -name compose.yml -o -name docker-compose.yaml -o -name docker-compose.yml \) \
                -print0 2>/dev/null)
    if (( ${#refs[@]} )); then
        printf '%s\n' "${refs[@]}" | sort -u
    else
        dirname "$file"
    fi
}

# project_image_containers <dir> <id> - container IDs in the project that
# run this image (any tag).
project_image_containers() {
    local dir="$1" id="$2" reg c img
    reg="$(img_get "$id" REGISTRY)"
    dc_set "$dir" || return 1
    # -a: include stopped containers, so one that crashed after an update is
    # seen (and fails its health check) at once instead of at the timeout.
    for c in $(timeout 60 "${DC[@]}" ps -a -q 2>/dev/null); do
        img="$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null)" || continue
        [[ "$img" == "$reg:"* ]] && printf '%s\n' "$c"
    done
    return 0
}

container_name() { docker inspect -f '{{.Name}}' "$1" 2>/dev/null | sed 's|^/||'; }

# ---------------------------------------------------------------------------
# Release metadata
# ---------------------------------------------------------------------------

_github_header_file() {
    local hdr="$WORK_DIR/github.hdr"
    {
        echo "Accept: application/vnd.github+json"
        echo "X-GitHub-Api-Version: 2022-11-28"
        echo "User-Agent: server-maintenance"
        if [[ -n "$GITHUB_TOKEN_FILE" ]]; then
            printf 'Authorization: Bearer %s\n' "$(tr -d '[:space:]' < "$GITHUB_TOKEN_FILE")"
        fi
    } > "$hdr"
    chmod 600 "$hdr"
    printf '%s' "$hdr"
}

# fetch_releases <id> - writes "<tag><TAB><published_epoch>" lines for
# published, non-prerelease releases whose tag matches TAG_REGEX to
# $WORK_DIR/rel_<id>.tsv. Fails closed on any API or parse problem.
fetch_releases() {
    local id="$1" repo out json hdr strip regex tag pub epoch
    out="$WORK_DIR/rel_${id}.tsv"
    [[ -f "$out" ]] && return 0
    repo="$(img_get "$id" REPO)"
    strip="$(img_get "$id" TAG_STRIP_PREFIX)"
    regex="$(img_get "$id" TAG_REGEX)"
    json="$WORK_DIR/rel_${id}.json"
    hdr="$(_github_header_file)"
    if ! http_get "https://api.github.com/repos/${repo}/releases?per_page=50" "$json" "$hdr"; then
        log_error "$id: could not fetch releases for $repo from the GitHub API"
        return 1
    fi
    if ! jq -e 'type == "array"' "$json" >/dev/null 2>&1; then
        log_error "$id: unexpected GitHub API response for $repo"
        return 1
    fi
    : > "$out.tmp"
    while IFS=$'\t' read -r tag pub; do
        [[ -n "$tag" && -n "$pub" ]] || continue
        tag="${tag#"$strip"}"
        [[ "$tag" =~ $TAG_CHARSET_RE ]] || continue
        if [[ -n "$regex" ]] && ! grep -Eq -- "$regex" <<< "$tag"; then
            continue
        fi
        epoch="$(date -d "$pub" +%s 2>/dev/null)" || continue
        printf '%s\t%s\n' "$tag" "$epoch" >> "$out.tmp"
    done < <(jq -r '.[] | select(.draft | not) | select(.prerelease | not) | [.tag_name, .published_at] | @tsv' "$json")
    mv -f "$out.tmp" "$out"
    if [[ ! -s "$out" ]]; then
        log_error "$id: no usable releases found for $repo (check IMAGE_${id}_TAG_REGEX / TAG_STRIP_PREFIX)"
        return 1
    fi
}

# release_date <id> <tag> - published epoch of a release, empty if unknown.
release_date() {
    awk -F'\t' -v t="$2" '$1 == t { print $2; exit }' "$WORK_DIR/rel_${1}.tsv" 2>/dev/null || true
}

fmt_date() { [[ -n "$1" ]] && date -d "@$1" '+%Y-%m-%d' || echo "unknown"; }

# registry_has_tag <ref> - confirms the exact tag exists in the registry
# before anything is changed. Bounded and retried.
registry_has_tag() {
    local ref="$1" attempt
    for attempt in 1 2 3; do
        timeout 60 docker manifest inspect "$ref" >/dev/null 2>&1 && return 0
        (( attempt < 3 )) && sleep $(( attempt * 3 ))
    done
    return 1
}

# image_evaluate <id> - fills E_* globals for one image:
#   E_PINNED E_PINNED_DATE    tag in FILE and its release date
#   E_NEWEST E_NEWEST_DATE    newest release (any age)
#   E_ELIGIBLE E_ELIGIBLE_DATE newest release newer than pinned and past SOAK_DAYS
#   E_APPROVED                recorded approval, if any
image_evaluate() {
    local id="$1" now soak tag epoch
    E_PINNED="" E_PINNED_DATE="" E_NEWEST="" E_NEWEST_DATE="" E_ELIGIBLE="" E_ELIGIBLE_DATE=""
    E_APPROVED="$(state_get "approval_${id}")"
    E_PINNED="$(image_pinned_tag "$id")" || return 1
    fetch_releases "$id" || return 1
    E_PINNED_DATE="$(release_date "$id" "$E_PINNED")"
    now="$(date +%s)"
    soak=$(( SOAK_DAYS * 86400 ))
    while IFS=$'\t' read -r tag epoch; do
        if [[ -z "$E_NEWEST" ]] || version_gt "$tag" "$E_NEWEST"; then
            E_NEWEST="$tag" E_NEWEST_DATE="$epoch"
        fi
        if version_gt "$tag" "$E_PINNED" && (( now - epoch >= soak )); then
            if [[ -z "$E_ELIGIBLE" ]] || version_gt "$tag" "$E_ELIGIBLE"; then
                E_ELIGIBLE="$tag" E_ELIGIBLE_DATE="$epoch"
            fi
        fi
    done < "$WORK_DIR/rel_${id}.tsv"
    return 0
}

# ---------------------------------------------------------------------------
# Compose file edits
# ---------------------------------------------------------------------------

# image_set_tag <id> <new_tag> <backup_path> - atomically rewrites the tag in
# FILE (temp file in the same directory, verified, then moved into place)
# after copying the original to <backup_path>.
image_set_tag() {
    local id="$1" new="$2" backup="$3" file re old tmp before changed
    [[ "$new" =~ $TAG_CHARSET_RE ]] || { log_error "Refusing unsafe tag '$new'"; return 1; }
    file="$(img_get "$id" FILE)"
    old="$(image_pinned_tag "$id")" || return 1
    re="$(image_line_re "$id")"
    before="$(grep -cE -- "$re" "$file")"
    mkdir -p "$(dirname "$backup")"
    cp -p "$file" "$backup"
    tmp="$(mktemp "$(dirname "$file")/.$(basename "$file").XXXXXX")"
    local reg_re old_re
    reg_re="$(_ere_escape "$(img_get "$id" REGISTRY)")"
    old_re="$(_ere_escape "$old")"
    sed -E "s|^([[:space:]]*image:[[:space:]]*[\"']?${reg_re}:)${old_re}([\"']?[[:space:]]*(#.*)?)\$|\\1${new}\\2|" "$file" > "$tmp"
    changed="$(diff "$file" "$tmp" | grep -c '^>' || true)"
    if [[ "$changed" != "$before" ]] || ! grep -Eq -- "image:[[:space:]]*[\"']?${reg_re}:$(_ere_escape "$new")([\"'[:space:]#]|\$)" "$tmp"; then
        rm -f "$tmp"
        log_error "$id: tag edit of $file did not produce the expected result; file left unchanged"
        return 1
    fi
    chmod --reference="$file" "$tmp"
    chown --reference="$file" "$tmp"
    mv -f "$tmp" "$file"
    log_info "$id: $file now pins $new (was $old; backup $backup)"
}

# restore_file <backup> <file> - atomic restore of a compose file backup.
restore_file() {
    local backup="$1" file="$2" tmp
    tmp="$(mktemp "$(dirname "$file")/.$(basename "$file").XXXXXX")"
    cp -p "$backup" "$tmp"
    mv -f "$tmp" "$file"
}

# prune_backups <dir> <keep>
prune_backups() {
    local dir="$1" keep="$2"
    [[ -d "$dir" ]] || return 0
    find "$dir" -maxdepth 1 -type f -printf '%T@ %p\n' | sort -rn | awk -v k="$keep" 'NR > k { sub(/^[^ ]+ /, ""); print }' \
        | while IFS= read -r f; do rm -f "$f"; done
}

# validate_projects <dir>... - `docker compose config -q` on each. Output is
# never shown on success; on failure only redacted stderr is logged.
validate_projects() {
    local dir err ok=0
    for dir in "$@"; do
        dc_set "$dir" || { ok=1; continue; }
        if ! err="$(timeout 60 "${DC[@]}" config -q 2>&1)"; then
            log_error "Compose validation failed for $dir: $(redact <<< "$err" | tail -n 5)"
            ok=1
        fi
    done
    return "$ok"
}

# ---------------------------------------------------------------------------
# Health checks
# ---------------------------------------------------------------------------

# health_check <id> <dir> <since_epoch> - authoritative pass/fail for one
# project after an update. Fails fast when a container exits.
health_check() {
    local id="$1" dir="$2" since="$3" spec deadline c
    spec="$(img_get "$id" HEALTH)"
    deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SECONDS ))
    local -a ctrs=()
    # Containers can take a moment to appear after `up -d`.
    while :; do
        mapfile -t ctrs < <(project_image_containers "$dir" "$id")
        (( ${#ctrs[@]} )) && break
        (( $(date +%s) >= deadline )) && { HEALTH_DETAIL="no running container for $id in $dir"; return 1; }
        sleep 2
    done

    local -A restarts=()
    for c in "${ctrs[@]}"; do
        restarts[$c]="$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null || echo 0)"
    done

    local kind="${spec%%:*}" arg="${spec#*:}" need text secs state all_ok
    while :; do
        for c in "${ctrs[@]}"; do
            state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
            if [[ "$state" == "exited" || "$state" == "dead" || "$state" == "missing" ]]; then
                HEALTH_DETAIL="$(container_name "$c") is $state. Last log lines:
$(timeout 20 docker logs --tail 20 "$c" 2>&1 | redact)"
                return 1
            fi
        done
        all_ok=1
        case "$kind" in
            log-match)
                need="${arg%%:*}" text="${arg#*:}"
                for c in "${ctrs[@]}"; do
                    local n
                    n="$(timeout 20 docker logs --since "$since" "$c" 2>&1 | grep -cF -- "$text" || true)"
                    (( n >= need )) || all_ok=0
                done
                ;;
            docker-health)
                for c in "${ctrs[@]}"; do
                    state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo none)"
                    case "$state" in
                        healthy) ;;
                        none) HEALTH_DETAIL="$(container_name "$c") has no HEALTHCHECK; choose another IMAGE_${id}_HEALTH"; return 1 ;;
                        unhealthy) HEALTH_DETAIL="$(container_name "$c") reports unhealthy"; return 1 ;;
                        *) all_ok=0 ;;
                    esac
                done
                ;;
            http)
                timeout 10 curl -fsS -o /dev/null --max-time 5 "$arg" 2>/dev/null || all_ok=0
                ;;
            running)
                secs="$arg"
                for c in "${ctrs[@]}"; do
                    local started now
                    started="$(date -d "$(docker inspect -f '{{.State.StartedAt}}' "$c")" +%s 2>/dev/null || echo 0)"
                    now="$(date +%s)"
                    (( now - started >= secs )) || all_ok=0
                    if [[ "$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null || echo 0)" != "${restarts[$c]}" ]]; then
                        HEALTH_DETAIL="$(container_name "$c") restarted during the check"
                        return 1
                    fi
                done
                # A "running" check needs its full duration even past the
                # general timeout.
                (( deadline < $(date +%s) + secs )) && deadline=$(( $(date +%s) + secs + 5 ))
                ;;
        esac
        if (( all_ok )); then
            HEALTH_DETAIL="passed ($spec)"
            return 0
        fi
        if (( $(date +%s) >= deadline )); then
            HEALTH_DETAIL="timed out after ${HEALTH_TIMEOUT_SECONDS}s waiting for: $spec"
            return 1
        fi
        sleep 3
    done
}

# diagnostics_for <id> - network diagnostics text for an alert.
diagnostics_for() {
    local id="$1" h
    for h in $(img_get "$id" DIAG_HOSTS); do
        diagnose_host "$h"
    done
}

# ---------------------------------------------------------------------------
# Pre-change hook (snapshots)
# ---------------------------------------------------------------------------

PRE_CHANGE_HOOK_DONE=0
run_pre_change_hook() {
    (( PRE_CHANGE_HOOK_DONE )) && return 0
    PRE_CHANGE_HOOK_DONE=1
    [[ -n "$PRE_CHANGE_HOOK" ]] || return 0
    log_info "Running pre-change hook"
    if timeout "$PRE_CHANGE_HOOK_TIMEOUT_SECONDS" bash -c "$PRE_CHANGE_HOOK" >> "${LOG_FILE:-/dev/null}" 2>&1; then
        log_info "Pre-change hook succeeded"
        return 0
    fi
    log_error "Pre-change hook failed; nothing was changed"
    return 1
}

# ---------------------------------------------------------------------------
# Check
# ---------------------------------------------------------------------------

# containers_check - read-only. Appends human-readable lines to
# CHECK_REPORT, alert text to CHECK_ALERTS, and returns non-zero when an
# image could not be evaluated (fail closed: a check that cannot see
# upstream is a failure, not "no updates").
containers_check() {
    local id rc=0 now line c dir running
    now="$(date +%s)"
    for id in $MANAGED_IMAGES; do
        if ! image_evaluate "$id"; then
            CHECK_ALERTS+="$id: could not be evaluated (see log).
$(diagnose_host api.github.com)
"
            rc=1
            continue
        fi
        line="$id: pinned $E_PINNED ($(fmt_date "$E_PINNED_DATE")), newest $E_NEWEST ($(fmt_date "$E_NEWEST_DATE"))"
        if [[ -n "$E_ELIGIBLE" ]]; then
            line+=", eligible $E_ELIGIBLE"
            if ! registry_has_tag "$(img_get "$id" REGISTRY):$E_ELIGIBLE"; then
                line+=" (NOT in registry yet)"
            elif is_true "$REQUIRE_APPROVAL" && [[ "$E_APPROVED" != "$E_ELIGIBLE" ]]; then
                line+=" (awaiting approval)"
                if [[ "$(state_get "notified_${id}")" != "$E_ELIGIBLE" ]]; then
                    CHECK_NOTICES+="$id: $E_PINNED -> $E_ELIGIBLE is past the ${SOAK_DAYS}-day soak period. Approve it with:
  sudo server-maintenance containers approve $id $E_ELIGIBLE
"
                    state_set "notified_${id}" "$E_ELIGIBLE"
                fi
            else
                line+=" (will apply in the next maintenance window)"
                if [[ "$(state_get "notified_${id}")" != "$E_ELIGIBLE" ]]; then
                    CHECK_NOTICES+="$id: $E_PINNED -> $E_ELIGIBLE will be applied in the next maintenance window.
"
                    state_set "notified_${id}" "$E_ELIGIBLE"
                fi
            fi
        elif version_gt "$E_NEWEST" "$E_PINNED"; then
            line+=", $E_NEWEST becomes eligible $(fmt_date $(( E_NEWEST_DATE + SOAK_DAYS * 86400 )))"
        else
            line+=", up to date"
        fi
        [[ -n "$E_APPROVED" ]] && line+=", approved $E_APPROVED"
        CHECK_REPORT+="$line
"
        if (( STALE_ALERT_DAYS > 0 )) && [[ -n "$E_PINNED_DATE" ]] && version_gt "$E_NEWEST" "$E_PINNED" \
            && (( now - E_PINNED_DATE > STALE_ALERT_DAYS * 86400 )); then
            CHECK_ALERTS+="$id: pinned $E_PINNED was released $(fmt_date "$E_PINNED_DATE"), more than $STALE_ALERT_DAYS days ago, and newer releases exist.
"
        fi
        # Running containers should match the pinned tag; a mismatch means
        # the file was edited without `up -d`, or a rollback was partial.
        while IFS= read -r dir; do
            [[ -n "$dir" ]] || continue
            for c in $(project_image_containers "$dir" "$id"); do
                running="$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null)"
                if [[ "${running##*:}" != "$E_PINNED" ]]; then
                    CHECK_ALERTS+="$id: $(container_name "$c") in $dir runs ${running##*:} but $E_PINNED is pinned.
"
                fi
            done
        done < <(image_projects "$id")
        STATUS_IMAGES+="$id=$E_PINNED${E_ELIGIBLE:+->$E_ELIGIBLE} "
    done
    return "$rc"
}

# ---------------------------------------------------------------------------
# Approve
# ---------------------------------------------------------------------------

containers_approve() {
    local id="$1" tag="$2"
    [[ " $MANAGED_IMAGES " == *" $id "* ]] || die "'$id' is not in MANAGED_IMAGES"
    [[ "$tag" =~ $TAG_CHARSET_RE ]] || die "Invalid tag '$tag'"
    image_evaluate "$id" || die "Could not evaluate $id; nothing approved"
    [[ -n "$(release_date "$id" "$tag")" ]] || die "$tag is not a published, non-prerelease release of $(img_get "$id" REPO) matching IMAGE_${id}_TAG_REGEX"
    version_gt "$tag" "$E_PINNED" || die "$tag is not newer than the pinned $E_PINNED"
    registry_has_tag "$(img_get "$id" REGISTRY):$tag" || die "$(img_get "$id" REGISTRY):$tag was not found in the registry"
    state_set "approval_${id}" "$tag"
    local eligible_on=$(( $(release_date "$id" "$tag") + SOAK_DAYS * 86400 ))
    log_info "Approved $id $tag (pinned now: $E_PINNED)."
    if (( eligible_on > $(date +%s) )); then
        log_info "It is still in its soak period and will be applied in the first maintenance window after $(fmt_date "$eligible_on"). Use 'containers apply --now $id $tag' to apply it immediately."
    else
        log_info "It will be applied in the next maintenance window ('containers apply' to apply it now)."
    fi
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

# apply_image <id> <target_tag> - updates every project of one image, one at
# a time, with rollback. Appends to APPLY_CHANGES / APPLY_FAILURES. Sets
# APPLY_CRITICAL=1 when a rollback itself failed.
apply_image() {
    local id="$1" target="$2" ref file old stamp backup dir since
    file="$(img_get "$id" FILE)"
    ref="$(img_get "$id" REGISTRY):$target"
    old="$E_PINNED"
    log_info "$id: updating $old -> $target"

    if ! registry_has_tag "$ref"; then
        APPLY_FAILURES+="$id: $ref not found in the registry; nothing changed.
"
        return 1
    fi
    local -a projects=()
    mapfile -t projects < <(image_projects "$id")
    if (( ${#projects[@]} == 0 )); then
        APPLY_FAILURES+="$id: no projects found; nothing changed.
"
        return 1
    fi
    log_info "$id: projects in update order: ${projects[*]}"
    if ! validate_projects "${projects[@]}"; then
        APPLY_FAILURES+="$id: a project failed validation before any change; nothing changed.
"
        return 1
    fi
    if ! run_pre_change_hook; then
        APPLY_FAILURES+="$id: pre-change hook failed; nothing changed.
"
        return 1
    fi

    stamp="$(date +%Y%m%d-%H%M%S)"
    backup="$STATE_DIR/backups/$id/$(basename "$file").$stamp"
    if ! image_set_tag "$id" "$target" "$backup"; then
        APPLY_FAILURES+="$id: could not edit $file; nothing changed.
"
        return 1
    fi
    if ! validate_projects "${projects[@]}"; then
        restore_file "$backup" "$file"
        APPLY_FAILURES+="$id: a project failed validation after the tag edit; $file restored, no container changed.
"
        return 1
    fi

    local -a touched=()
    local err fail=""
    for dir in "${projects[@]}"; do
        touched+=("$dir")
        dc_set "$dir"
        since=$(( $(date +%s) - 1 ))
        log_info "$id: pulling $dir"
        if ! err="$(timeout "$DOCKER_PULL_TIMEOUT" "${DC[@]}" pull -q 2>&1)"; then
            fail="pull failed in $dir: $(redact <<< "$err" | tail -n 5)"
            break
        fi
        log_info "$id: starting $dir on $target"
        if ! err="$(timeout "$DOCKER_UP_TIMEOUT" "${DC[@]}" up -d 2>&1)"; then
            fail="up -d failed in $dir: $(redact <<< "$err" | tail -n 5)"
            break
        fi
        HEALTH_DETAIL=""
        if ! health_check "$id" "$dir" "$since"; then
            fail="health check failed in $dir: $HEALTH_DETAIL"
            break
        fi
        log_info "$id: $dir healthy on $target ($HEALTH_DETAIL)"
    done

    if [[ -z "$fail" ]]; then
        state_del "approval_${id}"
        state_del "notified_${id}"
        printf '%s %s %s -> %s ok\n' "$(now_stamp)" "$id" "$old" "$target" >> "$STATE_DIR/history.log"
        APPLY_CHANGES+="$id: $old -> $target (${#projects[@]} project(s))
"
        prune_backups "$STATE_DIR/backups/$id" 10
        prune_old_images "$id" "$target"
        return 0
    fi

    log_error "$id: $fail"
    log_warn "$id: rolling back to $old"
    restore_file "$backup" "$file"
    local rb_report="" rb_ok=1
    for dir in "${touched[@]}"; do
        dc_set "$dir"
        since=$(( $(date +%s) - 1 ))
        if timeout "$DOCKER_UP_TIMEOUT" "${DC[@]}" up -d >/dev/null 2>&1 && health_check "$id" "$dir" "$since"; then
            rb_report+="  $dir: recovered on $old
"
        else
            rb_report+="  $dir: NOT recovered ($HEALTH_DETAIL)
"
            rb_ok=0
        fi
    done
    printf '%s %s %s -> %s FAILED, rollback %s\n' "$(now_stamp)" "$id" "$old" "$target" \
        "$( (( rb_ok )) && echo ok || echo FAILED)" >> "$STATE_DIR/history.log"
    # shellcheck disable=SC2034 # read by bin/server-maintenance.sh
    (( rb_ok )) || APPLY_CRITICAL=1
    local untouched=$(( ${#projects[@]} - ${#touched[@]} ))
    APPLY_FAILURES+="$id: update $old -> $target failed: $fail
Rollback ($( (( rb_ok )) && echo succeeded || echo 'FAILED, needs attention now')):
$rb_report  Projects never touched: $untouched
$(diagnostics_for "$id")
"
    return 1
}

# prune_old_images <id> <current> - removes local tags older than the
# KEEP_OLD_IMAGES newest previous ones. In-use images are never forced out.
prune_old_images() {
    local id="$1" current="$2" reg t
    reg="$(img_get "$id" REGISTRY)"
    local -a older=()
    mapfile -t older < <(docker image ls --format '{{.Tag}}' "$reg" 2>/dev/null \
        | grep -E "$TAG_CHARSET_RE" | grep -vx -- "$current" \
        | while IFS= read -r t; do version_gt "$current" "$t" && printf '%s\n' "$t"; done | sort -V)
    local n=${#older[@]} i
    for (( i = 0; i < n - KEEP_OLD_IMAGES; i++ )); do
        if timeout 60 docker image rm "$reg:${older[$i]}" >/dev/null 2>&1; then
            log_info "$id: removed old image $reg:${older[$i]}"
        fi
    done
    return 0
}

# containers_apply [--now <id> [tag]] - applies approved/eligible updates.
# Stops at the first failed image so one bad release cannot cascade.
containers_apply() {
    local now_id="" now_tag="" id target rel now
    if [[ "${1:-}" == "--now" ]]; then
        now_id="${2:-}" now_tag="${3:-}"
        [[ -n "$now_id" ]] || die "Usage: containers apply --now <image> [tag]"
        [[ " $MANAGED_IMAGES " == *" $now_id "* ]] || die "'$now_id' is not in MANAGED_IMAGES"
    fi
    now="$(date +%s)"
    for id in $MANAGED_IMAGES; do
        [[ -n "$now_id" && "$id" != "$now_id" ]] && continue
        if ! image_evaluate "$id"; then
            APPLY_FAILURES+="$id: could not be evaluated; nothing changed.
$(diagnose_host api.github.com)
"
            return 1
        fi
        target=""
        if [[ -n "$now_id" ]]; then
            target="${now_tag:-$E_NEWEST}"
            if [[ -n "$now_tag" && -z "$(release_date "$id" "$now_tag")" ]]; then
                APPLY_FAILURES+="$id: $now_tag is not a published release matching IMAGE_${id}_TAG_REGEX; nothing changed.
"
                return 1
            fi
            log_info "$id: --now given, skipping the soak period and approval"
        elif is_true "$REQUIRE_APPROVAL"; then
            if [[ -z "$E_APPROVED" ]]; then
                [[ -n "$E_ELIGIBLE" ]] && log_info "$id: $E_ELIGIBLE is eligible but not approved; skipping"
                continue
            fi
            if ! version_gt "$E_APPROVED" "$E_PINNED"; then
                log_info "$id: approval for $E_APPROVED is not newer than pinned $E_PINNED; clearing it"
                state_del "approval_${id}"
                continue
            fi
            rel="$(release_date "$id" "$E_APPROVED")"
            if [[ -z "$rel" ]]; then
                log_warn "$id: approved $E_APPROVED is no longer a listed release; skipping"
                continue
            fi
            if (( now - rel < SOAK_DAYS * 86400 )); then
                log_info "$id: approved $E_APPROVED is in its soak period until $(fmt_date $(( rel + SOAK_DAYS * 86400 ))); skipping"
                continue
            fi
            target="$E_APPROVED"
        else
            target="$E_ELIGIBLE"
        fi
        if [[ -z "$target" ]] || ! version_gt "$target" "$E_PINNED"; then
            log_info "$id: nothing to apply (pinned $E_PINNED)"
            continue
        fi
        apply_image "$id" "$target" || return 1
    done
    return 0
}

# containers_status - prints a table of every managed image.
containers_status() {
    local id dir c
    for id in $MANAGED_IMAGES; do
        echo "== $id ($(img_get "$id" REGISTRY))"
        if image_evaluate "$id"; then
            echo "  Pinned:    $E_PINNED (released $(fmt_date "$E_PINNED_DATE")) in $(img_get "$id" FILE)"
            echo "  Newest:    $E_NEWEST (released $(fmt_date "$E_NEWEST_DATE"))"
            echo "  Eligible:  ${E_ELIGIBLE:-none}${E_ELIGIBLE:+ (released $(fmt_date "$E_ELIGIBLE_DATE"))} (soak ${SOAK_DAYS} days)"
            echo "  Approved:  ${E_APPROVED:-none} (approval required: $REQUIRE_APPROVAL)"
        else
            echo "  Could not evaluate (see messages above)"
        fi
        while IFS= read -r dir; do
            [[ -n "$dir" ]] || continue
            echo "  Project:   $dir"
            for c in $(project_image_containers "$dir" "$id"); do
                echo "    $(container_name "$c"): $(docker inspect -f '{{.Config.Image}} {{.State.Status}}' "$c" 2>/dev/null)"
            done
        done < <(image_projects "$id")
    done
    if [[ -f "$STATE_DIR/history.log" ]]; then
        echo "== Recent history"
        tail -n 10 "$STATE_DIR/history.log" | sed 's/^/  /'
    fi
}
