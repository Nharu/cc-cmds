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

# 미인식 토큰은 조용한 0이 아니라 실패다. 0을 돌려주면 authorized()가 그것을
# 「인가 없음」으로 읽어 조용히 전부 거부하고, 오타 하나가 밤 전체의 산출을
# 착지시키지 못한 채 아무 원인도 보고하지 않는다.
if cutpoint_index 없는것 >/dev/null 2>&1; then
  bad "미인식 절단점" "0을 돌려주고 성공했다 — 조용한 거부 경로가 살아 있다"
else
  ok "미인식 절단점 토큰은 실패로 신호된다 (조용한 0 아님)"
fi

# 표시 문면과 저장 토큰은 다른 문자열이고, 그 차이가 실제로 출하 결함이었다 —
# 사람이 읽는 사다리는 `머지 후 후속 착수`인데 저장 토큰은 `머지후착수`라
# 표시 문면으로 쓰인 인가가 아무것도 인가하지 못했다.
check "표시 문면 -> 토큰"        "$(cutpoint_token '머지 후 후속 착수')" "머지후착수"
check "토큰 -> 표시 문면"        "$(cutpoint_display 머지후착수)"        "머지 후 후속 착수"
check "표시 문면도 색인된다"     "$(cutpoint_index '머지 후 후속 착수')" "7"
check "저장 토큰도 색인된다"     "$(cutpoint_index 머지후착수)"          "7"
if cutpoint_display 없는것 >/dev/null 2>&1; then
  bad "표시 매핑" "어휘 밖 토큰에 표시 문면을 돌려줬다"
else
  ok "표시 매핑은 어휘 밖 토큰을 거부한다"
fi

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
  # Restore `+e`, never `-e`. This block wraps ONE call in `set +e`, and the
  # obvious-looking `set -e` afterwards silently re-armed the option the harness
  # spent its header explaining it must not have — on the darwin leg only, so
  # ubuntu stayed green. It went unnoticed while every later negative assertion
  # happened to sit inside an `if`; the first bare `f; rc=$?` after it ended the
  # suite mid-file with the function's own return code and no summary line.
  set +e
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
# 12b. 순차 베이스 — 세그먼트 k+1이 k의 머지를 담은 베이스에서 갈라지는가
# ---------------------------------------------------------------------------
# 머지는 서버에서 일어나므로 로컬 브랜치 ref는 전진하지 않는다. 베이스를 벗겨 낸
# 로컬 이름에서 해소하면 k+1이 k의 머지 없는 커밋에서 분기하고, 겹치는 선언 파일이
# 순차 편집이 아니라 동시 편집이 된다.
if grep -qE 'refs/remotes/origin/\$\(base_branch( "\$[a-z_]+")?\)' "$DRIVER"; then
  ok "base_sha 가 원격 추적 ref에서 해소된다"
else
  bad "base_sha" "벗겨 낸 로컬 이름에서 해소 — 로컬 ref는 전진하지 않는다"
fi
if grep -qE '^base_fetch\(\)' "$DRIVER"; then ok "base_fetch 가 존재한다"; else bad "base_fetch" "정의 없음"; fi
if sed 's/#.*//' "$DRIVER" | grep -qE 'git worktree add -b "\$branch" "\$p" HEAD'; then
  bad "wt_create" "리터럴 HEAD에서 분기 — 메인 팁은 런 내내 움직이지 않는다"
else
  ok "wt_create 가 리터럴 HEAD에서 분기하지 않는다"
fi
if sed -n '/^merge_gate()/,/^}/p' "$DRIVER" | grep -q 'base_fetch'; then
  ok "머지 직후 base_fetch 가 돈다"
else
  bad "merge_gate" "머지 뒤 refresh 없음 — 다음 세그먼트가 낡은 베이스에서 갈라진다"
fi

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

# ---------------------------------------------------------------------------
# 16b. 진행성 오라클 — 폴하는 파일이 스테이지가 도는 동안 실제로 자라는가
# ---------------------------------------------------------------------------
# 결과 envelope 은 종료 시 한 번에 쓰이므로 그것을 폴하면 살아 있는 스테이지가
# 첫 폴부터 언제나 침묵으로 읽힌다 — 어떤 N도 그것을 고치지 못한다.
if sed -n '/^resume_verdict()/,/^}/p' "$DRIVER" | grep -q 'transcript_path'; then
  ok "진행성 오라클이 트랜스크립트를 폴한다"
else
  bad "진행성 오라클" "결과 envelope 을 폴한다 — 도는 내내 0바이트라 신호가 없다"
fi
if sed -n '/^resume_verdict()/,/^}/p' "$DRIVER" | grep -qE 'log/\$stage\.json'; then
  bad "진행성 오라클" "여전히 출력 JSON 크기를 읽는다"
else
  ok "출력 JSON 크기를 진행성 신호로 쓰지 않는다"
fi
# 트랜스크립트를 찾으려면 호출자가 고른 세션 id 가 넘어가야 한다. 함수만 있고
# 호출부가 없으면 파일을 찾을 수도 없다 — 이번 반증의 직접 원인이 그것이었다.
if sed -n '/^stage_spawn()/,/^}/p' "$DRIVER" | grep -q -- '--session-id'; then
  ok "stage_spawn 이 --session-id 를 넘긴다"
else
  bad "session-id" "session_uuid 가 정의만 되고 호출부가 없다"
fi
# `--session-id` 는 유효한 UUID 를 요구한다 (맨 32-hex 는 거부됨, 실측).
uu=$(DOC_KEY=x session_uuid "S4:seg:1")
if printf '%s' "$uu" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  ok "session_uuid 가 UUID 형태를 낸다 ($uu)"
else
  bad "session_uuid" "UUID 형태가 아니다: $uu"
fi
check "session_uuid 는 결정적이다" "$(DOC_KEY=x session_uuid 'S4:seg:1')" "$uu"
if [ "$(DOC_KEY=y session_uuid 'S4:seg:1')" != "$uu" ]; then
  ok "앵커가 다르면 다른 세션 id"
else
  bad "session_uuid" "앵커가 달라도 같은 id — 두 런이 한 트랜스크립트로 별칭된다"
fi
if [ "$STALL_SILENT_POLLS" -gt 1 ]; then
  ok "침묵 상한이 1보다 크다 ($STALL_SILENT_POLLS)"
else
  bad "침묵 상한" "단일 폴로는 조용한 스테이지와 정체를 가르지 못한다"
fi

# ---------------------------------------------------------------------------
# 16c. 매니페스트 계약 — 계산되고 기록되고 **비교되는가**
# ---------------------------------------------------------------------------
# 이 절이 잡는 실패는 「필드가 없다」가 아니라 「필드가 있는데 아무도 대조하지
# 않는다」이며, 그것이 이 파이프라인에서 반복해 나온 부류다.
MF_DIR="$WORK/manifest"; mkdir -p "$MF_DIR"
MF="$MF_DIR/plan.md"
HERE=$(git rev-parse --show-toplevel)
CG=$(cd "$HERE" && git rev-parse --path-format=absolute --git-common-dir)

