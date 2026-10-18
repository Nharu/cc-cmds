#!/usr/bin/env bash
# Fixture: `getconf` asked for a name other than ARG_MAX returns the same kind
# of value on both hosts, so the ARG_MAX rule has to stay silent about it.
set -euo pipefail

cache=$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null || true)
echo "${cache:-none}"
