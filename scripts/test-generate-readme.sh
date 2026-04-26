#!/usr/bin/env bash
# Test scripts/generate-readme.sh against simple/complex render fixtures plus
# fallback-insertion and slug-collision cases.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
gen="$script_dir/generate-readme.sh"
gold_dir="$repo_root/tests/fixtures/readme-gen/golden"
template="$repo_root/tests/fixtures/readme-gen/simple-readme-template.md"

failures=0
passed=0

run_case() {
  local name="$1" skills_dir="$2" golden="$3"
  local tmp
  tmp=$(mktemp)
  cp "$template" "$tmp"
  SKILLS_DIR="$skills_dir" README_PATH="$tmp" bash "$gen" >/dev/null

  if diff -u "$golden" "$tmp" >/dev/null; then
    passed=$((passed + 1))
    echo "PASS: $name (golden match)"
  else
    failures=$((failures + 1))
    echo "FAIL: $name (golden diff)" >&2
    diff -u "$golden" "$tmp" >&2 || true
  fi

  # Idempotency: second run produces no changes.
  local before
  before=$(shasum < "$tmp")
  SKILLS_DIR="$skills_dir" README_PATH="$tmp" bash "$gen" >/dev/null
  local after
  after=$(shasum < "$tmp")
  if [[ "$before" == "$after" ]]; then
    passed=$((passed + 1))
    echo "PASS: $name (idempotent)"
  else
    failures=$((failures + 1))
    echo "FAIL: $name (not idempotent)" >&2
  fi

  rm -f "$tmp"
}

run_case "simple"  "$repo_root/tests/fixtures/readme-gen/simple"  "$gold_dir/simple.md"
run_case "complex" "$repo_root/tests/fixtures/readme-gen/complex" "$gold_dir/complex.md"

# Fallback: README without markers gets `## Options` H2 + markers inserted before `## License`.
fallback_input=$(mktemp)
cat > "$fallback_input" <<'EOF'
# Test

## Commands

## License

MIT
EOF
SKILLS_DIR="$repo_root/tests/fixtures/readme-gen/simple" README_PATH="$fallback_input" bash "$gen" >/dev/null

opt_end_line=$(grep -n '<!-- SKILLS_OPTIONS_END -->' "$fallback_input" | head -1 | cut -d: -f1)
license_line=$(grep -n '^## License' "$fallback_input" | head -1 | cut -d: -f1)

if grep -q '<!-- SKILLS_TABLE_START -->' "$fallback_input" \
   && grep -q '<!-- SKILLS_OPTIONS_START -->' "$fallback_input" \
   && grep -q '^## Options' "$fallback_input" \
   && [[ -n "$opt_end_line" && -n "$license_line" && "$opt_end_line" -lt "$license_line" ]]; then
  passed=$((passed + 1))
  echo "PASS: fallback insertion (markers + ## Options inserted before ## License)"
else
  failures=$((failures + 1))
  echo "FAIL: fallback insertion" >&2
  cat "$fallback_input" >&2
fi

# Idempotency on fallback case
sha_before=$(shasum < "$fallback_input")
SKILLS_DIR="$repo_root/tests/fixtures/readme-gen/simple" README_PATH="$fallback_input" bash "$gen" >/dev/null
sha_after=$(shasum < "$fallback_input")
if [[ "$sha_before" == "$sha_after" ]]; then
  passed=$((passed + 1))
  echo "PASS: fallback idempotent"
else
  failures=$((failures + 1))
  echo "FAIL: fallback not idempotent" >&2
fi
rm -f "$fallback_input"

# Slug collision: README contains an existing `### /cc-cmds:zeroargs` heading
# in body content (outside the marker block). The Options block should still
# render correctly (and a future enhancement would assign `-1` suffix; current
# implementation only de-dupes within the generated ToC, which is sufficient
# for the present skill set). Verify the renderer doesn't crash and the
# generated ToC link is well-formed.
collision_input=$(mktemp)
cat > "$collision_input" <<'EOF'
# Test

## Commands

<!-- SKILLS_TABLE_START -->
<!-- SKILLS_TABLE_END -->

## Notes

### /cc-cmds:zeroargs

This is a stray heading.

## Options

<!-- SKILLS_OPTIONS_START -->
<!-- SKILLS_OPTIONS_END -->

## License

MIT
EOF
SKILLS_DIR="$repo_root/tests/fixtures/readme-gen/simple" README_PATH="$collision_input" bash "$gen" >/dev/null

if grep -q '\[/cc-cmds:zeroargs\](#cc-cmdszeroargs)' "$collision_input"; then
  passed=$((passed + 1))
  echo "PASS: slug rendering survives external collision (renderer doesn't crash)"
else
  failures=$((failures + 1))
  echo "FAIL: slug rendering on collision input" >&2
fi
rm -f "$collision_input"

echo "test-generate-readme: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
