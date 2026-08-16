#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
set -o pipefail

REPOSITORY=$(bashio::config 'repository')
BRANCH=$(bashio::config 'branch')
SOURCE=$(bashio::config 'source_path')
DESTINATION=$(bashio::config 'destination_path')
INTERVAL=$(bashio::config 'interval')
AFTER_SYNC=$(bashio::config 'after_sync')

CHECKOUT=/data/repository
PROCESSED=/data/processed
DEPLOYED=/data/deployed
FAILED=/data/failed

case "$REPOSITORY" in https://*) ;; *) bashio::exit.nok "repository must be a public HTTPS Git URL" ;; esac
case "$AFTER_SYNC" in none|reload|restart) ;; *) bashio::exit.nok "after_sync must be none, reload, or restart" ;; esac
valid_path() {
    case "$1" in ""|/*|.|..|../*|*/../*|*/..|*/.) return 1 ;; *) return 0 ;; esac
}
valid_path "$SOURCE" || bashio::exit.nok "source_path must be a relative directory"
valid_path "$DESTINATION" || bashio::exit.nok "destination_path must be a relative directory"
[ "$INTERVAL" -ge 60 ] || INTERVAL=60

DEST="/homeassistant/$DESTINATION"
PARENT=$(dirname "$DEST")
WORK_ROOT=/homeassistant/.git-package-sync
WORK_ID=$(printf '%s' "$DESTINATION" | sha256sum | awk '{ print $1 }')
WORK="$WORK_ROOT/$WORK_ID"
OWNER="$WORK_ROOT/.owner"
STAGE="$WORK/stage"
BACKUP="$WORK/backup"
ABSENT="$WORK/backup-absent"
OLD="$WORK/old"

remote_head() {
    git ls-remote "$REPOSITORY" "refs/heads/$BRANCH" | awk 'NR == 1 { print $1 }'
}

update_checkout() {
    local local_head
    if [ ! -d "$CHECKOUT/.git" ]; then
        rm -rf "$CHECKOUT"
        git clone --quiet --depth 1 --branch "$BRANCH" "$REPOSITORY" "$CHECKOUT"
        return $?
    fi
    git -C "$CHECKOUT" remote set-url origin "$REPOSITORY" || return 1
    local_head=$(git -C "$CHECKOUT" rev-parse HEAD) || return 1
    [ "$local_head" = "$1" ] && return 0
    git -C "$CHECKOUT" fetch --quiet --depth 1 origin "$BRANCH" || return 1
    git -C "$CHECKOUT" reset --quiet --hard FETCH_HEAD || return 1
    git -C "$CHECKOUT" clean -fdq
}

prepare_workdir() {
    local claim

    # Build a fully marked directory first, then rename it into place. A crash
    # while creating the claim can only leave an unused temporary directory.
    if [ ! -e "$WORK_ROOT" ]; then
        claim=$(mktemp -d /homeassistant/.git-package-sync.claim.XXXXXX) || return 1
        if ! printf 'git_package_sync\n' > "$claim/.owner"; then
            rm -rf "$claim"
            return 1
        fi
        if [ -e "$WORK_ROOT" ] || ! mv "$claim" "$WORK_ROOT"; then
            rm -rf "$claim"
        fi
    fi

    [ -d "$WORK_ROOT" ] && [ ! -L "$WORK_ROOT" ] || return 1
    [ -f "$OWNER" ] && [ ! -L "$OWNER" ] && [ "$(cat "$OWNER")" = "git_package_sync" ] || return 1
    mkdir -p "$WORK" || return 1
    [ -d "$WORK" ] && [ ! -L "$WORK" ]
}

destination_parent_safe() {
    local current=/homeassistant relative part
    local -a parts

    relative=$(dirname "$DESTINATION")
    [ "$relative" = "." ] && return 0

    IFS='/' read -r -a parts <<< "$relative"
    for part in "${parts[@]}"; do
        current="$current/$part"
        if [ -L "$current" ]; then
            bashio::log.error "Destination parent contains a symlink: $current"
            return 1
        fi
        if [ -e "$current" ] && [ ! -d "$current" ]; then
            bashio::log.error "Destination parent is not a directory: $current"
            return 1
        fi
    done
}

restore_backup() {
    rm -rf "$DEST" || return 1
    if [ -f "$ABSENT" ]; then
        rm -rf "$BACKUP" || return 1
        rm -f "$ABSENT"
    else
        mv "$BACKUP" "$DEST"
    fi
}

