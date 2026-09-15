#!/usr/bin/env bash
# Executable specification of the design-session leg's hand-off contracts:
# the interview brief the seat writes, the leg's artifact predicate, the
# pending-leg marker (`leg.json`), the park record, and the re-dispatch floor.
#
# WHAT THIS SUITE ACTUALLY FIXES, stated honestly. The seat and the leg are
# model processes that execute these predicates from SKILL.md prose; no shell
# script in the plugin evaluates them at runtime. So this suite does two things
# and no third:
#
#   (1) It carries a REFERENCE IMPLEMENTATION of each predicate as a shell
#       function and runs it against fixtures, so the SHAPE of every artifact
#       is fixed by an executable and a change to a fixture contract turns red
#       here before it turns into two skills disagreeing at 3 a.m.
#   (2) It PINS the literals the two SKILL.md files must share — the header
#       version strings, the brief's block names and the five delivery-shape
#       field names, the nine park site ids, the `redispatch_count` field —
#       so a rename on one side without the other is a failing build.
#
# If the prose changes, (2) goes red; if a fixture contract changes, (1) goes
# red. Neither proves that a running seat or leg applies the predicate — that
# is the model's residual, and it is stated rather than papered over.
#
# Cases (each with an OK fixture and at least one mutated FAIL fixture):
#   T7  brief guards         check_brief       tests/fixtures/design-brief/brief/
#   T8  gate exemption       runtime git repo  the brief path filtered out of porcelain
#   T9  pending-leg marker   check_leg         tests/fixtures/design-brief/leg/
#   T10 artifact predicate   check_artifact    tests/fixtures/design-brief/artifact/
#
# The T10 fixtures name the design document `design-doc.md` beside its
# `presentation.md` rather than mirroring the real `docs/{slug}.md` layout: this
# repository excludes any path component named `docs`, so a fixture under one
# would be silently untracked and would never reach a fresh clone or CI.
#   T11 park record          check_park        tests/fixtures/design-brief/park/
#   T13 re-dispatch floor    check_redispatch  tests/fixtures/design-brief/leg/
#   T6  CFI-U0 pin (helper)  lint-unattended-surfaces.sh over a copied tree
#   pin literal cross-pin    the two real SKILL.md files
#
# Usage:
#   bash scripts/test-design-brief.sh
#
# Exit codes:
#   0 — every case passed
#   1 — at least one case failed
#   2 — the suite could not run (missing fixtures or skills)
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`; BSD
# and GNU userland alike (no `sed -i`, no `readlink -f`, no `stat -f`/`-c`).

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="$repo_root/plugins/cc-cmds/skills"
fixtures="$repo_root/tests/fixtures/design-brief"

DESIGN="$skills_root/design/SKILL.md"
LEG="$skills_root/design-discuss-unattended/SKILL.md"
SURFACE_LINT="$script_dir/lint-unattended-surfaces.sh"

for need in "$DESIGN" "$LEG" "$SURFACE_LINT"; do
  if [[ ! -f "$need" ]]; then
    echo "test-design-brief: missing $need" >&2
    exit 2
  fi
done
if [[ ! -d "$fixtures" ]]; then
  echo "test-design-brief: fixtures root missing: $fixtures" >&2
  exit 2
fi

passed=0
failures=0

pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }

# expect_rc <want> <label> <cmd...> — run a reference function, compare rc.
expect_rc() {
  local want="$1" label="$2"; shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == "$want" ]]; then
    pass "$label (rc=$rc)"
  else
    fail "$label (rc=$rc, expected=$want)"
  fi
}

# expect_out <want> <label> <cmd...> — run a reference function, compare stdout.
expect_out() {
  local want="$1" label="$2"; shift 2
  local got
  got=$("$@" 2>/dev/null || true)
  if [[ "$got" == "$want" ]]; then
    pass "$label ($got)"
  else
    fail "$label (got='$got', expected='$want')"
  fi
}

# last_nonempty_line <file>
last_nonempty_line() {
  grep -v '^[[:space:]]*$' "$1" | tail -n 1
}

# ---------- literals shared by the two SKILL.md files ------------------------

BRIEF_HEADER_PREFIX='<!-- cc-design-brief v1; writer=design; reader=design-discuss-unattended; owner-doc='
BRIEF_TERMINATOR='<!-- cc-design-brief: end -->'
BRIEF_BLOCKS='## 요구사항
## 제약
## 배포 형상
## 탐색 결과
## 재현
## 팀 구성
## 기준선
## 대상'
SHAPE_FIELDS=('**레포**' '**슬라이스 수**' '**적용 위치**' '**적용 주체**' '**실패 시 파킹**')

PRESENTATION_HEADER_PREFIX='<!-- cc-design-presentation v1; writer=design-discuss-unattended; reader=design; slug='
PARK_HEADER_PREFIX='<!-- cc-design-park v1; writer=design-discuss-unattended; reader=design; slug='
PARK_TERMINATOR='<!-- /cc-design-park v1 -->'
COHERENCE_HEADER_TOKEN='cc-design-coherence v1'
PARK_FIELDS=('**중단 시각**' '**스킬**' '**스텝**' '**분류**' '**질문 문면**' '**선택지**' '**하네스 오류**' '**관측 상세**' '**재호출 명령**' '**후속**' '**자리 id**' '**묶인 대상**' '**원장 상태**')
PARK_SITES=('ledger-missing' 'case2-respawn-dead' 'unavail-streak' 'empty-streak' 'growth-streak' 'case1-thin-witness' 'fidelity-case1' 'fidelity-decision-reopen' 'sweep-claim-2nd-fail')
PARK_MAX_QUESTIONS=4
REDISPATCH_FLOOR=1

# ---------- reference implementation: brief guards (T7) ----------------------

# check_brief <brief.md> — 0 when every guard the leg's Step 1 states holds.
check_brief() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  # header: line 2, strict version token
  local l2
  l2=$(sed -n '2p' "$f")
  case "$l2" in
    "$BRIEF_HEADER_PREFIX"*) ;;
    *) return 1 ;;
  esac
  # eight blocks, in order, exactly
  local got
  got=$(grep -E '^## ' "$f" || true)
  [[ "$got" == "$BRIEF_BLOCKS" ]] || return 1
  # five delivery-shape field lines inside `## 배포 형상`
  local shape
  shape=$(awk '
    /^## / { incap = ($0 == "## 배포 형상") ; next }
    incap { print }
  ' "$f")
  local k
  for k in "${SHAPE_FIELDS[@]}"; do
    printf '%s\n' "$shape" | grep -qF -- "$k: " || return 1
  done
  # terminator on the last non-empty line
  [[ "$(last_nonempty_line "$f")" == "$BRIEF_TERMINATOR" ]] || return 1
  return 0
}

