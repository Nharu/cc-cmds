#!/usr/bin/env bash
# Test scripts/lint-countermeasure-records.sh against
# tests/fixtures/lint-countermeasure-records/.
#
# Each fixture directory becomes one small root when the test runs: it is
# copied into a fresh temporary directory, its top-level `rules/` is moved to
# `plugins/cc-cmds/orchestrator/rules/`, and the lint runs with CM_ROOT set to
# that directory. The rule files sit at the fixture root rather than at their
# real place because the run hook classifies any tracked path matching
# `*/orchestrator/rules/*` as the rule catalog — and the leading `*` crosses
# `/`, so a fixture path under tests/fixtures/ would match too.
#
# The directory name encodes the expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1, and every `FAIL: [단언 N]` line on stderr names
#            the one assertion the fixture's `expect` file holds — a FAIL
#            fixture that also trips another assertion is a broken fixture,
#            since it no longer shows which rule caught it.
#
# Outside the fixtures: a root with no registry exits 2.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-countermeasure-records"
LINT="$script_dir/lint-countermeasure-records.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — the lint reads hooks.json with it and exits 2 without it"
  echo "test-lint-countermeasure-records: 0 passed, 0 failed"
  exit 0
fi

if [[ ! -d "$fixtures" ]]; then
  echo "FAIL: fixtures root missing: $fixtures" >&2
  exit 2
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-lint-countermeasure-records.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

passed=0
failures=0
n=0

# make_root <fixture dir> <root> — copy the fixture and move rules/ into place.
make_root() {
  mkdir -p "$2"
  cp -R "${1%/}/." "$2/"
  if [ -d "$2/rules" ]; then
    mkdir -p "$2/plugins/cc-cmds/orchestrator"
    mv "$2/rules" "$2/plugins/cc-cmds/orchestrator/rules"
  fi
}

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    OK-*)   want=0 ;;
    FAIL-*) want=1 ;;
    *)
      echo "test-lint-countermeasure-records: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac
  want_n=''
  if [ "$want" = 1 ]; then
    if [ ! -f "$fixture/expect" ]; then
      echo "FAIL: $fixture_name — expect 파일이 없다" >&2
      failures=$((failures + 1))
      continue
    fi
    want_n=$(tr -d ' \t\n' < "$fixture/expect")
  fi

  n=$((n + 1))
  root="$WORK/root-$n"
  make_root "$fixture" "$root"
  CM_ROOT="$root" bash "$LINT" >/dev/null 2>"$WORK/err-$n"
  ec=$?

  if [ "$ec" != "$want" ]; then
    failures=$((failures + 1))
    echo "FAIL: $fixture_name (exit=$ec, expected=$want)" >&2
    sed -e 's/^/  | /' "$WORK/err-$n" >&2
    continue
  fi

  if [ "$want" = 1 ]; then
    hit=0
    other=''
    while IFS= read -r line; do
      case "$line" in
        "FAIL: [단언 ${want_n}] "*) hit=$((hit + 1)) ;;
        'FAIL: [단언 '*) other="${other}${line}"$'\n' ;;
      esac
    done < "$WORK/err-$n"
    if [ "$hit" -eq 0 ]; then
      failures=$((failures + 1))
      echo "FAIL: $fixture_name — 겨냥한 [단언 ${want_n}] 줄이 없다" >&2
      sed -e 's/^/  | /' "$WORK/err-$n" >&2
      continue
    fi
    if [ -n "$other" ]; then
      failures=$((failures + 1))
      echo "FAIL: $fixture_name — 겨냥한 [단언 ${want_n}] 밖의 단언도 실패했다" >&2
      printf '%s' "$other" | sed -e 's/^/  | /' >&2
      continue
    fi
  fi

  passed=$((passed + 1))
  echo "PASS: $fixture_name (exit=$ec, expected=$want${want_n:+, 단언 $want_n})"
done

# A root without a registry cannot be judged at all: exit 2, never 0.
noreg="$WORK/no-registry"
mkdir -p "$noreg/plugins/cc-cmds/hooks"
printf '{"hooks": {}}\n' > "$noreg/plugins/cc-cmds/hooks/hooks.json"
CM_ROOT="$noreg" bash "$LINT" >/dev/null 2>&1
ec=$?
if [ "$ec" = 2 ]; then
  passed=$((passed + 1))
  echo "PASS: 등록부 없는 루트 (exit=$ec, expected=2)"
else
  failures=$((failures + 1))
  echo "FAIL: 등록부 없는 루트 (exit=$ec, expected=2)" >&2
fi

echo "test-lint-countermeasure-records: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
