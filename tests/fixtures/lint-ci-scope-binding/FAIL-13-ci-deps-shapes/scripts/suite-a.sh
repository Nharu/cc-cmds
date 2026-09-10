#!/usr/bin/env bash
# A directory declaration whose tree holds no tracked file: the declaration is
# dead, and saying so is the only way a stale path shows up as an edit.
# ci-deps: emptydir/**
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
:
echo "suite-a.sh: ok"