# ---------- reference implementation: artifact predicate (T10) ---------------

# check_artifact <doc.md> <presentation.md> [exit_code]
# The optional third argument exists to make the point of T10 executable: an
# exit code is NOT part of the predicate, so passing 0 here changes nothing.
check_artifact() {
  local doc="$1" pres="$2"
  [[ -f "$doc" ]] || return 1
  # ledger block parses: rows between the opening comment and its close
  local rows
  rows=$(awk '
    /^<!-- cc-design-ledger v3/ { inblk = 1; next }
    inblk && /^-->/ { exit }
    inblk && / \| / { print }
  ' "$doc")
  [[ -n "$rows" ]] || return 1
  # every non-aborted row is done
  local bad
  bad=$(printf '%s\n' "$rows" | awk -F ' \\| ' '$2 != "done" && $2 != "aborted" { print }')
  [[ -z "$bad" ]] || return 1
  # presentation exists with a matching header version
  [[ -f "$pres" ]] || return 1
  local h
  h=$(sed -n '1p' "$pres")
  case "$h" in
    "$PRESENTATION_HEADER_PREFIX"*) ;;
    *) return 1 ;;
  esac
  return 0
}

# ---------- reference implementation: pending-leg marker (T9) ----------------

# check_leg <leg.json> <current-brief-sha256> <state-dir>
# Prints one verdict: stale-aside | parked | done | wait-or-recover
check_leg() {
  local leg="$1" cur="$2" state="$3"
  local recorded
  recorded=$(jq -r '.brief_sha256 // ""' "$leg")
  if [[ "$recorded" != "$cur" ]]; then
    echo "stale-aside"; return 0
  fi
  if [[ -f "$state/park.md" ]]; then
    local h
    h=$(sed -n '1p' "$state/park.md")
    case "$h" in
      "$PARK_HEADER_PREFIX"*) echo "parked"; return 0 ;;
    esac
  fi
  if check_artifact "$state/design-doc.md" "$state/presentation.md"; then
    echo "done"; return 0
  fi
  echo "wait-or-recover"
}

