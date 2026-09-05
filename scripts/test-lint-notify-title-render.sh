#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test scripts/lint-notify-title-render.sh against
# tests/fixtures/lint-notify-title-render/.
#
# Each fixture is a small tree of shell files the lint can be pointed at with
# `ROOT`, so a whole verdict can be driven without touching the real source. The
# directory name encodes the expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1
#
# The four that earn their keep are the four corners of the rule:
#   FAIL-title-swallowed — a title literal opening with a bracket, the defect
#                          that erased every title this tree ever raised
#   FAIL-body-swallowed  — the same defect on the body side, which was only ever
#                          half-guarded
#   OK-closing-bracket   — a closing bracket passes; a lint that banned all
#                          punctuation would be refusing correct text
#   OK-variable-argument — an argument opening with a variable is not judged,
#                          because its value is not in the source

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-notify-title-render"

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
      echo "test-lint-notify-title-render: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  ROOT="$fixture" EMITTER="$fixture/notify-run.sh" \
    bash "$script_dir/lint-notify-title-render.sh" >/dev/null 2>&1
  ec=$?

  if [[ "$ec" == "$want" ]]; then
    passed=$((passed + 1))
    echo "PASS: $fixture_name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
    echo "FAIL: $fixture_name (exit=$ec, expected=$want)" >&2
  fi
done

echo "test-lint-notify-title-render: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
