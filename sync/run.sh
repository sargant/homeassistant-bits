#!/usr/bin/with-contenv bashio
# shellcheck shell=bash

set -o pipefail

# The app owns exactly one Home Assistant package subtree: packages/synced.
# Everything else under packages/ is left alone.
REPOSITORY="git@github.com:sargant/homeassistant-bits.git"
BRANCH="main"
SOURCE_DIR="packages"
CHECKOUT_DIR="/data/repository"
DEST_DIR="/homeassistant/packages/synced"
STAGE_DIR="/homeassistant/.homeassistant-bits-synced-stage"
BACKUP_DIR="/homeassistant/.homeassistant-bits-synced-backup"
DISCARD_DIR="/homeassistant/.homeassistant-bits-synced-old"
DEPLOYED_FINGERPRINT="/data/deployed-fingerprint"
FAILED_FINGERPRINT="/data/failed-fingerprint"
PROCESSED_HEAD="/data/processed-head"
PENDING_RESTART="/data/pending-restart"
SSH_KEY="/root/.ssh/id_ed25519"

INTERVAL=$(bashio::config 'interval')
AUTO_RESTART=$(bashio::config 'auto_restart')
DEPLOYMENT_KEY=$(bashio::config 'deployment_key')

if [ "$INTERVAL" -lt 60 ]; then
    bashio::log.warning "Interval below 60 seconds; using 60 seconds instead"
    INTERVAL=60
fi

atomic_text() {
    local value=$1
    local destination=$2
    local temp

    temp=$(mktemp "${destination}.new.XXXXXX") || return 1
    if ! printf '%s\n' "$value" > "$temp" || ! mv "$temp" "$destination"; then
        rm -f "$temp"
        return 1
    fi
}

setup_ssh() {
    [ -n "$DEPLOYMENT_KEY" ] || bashio::exit.nok "A read-only GitHub deployment key is required"
    mkdir -p /root/.ssh || bashio::exit.nok "Could not create SSH directory"
    chmod 700 /root/.ssh || bashio::exit.nok "Could not secure SSH directory"
    rm -f "$SSH_KEY"

    while IFS= read -r line; do
        printf '%s\n' "$line" >> "$SSH_KEY" || bashio::exit.nok "Could not write deployment key"
    done <<< "$DEPLOYMENT_KEY"
    chmod 600 "$SSH_KEY" || bashio::exit.nok "Could not secure deployment key"

    cat > /root/.ssh/config <<'SSH_CONFIG'
Host github.com
    User git
    IdentityFile /root/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    UserKnownHostsFile /data/known_hosts
SSH_CONFIG
    chmod 600 /root/.ssh/config || bashio::exit.nok "Could not secure SSH config"
}

ensure_paths() {
    if [ -L /homeassistant ] || [ ! -d /homeassistant ]; then
        bashio::log.error "Home Assistant config mount is missing or is a symlink"
        return 1
    fi

    if [ -L /homeassistant/packages ] || { [ -e /homeassistant/packages ] && [ ! -d /homeassistant/packages ]; }; then
        bashio::log.error "Home Assistant packages path is unsafe"
        return 1
    fi
    mkdir -p /homeassistant/packages || {
        bashio::log.error "Could not create Home Assistant packages directory"
        return 1
    }

    for path in "$DEST_DIR" "$STAGE_DIR" "$BACKUP_DIR" "$DISCARD_DIR"; do
        if [ -L "$path" ]; then
            bashio::log.error "Refusing to use symlinked sync path: $path"
            return 1
        fi
    done

    if [ -e "$DEST_DIR" ] && [ ! -d "$DEST_DIR" ]; then
        bashio::log.error "Synced package path is not a directory"
        return 1
    fi
}

recover_swap() {
    ensure_paths || return 1

    # BACKUP_DIR exists only while a candidate has replaced the previous live
    # directory but has not yet committed. A crash therefore restores it.
    if [ -d "$BACKUP_DIR" ]; then
        bashio::log.warning "Recovering package deployment interrupted before commit"
        rm -rf "$DEST_DIR" || return 1
        mv "$BACKUP_DIR" "$DEST_DIR" || {
            bashio::log.error "Could not restore previous synced package directory"
            return 1
        }
        rm -f "$PENDING_RESTART"
    fi

    # A stage is never live. DISCARD_DIR contains only an old tree from a
    # deployment that had already passed validation and committed.
    rm -rf "$STAGE_DIR" "$DISCARD_DIR" || {
        bashio::log.error "Could not clean stale package sync directories"
        return 1
    }
}

remote_head() {
    local head

    if ! head=$(git ls-remote "$REPOSITORY" "refs/heads/$BRANCH" | awk 'NR == 1 { print $1 }'); then
        bashio::log.error "Could not check remote repository HEAD"
        return 1
    fi
    [ -n "$head" ] || {
        bashio::log.error "Remote branch $BRANCH did not return a HEAD commit"
        return 1
    }
    printf '%s\n' "$head"
}

