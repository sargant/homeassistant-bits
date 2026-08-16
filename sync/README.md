# Package sync

Tiny local Home Assistant app that watches `main` in this repository and deploys only tracked `packages/**/*.yaml` files into Home Assistant's `packages/` directory.

It deliberately does **not** turn `/config` into a Git checkout. The private clone lives in the app's `/data`, and only package YAML is copied into Home Assistant.

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

Start the app and check its logs.

## Behaviour

- checks only the remote `main` HEAD commit hash every five minutes by default;
- does not fetch the repository, inspect files or run a Home Assistant check when that HEAD has already been processed;
- when HEAD changes, fetches the new commit and considers only tracked package YAML;
- ignores changes outside tracked package YAML, so README/agent/sync-app edits do not cause a Home Assistant deployment;
- treats removal of the whole `packages/` directory as an empty managed package set, so previously managed files are removed;
- remembers package content that repeatedly fails Home Assistant validation while the restored baseline remains valid, and does not retry that package fingerprint until package YAML changes;
- tracks which package files it owns and removes them when they are removed or renamed in Git;
- never deletes unrelated local package files;
- refuses to overwrite an unmanaged local package unless it is a normal file at a non-symlinked path and is already byte-for-byte identical, in which case it adopts it;
- makes a durable rollback transaction before changing live package files and recovers an interrupted deployment before doing any new work after restart;
- runs a Home Assistant config check after changing packages and restores the previous package files when a candidate is invalid;
- retries transient Git, Supervisor, filesystem and state-persistence failures without unnecessarily refetching a commit already present locally;
- when `auto_restart` is enabled, records the restart requirement durably before considering a deployment complete and retries a failed restart request on later polls.

Home Assistant's directory include helpers load `.yaml` files, so `.yml` files are intentionally not deployed by this app.

The installed local app does not update its own app source. If files under `sync/` change, copy this directory into `/addons` again and rebuild/update the local app.
