#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test scripts/lint-statusline-token-arms.sh.
#
# THE FIXTURES ARE BUILT UNDER `mktemp -d`, NOT COMMITTED, which is where this
# suite parts company with its siblings under `tests/fixtures/`. The slice that
# adds this lint declared six files and no fixture tree, and a declared file set
# is what the authorization rests on — so the roots are written at run time and
# removed on exit. `ORCH_ROOT` is the override that makes that possible, and it
# is why the lint carries one.
#
# Each root is a self-contained pair: a `liveness.sh` holding a `cc_run_state`
# whose `printf` literals are the vocabulary AND a `cc_run_grade` whose arms are
# the third copy of it, and a `statusline.sh` holding the render `case`. Nothing
# here sources or executes either one — the lint reads them as bytes, so the
# fixtures only need the three shapes it matches.
#
# `FAIL-missing-arm` is the fixture that earns this lint's keep. A token with no
# arm falls to `*) emit_fallback`, whose bytes ARE the "no run in this session"
# line — so the defect ships green through the suite, the render probe and the
# apply verification, and a reader cannot tell it from having nothing to say.
#
# `FAIL-missing-grade-arm` is its sibling for rule 3, and it is the case rules 1
# and 2 cannot make: token set, render arms and grade arms all agree except that
# the grade is one arm short, so the first two rules are green on their own.
# That is why the grade arms are a SEPARATE argument here — folding them into
# the token list would make the only event rule 3 detects unwritable.
#
# `FAIL-two-literals-one-line` is what holds the extraction repair in place.
# Against the old greedy match it exits 0; against the repaired one the hidden
# token has no arm anywhere and it exits 1.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
LINT="$script_dir/lint-statusline-token-arms.sh"

if [[ ! -f "$LINT" ]]; then
  echo "FAIL: lint not found: $LINT" >&2
  exit 2
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-lint-token-arms-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

passed=0
failures=0

mk_liveness() {
  # mk_liveness [--grade "<arm>..."] [--state-line "<line>"] <root> <token>...
  #
  # A `cc_run_state` that can print those tokens, plus a `cc_run_grade` whose
  # arms are BY DEFAULT exactly those tokens — which is what keeps the six cases
  # written before rule 3 existed passing unamended.
  #
  # `--grade` makes the two sets diverge, and that divergence is the only event
  # rule 3 detects. `--state-line` injects one raw line into `cc_run_state`,
  # which is the only way to put two `printf` literals on one line and so the
  # only way to pin the extraction repair.
  local grade="" extra=""
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --grade)      grade="$2"; shift 2 ;;
      --state-line) extra="$2"; shift 2 ;;
      *) echo "mk_liveness: unknown option $1" >&2; return 2 ;;
    esac
  done
  local root="$1"; shift
  [[ -n "$grade" ]] || grade="$*"
  mkdir -p "$root"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'cc_run_state() {\n'
    printf '  # printf %s — a comment holding a literal, which must not be extracted.\n' "'미끼'"
    [[ -z "$extra" ]] || printf '%s\n' "$extra"
    local t
    for t in "$@"; do printf "  printf '%s'\n" "$t"; done
    printf '}\n'
    printf 'cc_run_grade() {\n'
    printf '  case "$1" in\n'
    local a
    for a in $grade; do printf "    %s)   printf '1' ;;\n" "$a"; done
    printf "    *)        printf '9' ;;\n"
    printf '  esac\n'
    printf '}\n'
  } > "$root/liveness.sh"
}

mk_statusline() {
  # mk_statusline <root> <arm>... — a render `case` with those arms plus the
  # default one. The lines around the arms are the shapes that end in `)` for
  # other reasons — a command substitution and an assignment — so every root
  # exercises the extraction against them.
  local root="$1"; shift
  mkdir -p "$root"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'case "$best_state" in\n'
    local a
    for a in "$@"; do
      printf '  %s)\n' "$a"
      printf '    slot=$(newest_stage_pid "$best_rd")\n'
      printf '    line="X ${best_rid}"\n'
      printf '    ;;\n'
    done
    printf '  *)\n'
    printf '    emit_fallback; exit 0\n'
    printf '    ;;\n'
    printf 'esac\n'
  } > "$root/statusline.sh"
}

