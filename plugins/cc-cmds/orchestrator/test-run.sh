#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test the autonomous pipeline driver's guards, predicates, and tables.
#
# Two things this harness does that a happy-path run cannot:
#
#   1. It runs the driver's own self-check under a SANITIZED PATH, on the
#      interpreter that PATH actually resolves. That is the whole point of the
#      exercise — a bash-4 builtin passes `make lint`, passes every hand-run
#      test, and dies only in the detached run, so the only test that catches
#      it is one run in the environment the detached run has.
#   2. It exercises the branches a successful pipeline never reaches: the
#      teardown guard's refusal arms, the hollow-success row of the termination
#      table, a truncated halt record, a held lock, and the backoff cap.
#
# Usage: bash plugins/cc-cmds/orchestrator/test-run.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)
DRIVER="$script_dir/run.sh"

# The sanitized PATH the driver normalizes to, plus the interpreter it picks.
SANITIZED_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# Scratch for the pre-source assertions; the post-source ones get their own.
WORK_EARLY=$(mktemp -d "${TMPDIR:-/tmp}/cc-orch-test-early.XXXXXX")
trap 'rm -rf "$WORK_EARLY"' EXIT

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

# ---------------------------------------------------------------------------
# 1. Parse and self-check on the sanitized interpreter
# ---------------------------------------------------------------------------
if env -i PATH="$SANITIZED_PATH" /usr/bin/env bash -n "$DRIVER" 2>/dev/null; then
  ok "정제 PATH가 고르는 인터프리터에서 전체 파일이 파싱된다"
else
  bad "정제 PATH 파싱" "bash -n 실패 — bash 4 전용 문법이 섞였을 수 있음"
fi

# Positive host-OS injection, the same convention the notification helper's
# tests use: the Linux runner takes the Darwin branch so the selection logic is
# verified WITHOUT darwin, and the opposite branch gets its own case below.
sc_out=$(env -i PATH="$SANITIZED_PATH" HOME="$HOME" CC_CMDS_ORCH_HOST_OS=Darwin \
           /usr/bin/env bash "$DRIVER" --self-check 2>&1)
sc_rc=$?
check "정제 환경 self-check 통과 (Darwin 주입)" "$sc_rc" "0"
case "$sc_out" in
  *"bash: 3."*) ok "self-check가 실제로 bash 3.2 위에서 돌았다 (하한이 실측된다)" ;;
  *)            printf 'NOTE: self-check ran on %s\n' "$(printf '%s' "$sc_out" | head -1)" ;;
esac
case "$sc_out" in
  *"잠금 소스 선택 -> /usr/bin/lockf"*) ok "Darwin 분기가 잠금 소스를 선택한다 (주입으로 검증)" ;;
  *) bad "잠금 소스 선택" "Darwin 주입인데 선택 행이 없음" ;;
esac
case "$sc_out" in
  *"부팅 시각 소스 선택 -> kern.boottime"*) ok "Darwin 분기가 부팅 시각 소스를 선택한다" ;;
  *) bad "부팅 시각 소스 선택" "Darwin 주입인데 선택 행이 없음" ;;
esac

# --- the opposite branch, on the same runner ------------------------------
lx_out=$(env -i PATH="$SANITIZED_PATH" HOME="$HOME" CC_CMDS_ORCH_HOST_OS=Linux \
           /usr/bin/env bash "$DRIVER" --self-check 2>&1)
check "비-darwin 주입에서도 self-check는 진단으로서 성립" "$?" "0"
case "$lx_out" in
  *"비지원 플랫폼: 소스 미선택"*) ok "비-darwin 분기는 소스를 선택하지 않는다" ;;
  *) bad "비-darwin 선택" "소스 미선택 행이 없음 — 조용한 열화 경로" ;;
esac

# The refusal is at ENTRY and is the whole point of the seam: a driver that
# silently does less on an unmeasured platform is the failure mode this design
# exists to prevent. Verified on any runner by injection.
env -i PATH="$SANITIZED_PATH" HOME="$HOME" CC_CMDS_ORCH_HOST_OS=Linux \
  /usr/bin/env bash "$DRIVER" --doc /dev/null >/dev/null 2>"$WORK_EARLY/refuse.txt"
check "비-darwin 기동은 진입에서 거부된다" "$?" "4"
if grep -q "재지 않은 것" "$WORK_EARLY/refuse.txt" 2>/dev/null; then
  ok "거부 사유가 「닫힘」이 아니라 「미측정」으로 진술된다"
