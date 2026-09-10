#!/usr/bin/env bash
# ci-deps: pkg/mod/a.md pkg/mod/b.md
# ci-subject: pkg/mod/**
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cat "$root/pkg/mod/a.md" "$root/pkg/mod/b.md" > /dev/null
echo "suite-a.sh: ok"
