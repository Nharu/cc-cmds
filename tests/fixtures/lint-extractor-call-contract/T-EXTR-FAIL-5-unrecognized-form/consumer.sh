#!/usr/bin/env bash
# Not an assignment at all: the result is piped. Neither guarded nor unguarded by
# this contract, so it must be reported rather than passed over.
set -euo pipefail
source "$(dirname "$0")/../../../../scripts/_extract-between.sh"
fail=0
extract_between "^## A" "^## B" "$f" "label" | grep -q x
exit "$fail"
