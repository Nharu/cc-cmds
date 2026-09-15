#!/usr/bin/env bash
# Test scripts/lint-harness-global-collisions.sh.
#
# THE FIXTURES ARE BUILT UNDER `mktemp -d`, NOT COMMITTED. The change that adds
# this lint declares its own two files and no fixture tree, so each case is a
# miniature tree written at run time — a harness file and two gate files — and
# the lint is pointed at it through `ROOT`, `HARNESS` and `GATE_FILES`. The
# unit has to be that large because what is under test is a relation between
# files, not a property of one.
#
# Every case asserts the exit code AND the exact set of `<rule>|<name>`
# violations. An exit code alone is satisfied by a lint that failed for some
# other reason, which is how a detector stops detecting with nobody noticing.
#
# The cases are the lint's stated exclusions, one each, on both sides: a
# command-prefix environment (single-line and `\`-continued), an indented
# harness assignment, a gate `local`, a gate loop variable, a gate comment.
# Each of those must be an OK, because reporting one as a collision is what
# would train readers to override the lint; the collisions themselves must be
# reported by NAME, because the seam's repair is a rename and the reader needs
# to know which one.
#
# Three sweep-wide checks keep the suite from passing vacuously: all three
# classes (OK, FAIL, ERR) are exercised; every rule id the lint can report —
# read out of the lint's own `viol` call sites — is observed in at least one
# case; and the number of assertions that actually ran is held to a floor.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
LINT="$script_dir/lint-harness-global-collisions.sh"

if [[ ! -f "$LINT" ]]; then
  echo "FAIL: lint not found: $LINT" >&2
  exit 2
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-lint-collisions-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

ASSERTION_FLOOR=24

passed=0
failures=0
assertions=0
seen_ok=0
seen_fail=0
seen_err=0
observed_ids=""

mk_tree() {
  # mk_tree <dir> <harness-body> <gate-body> <driver-body>
  #
  # A harness always exports GATE (the real one does) and a gate always assigns
  # RUN_DIR, so every tree has at least one name on each side and the empty-
  # derivation ERR cannot fire by accident.
  local dir="$1"
  mkdir -p "$dir/scripts" "$dir/plugins/cc-cmds/orchestrator"
  printf '%s\n' '#!/usr/bin/env bash' 'export GATE="$root/gate.sh"' "$2" > "$dir/scripts/test-gate.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'RUN_DIR="$1"' "$3" > "$dir/plugins/cc-cmds/orchestrator/gate.sh"
  printf '%s\n' '#!/usr/bin/env bash' "$4" > "$dir/plugins/cc-cmds/orchestrator/run.sh"
}

run_case() {
  # run_case <name> <want-exit> <dir> <expected violations, one `rule|name` per line>
  local name="$1" want="$2" dir="$3" want_v got_v ec case_ok=1
  ROOT="$dir" bash "$LINT" >"$WORK/out" 2>"$WORK/err"
  ec=$?

  case "$name" in
    OK-*)   seen_ok=1 ;;
    FAIL-*) seen_fail=1 ;;
    ERR-*)  seen_err=1 ;;
  esac

  want_v=$(printf '%s\n' "$4" | grep -v '^$' | sort -u)
  got_v=$(sed -n 's#^FAIL: \[\([^]]*\)\] \([^ ]*\) — .*$#\1|\2#p' "$WORK/err" | sort -u)
  observed_ids=$(printf '%s\n%s\n' "$observed_ids" "$(printf '%s\n' "$got_v" | cut -d'|' -f1)")

  assertions=$((assertions + 1))
  if [[ "$ec" != "$want" ]]; then
    case_ok=0
    echo "FAIL: $name (exit=$ec, expected=$want)" >&2
    sed 's/^/    /' "$WORK/err" >&2
  fi

  assertions=$((assertions + 1))
  if [[ "$got_v" != "$want_v" ]]; then
    case_ok=0
    echo "FAIL: $name (위반 집합이 기대와 다르다)" >&2
    echo "  expected:" >&2
    printf '%s\n' "$want_v" | sed 's/^/    /' >&2
    echo "  actual:" >&2
    printf '%s\n' "$got_v" | sed 's/^/    /' >&2
  fi

  if (( case_ok == 1 )); then
    passed=$((passed + 1))
    echo "PASS: $name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
  fi
}

# OK — disjoint names on the two sides.
mk_tree "$WORK/disjoint" 'FX_MANIFEST="$WT/plan.md"' 'MANIFEST=""' 'LEDGER=""'
run_case "OK-disjoint" 0 "$WORK/disjoint" ""

# OK — the gate spells the name only as a command-prefix environment, on one
# line and `\`-continued across lines, while the harness exports it. This is
# `CC_CLAUDE_BIN`: the harness must export it for its children, and the gate's
# launch prefixes it to a `bash` — nothing in the sourcing shell is touched.
mk_tree "$WORK/gate-prefix" 'export CC_CLAUDE_BIN="$WORK/bin/claude-noop"' \
'launch() {
  CC_CLAUDE_BIN="$CLI_BIN" \
  CC_PIPELINE_STAGE_ID="$seg#$attempt" \
  bash "$wrapper" --settings x
  CC_CLAUDE_BIN="$CLI_BIN" bash "$wrapper"
}' 'LEDGER=""'
run_case "OK-gate-prefix-env" 0 "$WORK/gate-prefix" ""

