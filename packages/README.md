# Packages

Add this to `configuration.yaml`:

```yaml
homeassistant:
  packages: !include_dir_named packages
```

## Manual deployment

Run `copy-from-github.sh` from any machine that can SSH to Home Assistant:

```bash
bash copy-from-github.sh
```

No local Git checkout is used. The script downloads the current `main` branch archive directly from GitHub and streams the contents of its `packages/` directory to `root@assistant:/config/packages/`.

Existing files with the same names are overwritten. Files that exist only in `/config/packages/` are left alone.

It deliberately does not validate, reload, restart, roll back, or otherwise manage Home Assistant. Verify the configuration and reload it manually.
