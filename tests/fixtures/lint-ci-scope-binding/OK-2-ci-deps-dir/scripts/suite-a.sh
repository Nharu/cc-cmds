#!/usr/bin/env bash
# ci-deps: lib/**
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/lib/helper.sh"
. "$root/lib/other.sh"
echo "suite-a.sh: ok"
