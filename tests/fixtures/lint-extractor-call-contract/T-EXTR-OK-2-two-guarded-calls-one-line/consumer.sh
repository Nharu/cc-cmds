#!/usr/bin/env bash
# Two calls on ONE line, both guarded, each by its own `if`. The occurrence-wise
# classifier must count BOTH and call both guarded — a fix that only made the
# second visible as a failure would be wrong about the count, and one that
# refused the second because an `if` had already closed on that line would be
# wrong about the verdict. An earlier draft of this fixture claimed one line and
# used two, which is the shape where a case passes its own coverage test while
# testing something else.
set -euo pipefail
source "$(dirname "$0")/../../../../scripts/_extract-between.sh"
fail=0
if a=$(extract_between "^## A" "^## B" "$f" "label"); then :; else fail=1; a="$REGION_UNAVAILABLE"; fi; if b=$(extract_between "^## C" "^## D" "$f" "label"); then :; else fail=1; b="$REGION_UNAVAILABLE"; fi
exit "$fail"
