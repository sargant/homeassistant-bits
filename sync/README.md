# Git package sync

Small local Home Assistant app for mirroring one directory from a public Git repository into one Home Assistant package directory owned entirely by the app.

This is intentionally **not** a general Git deployment engine. It exists to keep a small personal set of Home Assistant package YAML (dishwasher, laundry, and similar experiments) in sync without turning `/config` into a Git checkout or building a large transaction system around it.

The defaults for this repository are:

```yaml
repository: https://github.com/sargant/homeassistant-bits.git
branch: main
source_path: packages
destination_path: packages/synced
interval: 300
after_sync: reload
```

## Deliberate constraints

Keeping the scope narrow is part of the design:

- the repository must be publicly readable over HTTPS;
- `source_path` is one normalized relative Git directory path (for example `packages`), not a filesystem path with `.` components, `..`, repeated slashes, or a trailing slash;
- `destination_path` must be one visible direct child of `packages/`, such as `packages/synced`;
- the destination directory is wholly app-owned and may be replaced or deleted as a unit;
- sibling package files and directories are never touched;
- `/homeassistant/.git-package-sync/<destination-name>/` is reserved as scratch space for that destination;
- there is no per-file manifest, journal, multi-writer coordination, private-repository authentication, or attempt to make arbitrary destination layouts safe.

These constraints are preferable here to adding machinery for configurations this app does not need to support. If its reserved work area or destination is manually corrupted, failing loudly and fixing it manually is acceptable.

`source_path` matters because this repository contains more than Home Assistant packages. Only that Git subtree is fingerprinted and copied, so commits elsewhere in the repository do not cause package deployment.

## Home Assistant configuration

The existing package include is sufficient because `!include_dir_named` is recursive:

```yaml
homeassistant:
  packages: !include_dir_named packages
```

## Install

Copy this `sync` directory to `/addons/git_package_sync` on the Home Assistant host. Then go to **Settings → Apps → App store**, use **Check for updates**, install **Git Package Sync**, and start it.

This is a locally built app. Supervisor builds the image from `Dockerfile` when the app is installed; there is no `build.yaml` and no pre-built image to publish. The Dockerfile uses Home Assistant's multi-architecture `ghcr.io/home-assistant/base:3.23` image directly.

## Behaviour

- Every five minutes by default, check only the configured branch's remote HEAD hash.
- If that HEAD has already been processed, do nothing else.
- When HEAD changes, shallow-fetch it and inspect only `source_path`.
- Use the Git tree hash of `source_path` as the content fingerprint, so commits elsewhere in the repository do not cause a deployment.
- Build the complete source subtree in the destination-specific reserved work directory.
- Swap the previous destination aside and put the complete candidate directory in its place.
- Run the Home Assistant configuration check.
- If candidate validation fails, restore the previous directory. If the restored configuration validates, remember the rejected source tree so it is not retried until the source subtree changes; if the restored configuration also fails, treat the check as transient and retry later.
- If validation succeeds, rename the backup out of the rollback position. That is the commit point: an interrupted sync before it is rolled back on the next pass; after it, the validated candidate wins.
- If the configured reload or restart fails, retry the deployment on the next poll rather than adding a separate persistent action queue.
- After a successful deployment, `after_sync` controls what happens next:
  - `reload` (default) calls Home Assistant's quick `homeassistant.reload_all` action, matching **Quick reload all YAML configuration** in the UI;
  - `restart` requests a full Home Assistant restart;
  - `none` leaves the validated files in place without reloading or restarting.

Quick reload only affects YAML-backed integrations that support reloading. Use `restart` for changes that require a full restart.

Changing `destination_path` is intentionally a manual migration. Work/rollback state is isolated by destination name so changing the setting cannot apply an old destination's backup to the new one; clean up the old app-owned package directory and its reserved work directory yourself.

The installed local app does not update its own source under `sync/`; changes to the app still need to be recopied/rebuilt manually.