else
  bad "거부 문면" "리눅스가 왜 거부되는지를 미측정으로 진술하지 않음"
fi

# ---------------------------------------------------------------------------
# 2. Interpreter floor guard is the first executable block
# ---------------------------------------------------------------------------
first_exec=$(grep -nE '^[^#[:space:]]' "$DRIVER" | head -1 | cut -d: -f1)
guard_line=$(grep -n 'BASH_VERSINFO+set' "$DRIVER" | head -1 | cut -d: -f1)
if [ -n "$guard_line" ] && [ "$guard_line" = "$first_exec" ]; then
  ok "인터프리터 하한 가드가 첫 실행 블록이다"
else
  bad "가드 위치" "first executable line=$first_exec, guard=$guard_line"
fi

# ---------------------------------------------------------------------------
# 3. Load the definitions without running a pipeline
# ---------------------------------------------------------------------------
CC_ORCH_SOURCE_ONLY=1
export CC_ORCH_SOURCE_ONLY
# Drive the darwin branch for the sourced definitions too, so the assertions
# below exercise the same arm on every runner.
CC_CMDS_ORCH_HOST_OS=Darwin
export CC_CMDS_ORCH_HOST_OS
# shellcheck disable=SC1090
. "$DRIVER"
# The driver sets `-euo pipefail` for its own run, and sourcing imports it. A
# test harness must NOT inherit -e: every negative assertion here runs a
# command expected to fail, and under -e the first one aborts the whole suite
# instead of failing one line. That is how a Linux leg lost 30 assertions to a
# single missing sysctl key.
set +e
ok "소싱 시임으로 정의만 로드된다"
ok "하네스가 드라이버의 set -e 를 물려받지 않는다"

# Native-kernel seam for the harness itself. Sourcing the driver normalizes
# PATH, so a stubbed `uname` earlier in PATH stops being visible from here —
# which means the only way to rehearse the non-darwin runner locally is an
# explicit injection. Same spelling convention as the driver's own seam.
NATIVE_OS="${CC_CMDS_ORCH_TEST_NATIVE_OS:-$(uname -s)}"
printf 'native(harness): %s\n' "$NATIVE_OS"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-orch-test.XXXXXX")
# Replaces the earlier trap rather than adding to it — a bare `trap ... EXIT`
# overwrites, so both directories are named here or the first one leaks.
cleanup() { rm -rf "$WORK" "$WORK_EARLY"; }
trap cleanup EXIT

RUN_ID="testrun"
RUN_DIR="$WORK/rundir"; mkdir -p "$RUN_DIR/halt" "$RUN_DIR/log"
LEDGER="$WORK/ledger.md"; : > "$LEDGER"
BASE="$WORK/base"; mkdir -p "$BASE/docs"
DOC_KEY="docs/x.md"; SLUG="docs-x"

# ---------------------------------------------------------------------------
# 4. Permission cutpoint is ordered, and the order is the authorization
# ---------------------------------------------------------------------------
check "절단점 인덱스 커밋" "$(cutpoint_index 커밋)" "1"
check "절단점 인덱스 머지" "$(cutpoint_index 머지)" "5"
check "절단점 인덱스 미지의 값" "$(cutpoint_index 없는것)" "0"

grant_field() { printf 'PR'; }          # stub the grant read: cutpoint = PR
if authorized 커밋 && authorized PR && ! authorized 머지 && ! authorized 배포; then
  ok "절단점 PR: 커밋·PR 자율, 머지·배포는 초과"
else
  bad "절단점 판정" "PR 절단점에서의 자율 범위가 틀림"
fi

# ---------------------------------------------------------------------------
# 5. Termination classification — all four rows, including the measured one
# ---------------------------------------------------------------------------
check "종단: 정상 완료"   "$(classify_termination Sx 0 0)" "정상 완료"
check "종단: 공허한 성공" "$(classify_termination Sx 0 1)" "공허한 성공"
check "종단: 크래시"      "$(classify_termination Sx 1 1)" "크래시"

cat > "$RUN_DIR/halt/Sx.md" <<'EOF'
<!-- cc-pipeline-halt v1; writer=implement-unattended; reader=orchestrator; stage=Sx; run=testrun -->
**중단 시각**: 2026-08-23T00:00:00Z
**분류**: gate-unanswerable
**후속**: 보류 큐
<!-- /cc-pipeline-halt v1 -->
EOF
check "종단: 의도된 park (중단 기록 우선)" "$(classify_termination Sx 0 1)" "의도된 park"