update_checkout() {
    local expected_head=$1
    local local_head
    local fetched_head

    if [ ! -d "$CHECKOUT_DIR/.git" ]; then
        bashio::log.info "Creating private checkout in /data"
        rm -rf "$CHECKOUT_DIR"
        git clone --depth 1 --branch "$BRANCH" "$REPOSITORY" "$CHECKOUT_DIR" || {
            bashio::log.error "Git clone failed"
            return 1
        }
        return 0
    fi

    local_head=$(git -C "$CHECKOUT_DIR" rev-parse HEAD) || {
        bashio::log.error "Could not read local checkout HEAD"
        return 1
    }

    # Retry local/transient failures without fetching the same commit again.
    [ "$local_head" = "$expected_head" ] && return 0

    bashio::log.info "Repository HEAD changed; fetching $BRANCH"
    git -C "$CHECKOUT_DIR" fetch --depth 1 origin "$BRANCH" || {
        bashio::log.error "Git fetch failed"
        return 1
    }
    fetched_head=$(git -C "$CHECKOUT_DIR" rev-parse FETCH_HEAD) || {
        bashio::log.error "Could not read fetched HEAD"
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

    [ "$fetched_head" = "$expected_head" ] || \
        bashio::log.info "Repository HEAD moved while fetching; processing the fetched commit"
}

package_fingerprint() {
    # An absent packages/ directory intentionally hashes as an empty package set.
    git -C "$CHECKOUT_DIR" ls-files -s -- "$SOURCE_DIR" \
        | awk '$0 ~ /\.yaml$/ { print }' \
        | sha256sum \
        | awk '{ print $1 }'
}

build_stage() {
    local file_list
    local path
    local relative_path
    local source_path

    rm -rf "$STAGE_DIR" || return 1
    mkdir -p "$STAGE_DIR" || {
        bashio::log.error "Could not create staged package directory"
        return 1
    }

    file_list=$(mktemp /data/package-files.XXXXXX) || return 1
    if ! git -C "$CHECKOUT_DIR" ls-files -z -- "$SOURCE_DIR" > "$file_list"; then
        bashio::log.error "Could not list tracked package files"
        rm -f "$file_list"
        return 1
    fi

    while IFS= read -r -d '' path; do
        case "$path" in
            "$SOURCE_DIR"/*.yaml) ;;
            *) continue ;;
        esac

        relative_path=${path#"$SOURCE_DIR/"}
        source_path="$CHECKOUT_DIR/$path"

        if [ -L "$source_path" ] || [ ! -f "$source_path" ]; then
            bashio::log.error "Tracked package is not a regular file: $path"
            rm -f "$file_list"
            rm -rf "$STAGE_DIR"
            return 1
        fi

        mkdir -p "$STAGE_DIR/$(dirname "$relative_path")" || {
            bashio::log.error "Could not create staged directory for: $relative_path"
            rm -f "$file_list"
            rm -rf "$STAGE_DIR"
            return 1
        }
        cp -p "$source_path" "$STAGE_DIR/$relative_path" || {
            bashio::log.error "Could not stage package: $relative_path"
            rm -f "$file_list"
            rm -rf "$STAGE_DIR"
            return 1
        }
    done < "$file_list"

    rm -f "$file_list"
}

begin_swap() {
    [ ! -e "$BACKUP_DIR" ] || {
        bashio::log.error "A package rollback directory already exists"
        return 1
    }

    if [ -d "$DEST_DIR" ]; then
        mv "$DEST_DIR" "$BACKUP_DIR" || {
            bashio::log.error "Could not move previous synced packages aside"
            return 1
        }
    else
        # Empty means there was no previous synced tree, but gives first-run
        # failures the same rollback path as later deployments.
        mkdir "$BACKUP_DIR" || return 1
    fi

    if ! mv "$STAGE_DIR" "$DEST_DIR"; then
        bashio::log.error "Could not activate staged synced packages"
        rm -rf "$DEST_DIR"
        mv "$BACKUP_DIR" "$DEST_DIR" || \
            bashio::log.error "Could not restore previous synced packages after failed swap"
        return 1
    fi
}

rollback_swap() {
    [ -d "$BACKUP_DIR" ] || {
        bashio::log.error "Rollback directory is missing"
        return 1
    }

    rm -rf "$DEST_DIR" || return 1
    mv "$BACKUP_DIR" "$DEST_DIR" || {
        bashio::log.error "Could not restore previous synced packages"
        return 1
    }
    rm -f "$PENDING_RESTART"
}

commit_swap() {
    local fingerprint=$1

    # Moving the old tree out of BACKUP_DIR is the commit point. Before this a
    # crash rolls back; after it the already-validated candidate remains live.
    rm -rf "$DISCARD_DIR" || return 1
    mv "$BACKUP_DIR" "$DISCARD_DIR" || {
        bashio::log.error "Could not commit validated synced packages"
        return 1
    }

    # A required restart is recorded before this version is called deployed.
    if [ "$AUTO_RESTART" = "true" ]; then
        atomic_text pending "$PENDING_RESTART" || {
            bashio::log.error "Could not record pending Home Assistant restart"
            return 1
        }
    else
        rm -f "$PENDING_RESTART" || return 1
    fi

    rm -f "$FAILED_FINGERPRINT" || return 1
    atomic_text "$fingerprint" "$DEPLOYED_FINGERPRINT" || {
        bashio::log.error "Could not persist deployment fingerprint"
        return 1
    }

    # Cleanup failure is harmless; recover_swap removes this next poll.
    rm -rf "$DISCARD_DIR" || bashio::log.warning "Could not remove old synced package directory yet"
}

attempt_pending_restart() {
    [ -f "$PENDING_RESTART" ] || return 0

    if [ "$AUTO_RESTART" != "true" ]; then
        bashio::log.info "Automatic restart is disabled; clearing pending restart"
        rm -f "$PENDING_RESTART"
        return 0
    fi

    bashio::log.info "Requesting pending Home Assistant restart"
    if ! bashio::core.restart; then
        bashio::log.error "Home Assistant restart request failed; will retry next poll"
        return 1
    fi

    rm -f "$PENDING_RESTART"
    bashio::log.info "Home Assistant restart requested successfully"
}

try_candidate() {
    build_stage || return 1
    begin_swap || return 1

    if bashio::core.check; then
        return 0
    fi

    bashio::log.error "Candidate configuration check failed; restoring previous synced packages"
    rollback_swap || return 1
    return 2
}

confirm_candidate_failure() {
    # core.check reports invalid YAML and Supervisor/service failures alike.
    # Only remember the fingerprint after two candidate failures separated by
    # successful checks of the restored baseline.
    bashio::log.info "Checking restored baseline before classifying candidate failure"
    bashio::core.check || {
        bashio::log.error "Restored baseline check failed; treating candidate failure as transient"
        return 1
    }

    bashio::log.info "Retrying candidate once before marking its package fingerprint failed"
    try_candidate
    case $? in
        0)
            bashio::log.info "Candidate passed on retry; first check was transient"
            return 0
            ;;
        2) ;;
        *) return 1 ;;
    esac

    bashio::log.info "Rechecking restored baseline after second candidate failure"
    bashio::core.check || {
        bashio::log.error "Restored baseline check failed; treating candidate failure as transient"
        return 1
    }

    return 2
}

sync_packages() {
    local fingerprint
    local deployed_fingerprint=""
    local failed_fingerprint=""
    local result

    fingerprint=$(package_fingerprint) || {
        bashio::log.error "Could not fingerprint package files"
        return 1
    }

    [ -f "$DEPLOYED_FINGERPRINT" ] && deployed_fingerprint=$(cat "$DEPLOYED_FINGERPRINT")
    [ -f "$FAILED_FINGERPRINT" ] && failed_fingerprint=$(cat "$FAILED_FINGERPRINT")

    if [ "$fingerprint" = "$deployed_fingerprint" ]; then
        bashio::log.info "Repository changed, but package YAML is unchanged"
        return 0
    fi

    if [ -n "$failed_fingerprint" ] && [ "$fingerprint" = "$failed_fingerprint" ]; then
        bashio::log.warning "Package YAML matches a previously failed validation; waiting for package changes"
        return 0
    fi

    bashio::log.info "Package YAML changed; staging complete synced package directory"
    try_candidate
    result=$?

    if [ "$result" -eq 2 ]; then
        confirm_candidate_failure
        result=$?
    fi

    case "$result" in
        0)
            commit_swap "$fingerprint" || return 1
            bashio::log.info "Package sync completed and configuration is valid"
            if [ "$AUTO_RESTART" = "true" ]; then
                attempt_pending_restart || return 1
            else
                bashio::log.info "Home Assistant was not restarted (auto_restart is false)"
            fi
            return 0
            ;;
        2)
            atomic_text "$fingerprint" "$FAILED_FINGERPRINT" || {
                bashio::log.error "Could not remember failed package fingerprint; it will be retried"
                return 1
            }
            bashio::log.error "Previous synced packages restored; this package version is marked as failed"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

sync_once() {
    local head
    local processed_head=""
    local checkout_head

    recover_swap || return 1
    attempt_pending_restart || return 1

    # Unchanged polls do only this cheap remote HEAD lookup.
    head=$(remote_head) || return 1
    [ -f "$PROCESSED_HEAD" ] && processed_head=$(cat "$PROCESSED_HEAD")

    if [ "$head" = "$processed_head" ]; then
        bashio::log.info "Repository HEAD unchanged"
        return 0
    fi

    update_checkout "$head" || return 1
    sync_packages || return 1

    checkout_head=$(git -C "$CHECKOUT_DIR" rev-parse HEAD) || {
        bashio::log.error "Could not read processed checkout HEAD"
        return 1
    }
    atomic_text "$checkout_head" "$PROCESSED_HEAD" || {
        bashio::log.error "Could not remember processed repository HEAD"
        return 1
    }
}

setup_ssh
bashio::log.info "Watching $REPOSITORY ($BRANCH) every ${INTERVAL}s"
bashio::log.info "Unchanged polls check only the remote HEAD commit hash"
bashio::log.info "This app owns only $DEST_DIR"

while true; do
    if ! sync_once; then
        bashio::log.warning "Sync attempt failed; previous valid synced packages remain in place where possible"
    fi
    sleep "$INTERVAL"
done
