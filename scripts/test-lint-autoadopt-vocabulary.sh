#!/usr/bin/env bash
# lint-autoadopt-vocabulary: self-skip
# Test scripts/lint-autoadopt-vocabulary.sh against
# tests/fixtures/lint-autoadopt-vocabulary/.
#
# Each fixture is a self-contained pair of roots — `orchestrator/` (run.sh, the
# vocabulary SOT, and gate.sh, the emitted-marker parser) and `scan/` (the tree
# whose literals are compared) — so the lint can be exercised against a whole
# vocabulary without touching the real one. The directory name encodes the
# expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1
#
# The lint declared `ORCH_ROOT` / `SCAN_ROOT` as a fixture-runner seam from its
# first day and no fixture ever used it. That matters more than a missing test
# usually does: the rule that does the work extracts a value with `sed`, and an
# extraction that silently yields the empty string skips every occurrence and
# reports `OK`. Nothing in a real-tree run distinguishes that from a clean tree.
#
# Two fixtures carry that load and are the ones to look at first if this suite
# ever goes quiet. `FAIL-2-multi-token` is the bypass shape — class names set
# side by side so that a vocabulary check comparing substrings sees only
# permitted tokens. `OK-3-prose` is its false-positive guard: a sentence that
# begins with a class name and continues in ordinary words is not a value claim,
# and a lint that reports it is switched off by its reader, taking the bypass
# detection with it. The two fail in opposite directions, so no single broken
# extraction leaves both green.
#
# THE TWO PATHS THROUGH THE LINT NEED SEPARATE FIXTURES, and for a while only
# one of them had any. A value that reaches a terminator is compared whole; a
# value that runs to the end of the line is decided by its tokens, and those are
# different code. `FAIL-2-multi-token` ends at a field separator, so it exercises
# the first path only — disabling the token path's multi-token arm entirely left
# this suite green. `FAIL-7-bare-multi-token` is the same shape written without a
# terminator and is the only fixture that reaches that arm.
#
# `FAIL-8-bare-out-of-vocab-with-path` and `OK-4-sentinel-prose` are the two
# directions of one root: which string the metasyntax shapes are matched
# against. Asked about the whole unterminated remainder, a slash anywhere in a
# sentence skipped the line and its out-of-vocabulary head went uncompared,
# while a sentence beginning with the ledger sentinel was reported as a
# vocabulary violation. They fail in opposite directions for the same reason the
# pair above does.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-autoadopt-vocabulary"

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
      echo "test-lint-autoadopt-vocabulary: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  ORCH_ROOT="$fixture/orchestrator" SCAN_ROOT="$fixture/scan" \
    bash "$script_dir/lint-autoadopt-vocabulary.sh" >/dev/null 2>&1
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

echo "test-lint-autoadopt-vocabulary: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
