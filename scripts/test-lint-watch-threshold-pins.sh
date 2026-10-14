#!/usr/bin/env bash
# Test scripts/lint-watch-threshold-pins.sh against
# tests/fixtures/lint-watch-threshold-pins/.
#
# Each fixture is a self-contained pair of roots — `orchestrator/watch.sh` (the
# defaults' SOT) and `skills/autopilot/references/act2-seat.md` (the document
# that pins them) —
# so the lint can be driven over a whole disagreement without touching the real
# tree. The directory name encodes the expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1
#
# `FAIL-1-value-drift` is the fixture that earns its keep: it reproduces the
# failure the lint exists for, which is a default moving underneath a document
# that goes on stating the old number. That divergence is invisible until a
# night run behaves unlike its own contract, and every other check in the repo
# stays green through it.
#
# `FAIL-4-second-mention-drift` covers the other half of the same failure. Its
# launch line agrees with the script, so the rules anchored on that line pass,
# and only the paragraph restating the four thresholds has gone stale — the
# paragraph that carries no script name and is therefore invisible to a scan
# that locates the launch line by the script it invokes.
#
# `FAIL-5-silence-drift` pins the fifth pair. Its launch line spells every flag
# once and agrees on the other four, so it fails only if the lint reads
# `--silence` at all — and its failure is checked to name that flag, because an
# exit code alone would also be 1 for a fixture broken for some other reason.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-watch-threshold-pins"

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
      echo "test-lint-watch-threshold-pins: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  ORCH_ROOT="$fixture/orchestrator" SKILLS_ROOT="$fixture/skills" \
    bash "$script_dir/lint-watch-threshold-pins.sh" >/dev/null 2>&1
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

# The silence fixture fails for its own reason and no other.
silence_fx="$fixtures/FAIL-5-silence-drift"
if [[ -d "$silence_fx" ]]; then
  set +e
  silence_err=$(ORCH_ROOT="$silence_fx/orchestrator" SKILLS_ROOT="$silence_fx/skills" \
    bash "$script_dir/lint-watch-threshold-pins.sh" 2>&1 >/dev/null)
  set -e
  silence_fails=$(printf '%s\n' "$silence_err" | grep -c '^FAIL:' || true)
  silence_named=$(printf '%s\n' "$silence_err" | grep '^FAIL:' | grep -c -- '--silence' || true)
  if [[ "$silence_fails" != "0" && "$silence_fails" == "$silence_named" ]]; then
    passed=$((passed + 1))
    echo "PASS: FAIL-5-silence-drift 의 실패는 모두 --silence 를 지목한다 (${silence_fails}건)"
  else
    failures=$((failures + 1))
    echo "FAIL: FAIL-5-silence-drift — FAIL 줄 ${silence_fails}건 중 --silence 를 지목한 것은 ${silence_named}건" >&2
    printf '%s\n' "$silence_err" >&2
  fi
fi

echo "test-lint-watch-threshold-pins: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
