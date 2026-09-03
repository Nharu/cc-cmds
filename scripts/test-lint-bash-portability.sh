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
#
# Hit assertions. A fixture may also ship an `expected-hits.txt` listing the
# exact violations it should produce, one per line as
#
#   <file basename>:<line number>:<idiom id>
#
# in any order. When that file is present the reported violations must match it
# as a set. The exit code alone cannot see a violation reported against the
# wrong line, and line numbers are precisely what a change to how the lint walks
# a file can shift — a candidate line carrying its number from a separate pass
# has to agree with what a straight line-by-line read would have counted,
# including on a final line with no terminating newline. `expected-hits.txt` is
# not scanned by the lint itself, which only picks up `*.sh`.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-bash-portability"

if [[ ! -d "$fixtures" ]]; then
  echo "FAIL: fixtures root missing: $fixtures" >&2
  exit 2
fi

stderr_capture=$(mktemp "${TMPDIR:-/tmp}/test-lint-bash-portability.XXXXXX")
trap 'rm -f "$stderr_capture"' EXIT

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
  SCAN_ROOT="$fixture" bash "$script_dir/lint-bash-portability.sh" \
    >/dev/null 2>"$stderr_capture"
  ec=$?
  set -e

  fixture_ok=1

  if [[ "$ec" != "$want" ]]; then
    fixture_ok=0
    echo "FAIL: $fixture_name (exit=$ec, expected=$want)" >&2
  fi

  expected_hits="$fixture/expected-hits.txt"
  if [[ -f "$expected_hits" ]]; then
    # Reduce each violation report to `<basename>:<line>:<idiom id>`. The idiom
    # id is captured greedily so an id that itself contains quotes — `sed -i ''`
    # is one — still stops at the closing quote before ` detected in`.
    actual_hits=$(
      sed -n \
        "s|^FAIL: BSD/GNU divergent idiom '\(.*\)' detected in .*/\([^/:]*\):\([0-9][0-9]*\)$|\2:\3:\1|p" \
        "$stderr_capture" | sort
    )
    want_hits=$(sort "$expected_hits")
    if [[ "$actual_hits" != "$want_hits" ]]; then
      fixture_ok=0
      echo "FAIL: $fixture_name (hits differ from expected-hits.txt)" >&2
      echo "  expected:" >&2
      printf '%s\n' "$want_hits" | sed 's/^/    /' >&2
      echo "  actual:" >&2
      printf '%s\n' "$actual_hits" | sed 's/^/    /' >&2
    fi
  fi

  if (( fixture_ok == 1 )); then
    passed=$((passed + 1))
    echo "PASS: $fixture_name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
  fi
done

echo "test-lint-bash-portability: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
