#!/usr/bin/env bash
# A wildcard that is not the `<디렉터리>/**` form: a file or that one form.
# ci-deps: lib/*.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
:
echo "suite-c.sh: ok"
