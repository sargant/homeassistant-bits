#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
set -o pipefail

REPOSITORY=$(bashio::config 'repository')
BRANCH=$(bashio::config 'branch')
SOURCE=$(bashio::config 'source_path')
DESTINATION=$(bashio::config 'destination_path')
INTERVAL=$(bashio::config 'interval')
AUTO_RESTART=$(bashio::config 'auto_restart')

CHECKOUT=/data/repository
PROCESSED=/data/processed
DEPLOYED=/data/deployed
FAILED=/data/failed

case "$REPOSITORY" in https://*) ;; *) bashio::exit.nok "repository must be a public HTTPS Git URL" ;; esac
valid_path() {
    case "$1" in ""|/*|.|..|../*|*/../*|*/..) return 1 ;; *) return 0 ;; esac
}
valid_path "$SOURCE" || bashio::exit.nok "source_path must be a relative directory"
valid_path "$DESTINATION" || bashio::exit.nok "destination_path must be a relative directory"
[ "$INTERVAL" -ge 60 ] || INTERVAL=60

DEST="/homeassistant/$DESTINATION"
PARENT=$(dirname "$DEST")
NAME=$(basename "$DEST")
STAGE="$PARENT/.${NAME}.sync-stage"
BACKUP="$PARENT/.${NAME}.sync-backup"
ABSENT="$PARENT/.${NAME}.sync-backup-absent"
OLD="$PARENT/.${NAME}.sync-old"

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
    mkdir -p "$PARENT" || return 1
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
    if [ -e "$DEST" ]; then
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

    printf '%s\n' "$sync_key" > "$DEPLOYED" || return 1
    rm -f "$FAILED"
    printf '%s\n' "$key" > "$PROCESSED" || return 1
    bashio::log.info "Synced $SOURCE to $DESTINATION"
    if [ "$AUTO_RESTART" = "true" ]; then
        bashio::core.restart || bashio::log.error "Home Assistant restart request failed"
    fi
}

bashio::log.info "Watching $REPOSITORY ($BRANCH) every ${INTERVAL}s"
while true; do
    sync_once || bashio::log.warning "Sync attempt failed; will retry"
    sleep "$INTERVAL"
done
