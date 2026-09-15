#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test scripts/lint-gate-banner-fields.sh against the banner files beside this
# runner.
#
# Each fixture is a stand-in for scripts/test-gate.sh holding only banner lines,
# handed to the lint through GATE_BANNER_FIELDS_TARGET. The file name encodes the
# expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1, and the lint must name a line of the fixture
#   ERR-*  → expected exit 2 (the check could not be carried out)
#
# A missing target is asserted on its own below, since it has no file to carry
# its name.
#
# The runner lives in the fixture directory rather than as
# scripts/test-lint-gate-banner-fields.sh; it is registered in the Makefile's
# LINT_TESTS all the same.

set -uo pipefail

fixtures=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$fixtures/../../.." && pwd)
lint="$repo_root/scripts/lint-gate-banner-fields.sh"

if [[ ! -f "$lint" ]]; then
  echo "FAIL: lint script missing: $lint" >&2
  exit 2
fi

passed=0
failures=0
seen=0

for fixture in "$fixtures"/*.txt; do
  [[ -f "$fixture" ]] || continue
  seen=$((seen + 1))
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    OK-*)   want=0 ;;
    FAIL-*) want=1 ;;
    ERR-*)  want=2 ;;
    *)
      echo "test-lint-gate-banner-fields: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  err=$(GATE_BANNER_FIELDS_TARGET="$fixture" bash "$lint" 2>&1 >/dev/null)
  ec=$?

  if [[ "$ec" != "$want" ]]; then
    failures=$((failures + 1))
    echo "FAIL: $fixture_name (exit=$ec, expected=$want) — $err" >&2
    continue
  fi
  # A FAIL fixture must be refused for a reason located in the file, not merely
  # with the right code — a lint that exits 1 on every input passes the exit
  # check alone.
  if [[ "$want" == "1" ]]; then
    case "$err" in
      *"FAIL: $fixture_name:"[0-9]*) ;;
      *)
        failures=$((failures + 1))
        echo "FAIL: $fixture_name (exit=1 but no '<file>:<line>:' diagnostic) — $err" >&2
        continue
        ;;
    esac
  fi
  passed=$((passed + 1))
  echo "PASS: $fixture_name (exit=$ec, expected=$want)"
done

# An empty directory would make every loop above run zero times and report 0/0.
if [[ "$seen" -lt 3 ]]; then
  echo "FAIL: fixtures found: $seen — the directory lost its cases" >&2
  failures=$((failures + 1))
fi

GATE_BANNER_FIELDS_TARGET="$fixtures/does-not-exist.txt" bash "$lint" >/dev/null 2>&1
ec=$?
if [[ "$ec" == "2" ]]; then
  passed=$((passed + 1))
  echo "PASS: missing target (exit=2, expected=2)"
else
  failures=$((failures + 1))
  echo "FAIL: missing target (exit=$ec, expected=2)" >&2
fi

echo "test-lint-gate-banner-fields: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