# OK — the harness spells the name only as a prefix on a child command, while
# the gate assigns it globally. A prefix reaches the child and nothing else.
mk_tree "$WORK/harness-prefix" 'MANIFEST="$WT/plan.md" bash "$GATE" snapshot' 'MANIFEST=""' ''
run_case "OK-harness-prefix-env" 0 "$WORK/harness-prefix" ""

# OK — the gate assigns the name only as a function local.
mk_tree "$WORK/gate-local" 'MANIFEST="$WT/plan.md"' \
'f() {
  local MANIFEST="$1"
  printf "%s" "$MANIFEST"
}' ''
run_case "OK-gate-local" 0 "$WORK/gate-local" ""

# OK — the gate's only spelling is a loop variable, and a comment line that
# happens to read like an assignment.
mk_tree "$WORK/gate-loop-comment" 'GRANT="$WT/grant.md"
LEDGER="$WT/ledger.md"' \
'for GRANT in a b; do :; done
# LEDGER="$RUN_DIR/ledger.md" is derived below' ''
run_case "OK-gate-loop-and-comment" 0 "$WORK/gate-loop-comment" ""

# OK — the harness assigns the name only inside a function (indented). What a
# sourced file clobbers on entry is the top level; function state is the seam
# guard's business, not this lint's.
mk_tree "$WORK/harness-indented" \
'switch_run() {
  MANIFEST="$WT/plan2.md"
}' 'MANIFEST=""' ''
run_case "OK-harness-indented" 0 "$WORK/harness-indented" ""

# FAIL — the plain collision: a column-zero harness assignment and a gate
# global of the same name, reported by name.
mk_tree "$WORK/collide" 'MANIFEST="$WT/plan.md"' 'MANIFEST=""' ''
run_case "FAIL-column-zero-vs-gate-global" 1 "$WORK/collide" "충돌|MANIFEST"

# FAIL — `export NAME` in the harness against `readonly NAME=` in the driver.
mk_tree "$WORK/export-readonly" 'LEDGER="$WT/ledger.md"
export LEDGER' '' 'readonly LEDGER="${LEDGER:-}"'
run_case "FAIL-export-vs-readonly" 1 "$WORK/export-readonly" "충돌|LEDGER"

# FAIL — a gate assignment that is not the line's first statement is still an
# assignment: `A=1; B=2` assigns B, and `[ … ] || C=3` assigns C.
mk_tree "$WORK/gate-joined" 'B_NAME="x"
C_NAME="y"
D_NAME="z"' 'A_NAME=1; B_NAME=2
[ -n "$x" ] || C_NAME=3
if true; then D_NAME=4; fi' ''
run_case "FAIL-gate-joined-statements" 1 "$WORK/gate-joined" "충돌|B_NAME
충돌|C_NAME
충돌|D_NAME"

# FAIL — several collisions at once are all reported, not just the first.
mk_tree "$WORK/three" 'MANIFEST="a"
LEDGER="b"
GRANT="c"' 'MANIFEST=""
GRANT=""' 'LEDGER=""'
run_case "FAIL-every-collision-named" 1 "$WORK/three" "충돌|GRANT
충돌|LEDGER
충돌|MANIFEST"

# ERR — the harness file is missing.
mk_tree "$WORK/no-harness" 'X=1' 'Y=2' ''
rm -f "$WORK/no-harness/scripts/test-gate.sh"
run_case "ERR-harness-missing" 2 "$WORK/no-harness" ""

# ERR — a gate file is missing.
mk_tree "$WORK/no-gate" 'X=1' 'Y=2' ''
rm -f "$WORK/no-gate/plugins/cc-cmds/orchestrator/run.sh"
run_case "ERR-gate-file-missing" 2 "$WORK/no-gate" ""

# --- sweep-wide checks ------------------------------------------------------

if (( seen_ok == 0 )) || (( seen_fail == 0 )) || (( seen_err == 0 )); then
  echo "FAIL: 클래스 커버리지 — OK=$seen_ok FAIL=$seen_fail ERR=$seen_err, 세 팔이 전부 취해져야 한다" >&2
  failures=$((failures + 1))
fi

declared_ids=$(grep -oE 'viol "[^"]+"' "$LINT" | sed -E 's/^viol "//; s/"$//' | sort -u)
observed_ids=$(printf '%s\n' "$observed_ids" | grep -v '^$' | sort -u)
assertions=$((assertions + 1))
if [[ -z "$declared_ids" ]]; then
  echo "FAIL: 방출 커버리지 — 린트에서 viol 호출을 하나도 읽지 못했다" >&2
  failures=$((failures + 1))
else
  unobserved=$(comm -23 <(printf '%s\n' "$declared_ids") <(printf '%s\n' "$observed_ids"))
  if [[ -n "$unobserved" ]]; then
    echo "FAIL: 방출 커버리지 — 어느 사례에서도 관측되지 않은 규칙이 있다:" >&2
    printf '%s\n' "$unobserved" | sed 's/^/  /' >&2
    failures=$((failures + 1))
  fi
fi

if (( assertions < ASSERTION_FLOOR )); then
  echo "FAIL: 실행된 단언이 $assertions 개로 하한 $ASSERTION_FLOOR 미만이다 — 사례 순회가 무너졌다" >&2
  failures=$((failures + 1))
fi

printf 'test-lint-harness-global-collisions: %d passed, %d failed, %d assertions\n' \
  "$passed" "$failures" "$assertions"

if (( failures > 0 )); then
  exit 1
fi
exit 0
