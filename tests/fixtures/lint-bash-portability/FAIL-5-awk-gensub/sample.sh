#!/usr/bin/env bash
# Fixture: GNU awk `gensub(` extension should be detected as a
# literal-substring pattern.
set -euo pipefail

awk 'gensub(/foo/, "bar", "g")' /dev/null || true
