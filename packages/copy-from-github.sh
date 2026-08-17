#!/usr/bin/env bash
set -euo pipefail

archive="https://github.com/sargant/homeassistant-bits/archive/refs/heads/main.tar.gz"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

curl -fsSL "$archive" -o "$tmp"

tar -xzf "$tmp" -C /config/packages --strip-components=2 \
  homeassistant-bits-main/packages

mkdir -p /config/custom_components
tar -xzf "$tmp" -C /config/custom_components --strip-components=2 \
  homeassistant-bits-main/custom_components
