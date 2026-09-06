#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test scripts/lint-notify-fire-sites.sh against
# tests/fixtures/lint-notify-fire-sites/.
#
# Each fixture is a miniature orchestrator directory the lint can be pointed at
# with `ORCH_ROOT`. The directory name encodes the expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1
#
# `FAIL-clear-outside-emitter` is the fixture the whole lint exists for: a second
# caller launching the notifier from outside the emitter — here to REMOVE a
# banner, which is the one act that changes what is on a person's screen and the
# one the seat guard is a genuine precondition for. Without this fixture the lint
# could be gutted to a constant and the suite would not notice.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-notify-fire-sites"

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
      echo "test-lint-notify-fire-sites: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  ORCH_ROOT="$fixture/orchestrator" \
    bash "$script_dir/lint-notify-fire-sites.sh" >/dev/null 2>&1
  ec=$?

  if [[ "$ec" == "$want" ]]; then
    passed=$((passed + 1))
    echo "PASS: $fixture_name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
    echo "FAIL: $fixture_name (exit=$ec, expected=$want)" >&2
  fi
done

echo "test-lint-notify-fire-sites: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
