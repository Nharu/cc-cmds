#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test scripts/lint-unattended-surfaces.sh against
# tests/fixtures/lint-unattended-surfaces/.
#
# Each fixture directory is a SKILLS_ROOT: it holds `<skill>/SKILL.md` trees.
# The directory name encodes the expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1
#
# `OK-3-prose-mention` is the false-positive guard and is the fixture that
# earns its keep: every real unattended arm documents the tools it must not
# use, so a token-level denylist would flag exactly the sentences stating the
# invariant. If that fixture ever fails, the patterns stopped anchoring on
# call form.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-unattended-surfaces"

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
      echo "test-lint-unattended-surfaces: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  out=$(SKILLS_ROOT="$fixture" bash "$script_dir/lint-unattended-surfaces.sh" 2>&1)
  ec=$?
  set -e

  # The exit code alone cannot tell a verdict from a crash: a lint aborted by
  # `set -e` mid-report also exits non-zero. Every run that reaches its verdict
  # prints a terminal banner, so its presence is asserted as well. The match
  # is a bash regex rather than a pipe into `grep -q`, whose early exit would
  # SIGPIPE the writer and, under `pipefail`, invert the result on a match.
  case "$want" in
    0) banner='lint-unattended-surfaces: [0-9]' ;;
    1) banner='lint-unattended-surfaces: violations found' ;;
  esac
  banner_re=$'\n'"$banner"
  has_banner=0
  if [[ $'\n'"$out" =~ $banner_re ]]; then
    has_banner=1
  fi

  if [[ "$ec" == "$want" && "$has_banner" == 1 ]]; then
    passed=$((passed + 1))
    echo "PASS: $fixture_name (exit=$ec, expected=$want)"
  elif [[ "$ec" != "$want" ]]; then
    failures=$((failures + 1))
    echo "FAIL: $fixture_name (exit=$ec, expected=$want)" >&2
  else
    failures=$((failures + 1))
    echo "FAIL: $fixture_name (exit=$ec as expected, but the terminal banner /^${banner}/ is missing — the lint stopped before its verdict)" >&2
  fi
done

echo "test-lint-unattended-surfaces: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
