#!/usr/bin/env bash
# The substitution IS in the `if` condition position, and that is not enough:
# the declaration builtin supplies the assignment exit status, so a failing
# extraction takes the THEN branch with the region variable empty.
set -euo pipefail
source "$(dirname "$0")/../../../../scripts/_extract-between.sh"
fail=0
if local region=$(extract_between "^## A" "^## B" "$f" "label"); then :
else fail=1; region="$REGION_UNAVAILABLE"
fi
exit "$fail"