write_manifest() {   # write_manifest <출력> [대상맵다이제스트override] [계획다이제스트override]
  local out="$1" tdig="${2:-}" pdig="${3:-}"
  local trow="- \`target\` | 별칭=home | 메인 워크트리=$HERE | 공통 git 디렉터리=$CG | 베이스 브랜치=master | 홈=예 | 원격 슬러그=Nharu/cc-cmds | 절단점=머지 | 말단 행위 상한=없음"
  local plan='{ "steps": ["audit", "implement"] }'
  [ -n "$tdig" ] || tdig=$(printf '%s\n' "$trow" | sed 's/[[:space:]]\{1,\}/ /g' | sort | shasum -a 256 | cut -d' ' -f1)
  [ -n "$pdig" ] || pdig=$(printf '%s\n' "$plan" | shasum -a 256 | cut -d' ' -f1)
  {
    printf '# 파이프라인 런 매니페스트 — 20260825-deadbeef\n'
    printf '<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=20260825-deadbeef;\n'
    printf '     anchor-kind=repo; anchor-key=Nharu/cc-cmds;\n'
    printf '     owner-doc=(없음); origin-worktree=%s;\n' "$HERE"
    printf '     NOT a design doc; mechanism-local, never staged by a skill -->\n\n'
    printf '## 런 정체\n**킥오프 일시**: 2026-08-25T00:00:00Z\n**런 id**: 20260825-deadbeef\n'
    printf '**앵커 종류**: repo\n**앵커 키**: Nharu/cc-cmds\n**사용자 확인 문면**: 돌려라\n\n'
    printf '## 대상\n**대상 맵 다이제스트**: %s\n%s\n\n' "$tdig" "$trow"
    printf '## 요소\n**설계 문서**: (없음)\n**적용 주체**: (해당 없음)\n\n'
    printf '## 실행 계획\n**계획 다이제스트**: %s\n**승인 문면**: 진행\n' "$pdig"
    printf '```json\n%s\n```\n\n' "$plan"
    printf '## 인가\n**런 최대 절단점**: 머지\n**종료 지점**: 전부 머지\n'
    printf '**벽시계 마감**: 2026-08-26T09:00:00Z\n**시각 정합 마커**: 없음\n'
    printf '**사다리 가용 단 수**: 2\n**미선언 상황 처분**: park\n'
  } > "$out"
}

MANIFEST="$MF"; write_manifest "$MF"
if ( check_manifest ) >/dev/null 2>&1; then
  ok "정상 매니페스트가 열 연언을 통과한다"
else
  bad "매니페스트 검사" "정상 매니페스트가 거부됐다: $( ( check_manifest ) 2>&1 | tail -1 )"
fi

# 앵커가 문서가 아니어도 성립해야 한다 — 그것이 이 변경의 요점이다.
check "앵커 종류가 문서가 아니어도 읽힌다" "$(manifest_field '런 정체' '앵커 종류')" "repo"
check "대상 별칭 조회"                     "$(target_field home '원격 슬러그')"      "Nharu/cc-cmds"
check "대상별 절단점 조회"                 "$(target_field home '절단점')"           "머지"

# 5·6 — 다이제스트가 실제로 비교되는가. 이것이 없으면 필드는 장식이다.
write_manifest "$MF" "0000000000000000000000000000000000000000000000000000000000000000"
if ( check_manifest ) >/dev/null 2>&1; then
  bad "대상 맵 다이제스트" "틀린 다이제스트를 통과시켰다 — 기록만 되고 비교되지 않는다"
else
  ok "대상 맵 다이제스트 불일치가 거부된다"
fi
write_manifest "$MF" "" "1111111111111111111111111111111111111111111111111111111111111111"
if ( check_manifest ) >/dev/null 2>&1; then
  bad "계획 다이제스트" "틀린 다이제스트를 통과시켰다"
else
  ok "계획 다이제스트 불일치가 거부된다"
fi

# 10 — 소유 증명은 여전히 fail-closed 다. 증명을 바꾼 것이지 뺀 것이 아니다.
write_manifest "$MF"; sed 's/run-id=20260825-deadbeef;//' "$MF" > "$MF.x" && mv "$MF.x" "$MF"
if ( check_manifest ) >/dev/null 2>&1; then
  bad "소유 증명" "run-id= 없이 통과했다 — fail-closed 가 아니다"
else
  ok "run-id= 부재는 fail-closed"
fi
write_manifest "$MF"; sed 's/^\*\*런 id\*\*: .*/**런 id**: 다른값/' "$MF" > "$MF.x" && mv "$MF.x" "$MF"
if ( check_manifest ) >/dev/null 2>&1; then
  bad "소유 증명" "헤더와 본문의 런 id 가 달라도 통과했다"
else
  ok "헤더와 본문의 런 id 불일치가 거부된다"
fi

# 8 — 「없음」을 받는 검증자가 있으면 필수성은 성립하지 않는다.
write_manifest "$MF"; sed 's/^\*\*벽시계 마감\*\*: .*/**벽시계 마감**: 없음/' "$MF" > "$MF.x" && mv "$MF.x" "$MF"
if ( check_manifest ) >/dev/null 2>&1; then
  bad "벽시계 마감" "「없음」을 받아들였다 — 최외곽 상한이 성립하지 않는다"
else
  ok "벽시계 마감의 「없음」이 거부된다"
fi

# 2 — append 형식이 없으므로 둘째 인가 블록은 잔재가 아니라 변조다.
write_manifest "$MF"; printf '\n## 인가\n**런 최대 절단점**: 배포\n' >> "$MF"
if ( check_manifest ) >/dev/null 2>&1; then
  bad "인가 블록" "둘째 인가 블록을 통과시켰다 — 더 넓은 인가가 조용히 들어온다"
else
  ok "둘째 인가 블록이 거부된다"
fi

# 4 — 검증 없는 레포 집합 선언은 조용한 폴백을 살려 둔다.
write_manifest "$MF"; sed "s|메인 워크트리=$HERE|메인 워크트리=/없는/경로|" "$MF" > "$MF.x" && mv "$MF.x" "$MF"
if ( check_manifest ) >/dev/null 2>&1; then
  bad "대상 프리플라이트" "실재하지 않는 워크트리를 통과시켰다"
else
  ok "대상 프리플라이트가 실재하지 않는 워크트리를 거부한다"
fi

# 7 — 미인식 절단점은 조용한 0이 아니라 하드 오류다.
write_manifest "$MF"; sed 's/절단점=머지 |/절단점=없는토큰 |/' "$MF" > "$MF.x" && mv "$MF.x" "$MF"
if ( check_manifest ) >/dev/null 2>&1; then
  bad "절단점 토큰" "어휘 밖 토큰을 통과시켰다"
else
  ok "대상 행의 어휘 밖 절단점이 거부된다"
fi

MANIFEST=""

# ---------------------------------------------------------------------------
# 17. 워크플로 선언 파스 — 펜스 역학 넷과 3분기 술어
# ---------------------------------------------------------------------------
# 네 역학은 각각 「정답을 구성으로 아는」 픽스처로 잰다. 코퍼스 대조는 두 구현이
# 서로 맞는지만 말해 주지 둘 다 틀린 경우를 가르지 못하므로, 정답을 만들어 두고
# 파서에게 묻는 쪽이 이 항목이 요구하는 판정이다.
SLI="$WORK/slicing"; mkdir -p "$SLI"

# (a) ~~~ 펜스 — 백틱과 섞이지 않는다. 안의 표제는 보이지 않아야 한다.
cat > "$SLI/tilde.md" <<'FIXA'
# t
~~~
## 구현 슬라이싱
~~~
## 구현 슬라이싱

**슬라이스 수**: 1

### 슬라이스 A

**스킬**: implement
**레포**: `o/r`
**선언 파일**: `a.txt`
**선행**: 없음
**절단점**: 머지
FIXA
slicing_present "$SLI/tilde.md"; rc=$?
check "(a) ~~~ 펜스 안의 표제는 파스에 들어가지 않는다" "$rc" "0"
check "(a) 펜스 밖 표제 하나만 남는다" "$(defenced "$SLI/tilde.md" | grep -cxF '## 구현 슬라이싱')" "1"