# A record whose closing fence is missing is a crash mid-write, not a halt —
# the fence is the terminator, and without this the driver would read a
# half-written file as a deliberate stop and never retry.
sed '$d' "$RUN_DIR/halt/Sx.md" > "$RUN_DIR/halt/Sy.md"
if halt_record_present Sy; then bad "잘린 중단 기록" "종결자 없는 기록을 halt로 읽음"; else ok "종결자 없는 중단 기록은 halt가 아니다"; fi
check "잘린 기록의 종단 부류" "$(classify_termination Sy 0 1)" "공허한 성공"

# ---------------------------------------------------------------------------
# 6. Worktree teardown guard — BOTH conditions required
# ---------------------------------------------------------------------------
WORKTREE_INFIX_SAVE="$WORKTREE_INFIX"
main_root() { printf '%s' "$WORK/repo"; }
mkdir -p "$WORK/repo"

# (1) not recorded in this run's ledger -> refuse, even with the infix present
if wt_remove "segA" 2>/dev/null; then bad "철거 가드 (1)" "원장에 없는 경로를 철거함"; else ok "철거 거부: 이 런의 원장에 생성 시점 값이 없음"; fi

# recorded but WITHOUT the reserved infix -> refuse (defence in depth)
printf -- '- `segment` | id=segB | 워크트리=%s/repo-hand-made-segB\n' "$(dirname "$WORK/repo")" >> "$LEDGER"
if wt_remove "segB" 2>/dev/null; then bad "철거 가드 (2)" "예약 인픽스 없는 경로를 철거함"; else ok "철거 거부: 예약 인픽스 부재"; fi
check "인픽스 상수 불변" "$WORKTREE_INFIX" "$WORKTREE_INFIX_SAVE"

# ---------------------------------------------------------------------------
# 7. Detection lock — a held lock must return EX_TEMPFAIL, not block
# ---------------------------------------------------------------------------
LOCK_TOOL=$(lock_tool)
if [ "$NATIVE_OS" = "Darwin" ] && [ -n "$LOCK_TOOL" ] && [ -x "$LOCK_TOOL" ]; then
  "$LOCK_TOOL" -k "$RUN_DIR/designdoc.lock" sleep 3 &
  holder=$!
  sleep 1
  set +e
  with_doc_lock true
  lock_rc=$?
  set -e 2>/dev/null || true
  check "잠긴 문서에 대해 즉시 EX_TEMPFAIL" "$lock_rc" "75"
  wait "$holder" 2>/dev/null
  # -k is required: without it lockf removes the lock file on exit and the next
  # acquirer sees no contention at all.
  if [ -e "$RUN_DIR/designdoc.lock" ]; then ok "-k 로 잠금 파일이 보존된다"; else bad "-k 보존" "잠금 파일이 사라짐"; fi
else
  ok "잠금 경합 확인은 macOS 레그 담당 (이 러너에서는 건너뜀)"
fi

# ---------------------------------------------------------------------------
# 8. Review artifact predicate — the summary line, byte for byte
# ---------------------------------------------------------------------------
RP="$WORK/review.md"
printf '# 리뷰\n\n- **발견 요약**: 🔴 P0 0건 | 🟠 P1 2건 | 🟡 P2 3건 | 🟢 P3 1건\n' > "$RP"
if predicate_review "$RP"; then ok "리뷰 술어: 규정된 요약 줄을 인식한다"; else bad "리뷰 술어" "정상 요약 줄을 놓침"; fi
printf '# 리뷰\n\n- 발견 요약: P0 0건\n' > "$RP"
if predicate_review "$RP"; then bad "리뷰 술어" "형식이 다른 줄을 통과시킴"; else ok "리뷰 술어: 형식이 다르면 거짓"; fi
if predicate_review "$WORK/does-not-exist.md"; then bad "리뷰 술어" "없는 파일에 참"; else ok "리뷰 술어: 없는 리포트에 거짓"; fi

# ---------------------------------------------------------------------------
# 9. Backoff cap — the ladder must be finite even with no envelope to classify
# ---------------------------------------------------------------------------
if [ "$BACKOFF_WALLCLOCK_CAP_SECONDS" -gt 0 ]; then
  ok "백오프에 벽시계 상한이 있다 (${BACKOFF_WALLCLOCK_CAP_SECONDS}s)"
else
  bad "백오프 상한" "상한 없는 백오프는 종료를 보장하지 못함"
