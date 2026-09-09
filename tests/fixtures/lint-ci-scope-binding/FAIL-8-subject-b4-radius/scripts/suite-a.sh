#!/usr/bin/env bash
# ci-deps: pkg/wide/f01.md pkg/wide/f02.md
# ci-subject: pkg/wide/**
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cat "$root/pkg/wide/f01.md" "$root/pkg/wide/f02.md" > /dev/null
echo "suite-a.sh: ok"
