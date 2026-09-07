#!/usr/bin/env bash
# A file declaration that resolves to no tracked file.
# ci-deps: lib/missing.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
:
echo "suite-e.sh: ok"
