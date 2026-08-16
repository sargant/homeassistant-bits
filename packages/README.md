# Packages

Add this to `configuration.yaml`:

```yaml
homeassistant:
  packages: !include_dir_named packages
```

## Manual deployment

From a checkout of this repository:

```bash
bash packages/copy-from-git.sh
```

The script copies the tracked contents of `packages/` from the current Git commit to `root@assistant:/config/packages/`. Existing files with the same names are overwritten; other files already in `/config/packages/` are left alone.

It deliberately does not validate, reload, restart, or otherwise manage Home Assistant. Verify the configuration and reload it manually.
