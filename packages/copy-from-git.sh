#!/usr/bin/env bash
set -euo pipefail

curl -fsSL https://github.com/sargant/homeassistant-bits/archive/refs/heads/main.tar.gz \
  | ssh root@assistant \
      'tar -xzf - -C /config/packages --strip-components=2 homeassistant-bits-main/packages'
