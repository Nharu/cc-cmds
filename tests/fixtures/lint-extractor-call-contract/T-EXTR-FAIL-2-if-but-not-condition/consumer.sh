#!/usr/bin/env bash
# The substitution sits inside an `if` but is not what the `if` tests.
set -euo pipefail
source "$(dirname "$0")/../../../../scripts/_extract-between.sh"
fail=0
if true; then region=$(extract_between "^## A" "^## B" "$f" "label"); fi
assert_in_text "x" "$region" "label" "the region"
exit "$fail"
