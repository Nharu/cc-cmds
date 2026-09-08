#!/usr/bin/env bash
# ci-deps: none
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/lib/helper.sh"
echo "suite-a.sh: ok"