# (b) 백틱 넷 이상 — 안에 중첩된 ``` 는 닫지 못한다. 이 설계 문서 자신의 형태다.
cat > "$SLI/nested.md" <<'FIXB'
# n
````markdown
## 구현 슬라이싱

```text
## 구현 슬라이싱
```
````
## 구현 슬라이싱

**슬라이스 수**: 1

### 슬라이스 A

**스킬**: implement
**레포**: `o/r`
**선언 파일**: `a.txt`
**선행**: 없음
**절단점**: 머지
FIXB
check "(b) 중첩 펜스에서 파서가 「밖」으로 빠지지 않는다" \
  "$(defenced "$SLI/nested.md" | grep -cxF '## 구현 슬라이싱')" "1"
slicing_present "$SLI/nested.md"; rc=$?
check "(b) 백틱4+ 문서의 존재 판정" "$rc" "0"

# (c) 들여쓴 펜스 — 여는 줄이 들여써져도 같은 span 이다.
cat > "$SLI/indent.md" <<'FIXC'
# i

- 목록 안:

    ```
    ## 구현 슬라이싱
    ```

## 구현 슬라이싱

**슬라이스 수**: 1

### 슬라이스 A

**스킬**: implement
**레포**: `o/r`
**선언 파일**: `a.txt`
**선행**: 없음
**절단점**: 머지
FIXC
check "(c) 들여쓴 펜스 안의 표제도 보이지 않는다" \
  "$(defenced "$SLI/indent.md" | grep -cxF '## 구현 슬라이싱')" "1"

