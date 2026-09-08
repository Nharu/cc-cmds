#!/usr/bin/env bash
# ci-deps: none
# ci-subject: pkg/mod/**
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cat "$root/pkg/mod/a.md" "$root/pkg/mod/b.md" > /dev/null
echo "suite-a.sh: ok"
