#!/usr/bin/with-contenv bashio
# shellcheck shell=bash

set -o pipefail

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
ACTIVE_TRANSACTION="/data/active-transaction"
SSH_KEY="/root/.ssh/id_ed25519"

INTERVAL=$(bashio::config 'interval')
AUTO_RESTART=$(bashio::config 'auto_restart')
DEPLOYMENT_KEY=$(bashio::config 'deployment_key')

if [ "$INTERVAL" -lt 60 ]; then
    bashio::log.warning "Interval below 60 seconds; using 60 seconds instead"
    INTERVAL=60
fi

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
    # An absent packages/ directory is a valid empty package set.
    git -C "$CHECKOUT_DIR" ls-files -s -- "$SOURCE_DIR" \
        | awk '$0 ~ /\.yaml$/ { print }' \
        | sha256sum \
        | awk '{ print $1 }'
}

build_manifest() {
    local destination=$1
    git -C "$CHECKOUT_DIR" ls-files -- "$SOURCE_DIR" \
        | awk -v prefix="${SOURCE_DIR}/" '$0 ~ /\.yaml$/ { sub("^" prefix, ""); print }' \
        | sort > "$destination"
}

is_managed() {
    local relative_path=$1
    [ -f "$MANIFEST" ] && grep -Fxq -- "$relative_path" "$MANIFEST"
}

ensure_destination_root() {
    if [ -L /homeassistant ] || [ ! -d /homeassistant ]; then
        bashio::log.error "Home Assistant config mount is missing or is a symlink"
        return 1
    fi
    if [ -L "$DEST_DIR" ] || { [ -e "$DEST_DIR" ] && [ ! -d "$DEST_DIR" ]; }; then
        bashio::log.error "Home Assistant package path is unsafe"
        return 1
    fi
    mkdir -p "$DEST_DIR" || {
        bashio::log.error "Could not create Home Assistant package directory"
        return 1
    }
    [ ! -L "$DEST_DIR" ] && [ -d "$DEST_DIR" ] || {
        bashio::log.error "Home Assistant package directory became unsafe"
        return 1
    }
}

