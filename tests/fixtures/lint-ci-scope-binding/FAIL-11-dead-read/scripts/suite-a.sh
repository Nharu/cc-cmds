#!/usr/bin/env bash
# ci-deps: none
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
if [ -f "$root/docs/absent-doc.md" ]; then
  cat "$root/docs/absent-doc.md"
fi
echo "suite-a.sh: ok"
