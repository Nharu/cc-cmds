#!/usr/bin/env bash
# Fixture personal-rules extractor: `extract --source <file> --out-dir <dir>`
# writes the block as <dir>/<sha256>.md and names it in <dir>/current.
set -euo pipefail
src="" out=""
[ "${1:-}" = "extract" ] || exit 2
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --source) src="$2"; shift 2 ;;
    --out-dir) out="$2"; shift 2 ;;
    *) exit 2 ;;
  esac
done
[ -f "$src" ] || exit 1
mkdir -p "$out"
grep -E '^- ' "$src" > "$out/.block"
sha=$(shasum -a 256 "$out/.block" | cut -d' ' -f1)
mv "$out/.block" "$out/$sha.md"
printf '%s fixture\n' "$sha" > "$out/current"