# ---------- reference implementation: park record (T11) ----------------------

# check_park <park.md> — 0 when the record is renderable verbatim by the seat.
check_park() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  local h
  h=$(sed -n '1p' "$f")
  case "$h" in
    "$PARK_HEADER_PREFIX"*) ;;
    *) return 1 ;;
  esac
  local k
  for k in "${PARK_FIELDS[@]}"; do
    grep -qF -- "$k:" "$f" || return 1
  done
  # closed site set
  local site ok=0
  site=$(grep -F -- '**자리 id**: ' "$f" | head -n 1 | sed 's/^\*\*자리 id\*\*: //')
  for k in "${PARK_SITES[@]}"; do
    [[ "$site" == "$k" ]] && ok=1
  done
  [[ "$ok" == "1" ]] || return 1
  # at most four questions, at least one
  local nq
  nq=$(grep -cF -- '**질문 문면**: ' "$f" || true)
  [[ "${nq:-0}" -ge 1 && "${nq:-0}" -le "$PARK_MAX_QUESTIONS" ]] || return 1
  # every option line carries a label AND a verbatim description
  local opt
  while IFS= read -r opt; do
    [[ -n "$opt" ]] || continue
    printf '%s\n' "$opt" | grep -qE '^- `[^`]+` — .+$' || return 1
  done <<EOF
$(grep -E '^- ' "$f" || true)
EOF
  # the resume command is recorded (never executed — this suite runs nothing from it)
  grep -qE '^\*\*재호출 명령\*\*: .+$' "$f" || return 1
  [[ "$(last_nonempty_line "$f")" == "$PARK_TERMINATOR" ]] || return 1
  return 0
}

# ---------- reference implementation: re-dispatch floor (T13) ----------------

# check_redispatch <leg.json> — 0 while the ladder may still re-dispatch;
# 1 when the floor is reached and the seat demotes to running Steps 3-4 itself.
check_redispatch() {
  local n
  n=$(jq -r '.redispatch_count // 0' "$1")
  [[ "$n" -le "$REDISPATCH_FLOOR" ]]
}

# ============================================================================
# T7 — brief guards
# ============================================================================

expect_rc 0 "T7 brief OK-full"            check_brief "$fixtures/brief/OK-full.md"
expect_rc 1 "T7 brief FAIL-missing-field" check_brief "$fixtures/brief/FAIL-missing-field.md"
expect_rc 1 "T7 brief FAIL-missing-block" check_brief "$fixtures/brief/FAIL-missing-block.md"
expect_rc 1 "T7 brief FAIL-bad-version"   check_brief "$fixtures/brief/FAIL-bad-version.md"
expect_rc 1 "T7 brief FAIL-no-terminator" check_brief "$fixtures/brief/FAIL-no-terminator.md"

# ============================================================================
# T8 — gate exemption: the brief is filtered out of porcelain by the path the
#      exemption sentence in design/SKILL.md names, never by staging/ignoring.
# ============================================================================

# exemption_prefix <design-skill.md> — the directory prefix extracted from the
# carve-out sentence; empty when the sentence is gone.
exemption_prefix() {
  local p
  p=$(grep -F -- 'are NOT subject to this gate' "$1" \
    | grep -oE '`docs/design-brief/[^`]*`' | head -n 1 | tr -d '`' || true)
  [[ -n "$p" ]] || { echo ""; return 0; }
  echo "${p%/*}/"
}

