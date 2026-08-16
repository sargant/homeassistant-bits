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
WORK=/homeassistant/.git-package-sync
STAGE="$WORK/stage"
BACKUP="$WORK/backup"
OLD="$WORK/old"

case "$REPOSITORY" in https://*) ;; *) bashio::exit.nok "repository must be a public HTTPS Git URL" ;; esac
case "$AFTER_SYNC" in none|reload|restart) ;; *) bashio::exit.nok "after_sync must be none, reload, or restart" ;; esac
case "$SOURCE" in ""|/*|.|..|../*|*/../*|*/..|*/.) bashio::exit.nok "source_path must be a relative directory" ;; esac

# The sync target is deliberately one whole, direct child of packages/.
case "$DESTINATION" in
    packages/*) NAME=${DESTINATION#packages/} ;;
    *) bashio::exit.nok "destination_path must be a direct child of packages/" ;;
esac
case "$NAME" in ""|.|..|*/*) bashio::exit.nok "destination_path must be a direct child of packages/" ;; esac

PACKAGES=/homeassistant/packages
if [ -L "$PACKAGES" ] || { [ -e "$PACKAGES" ] && [ ! -d "$PACKAGES" ]; }; then
    bashio::exit.nok "/homeassistant/packages must be a real directory"
fi
mkdir -p "$PACKAGES" "$WORK" || bashio::exit.nok "could not prepare sync directories"
[ ! -L "$WORK" ] || bashio::exit.nok "$WORK must be a real directory"
DEST="$PACKAGES/$NAME"
[ "$INTERVAL" -ge 60 ] || INTERVAL=60

remote_head() {
    git ls-remote "$REPOSITORY" "refs/heads/$BRANCH" | awk 'NR == 1 { print $1 }'
}

update_checkout() {
    if [ ! -d "$CHECKOUT/.git" ]; then
        rm -rf "$CHECKOUT"
        git clone --quiet --depth 1 --branch "$BRANCH" "$REPOSITORY" "$CHECKOUT"
        return
    fi
    git -C "$CHECKOUT" remote set-url origin "$REPOSITORY" || return 1
    [ "$(git -C "$CHECKOUT" rev-parse HEAD)" = "$1" ] && return 0
    git -C "$CHECKOUT" fetch --quiet --depth 1 origin "$BRANCH" || return 1
    git -C "$CHECKOUT" reset --quiet --hard FETCH_HEAD || return 1
    git -C "$CHECKOUT" clean -fdq
}

restore_backup() {
    rm -rf "$DEST" || return 1
    mv "$BACKUP" "$DEST"
}

recover_swap() {
    rm -rf "$STAGE" "$OLD" || return 1
    if [ -e "$BACKUP" ]; then
        bashio::log.warning "Recovering interrupted sync"
        restore_backup
    fi
}

build_stage() {
    rm -rf "$STAGE" && mkdir "$STAGE" || return 1
    git -C "$CHECKOUT" archive "HEAD:$SOURCE" | tar -x -C "$STAGE"
}

install_stage() {
    rm -rf "$BACKUP" "$OLD" || return 1
    if [ -e "$DEST" ] || [ -L "$DEST" ]; then
        [ -d "$DEST" ] && [ ! -L "$DEST" ] || return 1
        mv "$DEST" "$BACKUP" || return 1
    else
        mkdir "$BACKUP" || return 1
    fi

    mv "$STAGE" "$DEST" || { restore_backup; return 1; }
    if ! bashio::core.check; then
        bashio::log.error "Candidate failed validation; restoring previous packages"
        restore_backup || return 1
        if ! bashio::core.check; then
            bashio::log.warning "Restored configuration also failed; retrying later"
            return 1
        fi
        return 2
    fi

    # Rename is the commit point; before it startup rolls back, after it the
    # validated destination wins even if cleanup is interrupted.
    mv "$BACKUP" "$OLD" || { restore_backup; return 1; }
    rm -rf "$OLD" || bashio::log.warning "Could not remove old synced tree"
}

after_sync() {
    case "$AFTER_SYNC" in
        none) return 0 ;;
        reload)
            bashio::log.info "Reloading Home Assistant YAML configuration"
            curl -fsS -X POST \
                -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
                -H "Content-Type: application/json" \
                -d '{}' \
                http://supervisor/core/api/services/homeassistant/reload_all >/dev/null
            ;;
        restart)
            bashio::log.info "Restarting Home Assistant"
            bashio::core.restart
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
    after_sync || { bashio::log.warning "Post-sync action failed; retrying later"; return 1; }

    printf '%s\n' "$sync_key" > "$DEPLOYED" || return 1
    rm -f "$FAILED"
    printf '%s\n' "$key" > "$PROCESSED"
}

bashio::log.info "Watching $REPOSITORY ($BRANCH) every ${INTERVAL}s"
while true; do
    sync_once || bashio::log.warning "Sync attempt failed; will retry"
    sleep "$INTERVAL"
done
