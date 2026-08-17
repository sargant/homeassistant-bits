# Packages

Add this to `configuration.yaml`:

```yaml
homeassistant:
  packages: !include_dir_named packages
```

`copy-from-github.sh` is a convenience script for the Home Assistant host. It
copies both the latest `packages/` contents and any `custom_components/` from
this repository into `/config`.