# t8_run <design-skill.md> — 0 when the filtered porcelain equals the baseline.
t8_run() {
  local skill="$1" work rc=0
  work=$(mktemp -d "${TMPDIR:-/tmp}/cc-test-design-brief.XXXXXX")
  (
    cd "$work"
    git init -q
    mkdir -p docs
    printf '# docs\n' > docs/README.md
    git add docs/README.md
    git -c user.name=t -c user.email=t@example.invalid commit -q -m 'track docs/'
    baseline=$(git status --porcelain)
    mkdir -p docs/design-brief
    cp "$fixtures/brief/OK-full.md" docs/design-brief/docs-x.md
    raw=$(git status --porcelain)
    [[ -n "$raw" ]] || exit 3          # the brief must be visible to porcelain at all
    prefix=$(exemption_prefix "$skill")
    if [[ -n "$prefix" ]]; then
      filtered=$(printf '%s\n' "$raw" | grep -vF -- "$prefix" || true)
    else
      filtered="$raw"                  # no exemption sentence → nothing is filtered
    fi
    [[ "$filtered" == "$baseline" ]]
  ) || rc=$?
  rm -rf "$work"
  return "$rc"
}

expect_rc 0 "T8 gate exemption OK (real design/SKILL.md)" t8_run "$DESIGN"

t8_mutant=$(mktemp "${TMPDIR:-/tmp}/cc-test-design-brief-skill.XXXXXX")
grep -vF -- 'are NOT subject to this gate' "$DESIGN" > "$t8_mutant" || true
expect_rc 1 "T8 gate exemption FAIL (exemption sentence removed)" t8_run "$t8_mutant"
rm -f "$t8_mutant"

# ============================================================================
# T9 — pending-leg marker: wait-or-recover vs stale-aside
# ============================================================================

t9_state=$(mktemp -d "${TMPDIR:-/tmp}/cc-test-design-brief-state.XXXXXX")
expect_out "wait-or-recover" "T9 leg OK-pending → wait-or-recover" \
  check_leg "$fixtures/leg/OK-pending.json" "BRIEF_SHA_CURRENT" "$t9_state"
expect_out "stale-aside" "T9 leg OK-stale → stale-aside" \
  check_leg "$fixtures/leg/OK-stale.json" "BRIEF_SHA_CURRENT" "$t9_state"
# mutation: a matching brief sha must never be read as stale
t9_mut=$(check_leg "$fixtures/leg/OK-pending.json" "BRIEF_SHA_CURRENT" "$t9_state")
if [[ "$t9_mut" == "stale-aside" ]]; then
  fail "T9 mutation: matching brief_sha256 judged stale"
else
  pass "T9 mutation: matching brief_sha256 not judged stale"
fi
# with the OK artifact set in place the same marker resolves to done
cp "$fixtures/artifact/OK/design-doc.md" "$t9_state/design-doc.md"
cp "$fixtures/artifact/OK/presentation.md" "$t9_state/presentation.md"
expect_out "done" "T9 leg OK-pending + OK artifacts → done" \
  check_leg "$fixtures/leg/OK-pending.json" "BRIEF_SHA_CURRENT" "$t9_state"
cp "$fixtures/park/OK.md" "$t9_state/park.md"
expect_out "parked" "T9 leg OK-pending + park.md → parked" \
  check_leg "$fixtures/leg/OK-pending.json" "BRIEF_SHA_CURRENT" "$t9_state"
rm -rf "$t9_state"

# ============================================================================
# T10 — artifact predicate (four conjuncts; an exit code is not one of them)
# ============================================================================

expect_rc 0 "T10 artifact OK" \
  check_artifact "$fixtures/artifact/OK/design-doc.md" "$fixtures/artifact/OK/presentation.md"
expect_rc 1 "T10 artifact FAIL-no-presentation" \
  check_artifact "$fixtures/artifact/FAIL-no-presentation/design-doc.md" "$fixtures/artifact/FAIL-no-presentation/presentation.md"
expect_rc 1 "T10 artifact FAIL-running-row" \
  check_artifact "$fixtures/artifact/FAIL-running-row/design-doc.md" "$fixtures/artifact/FAIL-running-row/presentation.md"
expect_rc 1 "T10 artifact FAIL-bad-header-version" \
  check_artifact "$fixtures/artifact/FAIL-bad-header-version/design-doc.md" "$fixtures/artifact/FAIL-bad-header-version/presentation.md"
