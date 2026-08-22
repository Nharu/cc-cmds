#!/usr/bin/env bash
# A bare assignment: under `set -euo pipefail` this aborts the script at the
# assignment and every later diagnostic is lost.
set -euo pipefail
source "$(dirname "$0")/../../../../scripts/_extract-between.sh"
fail=0
region=$(extract_between '^## A' '^## B' "$f" 'label')
assert_in_text 'x' "$region" 'label' 'the region'
exit "$fail"