# (d) 닫히지 않은 펜스 — 조용한 강등이 아니라 하드 오류(rc=3)다. 이후 전부가
#     「안」으로 읽히므로 선언한 문서가 통치되지 않은 것으로 취급된다.
cat > "$SLI/unclosed.md" <<'FIXD'
# u
```
## 구현 슬라이싱
FIXD
slicing_present "$SLI/unclosed.md"; rc=$?
check "(d) 닫히지 않은 펜스는 하드 오류로 판정된다" "$rc" "3"
if fence_unclosed "$SLI/nested.md"; then
  bad "(d) 대조군" "닫힌 문서를 닫히지 않았다고 판정했다"
else
  ok "(d) 대조군: 닫힌 문서는 하드 오류가 아니다"
fi

# 모호 — 펜스 밖 매치 둘. last-wins 로 조용히 하나를 고르지 않는다.
printf '## 구현 슬라이싱\n\n## 구현 슬라이싱\n' > "$SLI/dup.md"
slicing_present "$SLI/dup.md"; rc=$?
check "펜스 밖 매치 둘은 모호 오류다" "$rc" "2"

# 꼬리 텍스트가 붙은 표제는 선언이 아니다 — 전체줄 정확 일치.
printf '## 구현 슬라이싱 (단일 레포 먼저)\n' > "$SLI/tail.md"
slicing_present "$SLI/tail.md"; rc=$?
check "꼬리 텍스트가 붙은 표제는 선언으로 읽지 않는다" "$rc" "1"

# 3분기 술어.
check "부재 → 미통치" "$(slicing_branch "$SLI/tail.md")" "미통치"
check "필드 완전 → 선언통치" "$(slicing_branch "$SLI/tilde.md")" "선언통치"
sed 's/^\*\*레포\*\*: .*$//' "$SLI/tilde.md" > "$SLI/incomplete.md"
check "필드 불완전 → 선언불완전" "$(slicing_branch "$SLI/incomplete.md" 2>/dev/null)" "선언불완전"

# 필드 접근과 합성 규칙.
check "필드 조회" "$(slice_field "$SLI/tilde.md" A '레포')" '`o/r`'
check "슬라이스 id 열거" "$(slice_ids "$SLI/tilde.md" | tr '\n' ' ')" "A "
check "체크섬은 PR 이상 블록 수에서 파생된다" "$(slicing_pr_count "$SLI/tilde.md")" "1"
sed 's|^\*\*선언 파일\*\*: .*$|**선언 파일**: `x/SKILL.md`|' "$SLI/tilde.md" > "$SLI/skillonly.md"
check "SKILL.md 만 선언하면 필드 검사 실패" "$(slicing_branch "$SLI/skillonly.md" 2>/dev/null)" "선언불완전"
sed 's|^\*\*선언 파일\*\*: .*$|**선언 파일**: `x/SKILL.md`, `README.md`|' "$SLI/tilde.md" > "$SLI/skillreadme.md"
check "SKILL.md + README.md 는 통과한다" "$(slicing_branch "$SLI/skillreadme.md")" "선언통치"

# 커밋 절단점 슬라이스는 체크섬에 세지 않는다.
sed 's/^\*\*절단점\*\*: 머지$/**절단점**: 커밋/' "$SLI/tilde.md" > "$SLI/commitonly.md"
check "커밋 절단점은 PR 이상 블록 수에 들어가지 않는다" "$(slicing_pr_count "$SLI/commitonly.md")" "0"

# `선행`의 `없음` 은 독립성의 적극적 진술이다.
DONE_SAVE="$RUN_DIR/done.txt"; : > "$DONE_SAVE"
if deps_satisfied '없음'; then ok "선행 없음 은 즉시 만족된다"; else bad "선행" "없음 이 거부됐다"; fi
if deps_satisfied '슬라이스 A'; then
  bad "선행" "완료되지 않은 선행이 만족으로 판정됐다"
else
  ok "완료되지 않은 선행은 만족되지 않는다"
fi
printf 'A\n' > "$DONE_SAVE"
if deps_satisfied '슬라이스 A'; then ok "완료된 선행은 만족된다"; else bad "선행" "완료된 선행이 거부됐다"; fi
rm -f "$DONE_SAVE"

# 실물 설계 문서 — 이 변경 자신의 선언이 자기 파서를 통과해야 한다.
SELF_DOC="$repo_root/docs/autopilot-generalization.md"
if [ -f "$SELF_DOC" ]; then
  check "실물 문서: 분기" "$(slicing_branch "$SELF_DOC")" "선언통치"
  check "실물 문서: 체크섬 일치" \
    "$(slicing_body "$SELF_DOC" | sed -n 's/^\*\*슬라이스 수\*\*: //p')" "$(slicing_pr_count "$SELF_DOC")"
fi

# ---------------------------------------------------------------------------
# 18. 다중 레포 실행 — 별칭이 대상 집합의 키다
# ---------------------------------------------------------------------------
# N=1 에서 통과하는 것으로는 아무것도 말하지 못한다. 이 절의 모든 단언은 대상이
# **둘**인 매니페스트 위에서 돌고, 잡는 실패는 「두 번째 레포가 첫 번째 레포의
# 값을 물려받는다」 부류다.
MR_DIR="$WORK/multirepo"; mkdir -p "$MR_DIR"
MR_A="$MR_DIR/alpha"; MR_B="$MR_DIR/beta"
for d in "$MR_A" "$MR_B"; do
  mkdir -p "$d"
  ( cd "$d" && git init -q . && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init ) >/dev/null 2>&1
done
# Canonicalize. `git rev-parse --path-format=absolute` resolves symlinks, and on
# this platform TMPDIR is one (/var -> /private/var), so the declared value and
# the resolved value differ by a prefix that has nothing to do with the code.
MR_A=$(cd "$MR_A" && pwd -P); MR_B=$(cd "$MR_B" && pwd -P)
MR_DIR=$(cd "$MR_DIR" && pwd -P)
MR_CG_A=$(cd "$MR_A" && git rev-parse --path-format=absolute --git-common-dir)
MR_CG_B=$(cd "$MR_B" && git rev-parse --path-format=absolute --git-common-dir)
MR_MF="$MR_DIR/plan.md"
{
  printf '# m\n<!-- cc-run-manifest v1; run-id=mr; anchor-key=k -->\n\n'
  printf '## 대상\n'
  printf -- '- `target` | 별칭=fe | 메인 워크트리=%s | 공통 git 디렉터리=%s | 베이스 브랜치=main | 홈=예 | 원격 슬러그=o/alpha | 절단점=머지 | 말단 행위 상한=없음\n' "$MR_A" "$MR_CG_A"
  printf -- '- `target` | 별칭=be | 메인 워크트리=%s | 공통 git 디렉터리=%s | 베이스 브랜치=trunk | 홈=아니오 | 원격 슬러그=o/beta | 절단점=PR | 말단 행위 상한=3\n' "$MR_B" "$MR_CG_B"
} > "$MR_MF"
MANIFEST="$MR_MF"

check "홈 별칭은 홈=예 인 행이다" "$(home_alias)" "fe"
check "별칭 → 레포 루트 (홈)"     "$(alias_root fe)" "$MR_A"
check "별칭 → 레포 루트 (비홈)"   "$(alias_root be)" "$MR_B"
check "별칭 → 원격 슬러그"        "$(alias_slug be)" "o/beta"
check "슬러그 → 별칭"             "$(alias_for_slug o/beta)" "be"
if alias_for_slug o/gamma >/dev/null 2>&1; then
  bad "미선언 슬러그" "선언되지 않은 슬러그가 별칭으로 해소됐다"
else
  ok "선언되지 않은 슬러그는 별칭으로 해소되지 않는다"
fi
# 베이스 브랜치는 선언값을 쓰고 레포마다 다르다 — 전역 하나면 둘째 레포가
# 첫째의 값을 물려받는다.
check "베이스 브랜치는 별칭별 선언값 (홈)"   "$(base_branch fe)" "main"
check "베이스 브랜치는 별칭별 선언값 (비홈)" "$(base_branch be)" "trunk"

# 계획 행의 `레포` 가 세그먼트의 별칭을 정한다. 백틱은 선언 렌더링의 일부다.
printf 'segA\t`o/alpha`\ta.txt\t없음\nsegB\t`o/beta`\tb.txt\t슬라이스 segA\nsegX\t`o/gamma`\tx.txt\t없음\nsegN\t-\tn.txt\t없음\n' > "$RUN_DIR/plan.tsv"
check "세그먼트 별칭 (홈 레포)"    "$(seg_alias segA)" "fe"
check "세그먼트 별칭 (다른 레포)"  "$(seg_alias segB)" "be"
check "레포 미선언 세그먼트는 빈 별칭" "$(seg_alias segX 2>/dev/null)" ""
check "레포 열이 빈 계획은 홈으로"  "$(seg_alias segN)" "fe"
check "세그먼트 루트가 레포를 따라간다" "$(seg_root segB)" "$MR_B"
check "세그먼트 슬러그가 레포를 따라간다" "$(seg_slug segB)" "o/beta"

# 워크트리 경로가 레포마다 갈린다 — 한 부모 밑에 같은 이름으로 겹치면 두 레포의
# 세그먼트가 서로의 트리를 가져간다.
SLUG_SAVE="$SLUG"; SLUG="mr"
if [ "$(wt_path segA)" != "$(wt_path segB)" ]; then
  ok "워크트리 경로가 레포마다 갈린다"
else
  bad "워크트리 경로" "두 레포의 세그먼트가 같은 경로를 받는다"
fi
case "$(wt_path segB)" in
  "$MR_DIR"/beta*) ok "비홈 세그먼트의 워크트리가 그 레포 옆에 선다" ;;
  *) bad "워크트리 경로" "비홈 세그먼트가 홈 레포 옆에 놓였다: $(wt_path segB)" ;;
esac
# 미선언 별칭에는 워크트리를 만들지 않는다. 이 거부가 없으면 실패가 조용한
# 워크트리 누출로 나타난다 — 어떤 대상에도 귀속되지 않아 철거되지도 않는다.
if wt_create segX seg/mr-segX >/dev/null 2>&1; then
  bad "미선언 별칭" "선언되지 않은 레포에 워크트리를 만들었다"
else
  ok "미선언 별칭에는 워크트리를 만들지 않는다"
fi

# 철거 가드 셋째 조건 — 다른 별칭에 대해 쓰인 원장 행은 앞의 둘을 통과한다.
MR_LEDGER_SAVE="$LEDGER"; LEDGER="$MR_DIR/ledger.md"; : > "$LEDGER"
FOREIGN="$MR_DIR/beta$WORKTREE_INFIX$SLUG-segA"
printf -- '- `segment` | id=segA | 워크트리=%s\n' "$FOREIGN" >> "$LEDGER"
if wt_remove segA 2>/dev/null; then
  bad "철거 가드 (3)" "다른 별칭의 레포 루트 아래 경로를 철거했다"
else
  ok "철거 거부: 해당 별칭의 레포 루트 아래가 아님"
fi
LEDGER="$MR_LEDGER_SAVE"
SLUG="$SLUG_SAVE"
rm -f "$RUN_DIR/plan.tsv"

# stash 는 명시적 cwd 로 읽는다. 비레포 cwd 에서 전후가 모두 `none` 이면
# 가드가 공허하게 통과한다 — 정확히 잡아야 할 상황에서 성공을 보고한다.
check "stash_ref 는 대상 레포에서 읽는다" "$(stash_ref "$MR_A")" "none"
check "stash_ref 는 비레포 경로에서 none" "$(stash_ref "$MR_DIR/nope")" "none"
if sed -n '/^stash_ref()/,/^}/p' "$DRIVER" | grep -q 'cd "\$root"'; then
  ok "stash_ref 가 명시적 cwd 를 쓴다"
else
  bad "stash_ref" "상속 cwd 로 읽는다 — 비레포에서 가드가 공허하게 통과한다"
fi
if sed -n '/^stash_attribution_check()/,/^}/p' "$DRIVER" | grep -q 'cd "\$root"'; then
  ok "귀속 검사가 명시적 cwd 를 쓴다"
else
  bad "귀속 검사" "상속 cwd 로 stash 목록을 읽는다"
fi

# 모든 `gh` 호출이 `-R` 을 지나가는가. 주석은 먼저 걷어낸다 — 드라이버가 옛 형태를
# 설명하는 주석을 정당하게 담고, 자기 근거를 적발하는 검사는 근거를 지우라는 압력이 된다.
BARE_GH=$(sed 's/#.*//' "$DRIVER" | grep -nE '(^|[^_[:alnum:]])gh[[:space:]]+(pr|api|issue|repo)\b' | grep -v 'gh -R' || true)
if [ -z "$BARE_GH" ]; then
  ok "모든 gh 호출이 -R 을 지나간다"
else
  bad "gh -R" "cwd 상속 호출이 남았다: $(printf '%s' "$BARE_GH" | head -3 | tr '\n' ' ')"
fi
if sed -n '/^gh_q()/,/^}/p' "$DRIVER" | grep -q '2>"\$errf"'; then
  ok "gh_q 가 stderr 를 캡처한다"
else
  bad "gh_q" "stderr 를 버린다 — 비레포 오류가 빈 PR 번호로 삼켜진다"
fi
if sed -n '/^merge_gate()/,/^}/p' "$DRIVER" | grep -q 'GH_STDERR'; then
  ok "머지 게이트의 park 사유가 캡처한 stderr 를 싣는다"
else
  bad "merge_gate" "원인을 버리고 park 한다"
fi
# 술어는 세그먼트의 레포에서 평가돼야 한다. 홈에서 평가하면 홈이 아닌 레포의
# 모든 세그먼트가 만들어진 적 없는 브랜치를 조회당해 공허한 성공으로 떨어진다.
if sed -n '/^predicate_implement()/,/^}/p' "$DRIVER" | grep -q 'seg_root'; then
  ok "구현 술어가 세그먼트의 레포에서 평가된다"
else
  bad "predicate_implement" "홈 레포에서 평가된다 — N>1 에서 전부 공허한 성공"
fi

MANIFEST=""

# ---------------------------------------------------------------------------
# 19. S9 apply — 네 처분이 두 프로브에서 갈린다
# ---------------------------------------------------------------------------
# exit 2 는 apply 전후로 반대를 뜻하므로(전=변경 대기, 후=여전히 대기) 양쪽을
# 재고, 네 조합이 네 처분에 1:1 로 대응하는지 본다. 여기서 잡는 실패는
# 「실행했는데 결과를 모른다」가 조용히 성공으로 읽히는 것이다.
AP_DIR="$WORK/apply"; mkdir -p "$AP_DIR"
AP_REPO="$AP_DIR/repo"
mkdir -p "$AP_REPO"
( cd "$AP_REPO" && git init -q . && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init ) >/dev/null 2>&1
AP_REPO=$(cd "$AP_REPO" && pwd -P); AP_DIR=$(cd "$AP_DIR" && pwd -P)
AP_CG=$(cd "$AP_REPO" && git rev-parse --path-format=absolute --git-common-dir)
AP_SHA=$(cd "$AP_REPO" && git rev-parse HEAD)
AP_ST="$AP_DIR/state"; AP_CNT="$AP_DIR/ran"

ap_manifest() {   # ap_manifest <적용명령> <적용주체>
  {
    printf '# a\n<!-- cc-run-manifest v1; run-id=ap; anchor-key=k -->\n\n'
    printf '## 대상\n'
    printf -- '- `target` | 별칭=only | 메인 워크트리=%s | 공통 git 디렉터리=%s | 베이스 브랜치=main | 홈=예 | 원격 슬러그=o/repo | 절단점=배포 | 말단 행위 상한=없음\n\n' "$AP_REPO" "$AP_CG"
    printf '## 요소\n**적용 지점**: %s\n**적용 프로브**: %s\n**적용 주체**: %s\n' \
      "$1" "sh -c 'exit \$(cat $AP_ST)'" "$2"
  } > "$AP_DIR/plan.md"
  MANIFEST="$AP_DIR/plan.md"
}

AP_DOC_SAVE="${DOC:-}"; DOC=""
AP_LEDGER_SAVE="$LEDGER"; LEDGER="$AP_DIR/ledger.md"
AP_BASE_SAVE="$BASE"; BASE="$AP_DIR/base"; mkdir -p "$BASE/docs"
AP_SLUG_SAVE="$SLUG"; SLUG="ap"
printf 'segA\t`o/repo`\ta.txt\t없음\n' > "$RUN_DIR/plan.tsv"
grant_field() { printf '배포'; }        # 이 절에서만 배포까지 인가
MERGE_COMMIT="$AP_SHA"

# (0) 선언이 없으면 스테이지 자체가 없다 — 빈 명령에 대해 아무 일도 하지 않는다.
ap_manifest "(없음)" "파이프라인"
: > "$LEDGER"; : > "$AP_CNT"
if apply_stage segA && [ ! -s "$AP_CNT" ] && [ ! -s "$LEDGER" ]; then
  ok "적용 선언이 없으면 S9 는 아무것도 하지 않는다"
else
  bad "S9 부재" "선언이 없는데 스테이지가 돌았다"
fi

# (1) 적용 주체가 사람 — 인계다. 명령은 축자로 보고되고 실행되지 않는다.
ap_manifest "touch $AP_DIR/SHOULD_NOT_EXIST" "사람"
: > "$LEDGER"; printf '2\n' > "$AP_ST"
apply_stage segA
if [ ! -e "$AP_DIR/SHOULD_NOT_EXIST" ]; then
  ok "적용 주체가 사람이면 파이프라인은 명령을 실행하지 않는다"
else
  bad "인계" "사람 인계인데 드라이버가 실행했다"
fi
if grep -q '적용 인계' "$(report_path)" 2>/dev/null; then
  ok "인계 명령이 아침 보고서에 축자로 실린다"
else
  bad "인계" "보고서에 인계가 없다"
fi

# (2) 사전 프로브 0 — 적용할 변경이 없으므로 명령을 아예 돌리지 않는다.
ap_manifest "sh -c 'echo x >> $AP_CNT'" "파이프라인"
: > "$LEDGER"; : > "$AP_CNT"; printf '0\n' > "$AP_ST"
if apply_stage segA && [ ! -s "$AP_CNT" ]; then
  ok "사전 프로브 0: apply 를 건너뛴다"
else
  bad "사전 0" "변경이 없는데 apply 를 실행했다"
fi

# (3) 사전 프로브 1 — 프로브 자체의 실패다. 아무것도 건드리기 전에 거부한다.
: > "$LEDGER"; : > "$AP_CNT"; printf '1\n' > "$AP_ST"
if apply_stage segA; then
  bad "사전 1" "프로브가 실패했는데 성공을 돌려줬다"
else
  ok "사전 프로브 1: 거부한다"
fi
if [ ! -s "$AP_CNT" ]; then
  ok "사전 프로브 1: 아무것도 건드리기 전에 거부한다"
else
  bad "사전 1" "프로브 실패인데 apply 가 실행됐다"
fi

# (4) 사전 2 → 사후 0 — 수렴. 유일한 성공이다.
ap_manifest "sh -c 'echo x >> $AP_CNT; echo 0 > $AP_ST'" "파이프라인"
: > "$LEDGER"; : > "$AP_CNT"; printf '2\n' > "$AP_ST"
if apply_stage segA && [ "$(grep -c . "$AP_CNT")" = "1" ]; then
  ok "사전 2 → 사후 0: 수렴, apply 1회 실행"
else
  bad "수렴" "사전 2 → 사후 0 이 성공으로 판정되지 않았다"
fi
if grep -q '종단 부류=정상 완료' "$LEDGER"; then
  ok "수렴이 정상 완료로 기록된다"
else
  bad "수렴 기록" "정상 완료 행이 없다"
fi

# (5) 사전 2 → 사후 2 — 적용 불명. 재시도 0회, 워크트리 보존, 사람 대조 표시.
ap_manifest "sh -c 'echo x >> $AP_CNT'" "파이프라인"
: > "$LEDGER"; : > "$AP_CNT"; printf '2\n' > "$AP_ST"
if apply_stage segA; then
  bad "적용 불명" "사후에도 변경이 남았는데 성공을 돌려줬다"
else
  ok "사전 2 → 사후 2: 적용 불명으로 실패를 돌려준다"
fi
check "적용 불명에도 재시도는 0회 (apply 1회 실행)" "$(grep -c . "$AP_CNT")" "1"
if grep -q '종단 부류=적용 불명' "$LEDGER"; then
  ok "적용 불명이 자기 종단 부류로 기록된다"
else
  bad "적용 불명" "게이트 park 아래 묻혔다 — 가장 무거운 결과가 가장 흔한 토큰을 쓴다"
fi
AP_WT="$(apply_worktree segA)"
if [ -d "$AP_WT" ]; then
  ok "실패한 apply 의 워크트리는 보존된다"
else
  bad "워크트리 보존" "절반 적용된 상태의 유일한 재현본을 지웠다"
fi
if grep -q '사람 대조 필요' "$(report_path)" 2>/dev/null; then
  ok "적용 불명이 아침 보고서에 사람 대조 필요로 표시된다"
else
  bad "보고서" "적용 불명이 표시되지 않았다"
fi
check "park 이 선언된 폭발 반경을 싣는다" \
  "$(grep -c "폭발 반경 '레포'" "$LEDGER")" "1"

# (6) 반경 판정 — 런은 전부 멈추고, 레포는 같은 레포만, 슬라이스 목록은 그 셋만.
RUN_HALTED=0; rm -f "$RUN_DIR/halted-repo.txt" "$RUN_DIR/halted-segments.txt"
radius_park segA '레포'
if in_halted_radius segA; then ok "반경 레포: 같은 레포의 세그먼트가 반경 안"; else bad "반경 레포" "반경 안인데 아니라고 판정"; fi
rm -f "$RUN_DIR/halted-repo.txt"
radius_park segA '슬라이스 segC, 슬라이스 segD'
if in_halted_radius segC && in_halted_radius segD; then
  ok "반경 슬라이스 목록: 지명된 것만 반경 안"
else
  bad "반경 목록" "지명된 슬라이스가 반경 안으로 읽히지 않는다"
fi
if in_halted_radius segE; then bad "반경 목록" "지명되지 않은 것까지 멈췄다"; else ok "지명되지 않은 슬라이스는 계속 돈다"; fi
rm -f "$RUN_DIR/halted-segments.txt"
radius_park segA '런'
if in_halted_radius segZ; then ok "반경 런: 이후 전부 디스패치 중단"; else bad "반경 런" "런 반경인데 계속 돈다"; fi
RUN_HALTED=0

# (7) S9 는 경계 멱등이 아니다 — 되돌릴 수 없는 행위에 kill 허가를 주지 않는다.
if boundary_idempotent S9; then
  bad "S9 멱등성" "apply 가 경계 멱등 허용목록에 들어갔다"
else
  ok "S9 는 경계 멱등 허용목록에 없다"
fi
if kill_permitted "S9:segA:1"; then
  bad "S9 kill" "apply 스테이지에 kill 이 허용됐다"
else
  ok "apply 스테이지에는 kill 이 허용되지 않는다"
fi
# (8) 사다리 단을 소비하지 않는다. 소비하면 결함용 단이 말단 행위 실패로 닳는다.
if sed -n '/^apply_stage()/,/^}/p' "$DRIVER" | grep -q 'ladder_bump'; then
  bad "사다리" "apply 실패가 사다리 단을 소비한다"
else
  ok "apply 는 사다리 단을 소비하지 않는다"
fi
# (9) 실행자가 드라이버여야 한다 — 즉흥하는 스테이지는 프로브를 돌리고 아무 말이나 할 수 있다.
if sed -n '/^apply_stage()/,/^}/p' "$DRIVER" | grep -q 'stage_spawn\|dispatch_stage'; then
  bad "실행자" "apply 를 모델에 디스패치한다 — 날조 가능한 표면"
else
  ok "apply 는 드라이버가 직접 실행한다"
fi

MANIFEST=""; DOC="$AP_DOC_SAVE"; LEDGER="$AP_LEDGER_SAVE"; BASE="$AP_BASE_SAVE"; SLUG="$AP_SLUG_SAVE"
grant_field() { printf 'PR'; }          # 이후 절을 위해 원래 스텁으로 되돌린다
rm -f "$RUN_DIR/plan.tsv"

# ---------------------------------------------------------------------------
# 20. 종료 불변식 — 스코프와 원인을 지명하지 못하는 park 은 버그다
# ---------------------------------------------------------------------------
TI_DIR="$WORK/term"; mkdir -p "$TI_DIR"
TI_LEDGER_SAVE="$LEDGER"; LEDGER="$TI_DIR/ledger.md"; : > "$LEDGER"
TI_BASE_SAVE="$BASE"; BASE="$TI_DIR/base"; mkdir -p "$BASE/docs"

# 모든 park 호출부가 어휘 안의 스코프·원인을 싣는가. 주석은 먼저 걷어낸다.
UNSCOPED=$(sed 's/#.*//' "$DRIVER" | grep -nE '(^|[^_a-z])park "' \
  | grep -vE 'park "[^"]*" (act|cone|run) (막힘|무효화|불명) ' | grep -v radius_park || true)
if [ -z "$UNSCOPED" ]; then
  ok "모든 park 호출부가 스코프와 원인을 지명한다"
else
  bad "park 스코프" "지명하지 않은 호출부: $(printf '%s' "$UNSCOPED" | head -3 | tr '\n' ' ')"
fi
# 어휘 밖 값은 조용한 기본값이 아니라 하드 오류다.
if ( park t 없는스코프 막힘 r o ) >/dev/null 2>&1; then
  bad "park 어휘" "어휘 밖 스코프를 받아들였다"
else
  ok "어휘 밖 스코프는 하드 오류다"
fi
if ( park t act 없는원인 r o ) >/dev/null 2>&1; then
  bad "park 어휘" "어휘 밖 원인을 받아들였다"
else
  ok "어휘 밖 원인은 하드 오류다"
fi
: > "$LEDGER"
park tgt act 막힘 "인가 한도" "관측문" "재호출"
if grep -q '스코프=act' "$LEDGER" && grep -q '원인=막힘' "$LEDGER"; then
  ok "원장 blocked 행이 스코프와 원인을 싣는다"
else
  bad "원장" "blocked 행에 스코프·원인이 없다"
fi

# 기소된 여덟 — 말단 행위가 막히면 세그먼트를 버리지 않는다. merge_gate 의
# ACT 팔은 1(=CONE) 이 아니라 2 를 돌려주고, segment_cycle 이 그것을
# 완성-미착지(4)로 옮긴다.
if [ "$(sed -n '/^merge_gate()/,/^}/p' "$DRIVER" | grep -c '^    return 2$')" -ge 3 ]; then
  ok "머지 게이트의 막힌 행위가 ACT 팔로 빠진다"
else
  bad "ACT 팔" "머지 실패가 여전히 세그먼트를 버린다 — 절단점 오타 하나가 밤 전체를 비운다"
fi
if sed -n '/^segment_cycle()/,/^}/p' "$DRIVER" | grep -q 'return 4'; then
  ok "완성-미착지가 자기 반환 코드를 가진다"
else
  bad "완성-미착지" "막힌 말단 행위가 park 과 구별되지 않는다"
fi
if sed -n '/^main_loop()/,/^}/p' "$DRIVER" | grep -q '완성-미착지'; then
  ok "아침 보고서가 완성-미착지를 따로 센다"
else
  bad "보고서" "완성-미착지가 보류에 섞인다"
fi

# 사이클 상한은 자기 사유를 쓴다 — 가장 흔한 park 이 가장 드문 사유로
# 분류되면 원장이 사다리가 소진됐다고 말하는데 사다리는 시작도 안 했다.
if grep -q '"사이클 예산 소진"' "$DRIVER"; then
  ok "사이클 상한이 사이클 예산 소진으로 라벨링된다"
else
  bad "오라벨" "사이클 상한이 여전히 사다리 R4 로 기록된다"
fi
if sed -n '/^  if \[ "\$cycle" -ge "\$cap" \]/,/^  fi$/p' "$DRIVER" | grep -q '사다리 R4'; then
  bad "오라벨" "사이클 상한 자리에 사다리 R4 가 남았다"
else
  ok "사이클 상한 자리에 사다리 R4 라벨이 없다"
fi

# K 를 상수로 명명했는가. 두 상한이 같은 값을 참조해야 하는데 예전에는
# 서로 무관한 리터럴 둘이었다.
check "동일성당 단 수가 상수다" "$LADDER_RUNGS" "4"
check "세그먼트 상한 = K*F+1 (F=3)" "$(segment_cap 3)" "13"
check "세그먼트 상한 = K*F+1 (F=1)" "$(segment_cap 1)" "5"
if sed -n '/^segment_cycle()/,/^}/p' "$DRIVER" | grep -qE 'cap=\$\(\( *4 \*'; then
  bad "K" "세그먼트 상한이 리터럴 4 를 쓴다 — 두 상한이 갈라진다"
else
  ok "세그먼트 상한이 상수를 참조한다"
fi
printf 'a\t-\tx.txt,y.txt\t없음\nb\t-\tz.txt\t없음\n' > "$RUN_DIR/plan.tsv"
check "런 사이클 예산은 세그먼트 예산의 합" "$(run_cycle_budget)" "14"
# 빈 칸을 그대로 쓰면 안 되는 이유의 회귀. 탭은 IFS 공백 문자라 연속 탭이
# 접히고, 빈 칸 뒤의 모든 필드가 한 칸씩 밀린다 — 선언 파일이 레포로, 선행이
# 파일로 읽혀 예산이 조용히 절반이 된다.
printf 'a\t\tx.txt,y.txt\t없음\n' > "$RUN_DIR/plan.tsv"
if [ "$(run_cycle_budget)" = "9" ]; then
  bad "빈 칸" "빈 레포 칸이 필드를 밀지 않았다 — 이 단언이 낡았거나 픽스처가 틀렸다"
else
  ok "빈 칸은 필드를 밀어 버린다 (그래서 쓰는 쪽이 - 를 넣는다)"
fi
if sed -n '/^plan_from_declaration()/,/^}/p' "$DRIVER" | grep -q 'plan_cell' \
   && sed -n '/^plan_via_planner()/,/^}/p' "$DRIVER" | grep -q 'plan_cell'; then
  ok "두 계획 생성기가 모두 빈 칸을 - 로 쓴다"
else
  bad "빈 칸" "한쪽 생성기가 빈 칸을 그대로 쓴다"
fi
rm -f "$RUN_DIR/plan.tsv"

# 문제 동일성에 레포 성분이 있는가. 없으면 같은 경로를 가진 두 레포가 한
# 동일성으로 무너져 한쪽 결함이 다른 쪽 단을 소비한다.
printf 'segA\t`o/alpha`\ta.txt\t없음\n' > "$RUN_DIR/plan.tsv"
MANIFEST="$MR_MF"
check "동일성이 레포를 싣는다" "$(identity_of segA src/x.ts logic)" "o/alpha::src/x.ts::logic"
MANIFEST=""
rm -f "$RUN_DIR/plan.tsv"

# 사다리 가용 단은 매니페스트에서 읽고, 클램프가 아니라 park 이다.
LADDER_SAVE="$LADDER"; LADDER="$TI_DIR/ladder.tsv"; : > "$LADDER"
check "가용 단 기본값" "$(ladder_available)" "4"
check "첫 등장은 R1" "$(ladder_bump p logic)" "1"
check "재발은 R2"   "$(ladder_bump p logic)" "2"
: > "$LADDER"
ap_manifest_rungs() {
  { printf '# r\n<!-- cc-run-manifest v1 -->\n\n## 인가\n**사다리 가용 단 수**: 2\n'; } > "$TI_DIR/plan.md"
  MANIFEST="$TI_DIR/plan.md"
}
ap_manifest_rungs
check "가용 단을 매니페스트에서 읽는다" "$(ladder_available)" "2"
check "가용 집합 안: R1" "$(ladder_bump p logic)" "1"
check "가용 집합 안: R2" "$(ladder_bump p logic)" "2"
check "가용 집합 밖으로의 전이는 클램프가 아니라 신호" "$(ladder_bump p logic)" "99"
if sed -n '/^ladder_bump()/,/^}/p' "$DRIVER" | grep -q 'printf .99'; then
  ok "가용 집합 밖은 park 신호로 나온다 (클램프하면 종단 단이 무장 해제된다)"
else
  bad "사다리" "가용 단을 클램프한다 — 출하된 종단 단 분기에 영영 도달하지 못한다"
fi
MANIFEST=""; LADDER="$LADDER_SAVE"

# 세대 상한.
rm -f "$RUN_DIR/generation"
check "첫 세대는 1" "$(generation_now)" "1"
check "재계획이 세대를 올린다" "$(generation_bump)" "2"
check "상한을 넘는 세대가 관측된다" "$(generation_bump)" "3"
if [ "$(generation_now)" -gt "$GENERATION_MAX" ]; then
  ok "세대 상한 초과가 판정 가능하다 ($GENERATION_MAX)"
else
  bad "세대 상한" "상한을 넘겨도 판정되지 않는다"
fi
rm -f "$RUN_DIR/generation"
if grep -q '"세대=1"' "$DRIVER"; then
  bad "세대" "하드코딩된 세대=1 이 남았다 — 행이 세대를 말하면서 아무것도 재지 않는다"
else
  ok "세대 행이 실제 세대를 싣는다"
fi

# 벽시계 마감은 디스패치 게이트이지 kill 신호가 아니다.
if sed -n '/^past_deadline()/,/^}/p' "$DRIVER" | grep -qE 'kill|reap_orphan'; then
  bad "마감" "마감이 kill 신호로 쓰인다 — 비행 중 스테이지를 죽이면 모호한 반쯤 상태가 생긴다"
else
  ok "마감은 kill 신호가 아니다"
fi
if sed -n '/^segment_cycle()/,/^}/p' "$DRIVER" | grep -B8 'merge_gate "\$seg"' | grep -q 'past_deadline'; then
  ok "마감 이후에는 머지하지 않는다 (인라인 실행이라 「비행 중 완주」에 덮이지 않는다)"
else
  bad "마감" "마감 뒤에도 머지가 난다"
fi

# REPLAN_NEEDED latch 제거 + 다이제스트 비교 배선.
if grep -q 'REPLAN_NEEDED' "$DRIVER"; then
  bad "latch" "latch 하는 REPLAN_NEEDED 가 남았다 — 한 번 서면 이후 전 세그먼트를 park 한다"
else
  ok "latch 하는 REPLAN_NEEDED 가 제거됐다"
fi
if sed -n '/^segment_cycle()/,/^}/p' "$DRIVER" | grep -q 'plan_digest'; then
  ok "재계획 판정이 다이제스트 측정에 키잉된다"
else
  bad "재계획" "모델 자기 보고에 키잉된다"
fi
# 정규화가 실제로 걸렸는가 — 공백에 흔들리면 비교 술어로 부적격이다.
TI_DOC_SAVE="${DOC:-}"; DOC="$TI_DIR/d.md"
printf '# t\n\n\n본문\n' > "$DOC"; TI_D1=$(binding_digest)
printf '# t\r\n\n\n\n본문   \r\n' > "$DOC"; TI_D2=$(binding_digest)
check "정규화: CRLF·후행 공백·빈 줄 런에 불변" "$TI_D2" "$TI_D1"
printf '# t\n\n\n본문 다름\n' > "$DOC"; TI_D3=$(binding_digest)
if [ "$TI_D3" != "$TI_D1" ]; then
  ok "정규화가 실제 변경까지 지우지는 않는다"
else
  bad "정규화" "내용이 달라도 같은 다이제스트 — 술어가 공허하다"
fi
DOC="$TI_DOC_SAVE"

# 파일 집합 이탈 — 양쪽 집합을 다 적어야 과소 선언과 배회를 구별할 수 있다.
if sed -n '/^fileset_escape()/,/^}/p' "$DRIVER" | grep -q '실제 편집 집합'; then
  ok "이탈 행이 선언 집합과 실제 집합을 모두 적는다"
else
  bad "이탈 행" "이탈만 적어 과소 선언과 배회를 구별할 수 없다"
fi
if sed -n '/^fileset_escape()/,/^}/p' "$DRIVER" | grep -q '형제'; then
  bad "이탈 팔" "웨이브 형제 팔이 남았다 — 겹치는 선언 파일은 이제 설계된 정상이라 올바른 계획을 park 한다"
else
  ok "웨이브 형제 팔이 없다 (2분기)"
fi

# declared_files 가 디스패치 줄에 실린다.
if sed -n '/^segment_cycle()/,/^}/p' "$DRIVER" | grep -q '선언 파일: \$files'; then
  ok "declared_files 가 디스패치 줄에 실린다"
else
  bad "디스패치" "스테이지가 자기가 대조당할 계약을 듣지 못한다"
fi

LEDGER="$TI_LEDGER_SAVE"; BASE="$TI_BASE_SAVE"

# ---------------------------------------------------------------------------
# 20. 인수 테스트 — 백오프 수정과 kill 가드는 하나의 변경이다
# ---------------------------------------------------------------------------
# 이 테스트는 **반쪽 트리에서 통과할 수 없다.**
#   - 백오프만 고친 트리: 누산기가 자라 상한에 도달하고, 가드가 없으므로 그
#     경로가 비멱등 스테이지에 신호를 보낸다 → 아래 「신호 0회」가 실패한다.
#   - 가드만 넣은 트리: 누산기가 매 호출 버려져 상한이 도달 불가라 정체 경로가
#     끝나지 않는다 → 이 테스트는 작성조차 되지 않는다(도달 가능한 상한이 없다).
#
# S9를 이름으로 요구하지 않는 것은 의도다. 이 테스트는 결합을 지는 슬라이스에
# 실리고 S9는 나중에 오므로, S9를 지명하면 자기 슬라이스에서 실행 불가가 되어
# 강제가 그 창에서 사라진다. 요구하는 것은 「비멱등으로 분류된 스테이지」다.
ACC_DIR="$WORK/acceptance"; mkdir -p "$ACC_DIR"
RUN_DIR_SAVE="$RUN_DIR"; RUN_DIR="$ACC_DIR"; mkdir -p "$RUN_DIR/log"
LEDGER_SAVE="$LEDGER"; LEDGER="$ACC_DIR/ledger.md"; : > "$LEDGER"
BASE_SAVE="$BASE"; BASE="$ACC_DIR/base"; mkdir -p "$BASE/docs"

# 비멱등 스테이지를 하나 고른다 — 이름이 아니라 술어로.
NONIDEM=""
for cand in S1 S3 S6 S7 S9; do
  if ! boundary_idempotent "$cand"; then NONIDEM="$cand"; break; fi
done
if [ -n "$NONIDEM" ]; then
  ok "비멱등으로 분류된 스테이지가 존재한다 ($NONIDEM)"
else
  bad "인수 테스트 전제" "비멱등 스테이지가 하나도 없다 — 결합을 시험할 대상이 없음"
fi

# (1) 누산기가 지속돼 상한이 실제로 도달 가능한가. 도달 불가면 정체 경로가
#     끝나지 않아 이 테스트 자체가 성립하지 않는다.
ACC_STAGE="acc-$NONIDEM"
printf '%s %s\n' "$BACKOFF_WALLCLOCK_CAP_SECONDS" "1" > "$RUN_DIR/$ACC_STAGE.backoff"
if backoff_wait "$ACC_STAGE"; then
  bad "백오프 상한" "누산기가 상한을 넘겼는데도 계속 대기했다 — 상한 도달 불가"
else
  ok "백오프 누산기가 지속되고 상한이 도달 가능하다"
fi
printf '0 1\n' > "$RUN_DIR/$ACC_STAGE.backoff"
backoff_wait "$ACC_STAGE" >/dev/null 2>&1
read -r acc_e acc_s < "$RUN_DIR/$ACC_STAGE.backoff"
if [ "$acc_e" -gt 0 ] && [ "$acc_s" -gt 1 ]; then
  ok "누산기와 간격이 둘 다 호출을 가로질러 지속된다 (elapsed=$acc_e sleep=$acc_s)"
else
  bad "누산기 지속" "elapsed=$acc_e sleep=$acc_s — 둘 다 자라야 한다"
fi

# (2) 그 상한에 도달했을 때, 비멱등 스테이지에는 어떤 신호도 가지 않는가.
#     reap_orphan 을 감시 스텁으로 갈아 끼워 호출 자체를 관측한다.
REAPED=""
reap_orphan() { REAPED="$REAPED $1"; }
printf '99999\n' > "$RUN_DIR/$ACC_STAGE.pid"     # 살아있지 않은 pid (신호는 어차피 안 감)
if kill_permitted "$ACC_STAGE"; then
  bad "kill 가드" "비멱등 스테이지에 kill 이 허용됐다"
else
  ok "kill 가드가 비멱등 스테이지를 거부한다"
fi
if [ -z "$REAPED" ]; then
  ok "정체 상한 경로에서 비멱등 스테이지에 신호 0회"
else
  bad "신호 0회" "reap_orphan 이 호출됐다:$REAPED"
fi

# (3) 그러면 무엇을 하는가 — park 하고 사람 대조를 표시한다.
human_reconcile "$ACC_STAGE"
if grep -q '사유=외부 상태 불확정' "$LEDGER"; then
  ok "원장에 외부 상태 불확정으로 park 된다"
else
  bad "park 사유" "원장에 외부 상태 불확정 행이 없다"
fi
if grep -q '사람 대조 필요' "$(report_path)" 2>/dev/null; then
  ok "아침 보고서에 사람 대조 필요가 표시된다"
else
  bad "보고서 표시" "사람 대조 필요가 보고서에 없다"
fi

# (4) 대조군 — 경계 멱등 스테이지에는 같은 경로가 kill 을 허용해야 한다.
if kill_permitted "S4"; then
  ok "대조군: 경계 멱등 스테이지에는 kill 이 허용된다"
else
  bad "kill 가드" "경계 멱등 스테이지까지 막았다 — 가드가 과도하다"
fi

# `unset -f` REMOVES the watcher rather than restoring the driver's definition —
# bash has no function shadowing, so the original is gone for the rest of this
# process. That is why this block sits last: a later assertion calling it would
# die loudly rather than silently observing nothing.
unset -f reap_orphan
RUN_DIR="$RUN_DIR_SAVE"; LEDGER="$LEDGER_SAVE"; BASE="$BASE_SAVE"

printf '\ntest-run: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
