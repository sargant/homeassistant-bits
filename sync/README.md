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

`destination_path` is an ownership boundary. The app may replace or delete that entire directory during a sync. Do not put hand-managed files in it. With the default configuration, files elsewhere under `packages/` are untouched.

The app keeps its temporary staging and rollback directories under `/homeassistant/.git-package-sync/`, outside the package tree. That hidden work area is marked as app-owned before it is used, so package siblings are never repurposed as transaction storage.

## Home Assistant configuration

The existing package include is sufficient because `!include_dir_named` is recursive:

```yaml
homeassistant:
  packages: !include_dir_named packages
```

## Install

Copy this `sync` directory to `/addons/git_package_sync` on the Home Assistant host. Then go to **Settings → Apps → App store**, use **Check for updates**, install **Git Package Sync**, and start it.

No GitHub key or token is required: the configured repository must be publicly readable over HTTPS.

## Behaviour

- Every five minutes by default, check only the configured branch's remote HEAD hash.
- If that HEAD has already been processed, do nothing else.
- When HEAD changes, shallow-fetch it and inspect only `source_path`.
- Use the Git tree hash of `source_path` as the content fingerprint, so commits elsewhere in the repository do not cause a deployment.
- Build the whole source subtree in the hidden work area on the same Home Assistant config filesystem.
- Swap the previous destination aside and put the complete candidate directory in its place.
- Run the Home Assistant configuration check.
- If validation fails, restore the previous directory and remember that failed source tree so it is not retried until the source subtree changes.
- If validation succeeds, atomically rename the backup out of the rollback position; that rename is the commit point. Leftover old/staging directories are cleaned up on the next pass.
- After a successful deployment, `after_sync` controls what happens next:
  - `reload` (default) calls Home Assistant's quick `homeassistant.reload_all` action, matching **Quick reload all YAML configuration** in the UI;
  - `restart` requests a full Home Assistant restart;
  - `none` leaves the validated files in place without reloading or restarting.

Quick reload only affects YAML-backed integrations that support reloading. Use `restart` for changes that require a full restart.

Changing `destination_path` after the app has already synced is a manual migration: remove the old app-owned directory yourself so it is not left behind and loaded alongside the new one.

The installed local app does not update its own source under `sync/`; changes to the app still need to be recopied/rebuilt manually.
