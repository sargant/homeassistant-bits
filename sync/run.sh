#!/usr/bin/with-contenv bashio
# shellcheck shell=bash

# A pipeline failure must never be mistaken for a valid empty result.
set -o pipefail

# This app is deliberately specific to this repository. It keeps its Git
# checkout in /data and only deploys tracked YAML from packages/ into the Home
# Assistant package directory. Git never owns the Home Assistant config.
REPOSITORY="git@github.com:sargant/homeassistant-bits.git"
BRANCH="main"
SOURCE_DIR="packages"
DEST_DIR="/homeassistant/packages"
CHECKOUT_DIR="/data/repository"
MANIFEST="/data/managed-files.txt"
DEPLOYED_FINGERPRINT="/data/deployed-fingerprint"
FAILED_FINGERPRINT="/data/failed-fingerprint"
PROCESSED_HEAD="/data/processed-head"
PENDING_RESTART="/data/pending-restart"
SSH_KEY="/root/.ssh/id_ed25519"

INTERVAL=$(bashio::config 'interval')
AUTO_RESTART=$(bashio::config 'auto_restart')
DEPLOYMENT_KEY=$(bashio::config 'deployment_key')

# Five minutes is the default. Refuse an accidentally tiny interval so a typo
# cannot hammer GitHub or the Supervisor API.
if [ "$INTERVAL" -lt 60 ]; then
    bashio::log.warning "Interval below 60 seconds; using 60 seconds instead"
    INTERVAL=60
fi

setup_ssh() {
    if [ -z "$DEPLOYMENT_KEY" ]; then
        bashio::exit.nok "A read-only GitHub deployment key is required"
    fi

    if ! mkdir -p /root/.ssh; then
        bashio::exit.nok "Could not create SSH directory"
    fi
    chmod 700 /root/.ssh || bashio::exit.nok "Could not secure SSH directory"
    rm -f "$SSH_KEY"

    # Match the Home Assistant Git pull app convention: the private key is
    # supplied as a YAML list of lines and Bashio exposes it as newline text.
    while IFS= read -r line; do
        printf '%s\n' "$line" >> "$SSH_KEY" || bashio::exit.nok "Could not write deployment key"
    done <<< "$DEPLOYMENT_KEY"
    chmod 600 "$SSH_KEY" || bashio::exit.nok "Could not secure deployment key"

    cat > /root/.ssh/config <<'EOF'
Host github.com
    User git
    IdentityFile /root/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    UserKnownHostsFile /data/known_hosts
EOF
    chmod 600 /root/.ssh/config || bashio::exit.nok "Could not secure SSH config"
}

remote_head() {
    local head

    if ! head=$(
        git ls-remote "$REPOSITORY" "refs/heads/$BRANCH" \
            | awk 'NR == 1 { print $1 }'
    ); then
        bashio::log.error "Could not check remote repository HEAD"
        return 1
    fi

    if [ -z "$head" ]; then
        bashio::log.error "Remote branch $BRANCH did not return a HEAD commit"
        return 1
    fi

    printf '%s\n' "$head"
}

update_checkout() {
    local expected_head=$1
    local local_head
    local fetched_head

    if [ ! -d "$CHECKOUT_DIR/.git" ]; then
        bashio::log.info "Creating private checkout in /data"
        rm -rf "$CHECKOUT_DIR"
        if ! git clone --depth 1 --branch "$BRANCH" "$REPOSITORY" "$CHECKOUT_DIR"; then
            bashio::log.error "Git clone failed"
            return 1
        fi
        return 0
    fi

    if ! local_head=$(git -C "$CHECKOUT_DIR" rev-parse HEAD); then
        bashio::log.error "Could not read local checkout HEAD"
        return 1
    fi

    # A previous attempt may already have fetched this commit and then failed
    # for a local/transient reason. Retry locally without downloading it again.
    if [ "$local_head" = "$expected_head" ]; then
        return 0
    fi

    bashio::log.info "Repository HEAD changed; fetching $BRANCH"
    if ! git -C "$CHECKOUT_DIR" fetch --depth 1 origin "$BRANCH"; then
        bashio::log.error "Git fetch failed"
        return 1
    fi

    if ! fetched_head=$(git -C "$CHECKOUT_DIR" rev-parse FETCH_HEAD); then
        bashio::log.error "Could not read fetched HEAD"
        return 1
    fi

    if ! git -C "$CHECKOUT_DIR" reset --hard FETCH_HEAD >/dev/null; then
        bashio::log.error "Git reset failed"
        return 1
    fi
    if ! git -C "$CHECKOUT_DIR" clean -fd >/dev/null; then
        bashio::log.error "Git clean failed"
        return 1
    fi

    # The branch may move between ls-remote and fetch. Process what was fetched;
    # the next cheap HEAD poll will notice if GitHub moved again.
    if [ "$fetched_head" != "$expected_head" ]; then
        bashio::log.info "Repository HEAD moved again while fetching; processing the fetched commit"
    fi
}

