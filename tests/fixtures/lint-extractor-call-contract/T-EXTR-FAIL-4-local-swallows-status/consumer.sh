#!/usr/bin/env bash
# `local` supplies the assignment exit status, so the failure is swallowed
# rather than aborting — a different mechanism from the bare form, and the
# diagnostic has to say which one it is.
set -euo pipefail
source "$(dirname "$0")/../../../../scripts/_extract-between.sh"
fail=0
read_region() {
  local region
  local region=$(extract_between "^## A" "^## B" "$1" "label")
  assert_in_text "x" "$region" "label" "the region"
}
exit "$fail"