expect_rc 1 "T10 artifact FAIL-running-row with exit_code=0 still fails" \
  check_artifact "$fixtures/artifact/FAIL-running-row/design-doc.md" "$fixtures/artifact/FAIL-running-row/presentation.md" 0

# ============================================================================
# T11 — park record
# ============================================================================

expect_rc 0 "T11 park OK"                  check_park "$fixtures/park/OK.md"
expect_rc 1 "T11 park FAIL-summarized"     check_park "$fixtures/park/FAIL-summarized.md"
expect_rc 1 "T11 park FAIL-unknown-site"   check_park "$fixtures/park/FAIL-unknown-site.md"
expect_rc 1 "T11 park FAIL-five-questions" check_park "$fixtures/park/FAIL-five-questions.md"

# ============================================================================
# T13 — re-dispatch floor
# ============================================================================

expect_rc 0 "T13 redispatch OK-redispatch-0"   check_redispatch "$fixtures/leg/OK-redispatch-0.json"
expect_rc 1 "T13 redispatch FAIL-redispatch-2" check_redispatch "$fixtures/leg/FAIL-redispatch-2.json"

# ============================================================================
# T6 — CFI-U0 pin: the surface lint goes red when the substitution sentence
#      is deleted from the leg, and stays green on the shipped file.
# ============================================================================

t6_root=$(mktemp -d "${TMPDIR:-/tmp}/cc-test-design-brief-skills.XXXXXX")
mkdir -p "$t6_root/design-discuss-unattended"
cp "$LEG" "$t6_root/design-discuss-unattended/SKILL.md"
rc=0
SKILLS_ROOT="$t6_root" bash "$SURFACE_LINT" >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "0" ]]; then pass "T6 surface lint green on shipped leg"; else fail "T6 surface lint red on shipped leg (rc=$rc)"; fi

sed 's/this arm resolves that terminus to `park`/SENTENCE REMOVED/' "$LEG" \
  > "$t6_root/design-discuss-unattended/SKILL.md"
rc=0
SKILLS_ROOT="$t6_root" bash "$SURFACE_LINT" >/dev/null 2>&1 || rc=$?
if [[ "$rc" != "0" ]]; then pass "T6 surface lint red when CFI-U0 sentence removed"; else fail "T6 surface lint green with CFI-U0 sentence removed"; fi
rm -rf "$t6_root"

# ============================================================================
# Literal cross-pin — the two real SKILL.md files carry the same strings
# ============================================================================

pin_in() {
  local lit="$1" file="$2" label="$3"
  if grep -qF -- "$lit" "$file"; then
    pass "pin: $label carries $lit"
  else
    fail "pin: $label lacks $lit"
  fi
}

for s in "${PARK_SITES[@]}"; do
  pin_in "\`$s\`" "$LEG" "leg"
done
pin_in 'cc-design-park v1' "$LEG" "leg"
pin_in 'cc-design-presentation v1' "$LEG" "leg"
pin_in "$COHERENCE_HEADER_TOKEN" "$LEG" "leg"
pin_in 'cc-design-brief v1' "$LEG" "leg"
pin_in 'redispatch_count' "$LEG" "leg"
for k in "${SHAPE_FIELDS[@]}"; do
  pin_in "$k" "$LEG" "leg"
  pin_in "$k" "$DESIGN" "design"
done
pin_in 'cc-design-brief v1' "$DESIGN" "design"
pin_in "$BRIEF_TERMINATOR" "$DESIGN" "design"
pin_in "$BRIEF_TERMINATOR" "$LEG" "leg"
while IFS= read -r blk; do
  [[ -n "$blk" ]] || continue
  pin_in "\`$blk\`" "$DESIGN" "design (dispatch block)"
  pin_in "\`$blk\`" "$LEG" "leg (Step 1 guard)"
done <<EOF
$BRIEF_BLOCKS
EOF
pin_in 'cc-design-park v1' "$DESIGN" "design"
pin_in 'cc-design-presentation v1' "$DESIGN" "design"
pin_in "$COHERENCE_HEADER_TOKEN" "$DESIGN" "design"
pin_in 'redispatch_count' "$DESIGN" "design"

# ============================================================================

echo "test-design-brief: $passed passed, $failures failed"
if (( failures > 0 )); then
  exit 1
fi
exit 0
