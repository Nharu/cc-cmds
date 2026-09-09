#!/usr/bin/env bash
# One probe-visible read under the claimed tree. One read is a file, so it is
# declared as a file and the tree claim is refused.
# ci-deps: pkg/mod/a.md
# ci-subject: pkg/mod/**
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cat "$root/pkg/mod/a.md" > /dev/null
echo "suite-c.sh: ok"
