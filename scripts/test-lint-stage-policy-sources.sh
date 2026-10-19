#!/usr/bin/env bash
# Test `scripts/lint-stage-policy-sources.sh` against
# tests/fixtures/lint-stage-policy-sources/.
#
# Each fixture is a POLICY_ROOT-shaped directory: a `stage-policy.md` beside a
# `legacy/stage-policy.v6.md`. The directory name encodes the expected exit.
#   T-POLICY-OK-*   → expected exit 0
#   T-POLICY-FAIL-* → expected exit 1
# Every FAIL fixture is the OK pair with exactly one defect: a non-ASCII policy
# line, a volatile token, an oversize policy, the harness pin absent or
# doubled, a non-ASCII legacy line, the legacy file missing, or the policy
# still carrying the v6 harness pin sentence. Four more cases are built at run
# time from the OK pair: the policy and the legacy file each padded to exactly
# the lint's size ceiling, and to one byte more.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-stage-policy-sources"

failures=0
passed=0

for fixture in "$fixtures"/T-POLICY-*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-POLICY-OK-*)   want=0 ;;
    T-POLICY-FAIL-*) want=1 ;;
    *)
      echo "test-lint-stage-policy-sources: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  POLICY_ROOT="$fixture" bash "$script_dir/lint-stage-policy-sources.sh" >/dev/null 2>&1
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

# The size ceiling at its boundary, for the policy and for the frozen legacy
# file alike: padded to exactly the lint's ceiling passes and one byte more
# fails. The ceiling is read from the lint, not retyped, so raising it moves
# every case with it.
max_bytes=$(sed -n 's/^MAX_BYTES=\([0-9][0-9]*\)$/\1/p' "$script_dir/lint-stage-policy-sources.sh")
if [[ -z "$max_bytes" ]]; then
  failures=$((failures + 1))
  echo "FAIL: size boundary — no 'MAX_BYTES=<n>' line in lint-stage-policy-sources.sh" >&2
else
  bound_scratch=$(mktemp -d)
  for which in stage-policy.md legacy/stage-policy.v6.md; do
    for over in 0 1; do
      case_dir="$bound_scratch/${which%%/*}-$over"
      mkdir -p "$case_dir/legacy"
      cp "$fixtures/T-POLICY-OK-1/stage-policy.md" "$case_dir/"
      cp "$fixtures/T-POLICY-OK-1/legacy/stage-policy.v6.md" "$case_dir/legacy/"
      have=$(wc -c < "$case_dir/$which" | tr -d ' ')
      pad=$((max_bytes + over - have))
      # One final line of `x`: no heading, no pin, no volatile token.
      printf '%s\n' "$(printf '%*s' $((pad - 1)) '' | tr ' ' x)" >> "$case_dir/$which"
      size=$(wc -c < "$case_dir/$which" | tr -d ' ')
      want=$over
      set +e
      POLICY_ROOT="$case_dir" bash "$script_dir/lint-stage-policy-sources.sh" >/dev/null 2>&1
      ec=$?
      set -e
      if [[ "$size" == "$((max_bytes + over))" && "$ec" == "$want" ]]; then
        passed=$((passed + 1))
        echo "PASS: size boundary $which — $size bytes against a $max_bytes-byte ceiling (exit=$ec, expected=$want)"
      else
        failures=$((failures + 1))
        echo "FAIL: size boundary $which — $size bytes against a $max_bytes-byte ceiling (exit=$ec, expected=$want)" >&2
      fi
    done
  done
  rm -rf "$bound_scratch"
fi

# The plugin's own policy and its frozen v6 copy pass the lint as shipped.
set +e
bash "$script_dir/lint-stage-policy-sources.sh" >/dev/null 2>&1
ec=$?
set -e
if [[ "$ec" == 0 ]]; then
  passed=$((passed + 1))
  echo "PASS: shipped policy and legacy v6 copy (exit=$ec, expected=0)"
else
  failures=$((failures + 1))
  echo "FAIL: shipped policy and legacy v6 copy (exit=$ec, expected=0)" >&2
fi

echo "test-lint-stage-policy-sources: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
