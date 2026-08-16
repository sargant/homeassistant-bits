#!/usr/bin/with-contenv bashio
# shellcheck shell=bash

# Pipelines below must fail if any stage fails. In particular, a failed
# `git ls-files` must never be mistaken for an intentionally empty package set.
set -o pipefail

# This app is intentionally specific to this repository. It keeps its Git
# checkout in /data and only deploys tracked YAML files from packages/ into the
# Home Assistant package directory. Git never owns the Home Assistant config.

REPOSITORY="git@github.com:sargant/homeassistant-bits.git"
BRANCH="main"
SOURCE_DIR="packages"
DEST_DIR="/homeassistant/packages"
CHECKOUT_DIR="/data/repository"
MANIFEST="/data/managed-files.txt"
DEPLOYED_FINGERPRINT="/data/deployed-fingerprint"
SSH_KEY="/root/.ssh/id_ed25519"

INTERVAL=$(bashio::config 'interval')
AUTO_RESTART=$(bashio::config 'auto_restart')
DEPLOYMENT_KEY=$(bashio::config 'deployment_key')

# Five minutes is the default, but do not allow an accidentally tiny value to
# hammer GitHub or the Home Assistant config-check API.
if [ "$INTERVAL" -lt 60 ]; then
    bashio::log.warning "Interval below 60 seconds; using 60 seconds instead"
    INTERVAL=60
fi

setup_ssh() {
    if [ -z "$DEPLOYMENT_KEY" ]; then
        bashio::exit.nok "A read-only GitHub deployment key is required"
    fi

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    rm -f "$SSH_KEY"

    # Home Assistant's app configuration stores the private key as a list of
    # lines, matching the pattern used by the official Git pull app.
    while IFS= read -r line; do
        printf '%s\n' "$line" >> "$SSH_KEY"
    done <<< "$DEPLOYMENT_KEY"
    chmod 600 "$SSH_KEY"

    cat > /root/.ssh/config <<'EOF'
Host github.com
    User git
    IdentityFile /root/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    UserKnownHostsFile /data/known_hosts
EOF
    chmod 600 /root/.ssh/config
}

update_checkout() {
    if [ ! -d "$CHECKOUT_DIR/.git" ]; then
        bashio::log.info "Creating private checkout in /data"
        rm -rf "$CHECKOUT_DIR"
        git clone --depth 1 --branch "$BRANCH" "$REPOSITORY" "$CHECKOUT_DIR" || {
            bashio::log.error "Git clone failed"
            return 1
        }
        return 0
    fi

    bashio::log.info "Fetching $BRANCH"
    git -C "$CHECKOUT_DIR" fetch --depth 1 origin "$BRANCH" || {
        bashio::log.error "Git fetch failed"
        return 1
    }
    git -C "$CHECKOUT_DIR" reset --hard FETCH_HEAD >/dev/null || {
        bashio::log.error "Git reset failed"
        return 1
    }
    git -C "$CHECKOUT_DIR" clean -fd >/dev/null || {
        bashio::log.error "Git clean failed"
        return 1
    }
}

is_managed() {
    local relative_path=$1
    [ -f "$MANIFEST" ] && grep -Fxq -- "$relative_path" "$MANIFEST"
}

restore_files() {
    local touched_manifest=$1
    local backup_manifest=$2
    local backup_dir=$3
    local relative_path
    local failed=0

    # Remove anything from the attempted deployment, including newly-added
    # files, then put every pre-existing file back exactly where it was.
    while IFS= read -r relative_path; do
        [ -n "$relative_path" ] || continue
        if ! rm -f "$DEST_DIR/$relative_path"; then
            bashio::log.error "Rollback could not remove: $relative_path"
            failed=1
        fi
    done < "$touched_manifest"

    while IFS= read -r relative_path; do
        [ -n "$relative_path" ] || continue
        if ! mkdir -p "$DEST_DIR/$(dirname "$relative_path")"; then
            bashio::log.error "Rollback could not create parent directory for: $relative_path"
            failed=1
            continue
        fi
        if ! cp -p "$backup_dir/files/$relative_path" "$DEST_DIR/$relative_path"; then
            bashio::log.error "Rollback could not restore: $relative_path"
            failed=1
        fi
    done < "$backup_manifest"

    return "$failed"
}

