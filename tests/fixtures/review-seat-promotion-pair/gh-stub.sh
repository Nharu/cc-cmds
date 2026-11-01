#!/usr/bin/env bash
# GitHub CLI stub for scripts/test-review-seat-promotion-pair.sh.
#
# Every call appends its arguments, joined by spaces, as one line to
# $STUB_DIR/gh-calls. `pr view <N> --repo <slug> --json title,body,labels`
# prints $GH_STUB_DIR/<N>.json when that file exists and exits 1 otherwise;
# any other call exits 1.
set -euo pipefail

d="${STUB_DIR:?}"
mkdir -p "$d"
printf '%s\n' "$*" >> "$d/gh-calls"

if [ $# -eq 7 ] && [ "$1" = "pr" ] && [ "$2" = "view" ] && [ "$4" = "--repo" ] && [ "$6" = "--json" ] && [ "$7" = "title,body,labels" ]; then
  f="${GH_STUB_DIR:?}/$3.json"
  if [ -f "$f" ]; then cat "$f"; exit 0; fi
  echo "GraphQL: Could not resolve to a PullRequest with the number of $3." >&2
fi
exit 1
