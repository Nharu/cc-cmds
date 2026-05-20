#!/usr/bin/env bash
# Fixture: BSD-only `sed -i ''` single-quoted backup-extension should be
# detected as a literal-substring pattern.
set -euo pipefail

tmpfile=$(mktemp)
echo "x" > "$tmpfile"
sed -i '' 's/x/y/' "$tmpfile"
rm -f "$tmpfile"
