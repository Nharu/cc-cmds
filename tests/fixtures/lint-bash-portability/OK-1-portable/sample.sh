#!/usr/bin/env bash
# Fixture: portable shell idioms only — lint should report no violations.
set -euo pipefail

now=$(date -u +%s)
echo "epoch=$now"

# Standard utilities resolved from /usr/bin work the same on BSD and GNU.
grep -E '^foo' /dev/null || true
sed -e 's/x/y/' /dev/null
find . -name '*.txt' -maxdepth 1 >/dev/null 2>&1 || true
