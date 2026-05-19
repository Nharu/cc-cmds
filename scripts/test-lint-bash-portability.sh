#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test scripts/lint-bash-portability.sh against tests/fixtures/lint-bash-portability/.
#
# Each fixture is a directory containing one or more `*.sh` files. The fixture
# directory name encodes the expected exit code:
#   OK-*   → expected exit 0 (lint passes — clean / escape-suppressed / self-skip)
#   FAIL-* → expected exit 1 (lint detects at least one violation)
#
# Exit-code 2 (no scannable files) is not covered — every fixture ships at
# least one `*.sh` file, so the empty branch is tested by prevention.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-bash-portability"

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
      echo "test-lint-bash-portability: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  SCAN_ROOT="$fixture" bash "$script_dir/lint-bash-portability.sh" >/dev/null 2>&1
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

echo "test-lint-bash-portability: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
