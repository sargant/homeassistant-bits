#!/usr/bin/env bash
set -euo pipefail

archive="https://github.com/sargant/homeassistant-bits/archive/refs/heads/main.tar.gz"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

curl -fsSL "$archive" -o "$tmp"

# This detector moved from a package to a custom integration. Remove the old
# package explicitly because extracting the archive does not delete stale files.
rm -f /config/packages/dishwasher_indesit_d2ihl326uk.yaml

tar -xzf "$tmp" -C /config/packages --strip-components=2 \
  homeassistant-bits-main/packages

mkdir -p /config/custom_components
tar -xzf "$tmp" -C /config/custom_components --strip-components=2 \
  homeassistant-bits-main/custom_components
