#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
git archive HEAD packages | ssh root@assistant 'tar -x -C /config'
