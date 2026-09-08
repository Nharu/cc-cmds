#!/usr/bin/env bash
# A trailing slash alone does not say whether the declaration recurses.
# ci-deps: lib/
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
:
echo "suite-b.sh: ok"