validate_destination_path() {
    local relative_path=$1
    local parent
    local current="$DEST_DIR"
    local component
    local -a components

    case "$relative_path" in
        ""|/*)
            bashio::log.error "Unsafe package path: $relative_path"
            return 1
            ;;
    esac

    if [ -L "$DEST_DIR" ] || [ ! -d "$DEST_DIR" ]; then
        bashio::log.error "Home Assistant package directory became unsafe"
        return 1
    fi

    parent=$(dirname "$relative_path")
    [ "$parent" = "." ] && return 0

    IFS='/' read -r -a components <<< "$parent"
    for component in "${components[@]}"; do
        if [ -z "$component" ] || [ "$component" = "." ] || [ "$component" = ".." ]; then
            bashio::log.error "Unsafe package path component in: $relative_path"
            return 1
        fi
        current="$current/$component"
        if [ -L "$current" ]; then
            bashio::log.error "Package parent is a symlink: $relative_path"
            return 1
        fi
        if [ -e "$current" ] && [ ! -d "$current" ]; then
            bashio::log.error "Package parent is not a directory: $relative_path"
            return 1
        fi
    done
}

atomic_copy() {
    local source=$1
    local destination=$2
    local temp

    temp=$(mktemp "${destination}.new.XXXXXX") || return 1
    if ! cp -p "$source" "$temp" || ! mv "$temp" "$destination"; then
        rm -f "$temp"
        return 1
    fi
}

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

restore_files() {
    local transaction_dir=$1
    local touched="$transaction_dir/touched-files.txt"
    local existing="$transaction_dir/existing-files.txt"
    local relative_path
    local failed=0

    while IFS= read -r relative_path; do
        [ -n "$relative_path" ] || continue
        validate_destination_path "$relative_path" || { failed=1; continue; }
        rm -f "$DEST_DIR/$relative_path" || {
            bashio::log.error "Rollback could not remove: $relative_path"
            failed=1
        }
    done < "$touched"

    while IFS= read -r relative_path; do
        [ -n "$relative_path" ] || continue
        validate_destination_path "$relative_path" || { failed=1; continue; }
        mkdir -p "$DEST_DIR/$(dirname "$relative_path")" || {
            bashio::log.error "Rollback could not create parent directory for: $relative_path"
            failed=1
            continue
        }
        validate_destination_path "$relative_path" || { failed=1; continue; }
        if [ -L "$DEST_DIR/$relative_path" ]; then
            bashio::log.error "Rollback target became a symlink: $relative_path"
            failed=1
            continue
        fi
        cp -p "$transaction_dir/files/$relative_path" "$DEST_DIR/$relative_path" || {
            bashio::log.error "Rollback could not restore: $relative_path"
            failed=1
        }
    done < "$existing"

    return "$failed"
}

rollback_transaction() {
    [ -d "$ACTIVE_TRANSACTION" ] || return 0

    if ! restore_files "$ACTIVE_TRANSACTION"; then
        bashio::log.error "Rollback was incomplete; retaining transaction data for recovery"
        return 1
    fi
    rm -rf "$ACTIVE_TRANSACTION" || {
        bashio::log.error "Could not remove completed rollback transaction"
        return 1
    }
}

prepare_transaction() {
    local manifest_source=$1
    local fingerprint=$2
    local temp
    local touched
    local existing
    local relative_path
    local target_path
    local backup_parent

    [ ! -e "$ACTIVE_TRANSACTION" ] || {
        bashio::log.error "An active deployment transaction already exists"
        return 1
    }

    temp=$(mktemp -d /data/transaction.new.XXXXXX) || {
        bashio::log.error "Could not create deployment transaction"
        return 1
    }
    touched="$temp/touched-files.txt"
    existing="$temp/existing-files.txt"

    cp -p "$manifest_source" "$temp/new-manifest.txt" || {
        bashio::log.error "Could not store candidate package manifest"
        rm -rf "$temp"
        return 1
    }
    printf '%s\n' "$fingerprint" > "$temp/candidate-fingerprint" || {
        bashio::log.error "Could not store candidate package fingerprint"
        rm -rf "$temp"
        return 1
    }
    : > "$existing" || {
        bashio::log.error "Could not create rollback manifest"
        rm -rf "$temp"
        return 1
    }

    if ! { [ -f "$MANIFEST" ] && cat "$MANIFEST"; cat "$temp/new-manifest.txt"; } | sort -u > "$touched"; then
        bashio::log.error "Could not build rollback file list"
        rm -rf "$temp"
        return 1
    fi

    # Back up every file that can be removed or overwritten before the
    # transaction becomes visible. No live package is changed before the final
    # atomic rename to ACTIVE_TRANSACTION.
    while IFS= read -r relative_path; do
        [ -n "$relative_path" ] || continue
        validate_destination_path "$relative_path" || { rm -rf "$temp"; return 1; }
        target_path="$DEST_DIR/$relative_path"

        if [ -L "$target_path" ]; then
            bashio::log.error "Package path is a symlink: $relative_path"
            rm -rf "$temp"
            return 1
        fi
        if [ -e "$target_path" ] && [ ! -f "$target_path" ]; then
            bashio::log.error "Package path is not a regular file: $relative_path"
            rm -rf "$temp"
            return 1
        fi

        if [ -f "$target_path" ]; then
            backup_parent="$temp/files/$(dirname "$relative_path")"
            mkdir -p "$backup_parent" || { rm -rf "$temp"; return 1; }
            cp -p "$target_path" "$temp/files/$relative_path" || { rm -rf "$temp"; return 1; }
            printf '%s\n' "$relative_path" >> "$existing" || { rm -rf "$temp"; return 1; }
        fi
    done < "$touched"

    mv "$temp" "$ACTIVE_TRANSACTION" || {
        bashio::log.error "Could not activate deployment transaction"
        rm -rf "$temp"
        return 1
    }
}

deploy_candidate() {
    local relative_path
    local target_path

    if [ -f "$MANIFEST" ]; then
        while IFS= read -r relative_path; do
            [ -n "$relative_path" ] || continue
            validate_destination_path "$relative_path" || return 1
            rm -f "$DEST_DIR/$relative_path" || {
                bashio::log.error "Could not remove previous managed package: $relative_path"
                return 1
            }
        done < "$MANIFEST"
    fi

    while IFS= read -r relative_path; do
        [ -n "$relative_path" ] || continue
        validate_destination_path "$relative_path" || return 1
        mkdir -p "$DEST_DIR/$(dirname "$relative_path")" || {
            bashio::log.error "Could not create destination directory for: $relative_path"
            return 1
        }
        validate_destination_path "$relative_path" || return 1
        target_path="$DEST_DIR/$relative_path"
        [ ! -L "$target_path" ] || {
            bashio::log.error "Refusing to deploy through symlinked package path: $relative_path"
            return 1
        }
        cp -p "$CHECKOUT_DIR/$SOURCE_DIR/$relative_path" "$target_path" || {
            bashio::log.error "Could not deploy package: $relative_path"
            return 1
        }
    done < "$ACTIVE_TRANSACTION/new-manifest.txt"
}

mark_transaction_validated() {
    local temp="$ACTIVE_TRANSACTION/state.new"
    printf 'validated\n' > "$temp" && mv "$temp" "$ACTIVE_TRANSACTION/state"
}

finish_validated_transaction() {
    local fingerprint
    local state_temp="$ACTIVE_TRANSACTION/state.new"

    fingerprint=$(cat "$ACTIVE_TRANSACTION/candidate-fingerprint") || {
        bashio::log.error "Could not read validated candidate fingerprint"
        return 1
    }

    # Keep the candidate manifest in the transaction so recovery can repeat this
    # commit idempotently if the app stops halfway through it.
    atomic_copy "$ACTIVE_TRANSACTION/new-manifest.txt" "$MANIFEST" || {
        bashio::log.error "Could not persist managed-file manifest"
        return 1
    }

    # A required restart must be durable before the deployment fingerprint says
    # this package version is complete.
    if [ "$AUTO_RESTART" = "true" ]; then
        : > "$PENDING_RESTART" || {
            bashio::log.error "Could not record pending restart"
            return 1
        }
    else
        rm -f "$PENDING_RESTART" || return 1
    fi

    atomic_text "$fingerprint" "$DEPLOYED_FINGERPRINT" || {
        bashio::log.error "Could not persist deployment fingerprint"
        return 1
    }
    rm -f "$FAILED_FINGERPRINT" || {
        bashio::log.error "Could not clear older failed package fingerprint"
        return 1
    }

    printf 'committed\n' > "$state_temp" && mv "$state_temp" "$ACTIVE_TRANSACTION/state" || {
        bashio::log.error "Could not mark deployment transaction committed"
        return 1
    }

    rm -rf "$ACTIVE_TRANSACTION" || {
        bashio::log.error "Could not clean up committed transaction; will retry cleanup next poll"
        return 1
    }
}

recover_active_transaction() {
    local state=""

    [ -d "$ACTIVE_TRANSACTION" ] || return 0
    [ -f "$ACTIVE_TRANSACTION/state" ] && state=$(cat "$ACTIVE_TRANSACTION/state")

    case "$state" in
        validated)
            bashio::log.warning "Finishing metadata for a validated deployment interrupted by shutdown"
            finish_validated_transaction
            ;;
        committed)
            bashio::log.warning "Cleaning up a deployment committed before shutdown"
            rm -rf "$ACTIVE_TRANSACTION"
            ;;
        *)
            bashio::log.warning "Recovering an interrupted unvalidated package deployment"
            rollback_transaction
            ;;
    esac
}

attempt_pending_restart() {
    [ -f "$PENDING_RESTART" ] || return 0

    if [ "$AUTO_RESTART" != "true" ]; then
        bashio::log.info "Automatic restart is disabled; clearing pending restart"
        rm -f "$PENDING_RESTART"
        return 0
    fi

    bashio::log.info "Requesting pending Home Assistant restart"
    bashio::core.restart || {
        bashio::log.error "Home Assistant restart request failed; will retry next poll"
        return 1
    }
    rm -f "$PENDING_RESTART" || {
        bashio::log.error "Restart was requested, but pending marker could not be cleared"
        return 1
    }
    bashio::log.info "Home Assistant restart requested successfully"
}

commit_valid_candidate() {
    local fingerprint=$1

    mark_transaction_validated || {
        bashio::log.error "Could not mark valid deployment recoverable; rolling back"
        rollback_transaction || true
        return 1
    }
    finish_validated_transaction || return 1

    bashio::log.info "Package sync completed and configuration is valid"
    attempt_pending_restart
}

sync_packages() {
    local fingerprint
    local deployed=""
    local failed=""
    local manifest_temp
    local relative_path
    local source_path
    local target_path

    fingerprint=$(package_fingerprint) || {
        bashio::log.error "Could not fingerprint package files"
        return 1
    }
    [ -f "$DEPLOYED_FINGERPRINT" ] && deployed=$(cat "$DEPLOYED_FINGERPRINT")
    [ -f "$FAILED_FINGERPRINT" ] && failed=$(cat "$FAILED_FINGERPRINT")

    if [ "$fingerprint" = "$deployed" ]; then
        bashio::log.info "Repository changed, but package YAML is unchanged"
        return 0
    fi
    if [ -n "$failed" ] && [ "$fingerprint" = "$failed" ]; then
        bashio::log.warning "Package YAML matches a previously failed validation; waiting for package changes"
        return 0
    fi

    ensure_destination_root || return 1
    manifest_temp=$(mktemp /data/managed-files.new.XXXXXX) || return 1
    build_manifest "$manifest_temp" || { rm -f "$manifest_temp"; return 1; }

    # Unmanaged files are adopted only when the path is safe and the existing
    # regular file is byte-for-byte identical to the repository copy.
    while IFS= read -r relative_path; do
        [ -n "$relative_path" ] || continue
        validate_destination_path "$relative_path" || { rm -f "$manifest_temp"; return 1; }
        source_path="$CHECKOUT_DIR/$SOURCE_DIR/$relative_path"
        target_path="$DEST_DIR/$relative_path"
        if [ -L "$target_path" ]; then
            bashio::log.error "Refusing to adopt symlinked package path: $relative_path"
            rm -f "$manifest_temp"
            return 1
        fi
        if [ -e "$target_path" ] && ! is_managed "$relative_path"; then
            if [ -f "$target_path" ] && cmp -s "$source_path" "$target_path"; then
                bashio::log.info "Adopting existing identical package: $relative_path"
            else
                bashio::log.error "Refusing to overwrite unmanaged package: $relative_path"
                rm -f "$manifest_temp"
                return 1
            fi
        fi
    done < "$manifest_temp"

    prepare_transaction "$manifest_temp" "$fingerprint" || { rm -f "$manifest_temp"; return 1; }
    rm -f "$manifest_temp"

    deploy_candidate || {
        bashio::log.error "Package deployment failed; restoring previous packages"
        rollback_transaction || true
        return 1
    }

    bashio::log.info "Package YAML changed; checking Home Assistant configuration"
    if bashio::core.check; then
        commit_valid_candidate "$fingerprint"
        return $?
    fi

    # /core/check returns the same shell failure for invalid YAML and transient
    # Supervisor/service errors. Restore and validate the baseline, then retry
    # the candidate once before blacklisting it.
    bashio::log.error "Candidate configuration check failed; restoring previous packages"
    restore_files "$ACTIVE_TRANSACTION" || {
        bashio::log.error "Rollback failed; retaining transaction for recovery"
        return 1
    }

    bashio::log.info "Checking restored baseline to classify the failure"
    if ! bashio::core.check; then
        bashio::log.error "Restored baseline also failed; treating candidate result as transient"
        rollback_transaction || true
        return 1
    fi

    bashio::log.info "Baseline is healthy; rechecking candidate before marking it invalid"
    deploy_candidate || { rollback_transaction || true; return 1; }
    if bashio::core.check; then
        bashio::log.info "Candidate passed on recheck; first failure was transient"
        commit_valid_candidate "$fingerprint"
        return $?
    fi

    bashio::log.error "Candidate failed configuration check again; restoring previous packages"
    restore_files "$ACTIVE_TRANSACTION" || {
        bashio::log.error "Rollback failed; retaining transaction for recovery"
        return 1
    }

    # Require the service to validate the baseline again. Only the pattern
    # candidate-fail / baseline-pass / candidate-fail / baseline-pass is
    # remembered as a genuinely bad package fingerprint.
    bashio::log.info "Confirming restored baseline after second candidate failure"
    if ! bashio::core.check; then
        bashio::log.error "Baseline confirmation failed; treating candidate result as transient"
        rollback_transaction || true
        return 1
    fi

    rollback_transaction || return 1
    atomic_text "$fingerprint" "$FAILED_FINGERPRINT" || {
        bashio::log.error "Could not remember failed package fingerprint; it will be retried"
        return 1
    }
    bashio::log.error "Previous valid packages restored; this package version is marked as failed"
}

sync_once() {
    local head
    local processed=""
    local checkout_head

    # Recovery must run before restart or Git work. An unvalidated candidate is
    # always rolled back; a validated one only finishes its idempotent metadata
    # commit before normal polling resumes.
    recover_active_transaction || return 1
    attempt_pending_restart || return 1

    # The steady-state five-minute poll does exactly one remote HEAD lookup.
    head=$(remote_head) || return 1
    [ -f "$PROCESSED_HEAD" ] && processed=$(cat "$PROCESSED_HEAD")
    if [ "$head" = "$processed" ]; then
        bashio::log.info "Repository HEAD unchanged"
        return 0
    fi

    update_checkout "$head" || return 1
    sync_packages || return 1
    checkout_head=$(git -C "$CHECKOUT_DIR" rev-parse HEAD) || return 1
    atomic_text "$checkout_head" "$PROCESSED_HEAD" || {
        bashio::log.error "Could not remember processed repository HEAD"
        return 1
    }
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
