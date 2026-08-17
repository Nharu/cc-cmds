#!/usr/bin/env bash
# Quotes around the substitution. Identical to the shell, invisible to a matcher
# that anchors on `=$(`.
set -euo pipefail
source "$(dirname "$0")/../../../../scripts/_extract-between.sh"
fail=0
region="$(extract_between "^## A" "^## B" "$f" "label")"
assert_in_text "x" "$region" "label" "the region"
exit "$fail"
