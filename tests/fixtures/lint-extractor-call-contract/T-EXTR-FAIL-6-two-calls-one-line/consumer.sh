#!/usr/bin/env bash
# Two calls on ONE line, the second unguarded. The same two calls on two lines
# were caught; on one line the enumerator emitted a single record and every
# classifier was anchored at the line start, so the second call was neither
# counted nor checked and `0 unrecognized` was an active false claim.
set -euo pipefail
source "$(dirname "$0")/../../../../scripts/_extract-between.sh"
fail=0
if a=$(extract_between "^## A" "^## B" "$f" "label"); then :; else fail=1; a="$REGION_UNAVAILABLE"; fi; b=$(extract_between "^## C" "^## D" "$f" "label")
exit "$fail"
