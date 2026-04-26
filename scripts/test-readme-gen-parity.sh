#!/usr/bin/env bash
# Verify that the new yq-based generate-readme.sh produces a SKILLS_TABLE block
# byte-identical to the pre-yq snapshot when fed the same SKILL.md inputs.
# This guards the awk → yq parser swap from regressions on description /
# when_to_use values containing quotes, colons, parentheses, and Korean text.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
gen="$script_dir/generate-readme.sh"
fixt="$repo_root/tests/fixtures/readme-gen"
snapshot="$fixt/pre-yq-snapshot.md"
pre_skills="$fixt/pre-yq-skills"

if [[ ! -f "$snapshot" ]]; then
  echo "test-readme-gen-parity: snapshot $snapshot missing" >&2
  exit 1
fi
if [[ ! -d "$pre_skills" ]]; then
  echo "test-readme-gen-parity: pre-yq skills dir $pre_skills missing" >&2
  exit 1
fi

# Render against the fixed pre-yq skill inputs into a temp copy of the snapshot.
tmp=$(mktemp)
cp "$snapshot" "$tmp"

SKILLS_DIR="$pre_skills" README_PATH="$tmp" bash "$gen" >/dev/null

# Extract the SKILLS_TABLE block from both snapshot and rendered file. Parity is
# scoped to that block — the snapshot was taken before SKILLS_OPTIONS existed.
extract_table() {
  awk '
    /<!-- SKILLS_TABLE_START -->/ { in_block=1 }
    in_block { print }
    /<!-- SKILLS_TABLE_END -->/   { in_block=0 }
  ' "$1"
}

snapshot_table=$(extract_table "$snapshot")
rendered_table=$(extract_table "$tmp")

if [[ "$snapshot_table" == "$rendered_table" ]]; then
  echo "PASS: SKILLS_TABLE parity (yq output matches pre-yq snapshot)"
  rm -f "$tmp"
  exit 0
else
  echo "FAIL: SKILLS_TABLE parity diff" >&2
  diff -u <(printf '%s\n' "$snapshot_table") <(printf '%s\n' "$rendered_table") >&2 || true
  rm -f "$tmp"
  exit 1
fi
