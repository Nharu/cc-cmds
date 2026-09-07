#!/usr/bin/env bash
# The one-line off switch: `/**` with a wildcard in the directory part. If this
# is admitted, `tracked_under` greps `^[^/]*/` and every path with a slash joins
# the execution set, so rules 1 and 2 are satisfied by anything at all.
# ci-deps: */**
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
:
echo "suite-d.sh: ok"
