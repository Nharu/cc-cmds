#!/usr/bin/env bash
# lint-sidecar-field-table: self-skip
# Test scripts/lint-sidecar-field-table.sh against
# tests/fixtures/lint-sidecar-field-table/.
#
# Each fixture is a pair of roots — `orchestrator/` (a gate.sh holding the
# `gate_append` call sites) and `skills/` (the contract holding the field
# table). The directory name encodes the expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1
#
# The two directions of the comparison are two fixtures: `FAIL-1` is a call
# site writing a field the table does not list, `FAIL-2` is the table listing a
# field no literal call site writes. `OK-2` is the pass-through guard — a
# series whose call site forwards `"$@"` may legitimately carry fields the
# literal keys do not show, so only the subset direction is enforced there.
# `OK-1` carries a multi-line call site, because a lint that read one physical
# line would see half the fields and pass on the half it saw.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-sidecar-field-table"

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
      echo "test-lint-sidecar-field-table: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  ORCH_ROOT="$fixture/orchestrator" SKILLS_ROOT="$fixture/skills" \
    bash "$script_dir/lint-sidecar-field-table.sh" >/dev/null 2>&1
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

echo "test-lint-sidecar-field-table: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
