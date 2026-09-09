#!/usr/bin/env bash
# ci-deps: pkg/sub/mod/a.md pkg/sub/mod/b.md
# ci-subject: pkg/sub/**
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cat "$root/pkg/sub/mod/a.md" "$root/pkg/sub/mod/b.md" > /dev/null
echo "suite-a.sh: ok"
