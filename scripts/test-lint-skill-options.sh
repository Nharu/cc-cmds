#!/usr/bin/env bash
# Test scripts/lint-skill-options.sh against tests/fixtures/options-lint/.
#
# Convention: each fixture filename ends with `-pass`, `-warn`, or `-fail`.
#   pass / warn → expected exit 0
#   fail        → expected exit 1
#
# Also verifies the kislyuk-yq detection path via tests/fixtures/fake-yq/.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/options-lint"
fake_yq_dir="$repo_root/tests/fixtures/fake-yq"

failures=0
passed=0

for fixture in "$fixtures"/*.md; do
  base=$(basename "$fixture" .md)
  suffix="${base##*-}"
  case "$suffix" in
    pass|warn) want=0 ;;
    fail)      want=1 ;;
    *)
      echo "test-lint-skill-options: fixture '$base' has unrecognized suffix '$suffix'" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  bash "$script_dir/lint-skill-options.sh" "$fixture" >/dev/null 2>&1
  ec=$?
  set -e

  if [[ "$ec" == "$want" ]]; then
    passed=$((passed + 1))
    echo "PASS: $base (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
    echo "FAIL: $base (exit=$ec, expected=$want)" >&2
  fi
done

# kislyuk/yq detection: prefix PATH with the fake-yq directory and run lint.
# It must exit 1 with the design-spec error string.
fake_output=$(PATH="$fake_yq_dir:$PATH" bash "$script_dir/lint-skill-options.sh" "$fixtures/rule3-valid-pass.md" 2>&1 || true)
fake_exit=$(PATH="$fake_yq_dir:$PATH" bash -c "bash '$script_dir/lint-skill-options.sh' '$fixtures/rule3-valid-pass.md' >/dev/null 2>&1; echo \$?")

if [[ "$fake_exit" == "1" ]] && [[ "$fake_output" == *"mikefarah/yq not found"* ]] && [[ "$fake_output" == *"kislyuk/yq"* ]]; then
  passed=$((passed + 1))
  echo "PASS: kislyuk-yq detection (exit=1, error string matches)"
else
  failures=$((failures + 1))
  echo "FAIL: kislyuk-yq detection (exit=$fake_exit)" >&2
  echo "----- output -----" >&2
  echo "$fake_output" >&2
  echo "------------------" >&2
fi

echo "test-lint-skill-options: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
