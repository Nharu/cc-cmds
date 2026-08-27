#!/usr/bin/env bash
# Test scripts/lint-judgment-grade.sh against tests/fixtures/lint-judgment-grade/.
#
# Each fixture is a miniature skills root — one attended skill and its unattended
# counterpart — so the three rules can be exercised without touching the real
# tree. The directory name encodes the expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1
#
# `OK-2-exempt-prose` is the fixture that earns its keep. The narrow ask-call
# detector matches a line by "mentions the tool AND carries an option list", and
# the sentences that DEFINE that convention match both halves. Without the
# exemption list the lint would demand a grade token on the prose explaining
# what grade tokens are.
#
# `FAIL-1-unmarked-ask` is its mirror: an ask point with an option list and no
# token must fail, or the exemption list would be free to swallow everything.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-judgment-grade"

if [[ ! -d "$fixtures" ]]; then
  echo "FAIL: fixtures root missing: $fixtures" >&2
  exit 2
fi

passed=0
failures=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    OK-*)   want=0 ;;
    FAIL-*) want=1 ;;
    *)
      echo "test-lint-judgment-grade: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  SKILLS_ROOT="$fixture" bash "$script_dir/lint-judgment-grade.sh" >/dev/null 2>&1
  ec=$?
  set -e

  if [[ "$ec" == "$want" ]]; then
    passed=$((passed + 1))
    echo "PASS: $fixture_name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
    echo "FAIL: $fixture_name (exit=$ec, expected=$want)" >&2
  fi
done

echo "test-lint-judgment-grade: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