package_fingerprint() {
    git -C "$CHECKOUT_DIR" ls-files -s -- "$SOURCE_DIR" \
        | awk '$0 ~ /\.ya?ml$/ { print }' \
        | sha256sum \
        | awk '{ print $1 }'
}

build_manifest() {
    local destination=$1

    git -C "$CHECKOUT_DIR" ls-files -- "$SOURCE_DIR" \
        | awk -v prefix="${SOURCE_DIR}/" '$0 ~ /\.ya?ml$/ { sub("^" prefix, ""); print }' \
        | sort > "$destination"
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

    # Remove everything the attempted deployment may have touched, then restore
    # exactly the files that existed before it began.
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

sync_packages() {
    local fingerprint
    local deployed_fingerprint=""
    local failed_fingerprint=""
    local new_manifest
    local touched_manifest
    local backup_manifest
    local backup_dir
    local backup_parent
    local relative_path
    local source_path
    local target_path

    [ -d "$CHECKOUT_DIR/$SOURCE_DIR" ] || {
        bashio::log.error "Repository does not contain $SOURCE_DIR/"
        return 1
    }

    if ! fingerprint=$(package_fingerprint); then
        bashio::log.error "Could not fingerprint package files"
        return 1
    fi

    [ -f "$DEPLOYED_FINGERPRINT" ] && deployed_fingerprint=$(cat "$DEPLOYED_FINGERPRINT")
    [ -f "$FAILED_FINGERPRINT" ] && failed_fingerprint=$(cat "$FAILED_FINGERPRINT")

    if [ "$fingerprint" = "$deployed_fingerprint" ]; then
        bashio::log.info "Repository changed, but package YAML is unchanged"
        return 0
    fi

    # Remember bad package content, not merely a commit. A README-only commit on
    # top of the same rejected YAML must not make us validate it again.
    if [ -n "$failed_fingerprint" ] && [ "$fingerprint" = "$failed_fingerprint" ]; then
        bashio::log.warning "Package YAML matches a previously failed validation; waiting for package changes"
        return 0
    fi

    new_manifest=$(mktemp /data/managed-files.new.XXXXXX) || {
        bashio::log.error "Could not create temporary package manifest"
        return 1
    }

    if ! build_manifest "$new_manifest"; then
        bashio::log.error "Could not build package manifest"
        rm -f "$new_manifest"
        return 1
    fi

    if ! mkdir -p "$DEST_DIR"; then
        bashio::log.error "Could not create Home Assistant package directory"
        rm -f "$new_manifest"
        return 1
    fi

    # Never silently take ownership of a local file. An unmanaged existing file
    # can only be adopted when it is a real regular file (not a symlink) and is
    # byte-for-byte identical to the repository copy.
    while IFS= read -r relative_path; do
        [ -n "$relative_path" ] || continue
        source_path="$CHECKOUT_DIR/$SOURCE_DIR/$relative_path"
        target_path="$DEST_DIR/$relative_path"

        if [ -L "$target_path" ]; then
            bashio::log.error "Refusing to adopt symlinked package path: $relative_path"
            rm -f "$new_manifest"
            return 1
        fi

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
        [ -f "$MANIFEST" ] && cat "$MANIFEST"
        cat "$new_manifest"
    } | sort -u > "$touched_manifest"; then
        bashio::log.error "Could not build rollback file list"
        rm -rf "$backup_dir"
        rm -f "$new_manifest"
        return 1
    fi

    # Prove the rollback copy is complete before touching live packages.
    while IFS= read -r relative_path; do
        [ -n "$relative_path" ] || continue
        target_path="$DEST_DIR/$relative_path"

        if [ -L "$target_path" ]; then
            bashio::log.error "Managed package path became a symlink: $relative_path"
            rm -rf "$backup_dir"
            rm -f "$new_manifest"
            return 1
        fi
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

    # Remove the previous managed set first so Git deletions/renames are
    # reflected locally without touching unrelated local package files.
    if [ -f "$MANIFEST" ]; then
        while IFS= read -r relative_path; do
            [ -n "$relative_path" ] || continue
            if ! rm -f "$DEST_DIR/$relative_path"; then
                bashio::log.error "Could not remove previous managed package: $relative_path"
                restore_files "$touched_manifest" "$backup_manifest" "$backup_dir" || bashio::log.error "Rollback also encountered errors"
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
            restore_files "$touched_manifest" "$backup_manifest" "$backup_dir" || bashio::log.error "Rollback also encountered errors"
            rm -rf "$backup_dir"
            rm -f "$new_manifest"
            return 1
        fi
        if ! cp -p "$CHECKOUT_DIR/$SOURCE_DIR/$relative_path" "$DEST_DIR/$relative_path"; then
            bashio::log.error "Could not deploy package: $relative_path"
            restore_files "$touched_manifest" "$backup_manifest" "$backup_dir" || bashio::log.error "Rollback also encountered errors"
            rm -rf "$backup_dir"
            rm -f "$new_manifest"
            return 1
        fi
    done < "$new_manifest"

    bashio::log.info "Package YAML changed; checking Home Assistant configuration"
    if ! bashio::core.check; then
        bashio::log.error "Candidate configuration check failed; restoring previous packages"

        if ! restore_files "$touched_manifest" "$backup_manifest" "$backup_dir"; then
            bashio::log.error "Rollback also encountered errors; package version will be retried"
            rm -rf "$backup_dir"
            rm -f "$new_manifest"
            return 1
        fi

        rm -rf "$backup_dir"
        rm -f "$new_manifest"

        # bashio::core.check reports both invalid configuration and Supervisor /
        # service failures as a non-zero result. Distinguish them safely by
        # checking again *after* restoring the previous known-good packages.
        # If that baseline also cannot be checked, treat the event as transient
        # and retry next poll rather than permanently blacklisting the YAML.
        bashio::log.info "Checking restored baseline to classify the failure"
        if ! bashio::core.check; then
            bashio::log.error "Restored baseline check also failed; treating validation failure as transient"
            return 1
        fi

        if ! printf '%s\n' "$fingerprint" > "$FAILED_FINGERPRINT"; then
            bashio::log.error "Could not remember failed package fingerprint; it will be retried"
            return 1
        fi

        bashio::log.error "Previous valid packages restored; this package version is marked as failed"
        return 0
    fi

    # The ownership manifest is part of the deployment transaction. If it
    # cannot be committed, restore the live package files before discarding the
    # rollback data.
    if ! mv "$new_manifest" "$MANIFEST"; then
        bashio::log.error "Config is valid but managed-file manifest could not be persisted; rolling back"
        restore_files "$touched_manifest" "$backup_manifest" "$backup_dir" || bashio::log.error "Rollback also encountered errors"
        rm -rf "$backup_dir"
        rm -f "$new_manifest"
        return 1
    fi

    if ! printf '%s\n' "$fingerprint" > "$DEPLOYED_FINGERPRINT"; then
        bashio::log.error "Config is valid but deployment fingerprint could not be persisted"
        rm -rf "$backup_dir"
        return 1
    fi

    rm -f "$FAILED_FINGERPRINT"
    rm -rf "$backup_dir"

    bashio::log.info "Package sync completed and configuration is valid"

    if [ "$AUTO_RESTART" = "true" ]; then
        if ! : > "$PENDING_RESTART"; then
            bashio::log.error "Could not record pending restart"
            return 1
        fi
        attempt_pending_restart || return 1
    else
        bashio::log.info "Home Assistant was not restarted (auto_restart is false)"
    fi
}