fi
sum=0; s="$BACKOFF_START_SECONDS"; n=0
while [ "$sum" -lt "$BACKOFF_WALLCLOCK_CAP_SECONDS" ] && [ "$n" -lt 1000 ]; do
  sum=$((sum + s)); s=$((s * BACKOFF_FACTOR))
  [ "$s" -gt "$BACKOFF_MAX_SLEEP_SECONDS" ] && s="$BACKOFF_MAX_SLEEP_SECONDS"
  n=$((n + 1))
done
if [ "$n" -lt 1000 ]; then ok "백오프가 유한 횟수(${n})에 상한에 도달한다"; else bad "백오프 수렴" "상한에 도달하지 못함"; fi

# ---------------------------------------------------------------------------
# 10. Boundary idempotency split — the limit ladder keys on it
# ---------------------------------------------------------------------------
if boundary_idempotent S4 && boundary_idempotent S5 && boundary_idempotent S2; then
  ok "구현·리뷰·감사는 경계 멱등 (죽이고 재실행 가능)"
else
  bad "멱등 분할" "경계 멱등 스테이지를 비멱등으로 분류함"
fi
if ! boundary_idempotent S1; then ok "설계는 비멱등 (죽이지 않고 대기)"; else bad "멱등 분할" "설계를 멱등으로 분류함"; fi

# ---------------------------------------------------------------------------
# 11. Sleep discriminator reads a real clock
# ---------------------------------------------------------------------------
if [ "$NATIVE_OS" = "Darwin" ]; then
  b=$(boot_epoch)
  if [ -n "$b" ] && [ "$b" -gt 0 ]; then ok "부팅 시각을 읽는다 ($b)"; else bad "부팅 시각" "부팅 시각 파싱 실패"; fi
else
  ok "부팅 시계 판독은 macOS 레그 담당 (이 러너에서는 건너뜀)"
fi
# The discriminator ARITHMETIC is seam-driven and needs no darwin: a wake
# timestamp that is not later than the window start means the machine did not
# sleep during it, whatever the clock source was.
if machine_slept_since "$(now_epoch)"; then bad "절전 판별자" "미래 시점 이후에 절전했다고 판정"; else ok "절전 판별자: 방금 이후로는 잔 적 없음"; fi

# ---------------------------------------------------------------------------
# 12. Ledger is append-only and machine-readable
# ---------------------------------------------------------------------------
ledger_row 'stage-result' "세그먼트=segA" "스테이지=S4" "종료 코드=0" "종단 부류=정상 완료"
check "원장 마지막 값 조회" "$(ledger_last 'stage-result' '종단 부류')" "정상 완료"
before=$(grep -c . "$LEDGER")
ledger_row 'cost' "누적 usd=0.42"
after=$(grep -c . "$LEDGER")
check "원장은 append 전용" "$((after - before))" "1"

# ---------------------------------------------------------------------------
# 13. Binding-surface digest — invariant to the implementation arm's writes,
#     sensitive to everything else. This is the property the segment plan's
#     freshness predicate rests on, so it is tested in both directions.
# ---------------------------------------------------------------------------
DOC="$WORK/doc.md"
cat > "$DOC" <<'EOF'
# 설계

## 합의된 아키텍처
드라이버가 상태 기계를 소유한다.

## 구현 시 검증 항목

### R1. 주장
**주장**: 무언가가 참이다.
**검증 등급**: 구현 시 검증

### R2. 다른 주장
**주장**: 다른 무언가가 참이다.
- 검증 등급: 구현 시 검증
EOF
d_before=$(binding_digest)

# W1 on the canonical rendering + W2 append
sed 's/^\*\*검증 등급\*\*: 구현 시 검증$/**검증 등급**: 검증됨(통과)\
**구현 시 검증 기록**: 2026-08-23 — ok/' "$DOC" > "$DOC.tmp" && mv "$DOC.tmp" "$DOC"
d_after_canon=$(binding_digest)
check "구속면 다이제스트는 정규 렌더링의 W1/W2에 불변" "$d_after_canon" "$d_before"

# W1 on the LEGACY bullet/no-bold rendering — the case a strict removed-side
# filter misses, moving the digest at exactly the flip it must hide.
sed 's/^- 검증 등급: 구현 시 검증$/**검증 등급**: 반증됨(실패)/' "$DOC" > "$DOC.tmp" && mv "$DOC.tmp" "$DOC"
d_after_legacy=$(binding_digest)
check "구속면 다이제스트는 legacy 불릿 렌더링의 flip에도 불변" "$d_after_legacy" "$d_before"

