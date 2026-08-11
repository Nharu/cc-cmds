#!/usr/bin/env bash
# The canonical form, copied from the helper's own example.
set -euo pipefail
source "$(dirname "$0")/_extract-between.sh"
fail=0
if region=$(extract_between '^## A' '^## B' "$f" 'label'); then :
else fail=1; region="$REGION_UNAVAILABLE"
fi
assert_in_text 'x' "$region" 'label' 'the region'
exit "$fail"
