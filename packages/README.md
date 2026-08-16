# Packages

Add this to `configuration.yaml`:

```yaml
homeassistant:
  packages: !include_dir_named packages
```

A small `copy-from-github.sh` convenience script is included for copying the latest `packages/` contents from GitHub to Home Assistant.