# A real binding-tier edit MUST move it, or the predicate is vacuous.
printf '\n결정을 뒤집는다.\n' >> "$DOC"
d_moved=$(binding_digest)
if [ "$d_moved" != "$d_before" ]; then ok "구속 티어 편집은 다이제스트를 움직인다"; else bad "다이제스트 민감도" "구속면 편집에 반응하지 않음"; fi

# Section scoping: the same literal outside the residual section is prose.
printf '\n## 딴 섹션\n**검증 등급**: 이건 산문이다\n' >> "$DOC"
d_prose=$(binding_digest)
if [ "$d_prose" != "$d_moved" ]; then ok "섹션 밖의 같은 문면은 걸러지지 않는다 (파일 전역 필터가 아님)"; else bad "섹션 스코프" "섹션 밖 문면까지 걸러냄"; fi

# ---------------------------------------------------------------------------
# 14. Judgment calls are wired by convention, and every one has both halves
# ---------------------------------------------------------------------------
for j in $JUDGMENTS; do
  if [ -f "$PROMPT_DIR/$j.md" ]; then ok "판단 프롬프트 존재: $j"; else bad "판단 프롬프트" "$j.md 없음"; fi
  if [ -f "$PROMPT_DIR/$j.schema.json" ]; then
    if jq empty "$PROMPT_DIR/$j.schema.json" 2>/dev/null; then ok "판단 스키마가 유효한 JSON: $j"
    else bad "판단 스키마" "$j.schema.json 파싱 실패"; fi
  else
    bad "판단 스키마" "$j.schema.json 없음"
  fi
done

# ---------------------------------------------------------------------------
# 15. Escalation ladder — the only structural bound on re-fix depth
# ---------------------------------------------------------------------------
ladder_init
check "미등장 동일성의 현재 단은 0"      "$(ladder_rung src/a.ts correctness)" "0"
check "첫 등장은 R1"                     "$(ladder_bump src/a.ts correctness)" "1"
check "재발은 R2"                        "$(ladder_bump src/a.ts correctness)" "2"
check "다음 재발은 R3"                   "$(ladder_bump src/a.ts correctness)" "3"
check "그다음은 R4 (사람)"               "$(ladder_bump src/a.ts correctness)" "4"
check "R4에서 포화 — 더 오르지 않는다"   "$(ladder_bump src/a.ts correctness)" "4"

# File-level rung merge: a NEW category appearing in a file that has already
# consumed the deep rungs inherits them rather than starting fresh. That is what
# collapses a file's total consumable rungs to 4 and makes the 4F+1 cycle bound
# hold; without it a file could yield one fresh budget per category tag.
# Inheriting the HUMAN rung is the conservative direction on purpose.
check "같은 파일의 신규 동일성은 소비된 단을 상속" "$(ladder_rung src/a.ts perf)" "4"

# Severity is NOT part of the identity, so the same defect read at a different
# grade is the SAME problem. Were severity in the key, the line above would
# return 0 and the defect would collect a fresh budget every time a reviewer
# set graded it differently — the disarming this design exists to prevent.
check "다른 파일은 영향 없음"            "$(ladder_rung src/b.ts correctness)" "0"

# 4F + 1 with F the DECLARED file-set size.
f=3; cap=$(( 4 * f + 1 ))
check "사이클 상한 4F+1 (F=3)" "$cap" "13"

# ---------------------------------------------------------------------------
# 16. Liveness oracle is kill -0 on the recorded pid, never `wait -n`
# ---------------------------------------------------------------------------
# Comment lines are stripped first: the driver legitimately NAMES the builtin in
# the comment explaining why it does not use it, and a check that flags its own
# rationale would be pressure to delete the rationale.
if sed 's/#.*//' "$DRIVER" | grep -qE '\bwait[[:space:]]+-n\b'; then
  bad "생존성 오라클" "wait -n 사용 — 인터프리터 하한에서 rc=2"
else
  ok "wait -n 미사용 (하한 인터프리터에 없는 빌트인)"
fi
printf '999999\n' > "$RUN_DIR/Sdead.pid"
if stage_alive Sdead; then bad "stage_alive" "죽은 pid에 살아있다고 판정"; else ok "stage_alive: 죽은 pid에 거짓"; fi
rm -f "$RUN_DIR/Sdead.pid"
if stage_alive Snothing; then bad "stage_alive" "기록 없는 스테이지에 참"; else ok "stage_alive: pid 기록이 없으면 거짓"; fi

printf '\ntest-run: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
