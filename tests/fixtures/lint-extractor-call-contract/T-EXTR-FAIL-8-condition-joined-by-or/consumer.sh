#!/usr/bin/env bash
# The substitution is joined to the condition by `|| true`, so the condition
# holds even when the extraction failed. The guard predicate stopped at the
# first `=` and never saw it.
set -euo pipefail
source "$(dirname "$0")/../../../../scripts/_extract-between.sh"
fail=0
if region=$(extract_between "^## A" "^## B" "$f" "label") || true; then :
else fail=1; region="$REGION_UNAVAILABLE"
fi
exit "$fail"
