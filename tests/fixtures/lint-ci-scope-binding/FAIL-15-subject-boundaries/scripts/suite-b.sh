#!/usr/bin/env bash
# The directory part carries a wildcard, so the breadth of the claim is not a
# quantity anyone can read off the declaration.
# ci-deps: none
# ci-subject: pkg*/mod/**
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
:
echo "suite-b.sh: ok"
