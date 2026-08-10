#!/usr/bin/env bash
# Test scripts/lint-active-notify-drift.sh against
# tests/fixtures/lint-active-notify-drift/.
#
# Each fixture is a SKILLS_ROOT-shaped directory holding the two surfaces the
# lint pairs: `active-notify/SKILL.md` (owner) and `_common/notify.md` (shared).
# Convention: fixture directory name encodes the expected exit code.
#   T-ANDRIFT-OK-*   → expected exit 0
#   T-ANDRIFT-FAIL-* → expected exit 1
#
# T-ANDRIFT-FAIL-2 is the load-bearing one: every section number it cites
# exists as a heading, so an existence-only citation check reports zero
# findings on it. If that fixture ever starts passing, rule (B) has been
# weakened back to an existence check and the drift this lint was written for
# is undetectable again.
#
# Fixtures added after the first four carry a descriptive suffix after the
# index (`T-ANDRIFT-FAIL-9-banned-wrapped`), the majority convention elsewhere
# under `tests/fixtures/`. The original four stay un-suffixed on purpose —
# renaming them would churn history for no functional gain — and the `case`
# below accepts both shapes.
#
# Exit-code 2 (no scannable files) is not covered by a fixture, but the reason
# is no longer "every fixture ships both surfaces": `T-ANDRIFT-FAIL-12-shared-
# file-missing` deliberately omits the shared file. That fixture pins the
# precedence — a declared-but-absent shared file is a violation (exit 1), and
# reporting it as an empty collection instead would hide the finding behind
# exit 2.
#
# Each fixture's discriminating power is measured rather than assumed, and the
# measurement ships with it: `MUTATIONS.md` beside the fixtures states the rules
# a row must satisfy, and every row lives under
# `tests/fixtures/lint-active-notify-drift-mutations/` as an anchored literal
# replacement with the set of fixtures it is expected to redden.
# `scripts/test-lint-active-notify-drift-mutations.sh` applies them one at a
# time against the whole set and requires each observed set to equal its
# declared one.
#
# Re-derive the figures with that harness rather than reading them here. What
# does not change with the next fixture addition is the shape of the claim: a
# clean run says every LISTED mutation is killed. It does not say any fixture is
# unpinned, and it does not say any property lacks coverage — those depend on
# the list's scope, which is not in the list. Fixtures that kill nothing
# uniquely are kept rather than removed: they are the plain base case of their
# rule, the shape a reader looks for first.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-active-notify-drift"

failures=0
passed=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-ANDRIFT-OK-*)   want=0 ;;
    T-ANDRIFT-FAIL-*) want=1 ;;
    *)
      echo "test-lint-active-notify-drift: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  SKILLS_ROOT="$fixture" bash "$script_dir/lint-active-notify-drift.sh" >/dev/null 2>&1
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

echo "test-lint-active-notify-drift: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
