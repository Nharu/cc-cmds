#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test scripts/lint-lead-read-set.sh against tests/fixtures/lint-lead-read-set/.
#
# OK-1-both-leads is a complete minimal tree: `plugins/cc-cmds/skills/`, which
# is handed to the lint as SKILLS_ROOT, and a `ceiling` file whose number is
# handed to it as LEAD_READ_SET_CEILING, so that a tree of a few kilobytes can
# exercise the ceiling rule. Every other case holds only the files it changes:
# the case's tree is OK-1 copied into a scratch directory with the case's files
# laid over it, and an `absent` file, when present, names skill directories to
# remove from that tree. A FAIL case therefore differs from a passing tree in
# exactly the files it carries, and cannot fail for another reason.
#
# The directory name encodes the expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-lead-read-set"

if [[ ! -d "$fixtures" ]]; then
  echo "FAIL: fixtures root missing: $fixtures" >&2
  exit 2
fi

base="$fixtures/OK-1-both-leads"
if [[ ! -d "$base/plugins/cc-cmds/skills" ]]; then
  echo "FAIL: base fixture missing: $base" >&2
  exit 2
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/test-lint-lead-read-set.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

passed=0
failures=0

for case_dir in "$fixtures"/*/; do
  case_dir="${case_dir%/}"
  fixture_name=$(basename "$case_dir")
  fixture="$scratch/$fixture_name"
  mkdir -p "$fixture"
  cp -R "$base/." "$fixture/"
  if [[ "$case_dir" != "$base" ]]; then
    cp -R "$case_dir/." "$fixture/"
  fi
  if [[ -f "$fixture/absent" ]]; then
    while IFS= read -r gone; do
      [[ -n "$gone" ]] && rm -rf "${fixture:?}/plugins/cc-cmds/skills/$gone"
    done < "$fixture/absent"
  fi
  case "$fixture_name" in
    OK-*)   want=0 ;;
    FAIL-*) want=1 ;;
    *)
      echo "test-lint-lead-read-set: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  if [[ ! -f "$fixture/ceiling" ]]; then
    echo "FAIL: $fixture_name (no ceiling file)" >&2
    failures=$((failures + 1))
    continue
  fi
  ceiling=$(tr -d ' \n' < "$fixture/ceiling")

  set +e
  out=$(LEAD_READ_SET_CEILING="$ceiling" SKILLS_ROOT="$fixture/plugins/cc-cmds/skills" \
    bash "$script_dir/lint-lead-read-set.sh" 2>&1)
  ec=$?
  set -e

  # The exit code alone cannot tell a verdict from a crash: a lint aborted by
  # `set -e` mid-report also exits non-zero. Every run that reaches its verdict
  # prints a terminal banner, so its presence is asserted as well. The match
  # is a bash regex rather than a pipe into `grep -q`, whose early exit would
  # SIGPIPE the writer and, under `pipefail`, invert the result on a match.
  case "$want" in
    0) banner='lint-lead-read-set: OK — ' ;;
    1) banner='lint-lead-read-set: violations found' ;;
  esac
  banner_re=$'\n'"$banner"
  has_banner=0
  if [[ $'\n'"$out" =~ $banner_re ]]; then
    has_banner=1
  fi

  if [[ "$ec" == "$want" && "$has_banner" == 1 ]]; then
    passed=$((passed + 1))
    echo "PASS: $fixture_name (exit=$ec, expected=$want)"
    # TEST_LINT_VERBOSE=1 prints each verdict, to read that a FAIL case names
    # only the rule it is for.
    if [[ "${TEST_LINT_VERBOSE:-0}" == 1 ]]; then
      printf '%s\n' "$out" | sed 's/^/    /'
    fi
  elif [[ "$ec" != "$want" ]]; then
    failures=$((failures + 1))
    echo "FAIL: $fixture_name (exit=$ec, expected=$want)" >&2
    printf '%s\n' "$out" >&2
  else
    failures=$((failures + 1))
    echo "FAIL: $fixture_name (exit=$ec as expected, but the terminal banner /^${banner}/ is missing — the lint stopped before its verdict)" >&2
    printf '%s\n' "$out" >&2
  fi
done

echo "test-lint-lead-read-set: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
