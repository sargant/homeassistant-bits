# Git package sync

Small local Home Assistant app for mirroring one directory from a public Git repository into one directory owned entirely by the app.

The defaults for this repository are:

```yaml
repository: https://github.com/sargant/homeassistant-bits.git
branch: main
source_path: packages
destination_path: packages/synced
interval: 300
after_sync: reload
```

`source_path` is important: this repository contains more than Home Assistant packages, so the app copies only that subtree. The complete subtree is copied, including non-YAML files; Home Assistant's `!include_dir_named` loader ignores files that are not YAML.

`destination_path` is the ownership boundary and must be one direct child of `packages/`, such as `packages/synced`. The app may replace or delete that entire directory during a sync. Do not put hand-managed files in it; sibling package directories and files are untouched.

The app also reserves `/homeassistant/.git-package-sync/` for temporary staging and rollback data. It is outside the recursively included package tree but on the same Home Assistant config filesystem, so directory renames remain atomic.

## Home Assistant configuration

The existing package include is sufficient because `!include_dir_named` is recursive:

```yaml
homeassistant:
  packages: !include_dir_named packages
```

## Install

Copy this `sync` directory to `/addons/git_package_sync` on the Home Assistant host. Then go to **Settings → Apps → App store**, use **Check for updates**, install **Git Package Sync**, and start it.

No GitHub key or token is required: the configured repository must be publicly readable over HTTPS.

This is a locally built app. Supervisor builds the image from `Dockerfile` when the app is installed; there is no `build.yaml` and no pre-built image to publish. The Dockerfile uses Home Assistant's multi-architecture `ghcr.io/home-assistant/base:3.23` image directly.

## Behaviour

- Every five minutes by default, check only the configured branch's remote HEAD hash.
- If that HEAD has already been processed, do nothing else.
- When HEAD changes, shallow-fetch it and inspect only `source_path`.
- Use the Git tree hash of `source_path` as the content fingerprint, so commits elsewhere in the repository do not cause a deployment.
- Build the whole source subtree in the reserved work directory.
- Swap the previous destination aside and put the complete candidate directory in its place.
- Run the Home Assistant configuration check.
- If candidate validation fails, restore the previous directory. If the restored configuration validates, remember the rejected source tree so it is not retried until the source subtree changes; if the restored configuration also fails, treat the check as transient and retry later.
- If validation succeeds, atomically rename the backup out of the rollback position; that rename is the commit point. A crash before it rolls back on the next pass; a crash after it keeps the validated candidate.
- After a successful deployment, `after_sync` controls what happens next:
  - `reload` (default) calls Home Assistant's quick `homeassistant.reload_all` action, matching **Quick reload all YAML configuration** in the UI;
  - `restart` requests a full Home Assistant restart;
  - `none` leaves the validated files in place without reloading or restarting.

Quick reload only affects YAML-backed integrations that support reloading. Use `restart` for changes that require a full restart.

Changing `destination_path` after the app has already synced is a manual migration: remove the old app-owned directory yourself so it is not left behind and loaded alongside the new one.

The installed local app does not update its own source under `sync/`; changes to the app still need to be recopied/rebuilt manually.