recover_swap() {
    destination_parent_safe || return 1
    mkdir -p "$PARENT" || return 1
    destination_parent_safe || return 1
    prepare_workdir || return 1
    rm -rf "$STAGE" "$OLD" || return 1
    if [ -e "$BACKUP" ]; then
        bashio::log.warning "Recovering interrupted sync"
        restore_backup
    else
        rm -f "$ABSENT"
    fi
}

build_stage() {
    [ -d "$CHECKOUT/$SOURCE" ] || return 1
    rm -rf "$STAGE" && mkdir -p "$STAGE" || return 1
    git -C "$CHECKOUT" archive "HEAD:$SOURCE" | tar -x -C "$STAGE"
}

install_stage() {
    rm -rf "$BACKUP" "$OLD" || return 1
    rm -f "$ABSENT" || return 1
    if [ -e "$DEST" ] || [ -L "$DEST" ]; then
        [ -d "$DEST" ] && [ ! -L "$DEST" ] || return 1
        mv "$DEST" "$BACKUP" || return 1
    else
        : > "$ABSENT" || return 1
        mkdir -p "$BACKUP" || { rm -f "$ABSENT"; return 1; }
    fi

    mv "$STAGE" "$DEST" || { restore_backup; return 1; }
    if ! bashio::core.check; then
        bashio::log.error "Home Assistant rejected the candidate; restoring previous packages"
        if ! restore_backup; then
            bashio::log.error "Rollback failed"
            return 1
        fi
        return 2
    fi

    # This rename is the commit point. If the app stops before it, startup
    # restores BACKUP. After it, the validated destination wins.
    mv "$BACKUP" "$OLD" || { restore_backup; return 1; }
    rm -f "$ABSENT"
    rm -rf "$OLD" || bashio::log.warning "Could not remove old synced tree"
}

after_sync() {
    case "$AFTER_SYNC" in
        none)
            ;;
        reload)
            bashio::log.info "Reloading Home Assistant YAML configuration"
            if ! curl -fsS -X POST \
                -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
                -H "Content-Type: application/json" \
                -d '{}' \
                http://supervisor/core/api/services/homeassistant/reload_all >/dev/null; then
                bashio::log.error "Home Assistant YAML reload failed"
                return 1
            fi
            ;;
        restart)
            bashio::log.info "Restarting Home Assistant"
            if ! bashio::core.restart; then
                bashio::log.error "Home Assistant restart request failed"
                return 1
            fi
            ;;
    esac
}

sync_once() {
    local head key tree sync_key deployed="" failed="" result
    recover_swap || return 1

    head=$(remote_head) || return 1
    [ -n "$head" ] || return 1
    key="$REPOSITORY|$BRANCH|$SOURCE|$DESTINATION|$head"
    [ -f "$PROCESSED" ] && [ "$(cat "$PROCESSED")" = "$key" ] && return 0

    update_checkout "$head" || return 1
    [ -d "$CHECKOUT/$SOURCE" ] || { bashio::log.error "Source directory not found: $SOURCE"; return 1; }
    tree=$(git -C "$CHECKOUT" rev-parse "HEAD:$SOURCE") || return 1
    sync_key="$DESTINATION|$tree"
    [ -f "$DEPLOYED" ] && deployed=$(cat "$DEPLOYED")
    [ -f "$FAILED" ] && failed=$(cat "$FAILED")

    if [ "$sync_key" = "$deployed" ] || { [ -n "$failed" ] && [ "$sync_key" = "$failed" ]; }; then
        printf '%s\n' "$key" > "$PROCESSED"
        return 0
    fi

    build_stage || return 1
    install_stage
    result=$?
    if [ "$result" -eq 2 ]; then
        printf '%s\n' "$sync_key" > "$FAILED"
        printf '%s\n' "$key" > "$PROCESSED"
        return 0
    fi
    [ "$result" -eq 0 ] || return 1

    bashio::log.info "Synced $SOURCE to $DESTINATION"
    if ! after_sync; then
        bashio::log.warning "Post-sync action failed; the deployment will be retried"
        return 1
    fi

    printf '%s\n' "$sync_key" > "$DEPLOYED" || return 1
    rm -f "$FAILED"
    printf '%s\n' "$key" > "$PROCESSED" || return 1
}

bashio::log.info "Watching $REPOSITORY ($BRANCH) every ${INTERVAL}s"
while true; do
    sync_once || bashio::log.warning "Sync attempt failed; will retry"
    sleep "$INTERVAL"
done