sync_packages() {
    local fingerprint
    local current_fingerprint=""
    local new_manifest
    local touched_manifest
    local backup_manifest
    local backup_dir
    local relative_path
    local source_path
    local target_path
    local backup_parent

    [ -d "$CHECKOUT_DIR/$SOURCE_DIR" ] || {
        bashio::log.error "Repository does not contain $SOURCE_DIR/"
        return 1
    }

    # Fingerprint only tracked YAML package files. Changes elsewhere in this
    # bits-and-pieces repository (README, AGENTS.md, sync app, etc.) therefore
    # do not trigger a Home Assistant deployment or config check. A failed Git
    # index read is an error, not an empty package set.
    if ! fingerprint=$(
        git -C "$CHECKOUT_DIR" ls-files -s -- "$SOURCE_DIR" \
            | awk '$0 ~ /\.ya?ml$/ { print }' \
            | sha256sum \
            | awk '{ print $1 }'
    ); then
        bashio::log.error "Could not fingerprint package files"
        return 1
    fi

    if [ -f "$DEPLOYED_FINGERPRINT" ]; then
        current_fingerprint=$(cat "$DEPLOYED_FINGERPRINT")
    fi

    if [ "$fingerprint" = "$current_fingerprint" ]; then
        bashio::log.info "No package YAML changes"
        return 0
    fi

    new_manifest=$(mktemp /data/managed-files.new.XXXXXX) || {
        bashio::log.error "Could not create temporary package manifest"
        return 1
    }

    if ! git -C "$CHECKOUT_DIR" ls-files -- "$SOURCE_DIR" \
        | awk -v prefix="${SOURCE_DIR}/" '$0 ~ /\.ya?ml$/ { sub("^" prefix, ""); print }' \
        | sort > "$new_manifest"; then
        bashio::log.error "Could not build package manifest"
        rm -f "$new_manifest"
        return 1
    fi

    if ! mkdir -p "$DEST_DIR"; then
        bashio::log.error "Could not create Home Assistant package directory"
        rm -f "$new_manifest"
        return 1
    fi

    # Never silently take ownership of a local package. An existing unmanaged
    # file may only be adopted when it is byte-for-byte identical to the Git
    # version, which makes first installation painless for files already copied
    # into the Home Assistant package directory by hand.
    while IFS= read -r relative_path; do
        [ -n "$relative_path" ] || continue
        source_path="$CHECKOUT_DIR/$SOURCE_DIR/$relative_path"
        target_path="$DEST_DIR/$relative_path"

        if [ -e "$target_path" ] && ! is_managed "$relative_path"; then
            if [ -f "$target_path" ] && cmp -s "$source_path" "$target_path"; then
                bashio::log.info "Adopting existing identical package: $relative_path"
            else
                bashio::log.error "Refusing to overwrite unmanaged package: $relative_path"
                rm -f "$new_manifest"
                return 1
            fi
        fi
    done < "$new_manifest"

    backup_dir=$(mktemp -d /data/rollback.XXXXXX) || {
        bashio::log.error "Could not create rollback directory"
        rm -f "$new_manifest"
        return 1
    }
    touched_manifest="$backup_dir/touched-files.txt"
    backup_manifest="$backup_dir/existing-files.txt"

    if ! : > "$backup_manifest"; then
        bashio::log.error "Could not create rollback manifest"
        rm -rf "$backup_dir"
        rm -f "$new_manifest"
        return 1
    fi

    if ! {
        if [ -f "$MANIFEST" ]; then
            cat "$MANIFEST"
        fi
        cat "$new_manifest"
    } | sort -u > "$touched_manifest"; then
        bashio::log.error "Could not build rollback file list"
        rm -rf "$backup_dir"
        rm -f "$new_manifest"
        return 1
    fi

    # Back up every existing file we are about to touch. This includes an
    # identical unmanaged file being adopted on the first run. The backup must
    # be complete before any live package is removed or overwritten.
    while IFS= read -r relative_path; do
        [ -n "$relative_path" ] || continue
        target_path="$DEST_DIR/$relative_path"

        if [ -e "$target_path" ] && [ ! -f "$target_path" ]; then
            bashio::log.error "Managed path is not a regular file: $relative_path"
            rm -rf "$backup_dir"
            rm -f "$new_manifest"
            return 1
        fi

        if [ -f "$target_path" ]; then
            backup_parent="$backup_dir/files/$(dirname "$relative_path")"
            if ! mkdir -p "$backup_parent"; then
                bashio::log.error "Could not create rollback directory for: $relative_path"
                rm -rf "$backup_dir"
                rm -f "$new_manifest"
                return 1
            fi
            if ! cp -p "$target_path" "$backup_dir/files/$relative_path"; then
                bashio::log.error "Could not back up existing package: $relative_path"
                rm -rf "$backup_dir"
                rm -f "$new_manifest"
                return 1
            fi
            if ! printf '%s\n' "$relative_path" >> "$backup_manifest"; then
                bashio::log.error "Could not record rollback entry for: $relative_path"
                rm -rf "$backup_dir"
                rm -f "$new_manifest"
                return 1
            fi
        fi
    done < "$touched_manifest"

    # Remove the previous managed set first so deletions and renames in Git are
    # reflected locally, without touching package files that this app does not
    # own. Any filesystem failure from this point onward triggers rollback.
    if [ -f "$MANIFEST" ]; then
        while IFS= read -r relative_path; do
            [ -n "$relative_path" ] || continue
            if ! rm -f "$DEST_DIR/$relative_path"; then
                bashio::log.error "Could not remove previous managed package: $relative_path"
                if ! restore_files "$touched_manifest" "$backup_manifest" "$backup_dir"; then
                    bashio::log.error "Rollback also encountered errors"
                fi
                rm -rf "$backup_dir"
                rm -f "$new_manifest"
                return 1
            fi
        done < "$MANIFEST"
    fi

    while IFS= read -r relative_path; do
        [ -n "$relative_path" ] || continue

        if ! mkdir -p "$DEST_DIR/$(dirname "$relative_path")"; then
            bashio::log.error "Could not create destination directory for: $relative_path"
            if ! restore_files "$touched_manifest" "$backup_manifest" "$backup_dir"; then
                bashio::log.error "Rollback also encountered errors"
            fi
            rm -rf "$backup_dir"
            rm -f "$new_manifest"
            return 1
        fi

        if ! cp -p "$CHECKOUT_DIR/$SOURCE_DIR/$relative_path" "$DEST_DIR/$relative_path"; then
            bashio::log.error "Could not deploy package: $relative_path"
            if ! restore_files "$touched_manifest" "$backup_manifest" "$backup_dir"; then
                bashio::log.error "Rollback also encountered errors"
            fi
            rm -rf "$backup_dir"
            rm -f "$new_manifest"
            return 1
        fi
    done < "$new_manifest"

    bashio::log.info "Package YAML changed; checking Home Assistant configuration"
    if ! bashio::core.check; then
        bashio::log.error "Config check failed; restoring the previous package files"
        if ! restore_files "$touched_manifest" "$backup_manifest" "$backup_dir"; then
            bashio::log.error "Rollback also encountered errors"
        fi
        rm -rf "$backup_dir"
        rm -f "$new_manifest"
        return 1
    fi

    # The ownership manifest is part of the deployment transaction. If it cannot
    # be committed, put the live package directory back before discarding the
    # rollback data; otherwise the filesystem and ownership record can diverge.
    if ! mv "$new_manifest" "$MANIFEST"; then
        bashio::log.error "Config is valid but managed-file manifest could not be persisted; rolling back"
        if ! restore_files "$touched_manifest" "$backup_manifest" "$backup_dir"; then
            bashio::log.error "Rollback also encountered errors"
        fi
        rm -rf "$backup_dir"
        rm -f "$new_manifest"
        return 1
    fi

    if ! printf '%s\n' "$fingerprint" > "$DEPLOYED_FINGERPRINT"; then
        bashio::log.error "Config is valid but deployment fingerprint could not be persisted"
        rm -rf "$backup_dir"
        return 1
    fi

    rm -rf "$backup_dir"

    bashio::log.info "Package sync completed and configuration is valid"
    if [ "$AUTO_RESTART" = "true" ]; then
        bashio::log.info "Restarting Home Assistant"
        bashio::core.restart
    else
        bashio::log.info "Home Assistant was not restarted (auto_restart is false)"
    fi
}

sync_once() {
    update_checkout || return 1
    sync_packages || return 1
}

setup_ssh
bashio::log.info "Watching $REPOSITORY ($BRANCH) every ${INTERVAL}s"
bashio::log.info "Only tracked YAML under $SOURCE_DIR/ is deployed to $DEST_DIR"

while true; do
    if ! sync_once; then
        bashio::log.warning "Sync attempt failed; the previous valid package set remains in place where possible"
    fi
    sleep "$INTERVAL"
done
