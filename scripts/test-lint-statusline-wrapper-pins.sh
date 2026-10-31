#!/usr/bin/env bash
# Test scripts/lint-statusline-wrapper-pins.sh against
# tests/fixtures/lint-statusline-wrapper-pins/.
#
# Each fixture is a whole miniature root — the shared grammar file, the suite
# that is licensed to hand-write a copy of it, and a README — so the lint can be
# driven over a complete disagreement without touching the real tree. The
# directory name encodes the expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1
#
# THE FAIL ROOTS ARE WHY THIS FILE EXISTS. A lint that degenerated into `exit 0`
# — a renamed variable, a `grep` that stopped matching, a check quietly removed —
# passes every OK root there is. One FAIL root per check is the only shape that
# says each of the five is still doing something.
#
# `FAIL-3-third-copy` is the one worth naming: it is a third file writing the
# wrapper grammar out by hand instead of sourcing it, which is how two processes
# end up with two recognisers that disagree — the hook says "proceed" and the
# installer parks, on every startup, with nothing written anywhere to say so.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-statusline-wrapper-pins"

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
      echo "test-lint-statusline-wrapper-pins: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  STATUSLINE_PINS_ROOT="${fixture%/}" \
    bash "$script_dir/lint-statusline-wrapper-pins.sh" >/dev/null 2>&1
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

echo "test-lint-statusline-wrapper-pins: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