run_case() {
  # run_case <name> <want-exit> <root>
  local name="$1" want="$2" root="$3" ec
  ORCH_ROOT="$root" bash "$LINT" >/dev/null 2>&1
  ec=$?
  if [[ "$ec" == "$want" ]]; then
    passed=$((passed + 1))
    echo "PASS: $name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
    echo "FAIL: $name (exit=$ec, expected=$want)" >&2
  fi
}

VOCAB="도는중 승인대기 종단 진행중 정지경고 버려짐"

# OK — six tokens, six arms, one to one in both directions.
mk_liveness   "$WORK/ok" $VOCAB
mk_statusline "$WORK/ok" $VOCAB
run_case "OK-one-to-one" 0 "$WORK/ok"

# FAIL — the token is in the vocabulary and the render has no arm for it. This
# is the shape that produces the "no run" bytes instead of an error.
mk_liveness   "$WORK/missing" $VOCAB
mk_statusline "$WORK/missing" 도는중 승인대기 종단 진행중 정지경고
run_case "FAIL-missing-arm" 1 "$WORK/missing"

# FAIL — an arm for a token `cc_run_state` cannot print. Dead render code that
# reads as a supported state.
mk_liveness   "$WORK/orphan" $VOCAB
mk_statusline "$WORK/orphan" $VOCAB 없는토큰
run_case "FAIL-orphan-arm" 1 "$WORK/orphan"

# FAIL — a grouped arm. Admitted by the extraction and rejected by the rule, so
# that grouping cannot make a token's arm disappear from the count instead.
mk_liveness   "$WORK/grouped" $VOCAB
mk_statusline "$WORK/grouped" 도는중 승인대기 종단 진행중 '정지경고|버려짐'
run_case "FAIL-grouped-arm" 1 "$WORK/grouped"

# FAIL — rule 3's own case. Six tokens, six render arms, and `cc_run_grade` is
# missing the arm for one of them. Rules 1 and 2 are both green here, so without
# rule 3 this root passes and the token sinks to the worst rank in silence.
mk_liveness --grade "도는중 승인대기 종단 진행중 정지경고" "$WORK/nograde" $VOCAB
mk_statusline "$WORK/nograde" $VOCAB
run_case "FAIL-missing-grade-arm" 1 "$WORK/nograde"

# FAIL — the other direction: a grade arm for a token `cc_run_state` cannot
# print. Dead ranking code that reads as a supported state.
mk_liveness --grade "$VOCAB 없는토큰" "$WORK/gorphan" $VOCAB
mk_statusline "$WORK/gorphan" $VOCAB
run_case "FAIL-orphan-grade-arm" 1 "$WORK/gorphan"

# FAIL — two `printf` literals on one line. This is the fixture that pins the
# extraction repair rather than any rule: the greedy match kept only the second
# literal, so the first token was never extracted, had no arm anywhere, and the
# lint exited 0. Collecting every occurrence surfaces 숨은토큰, which has no
# render arm and no grade arm, and both rule 1 and rule 3 say so.
mk_liveness --state-line "  if x; then printf '숨은토큰'; else printf '도는중'; fi" \
  "$WORK/twolit" $VOCAB
mk_statusline "$WORK/twolit" $VOCAB
run_case "FAIL-two-literals-one-line" 1 "$WORK/twolit"

# Exit 2 — the render is there and the vocabulary could not be read. Separated
# from exit 1 because "the extraction broke" is not "the arms are wrong", and
# folding them would let a broken `sed` report a violation it never checked.
mkdir -p "$WORK/nosot"
printf '#!/usr/bin/env bash\ncc_run_state() {\n  return 0\n}\n' > "$WORK/nosot/liveness.sh"
mk_statusline "$WORK/nosot" $VOCAB
run_case "FAIL-2-no-tokens-extracted" 2 "$WORK/nosot"

# SKIP — the mechanism is not present. Green, matching the sibling lints'
# incremental-rollout posture.
mkdir -p "$WORK/skip"
mk_statusline "$WORK/skip" $VOCAB
run_case "SKIP-liveness-absent" 0 "$WORK/skip"

mkdir -p "$WORK/skip2"
mk_liveness "$WORK/skip2" $VOCAB
run_case "SKIP-statusline-absent" 0 "$WORK/skip2"

echo "test-lint-statusline-token-arms: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
