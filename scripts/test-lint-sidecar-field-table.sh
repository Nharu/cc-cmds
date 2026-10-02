#!/usr/bin/env bash
# lint-sidecar-field-table: self-skip
# Test scripts/lint-sidecar-field-table.sh against
# tests/fixtures/lint-sidecar-field-table/.
#
# Each fixture is a pair of roots — `orchestrator/` (a gate.sh holding the
# `gate_append` call sites) and `skills/` (the contract holding the field
# table). The directory name encodes the expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1
#
# The two directions of the comparison are two fixtures: `FAIL-1` is a call
# site writing a field the table does not list, `FAIL-2` is the table listing a
# field no literal call site writes. `OK-2` is the pass-through guard — a
# series whose call site forwards `"$@"` may legitimately carry fields the
# literal keys do not show, so only the subset direction is enforced there.
# `OK-1` carries a multi-line call site, because a lint that read one physical
# line would see half the fields and pass on the half it saw.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-sidecar-field-table"

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
      echo "test-lint-sidecar-field-table: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  ORCH_ROOT="$fixture/orchestrator" SKILLS_ROOT="$fixture/skills" \
    bash "$script_dir/lint-sidecar-field-table.sh" >/dev/null 2>&1
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

# --- the row lookups' argument shape ----------------------------------------
# Scratch roots built here rather than fixture directories: each case is one
# `gate_has_row` line, next to a `gate_append` and a table row that agree, so
# the only thing that can move the exit code is the lookup's argument. The
# joined spelling is what the gate's document-hash guard carried, and it is
# the case the rule exists for; it must fail with exactly one lookup finding.
scratch=$(mktemp -d "${TMPDIR:-/tmp}/lint-sidecar-has-row.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

has_row_case() {
  # has_row_case <이름> <기대 exit> <기대 형태 위반 수> <gate_has_row 줄>
  local name="$1" want="$2" want_n="$3" line="$4" d ec out n
  d="$scratch/$name"
  mkdir -p "$d/orchestrator" "$d/skills/_common"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'f() {\n'
    printf '  %s || \\\n' "$line"
    printf '    gate_append %s "a=1" "b=2"\n' "'x'"
    printf '}\n'
  } > "$d/orchestrator/gate.sh"
  printf '| 계열 | 필드 |\n| --- | --- |\n| `x` | `a` · `b` |\n' > "$d/skills/_common/pipeline-sidecar.md"
  set +e
  out=$(ORCH_ROOT="$d/orchestrator" SKILLS_ROOT="$d/skills" \
    bash "$script_dir/lint-sidecar-field-table.sh" 2>&1)
  ec=$?
  set -e
  n=$(printf '%s\n' "$out" | grep -c '^FAIL: gate_has_row 인자 형태' || true)
  if [[ "$ec" == "$want" && "$n" == "$want_n" ]]; then
    passed=$((passed + 1))
    echo "PASS: has-row $name (exit=$ec, 형태 위반=$n)"
  else
    failures=$((failures + 1))
    echo "FAIL: has-row $name (exit=$ec, expected=$want; 형태 위반=$n, expected=$want_n)" >&2
    printf '%s\n' "$out" >&2
  fi
}

has_row_case joined-by-space 1 1 "gate_has_row 'x' \"a=1 b=2\""
has_row_case two-arguments   0 0 "gate_has_row 'x' \"a=1\" \"b=2\""
has_row_case anchored        0 0 "gate_has_row 'x' \"| a=1 |\""
has_row_case no-equals       1 1 "gate_has_row 'x' \"a\""

echo "test-lint-sidecar-field-table: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