sync_once() {
    local head
    local processed_head=""
    local checkout_head

    # Finish an already-requested deployment action before looking for more Git
    # work. A failed restart remains pending and is retried without re-copying
    # packages or re-running the configuration check.
    attempt_pending_restart || return 1

    # Normal polling is intentionally tiny: ask GitHub only for the branch HEAD
    # hash. If it is unchanged, do no fetch, checkout scan, fingerprinting, file
    # copy, Supervisor config check, or restart work.
    if ! head=$(remote_head); then
        return 1
    fi

    [ -f "$PROCESSED_HEAD" ] && processed_head=$(cat "$PROCESSED_HEAD")

    if [ "$head" = "$processed_head" ]; then
        bashio::log.info "Repository HEAD unchanged"
        return 0
    fi

    update_checkout "$head" || return 1
    sync_packages || return 1

    if ! checkout_head=$(git -C "$CHECKOUT_DIR" rev-parse HEAD); then
        bashio::log.error "Could not read processed checkout HEAD"
        return 1
    fi

    # Mark a commit processed only after its package content was successfully
    # deployed, found unchanged, or identified as the same package fingerprint
    # already rejected by a confirmed validation failure. Transient failures do
    # not advance this marker and are retried next poll.
    if ! printf '%s\n' "$checkout_head" > "$PROCESSED_HEAD"; then
        bashio::log.error "Could not remember processed repository HEAD"
        return 1
    fi
}

setup_ssh
bashio::log.info "Watching $REPOSITORY ($BRANCH) every ${INTERVAL}s"
bashio::log.info "Unchanged polls check only the remote HEAD commit hash"
bashio::log.info "Only tracked YAML under $SOURCE_DIR/ is deployed to $DEST_DIR"

while true; do
    if ! sync_once; then
        bashio::log.warning "Sync attempt failed; previous valid packages remain in place where possible"
    fi
    sleep "$INTERVAL"
done
