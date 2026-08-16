# Package sync

Tiny local Home Assistant app that watches `main` in this repository and deploys tracked `packages/**/*.yaml` into `/config/packages/synced/`.

The important ownership boundary is simple: **the app owns the whole `packages/synced/` directory and nothing else under `packages/`**. The private Git checkout lives in the app's `/data`; Home Assistant's config directory is never turned into a Git checkout.

This assumes Home Assistant already uses recursive packages, for example:

```yaml
homeassistant:
  packages: !include_dir_named packages
```

## Install

Copy this `sync` directory to the Home Assistant host as a subdirectory of `/addons`, for example `/addons/homeassistant_bits_sync`.

Then in Home Assistant go to **Settings → Apps → App store**, use **Check for updates**, and install the local **Home Assistant Bits Sync** app.

Because this repository is private, create a read-only GitHub deploy key for `sargant/homeassistant-bits` and put the private key into the app configuration as one line per list item:

```yaml
interval: 300
auto_restart: false
deployment_key:
  - "-----BEGIN OPENSSH PRIVATE KEY-----"
  - "..."
  - "-----END OPENSSH PRIVATE KEY-----"
```

Before the first successful sync, remove any manually copied package files outside `packages/synced/` that duplicate files from this repository. The app deliberately will not move or delete them for you; duplicate package definitions should fail the Home Assistant config check and roll the attempted sync back.

Start the app and check its logs.

## Behaviour

- checks only the remote `main` HEAD commit hash every five minutes by default;
- does not fetch the repository, inspect files or run a Home Assistant check when that HEAD has already been processed;
- when HEAD changes, fetches the new commit and considers only tracked `.yaml` under this repository's `packages/` directory;
- ignores repository changes outside package YAML;
- remembers package content that repeatedly fails Home Assistant validation and does not retry that same package fingerprint until package YAML changes;
- builds the complete next `packages/synced/` tree before touching the live one;
- swaps the whole owned directory rather than updating individual files;
- runs a Home Assistant config check against the candidate directory;
- restores the previous complete `packages/synced/` tree if validation fails;
- recovers an interrupted directory swap on the next run before doing any new Git work;
- never modifies anything else under Home Assistant's `packages/` directory;
- optionally restarts Home Assistant after a successful sync when `auto_restart` is enabled, and retries a failed restart request.

The installed local app does not update its own app source. If files under `sync/` change, copy this directory into `/addons` again and rebuild/update the local app.
