#!/usr/bin/env bash
# A subject tree must be written in the `<디렉터리>/**` form; a bare directory
# does not say whether it recurses.
# ci-deps: none
# ci-subject: pkg/mod
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
:
echo "suite-a.sh: ok"
