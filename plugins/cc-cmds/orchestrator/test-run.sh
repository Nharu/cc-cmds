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

# `grep -q` on the right of a pipe exits as soon as it matches, which kills the
# writer with SIGPIPE — and under `pipefail` the whole pipeline then reports
# failure even though the match was found. GNU sed makes it loud ("couldn't
# flush stdout: Broken pipe") and BSD sed usually does not, so this failed only
# on the Linux leg and only once a scanned function grew long enough for the
# race to be real.
#
# `grep -c` has the same truth value and consumes its input to the end, so the
# writer never sees a closed pipe. The count goes to /dev/null; only the exit
# status is wanted.
grep_all_q() {
  # The count is CAPTURED, not redirected to /dev/null: BSD grep short-circuits
  # when its output is being discarded, which reintroduces the very SIGPIPE this
  # helper exists to avoid. Measured — `sed … | grep -c … >/dev/null` returns
  # 141 while `n=$(grep -c …)` returns 0.
  local n
  n=$(grep -c "$@" || true)
  [ "${n:-0}" != "0" ]
}

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
  *)            printf 'NOTE: self-check ran on %s\n' "$(printf '%s' "$sc_out" | awk 'NR<=1')" ;;
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
first_exec=$(grep -nE '^[^#[:space:]]' "$DRIVER" | awk 'NR<=1' | cut -d: -f1)
guard_line=$(grep -n 'BASH_VERSINFO+set' "$DRIVER" | awk 'NR<=1' | cut -d: -f1)
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

# Environment facts, printed unconditionally and early. A runner whose awk
# mishandles multibyte text does not announce itself — it just stops matching,
# and the resulting failure names the assertion rather than the cause. These
# three lines are what turned "a manifest was rejected" into "this runner's
# locale was C and its awk lost the Korean heading".
printf 'locale(driver): LC_CTYPE=%s LC_COLLATE=%s %s=%s (locale -a 후보 %s개)\n' \
  "${LC_CTYPE:-unset}" "${LC_COLLATE:-unset}" "${ORCH_LOCALE_SOURCE:-미해결}" \
  "${ORCH_UTF8_LOCALE:-없음}" "$(locale -a 2>/dev/null | grep -c . || printf 0)"
# UTF-8 이 어느 경로로도 서지 않았다면 그 자체가 발견이다. 이 하네스가 도는
# 호스트에서 한국어 어휘 비교가 성립하지 않는다는 뜻이고, 아래 프로브가 그것을
# 확인한다 — 선택이 조용히 아무것도 하지 않은 경우와 통한 경우를 가르려고
# 출처를 함께 찍는다.
if [ -n "${ORCH_UTF8_LOCALE:-}" ]; then
  ok "UTF-8 LC_CTYPE 이 선다 (${ORCH_LOCALE_SOURCE})"
else
  bad "로케일" "UTF-8 LC_CTYPE 이 선택으로도 상속으로도 서지 않았다"
fi
# 이 하네스는 소싱 전에 이미 pipefail 을 켜므로, 여기서 「선택」이 나온다는 것은
# 드라이버의 로케일 탐색이 pipefail 아래에서도 발화한다는 뜻이다. `grep -q` 는
# 첫 매치에서 종료해 왼쪽에 SIGPIPE 를 남기고, pipefail 은 그 파이프라인을
# 실패로 보고한다 — 답이 「예」일 때 정확히 조건이 거짓이 된다.
if [ "${ORCH_LOCALE_SOURCE:-}" = "선택" ]; then
  ok "로케일 탐색이 pipefail 아래에서 발화한다"
else
  bad "로케일 탐색" "pipefail 아래에서 탐색이 조용히 비었다 (출처=${ORCH_LOCALE_SOURCE:-미해결}) — 상속이 가려 주고 있을 뿐이다"
fi
# 조기 종료 읽기가 남아 있으면 같은 함정이 다시 생긴다. 파일을 읽는 `grep -q` 는
# 파이프라인이 아니므로 대상이 아니고, 걸러야 할 것은 파이프의 오른쪽이다.
EARLY=$(sed 's/#.*//' "$DRIVER" | grep -nE '\| *(head -|grep -[A-Za-z]*q)' || true)
if [ -z "$EARLY" ]; then
  ok "파이프 오른쪽에 조기 종료 읽기가 없다"
else
  bad "pipefail 함정" "$(printf '%s' "$EARLY" | awk 'NR<=3' | tr '\n' ' ')"
fi
printf 'awk(harness): %s\n' "$(awk --version 2>&1 | awk 'NR<=1' || printf unknown)"
if printf '한글\n' | awk '/^한글$/{print "hit"}' | grep_all_q hit \
   && [ "$(printf '한글\n' | awk -v k=한글 '$0==k{print "hit"}')" = "hit" ]; then
  ok "러너의 awk 가 멀티바이트 정규식과 -v 대입을 모두 처리한다"
else
  bad "awk 멀티바이트" "이 러너에서 한국어 어휘 비교가 조용히 실패한다 — 아래 실패들의 원인일 수 있다"
fi

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

# The sixth class. A stage that REACHED a decision point and declined to decide
# for the user is not a stage that attempted nothing — and until this class
# existed the two were byte-identical to the driver: exit 0, no artifact, no
# halt record. The correct refusal was classified hollow, retried once, and
# parked for "no artifact" with the real cause recorded nowhere.
mkdir -p "$RUN_DIR/log"
printf '%s\n' '{"type":"tool_use","name":"ToolSearch","input":{"query":"select:AskUserQuestion"}}' \
  > "$RUN_DIR/log/Sz.json"
check "종단: 산출물 없는 정지" "$(classify_termination Sz 0 1)" "산출물 없는 정지"

# The distinction is the ndjson trace and nothing else — same exit code, same
# absent artifact, same absent halt record.
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}' \
  > "$RUN_DIR/log/Sw.json"
check "흔적이 없으면 여전히 공허한 성공" "$(classify_termination Sw 0 1)" "공허한 성공"
if decision_point_reached Snone; then bad "결정 지점 탐지기" "ndjson 이 없는데 참을 냈다"; else ok "결정 지점 탐지기는 ndjson 이 없으면 거짓"; fi

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
if sed 's/#.*//' "$DRIVER" | grep_all_q -E 'git worktree add -b "\$branch" "\$p" HEAD'; then
  bad "wt_create" "리터럴 HEAD에서 분기 — 메인 팁은 런 내내 움직이지 않는다"
else
  ok "wt_create 가 리터럴 HEAD에서 분기하지 않는다"
fi
if sed -n '/^merge_gate()/,/^}/p' "$DRIVER" | grep_all_q 'base_fetch'; then
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

# 파일 단위 단 상속은 없다. 있던 시절에도 실제 도착 순서에서 0회 발화했고 —
# 한 파일의 동일성들은 그 파일의 최댓값이 아직 1일 때 전부 도입된다 — 사이클
# 상한이 파일 단위 붕괴에서 온다는 잘못된 모델을 독자에게 심었다. 상한은 각
# 동일성이 자기 단을 오르는 데서 온다.
check "같은 파일의 새 카테고리는 자기 단부터" "$(ladder_rung src/a.ts perf)" "0"

# Severity is NOT part of the identity, so the same defect read at a different
# grade is the SAME problem. Were severity in the key, the line below would
# return 0 for a defect that HAS climbed, and it would collect a fresh budget
# every time a reviewer set graded it differently — the disarming this design
# exists to prevent.
check "동일성은 심각도를 담지 않는다"     "$(ladder_rung src/a.ts correctness)" "4"
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
if sed 's/#.*//' "$DRIVER" | grep_all_q -E '\bwait[[:space:]]+-n\b'; then
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
if sed -n '/^resume_verdict()/,/^}/p' "$DRIVER" | grep_all_q 'transcript_path'; then
  ok "진행성 오라클이 트랜스크립트를 폴한다"
else
  bad "진행성 오라클" "결과 envelope 을 폴한다 — 도는 내내 0바이트라 신호가 없다"
fi
if sed -n '/^resume_verdict()/,/^}/p' "$DRIVER" | grep_all_q -E 'log/\$stage\.json'; then
  bad "진행성 오라클" "여전히 출력 JSON 크기를 읽는다"
else
  ok "출력 JSON 크기를 진행성 신호로 쓰지 않는다"
fi
# 트랜스크립트를 찾으려면 호출자가 고른 세션 id 가 넘어가야 한다. 함수만 있고
# PATH 정규화는 시스템 접두사를 앞에 두는 것이지 나머지를 버리는 것이 아니다.
# 버렸을 때의 대가가 측정됐다 — Homebrew 접두사에 사는 gh·terraform 이 해소되지
# 않아, 절단점이 PR 이상인 런이 말단 행위를 하나도 수행하지 못했다. 게이트도 룰도
# 통과시킨 뒤 셸이 rc=127 로 죽었고, 통과 행은 이미 원장에 있었다.
fakebin="/opt/cc-cmds-test-prefix/bin"
# `/bin` stays in the seed PATH because that is where `bash` itself lives on the
# hosts this runs on — a seed without it makes the probe fail to launch and the
# assertion then reports an empty PATH instead of the property under test.
newpath=$(PATH="/usr/bin:/bin:$fakebin" bash -c 'CC_ORCH_SOURCE_ONLY=1 . "'"$DRIVER"'" >/dev/null 2>&1; printf %s "$PATH"')
case "$newpath" in
  /usr/bin:/bin:/usr/sbin:/sbin:*) ok "시스템 접두사가 PATH 앞에 온다 (정규화가 남아 있다)" ;;
  *) bad "PATH 정규화" "시스템 접두사가 앞이 아니다: $newpath" ;;
esac
case "$newpath" in
  *"$fakebin"*) ok "물려받은 PATH 가 뒤에 남는다 (행위가 부르는 도구는 시스템 도구가 아니다)" ;;
  *) bad "PATH 절단" "사용자 설치 접두사가 사라졌다: $newpath" ;;
esac

# 호출부가 없으면 파일을 찾을 수도 없다 — 이번 반증의 직접 원인이 그것이었다.
if sed -n '/^stage_spawn()/,/^}/p' "$DRIVER" | grep_all_q -- '--session-id'; then
  ok "stage_spawn 이 --session-id 를 넘긴다"
else
  bad "session-id" "session_uuid 가 정의만 되고 호출부가 없다"
fi
# `--session-id` 는 유효한 UUID 를 요구한다 (맨 32-hex 는 거부됨, 실측).
uu=$(DOC_KEY=x session_uuid "S4:seg:1")
if printf '%s' "$uu" | grep_all_q -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
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
# 같은 문서를 두 번 도는 것은 예외가 아니라 정상이다 — 리메디에이션 런은 앞선
# 런과 같은 문서를 다시 잡는다. 런 id 가 유도에서 빠지면 두 번째 런의 첫 스테이지가
# "Session ID ... is already in use" 로 즉사한다.
uu_r1=$(RUN_ID=r1 DOC_KEY=x session_uuid 'S4:seg:1')
uu_r2=$(RUN_ID=r2 DOC_KEY=x session_uuid 'S4:seg:1')
if [ "$uu_r1" != "$uu_r2" ]; then
  ok "런 id 가 다르면 다른 세션 id"
else
  bad "session_uuid" "런 id 가 달라도 같은 id — 같은 문서의 두 번째 런이 첫 스테이지에서 죽는다"
fi
# 시도 항이 실제로 값을 가른다. 스테이지가 결과를 남기기 전에 죽으면 그 세션 id 는
# 점유된 채 남고, 시도 항이 늘 같은 값이면 같은 세그먼트의 재시도가 CLI 에서
# 「already in use」로 즉사한다 — 게이트를 통과하고 원장에 행을 남긴 뒤에.
uu_a1=$(RUN_ID=r1 DOC_KEY=x session_uuid 'S4:seg:1' 1)
uu_a2=$(RUN_ID=r1 DOC_KEY=x session_uuid 'S4:seg:1' 2)
if [ "$uu_a1" != "$uu_a2" ]; then
  ok "시도 번호가 다르면 다른 세션 id"
else
  bad "session_uuid" "시도가 달라도 같은 id — 죽은 스테이지가 세그먼트를 영구 점유한다"
fi

# 설계 문서가 어느 레포에도 속하지 않는 배치는 공용 계약이 정의하는 경우이지
# 남용이 아니다. 그때 문서 키는 레포 상대 경로가 아니라 절대 경로에서 앞의
# 구분자만 뗀 값이고, `$BASE/$키` 로 합치면 존재하지 않는 경로가 나온다.
if sed -n '/^derive_paths_from_manifest()/,/^}/p' "$DRIVER" | grep_all_q -F 'elif [ -f "/$DOC" ];'; then
  ok "레포 밖 문서 키를 절대 경로로도 해소한다"
else
  bad "문서 경로" "레포 상대 조합 하나뿐이라 레포 밖 문서가 영영 없는 파일이 된다"
fi
# 감사 사이드카는 문서 옆에 놓이므로 런의 베이스가 아니라 문서의 베이스로 찾는다.
if grep_all_q -F '"$DOC_BASE/docs/design-audit/$DOC_SLUG"' "$DRIVER"; then
  ok "감사 술어가 문서의 베이스를 본다"
else
  bad "감사 술어" "런의 베이스를 봐서 문서 옆에 있는 산출물을 없다고 답한다"
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
  # An empty third argument means "omit the binding digest"; a non-empty one is
  # written verbatim so a WRONG value can be exercised.
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
    printf '## 실행 계획\n**승인 문면**: 진행\n'
    printf '```json\n%s\n```\n\n' "$plan"
    printf '## 인가\n**런 최대 절단점**: 머지\n**종료 지점**: 전부 머지\n'
    printf '**벽시계 마감**: 2026-08-26T09:00:00Z\n**시각 정합 마커**: 없음\n'
    printf '**사다리 가용 단 수**: 2\n**미선언 상황 처분**: park\n'
    [ -n "$pdig" ] && printf '**구속 다이제스트**: %s\n' "$pdig"
    printf -- '- `종료 절` | id=C1 | 문면=네 슬라이스가 전부 머지됐다\n'
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
# The plan digest is GONE, and its absence is the point: the router decides the
# step graph one act at a time, so a frozen plan would be recorded and never
# compared — the defect class this contract exists to remove, arriving as a
# leftover. What replaces it freezes the goal and the constraints.
if grep -q '계획 다이제스트' "$DRIVER"; then
  bad "계획 다이제스트 제거" "드라이버가 아직 계획 다이제스트를 읽는다"
else
  ok "계획 다이제스트가 사라졌다 (얼릴 계획이 더는 없다)"
fi

write_manifest "$MF" "" "1111111111111111111111111111111111111111111111111111111111111111"
if ( check_manifest ) >/dev/null 2>&1; then
  bad "구속 다이제스트" "틀린 다이제스트를 통과시켰다"
else
  ok "구속 다이제스트 불일치가 거부된다"
fi

# Present-and-correct must pass, or the assertion above is satisfied by a field
# that always fails.
MANIFEST="$MF"
write_manifest "$MF" "" "$(binding_set_bytes | shasum -a 256 | cut -d' ' -f1)"
if ( check_manifest ) >/dev/null 2>&1; then
  ok "올바른 구속 다이제스트는 통과한다"
else
  bad "구속 다이제스트" "맞는 값인데 거부됐다: $( ( check_manifest ) 2>&1 | tail -1 )"
fi

# A goal edit must move it — otherwise the digest is over something that cannot
# change and the check is vacuous.
bd_before=$(binding_set_bytes | shasum -a 256 | cut -d' ' -f1)
sed 's/\*\*종료 지점\*\*: 전부 머지/**종료 지점**: 하나만 머지/' "$MF" > "$MF.g" && mv "$MF.g" "$MF"
if [ "$(binding_set_bytes | shasum -a 256 | cut -d' ' -f1)" = "$bd_before" ]; then
  bad "구속 집합 감도" "종료 지점을 바꿨는데 다이제스트가 그대로다"
else
  ok "종료 지점이 바뀌면 구속 다이제스트가 움직인다"
fi
write_manifest "$MF"

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
if sed -n '/^stash_ref()/,/^}/p' "$DRIVER" | grep_all_q 'cd "\$root"'; then
  ok "stash_ref 가 명시적 cwd 를 쓴다"
else
  bad "stash_ref" "상속 cwd 로 읽는다 — 비레포에서 가드가 공허하게 통과한다"
fi
if sed -n '/^stash_attribution_check()/,/^}/p' "$DRIVER" | grep_all_q 'cd "\$root"'; then
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
  bad "gh -R" "cwd 상속 호출이 남았다: $(printf '%s' "$BARE_GH" | awk 'NR<=3' | tr '\n' ' ')"
fi
if sed -n '/^gh_q()/,/^}/p' "$DRIVER" | grep_all_q '2>"\$errf"'; then
  ok "gh_q 가 stderr 를 캡처한다"
else
  bad "gh_q" "stderr 를 버린다 — 비레포 오류가 빈 PR 번호로 삼켜진다"
fi
if sed -n '/^merge_gate()/,/^}/p' "$DRIVER" | grep_all_q 'GH_STDERR'; then
  ok "머지 게이트의 park 사유가 캡처한 stderr 를 싣는다"
else
  bad "merge_gate" "원인을 버리고 park 한다"
fi
# 술어는 세그먼트의 레포에서 평가돼야 한다. 홈에서 평가하면 홈이 아닌 레포의
# 모든 세그먼트가 만들어진 적 없는 브랜치를 조회당해 공허한 성공으로 떨어진다.
if sed -n '/^predicate_implement()/,/^}/p' "$DRIVER" | grep_all_q 'seg_root'; then
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
if sed -n '/^apply_stage()/,/^}/p' "$DRIVER" | grep_all_q 'ladder_bump'; then
  bad "사다리" "apply 실패가 사다리 단을 소비한다"
else
  ok "apply 는 사다리 단을 소비하지 않는다"
fi
# (9) 실행자가 드라이버여야 한다 — 즉흥하는 스테이지는 프로브를 돌리고 아무 말이나 할 수 있다.
if sed -n '/^apply_stage()/,/^}/p' "$DRIVER" | grep_all_q 'stage_spawn\|dispatch_stage'; then
  bad "실행자" "apply 를 모델에 디스패치한다 — 날조 가능한 표면"
else
  ok "apply 는 드라이버가 직접 실행한다"
fi

MANIFEST=""; DOC="$AP_DOC_SAVE"; LEDGER="$AP_LEDGER_SAVE"; BASE="$AP_BASE_SAVE"; SLUG="$AP_SLUG_SAVE"
grant_field() { printf 'PR'; }          # 이후 절을 위해 원래 스텁으로 되돌린다
rm -f "$RUN_DIR/plan.tsv"

# 킥오프 판정은 드라이버가 아니라 스킬이 쓰지만 프롬프트와 스키마는 여기 산다.
# 짝이 깨지면 1막이 계약 없이 판정하게 되고, 그 판정 위에 매니페스트가 동결된다.
for pair in entry-plan; do
  if [ -f "$script_dir/prompts/$pair.md" ]; then ok "킥오프 프롬프트 존재: $pair"; else bad "프롬프트" "$pair.md 없음"; fi
  if jq empty "$script_dir/prompts/$pair.schema.json" 2>/dev/null; then
    ok "킥오프 스키마가 유효한 JSON: $pair"
  else
    bad "스키마" "$pair.schema.json 가 유효한 JSON 이 아님"
  fi
done

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
  bad "park 스코프" "지명하지 않은 호출부: $(printf '%s' "$UNSCOPED" | awk 'NR<=3' | tr '\n' ' ')"
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
if sed -n '/^segment_cycle()/,/^}/p' "$DRIVER" | grep_all_q 'return 4'; then
  ok "완성-미착지가 자기 반환 코드를 가진다"
else
  bad "완성-미착지" "막힌 말단 행위가 park 과 구별되지 않는다"
fi
if sed -n '/^main_loop()/,/^}/p' "$DRIVER" | grep_all_q '완성-미착지'; then
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
if sed -n '/^  if \[ "\$cycle" -ge "\$cap" \]/,/^  fi$/p' "$DRIVER" | grep_all_q '사다리 R4'; then
  bad "오라벨" "사이클 상한 자리에 사다리 R4 가 남았다"
else
  ok "사이클 상한 자리에 사다리 R4 라벨이 없다"
fi

# K 를 상수로 명명했는가. 두 상한이 같은 값을 참조해야 하는데 예전에는
# 서로 무관한 리터럴 둘이었다.
check "동일성당 단 수가 상수다" "$LADDER_RUNGS" "4"
check "세그먼트 상한 = K*F+1 (F=3)" "$(segment_cap 3)" "13"
check "세그먼트 상한 = K*F+1 (F=1)" "$(segment_cap 1)" "5"
if sed -n '/^segment_cycle()/,/^}/p' "$DRIVER" | grep_all_q -E 'cap=\$\(\( *4 \*'; then
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
if sed -n '/^plan_from_declaration()/,/^}/p' "$DRIVER" | grep_all_q 'plan_cell' \
   && sed -n '/^plan_via_planner()/,/^}/p' "$DRIVER" | grep_all_q 'plan_cell'; then
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
if sed -n '/^ladder_bump()/,/^}/p' "$DRIVER" | grep_all_q 'printf .99'; then
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
if sed -n '/^past_deadline()/,/^}/p' "$DRIVER" | grep_all_q -E 'kill|reap_orphan'; then
  bad "마감" "마감이 kill 신호로 쓰인다 — 비행 중 스테이지를 죽이면 모호한 반쯤 상태가 생긴다"
else
  ok "마감은 kill 신호가 아니다"
fi
if sed -n '/^segment_cycle()/,/^}/p' "$DRIVER" | grep -B8 'merge_gate "\$seg"' | grep_all_q 'past_deadline'; then
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
if sed -n '/^segment_cycle()/,/^}/p' "$DRIVER" | grep_all_q 'plan_digest'; then
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
if sed -n '/^fileset_escape()/,/^}/p' "$DRIVER" | grep_all_q '실제 편집 집합'; then
  ok "이탈 행이 선언 집합과 실제 집합을 모두 적는다"
else
  bad "이탈 행" "이탈만 적어 과소 선언과 배회를 구별할 수 없다"
fi
if sed -n '/^fileset_escape()/,/^}/p' "$DRIVER" | grep_all_q '형제'; then
  bad "이탈 팔" "웨이브 형제 팔이 남았다 — 겹치는 선언 파일은 이제 설계된 정상이라 올바른 계획을 park 한다"
else
  ok "웨이브 형제 팔이 없다 (2분기)"
fi

# declared_files 가 디스패치 줄에 실린다.
if sed -n '/^segment_cycle()/,/^}/p' "$DRIVER" | grep_all_q '선언 파일: \$files'; then
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

# ---------------------------------------------------------------------------
# 21. 장식 삭제와 미배선 탐지기
# ---------------------------------------------------------------------------
# 이 절이 지키는 것은 「지금 깨끗하다」가 아니라 「다시 더러워지면 실패한다」다.
for gone in STAGE_IDS CRASH_RETRIES HOLLOW_SUCCESS_RETRIES WAVE_DEMOTED wave_mode predicate_design; do
  if grep -q "$gone" "$DRIVER"; then
    bad "장식 삭제" "$gone 이 남았다"
  else
    ok "삭제됨: $gone"
  fi
done
if sed 's/#.*//' "$DRIVER" | grep_all_q '형제'; then
  bad "웨이브 어휘" "형제 팔이 남았다 — 도달 불가한 분기이고 그 플래그는 참이 될 수 없다"
else
  ok "형제 충돌 팔이 삭제됐다 (병렬 웨이브가 없으므로 도달 불가였다)"
fi
if grep -q '"mode"\|serial_reason' "$script_dir/prompts/segment-plan.schema.json"; then
  bad "스키마 어휘" "계획기가 계약상 웨이브 어휘를 방출해야 하는 상태로 남았다"
else
  ok "계획기 스키마에서 웨이브 어휘가 사라졌다"
fi
if grep -qi 'antichain' "$script_dir/prompts/segment-plan.md"; then
  bad "계획기 프롬프트" "antichain 스케줄링 문면이 남았다"
else
  ok "계획기 프롬프트에서 antichain 문면이 사라졌다"
fi
# 규칙의 실질은 살아 있어야 한다 — 삭제가 규칙까지 가져가면 설계 문서가 두
# 세그먼트의 공유 쓰기 대상이 되어 diff 게이트가 터진다.
if grep -q '잔여\|residual' "$script_dir/prompts/segment-plan.md"; then
  ok "잔여 항목을 한 세그먼트에 모으는 규칙은 존치한다"
else
  bad "계획기 프롬프트" "웨이브 어휘와 함께 규칙의 실질까지 사라졌다"
fi

# 탐지기 — 자기 자신에 대해 통과해야 하고, 결함을 심으면 실패해야 한다.
SC_OUT="$WORK/selfcheck.out"
env -u CC_ORCH_SOURCE_ONLY CC_CMDS_ORCH_HOST_OS=Darwin bash "$DRIVER" --self-check > "$SC_OUT" 2>&1
if grep -q '선언된 것에 전부 독자·호출부·비교자가 있다' "$SC_OUT"; then
  ok "미배선 탐지기가 이 드라이버에 대해 통과한다"
else
  bad "탐지기" "$(grep '^FAIL' "$SC_OUT" | awk 'NR<=3' | tr '\n' ' ')"
fi
if grep -q '조건부 배선 예외' "$SC_OUT"; then
  ok "예외 등재 목록의 상태가 원장에 남는다 (비어 있어도 그 사실이 보인다)"
else
  bad "탐지기" "예외 목록이 보이지 않는다 — 아무도 못 보는 예외는 검사가 안 도는 것과 구별되지 않는다"
fi
# 결함을 심고 실제로 잡히는지 — 이 확인이 없으면 위 통과가 공허할 수 있다.
SC_DIRTY="$WORK/dirty-driver.sh"
sed 's/^readonly LADDER_RUNGS=4$/readonly LADDER_RUNGS=4\nreadonly NOBODY_READS_THIS=1/' "$DRIVER" > "$SC_DIRTY"
env -u CC_ORCH_SOURCE_ONLY CC_CMDS_ORCH_HOST_OS=Darwin bash "$SC_DIRTY" --self-check > "$SC_OUT" 2>&1
if grep -q 'NOBODY_READS_THIS' "$SC_OUT"; then
  ok "독자 없는 상수를 심으면 탐지기가 잡는다"
else
  bad "탐지기" "독자 없는 상수를 놓쳤다 — 통과가 공허하다"
fi
sed 's/^ladder_init() {/nobody_calls_this() { :; }\nladder_init() {/' "$DRIVER" > "$SC_DIRTY"
env -u CC_ORCH_SOURCE_ONLY CC_CMDS_ORCH_HOST_OS=Darwin bash "$SC_DIRTY" --self-check > "$SC_OUT" 2>&1
if grep -q 'nobody_calls_this' "$SC_OUT"; then
  ok "호출부 0 인 함수를 심으면 탐지기가 잡는다"
else
  bad "탐지기" "호출부 0 인 함수를 놓쳤다 — 이번 반증의 직접 원인이 그 부류였다"
fi

# ---------------------------------------------------------------------------
# N. Run identity vs document identity — the two must not share one variable
#
# A manifest run set SLUG to the run id and a document run set it to the
# document key, while ONE consumer (the audit artifact predicate) needs the
# document key in both. Whichever value went in, the other consumer read a path
# that does not exist: the manifest run's audit predicate globbed
# `docs/design-audit/<run-id>.reader-*.md`, always missed, and every run died at
# its first stage as a hollow success. These assertions pin the split.
# ---------------------------------------------------------------------------
MFD="$MF_DIR/plan-doc.md"
write_manifest "$MFD"
# Same fixture, but naming a document — the arm that must yield a DOC_SLUG.
sed 's#^\*\*설계 문서\*\*: (없음)$#**설계 문서**: docs/some/design-note.md#' "$MFD" > "$MFD.tmp" && mv "$MFD.tmp" "$MFD"

MANIFEST="$MFD"; RUN_ID="20260825-deadbeef"
derive_paths_from_manifest
check "매니페스트 진입: SLUG 는 런 정체다" "$SLUG" "20260825-deadbeef"
check "매니페스트 진입: DOC_SLUG 는 문서 정체다" "$DOC_SLUG" "docs-some-design-note"
if [ "$SLUG" != "$DOC_SLUG" ]; then
  ok "두 정체가 실제로 다른 값을 갖는다 (한 변수였다면 불가능하다)"
else
  bad "정체 분리" "SLUG 와 DOC_SLUG 가 같다 — 분리가 이름뿐이다"
fi

# The DISCRIMINATING assertion: a manifest run whose audit really did publish
# its reader reports. The reports land at the DOCUMENT slug, because the shared
# sidecar contract keys that one path on the document. Reading them at the run
# id — what the single-variable version did — misses every time, and the miss is
# classified as a hollow success, which is a run-scope park at the first stage.
# A negative-only test cannot see this: with no reports on disk BOTH versions
# return false, so the assertion passes while the bug is fully present.
RUN_DIR_SAVE="${RUN_DIR:-}"; BASE_SAVE="$BASE"
MANIFEST="$MFD"; RUN_ID="20260825-deadbeef"
derive_paths_from_manifest
# 산출물은 문서의 베이스 아래에 놓는다. 런의 베이스와 문서의 베이스는 문서가 어느
# 레포에도 속하지 않을 때 서로 다른 디렉터리이고, 사이드카는 문서 옆에 놓인다.
BASE="$WORK/audit-run-base"; DOC_BASE="$WORK/audit-doc-base"
RUN_DIR="$WORK/audit-pred"
mkdir -p "$RUN_DIR/log" "$BASE/docs/design-audit" "$DOC_BASE/docs/design-audit"
printf '%s\n' "$LIT_AUDIT_TERMINAL" > "$RUN_DIR/log/S2.json"
: > "$DOC_BASE/docs/design-audit/$DOC_SLUG.reader-1.md"
if predicate_audit S2; then
  ok "감사 산출물이 문서 슬러그에 있으면 매니페스트 런의 술어가 통과한다"
else
  bad "감사 술어" "문서 슬러그의 리더 리포트를 찾지 못했다 — 런 id 로 보고 있다"
fi
# And the same run must NOT pass by looking at the run id.
: > "$DOC_BASE/docs/design-audit/$RUN_ID.reader-1.md"
rm -f "$DOC_BASE/docs/design-audit/$DOC_SLUG.reader-1.md"
if predicate_audit S2; then
  bad "감사 술어" "런 id 경로의 파일로 통과했다 — 문서 파생이 아니다"
else
  ok "런 id 경로에만 산출물이 있으면 통과하지 않는다"
fi
# 그리고 런의 베이스 아래에만 있으면 통과하지 않는다 — 레포 밖 문서에서는 이 둘이
# 갈리고, 런의 베이스를 보면 문서 옆에 있는 산출물을 없다고 답한다.
rm -f "$DOC_BASE/docs/design-audit/$RUN_ID.reader-1.md"
: > "$BASE/docs/design-audit/$DOC_SLUG.reader-1.md"
if predicate_audit S2; then
  bad "감사 술어" "런의 베이스로 통과했다 — 문서의 베이스를 보지 않는다"
else
  ok "런의 베이스에만 산출물이 있으면 통과하지 않는다 (사이드카는 문서 옆에 있다)"
fi

MANIFEST="$MF"; RUN_ID="20260825-deadbeef"
derive_paths_from_manifest
check "문서 없는 런은 DOC_SLUG 가 비어 있다" "$DOC_SLUG" ""
BASE="$WORK/audit-base"
if predicate_audit S2; then
  bad "감사 술어" "DOC_SLUG 가 빈데도 통과했다 — 빈 슬러그로 디렉터리를 글로빙한 것이다"
else
  ok "DOC_SLUG 가 비면 감사 술어는 통과하지 않는다"
fi
RUN_DIR="$RUN_DIR_SAVE"; BASE="$BASE_SAVE"

# The driver hands the run id and both sidecar paths down to every stage. The
# arms re-derived them from the document key, which resolves only for a run
# started from a document, so a manifest run's arm could not reach the grant it
# must read to write a halt record.
for v in CC_PIPELINE_RUN_ID CC_PIPELINE_GRANT CC_PIPELINE_LEDGER CC_PIPELINE_RUN_DIR; do
  if grep -q "$v=" "$DRIVER"; then
    ok "스테이지에 $v 를 넘긴다"
  else
    bad "환경 전달" "$v 가 스테이지로 넘어가지 않는다"
  fi
done

# ---------------------------------------------------------------------------
# 22. 원장의 둘째 필자도 게이트와 같은 필드 정규화를 받는다
#
# `ledger_row` 는 게이트와 같은 파일에 쓰면서 게이트의 바닥을 하나도 거치지
# 않았다. `|` 는 필드를 가르고 개행은 행을 끝내므로, 그 둘을 담은 값은 행 문법을
# 스플라이스한다 — 그리고 이 함수에 닿는 값은 설계 문서의 `선행`·`선언 파일
# 집합`과 모델 출력이라 한국어 산문의 파이프가 예사롭다. 스플라이스된 `segment`
# 행은 지저분한 정도가 아니다: 모든 판독기가 행 텍스트를 `|` 로 가르고 `id=` 를
# 탐욕적으로 잡으므로, 그 행이 어느 세그먼트에 대한 것인지가 바뀐다.
# ---------------------------------------------------------------------------
LEDGER_SAVE="$LEDGER"
LEDGER="$WORK/ledger-norm.md"; : > "$LEDGER"
ledger_row 'segment' "id=SP" "선행=SA|SB" "사유=파이프 | 가 든 산문"
# 행 텍스트를 직접 본다 — `ledger_last` 는 마지막 필드가 아닌 값에 후행 공백을
# 남기므로, 그것으로 재면 정규화가 아니라 판독기의 손질을 재게 된다.
case "$(grep -F 'id=SP' "$LEDGER")" in
  *'| 선행=SA/SB |'*) ok "값 안의 파이프가 슬래시로 바뀐다" ;;
  *) bad "필드 정규화" "$(grep -F 'id=SP' "$LEDGER")" ;;
esac
check "그 행은 여전히 한 줄이다" "$(grep -c . "$LEDGER")" "1"
case "$(grep -F 'id=SP' "$LEDGER")" in
  *'사유=파이프 / 가 든 산문'*) ok "산문 안의 파이프도 새 필드를 만들지 못한다" ;;
  *) bad "필드 정규화" "$(grep -F 'id=SP' "$LEDGER")" ;;
esac
: > "$LEDGER"
ledger_row 'segment' "id=SN" "사유=첫 줄
둘째 줄"
check "값 안의 개행이 행을 끊지 못한다" "$(grep -c . "$LEDGER")" "1"
# 상한을 넘는 행은 `die` 로 멈춘다 — 게이트와 같은 처분이므로 서브셸에서 잰다.
LONGV=$(printf '%1100s' '' | tr ' ' 'x')
( ledger_row 'segment' "id=SL" "사유=$LONGV" ) >/dev/null 2>&1
check "상한을 넘는 행은 거부된다" "$?" "1"
check "거부된 행은 원장에 남지 않는다" "$(grep -cF 'id=SL' "$LEDGER" || true)" "0"
LEDGER="$LEDGER_SAVE"

# ---------------------------------------------------------------------------
# 23. `선행` 판독기는 하나이고, 게이트의 것과 같은 어휘를 쓴다
#
# 이 필드의 판독기가 두 파일에 넷 있었고 어느 둘도 일치하지 않았다. 이쪽 셋은
# 널 sentinel 을 토큰이 아니라 값 전체에 대고 검사해 `없음,SA` 가 한쪽에는 실제
# 목록이고 다른 쪽에는 아무것도 아니었으며, 게이트의 판독기는 `-` 를 널로 받지도
# 설계 문서가 적는 `슬라이스 ` 접두사를 벗기지도 않아 한 의존의 한 철자가 이쪽에선
# 한 토큰이고 저쪽에선 미지 토큰 둘이었다 — 그리고 저쪽이 행을 쓸 수 있는지를
# 정하는 바닥이다.
# ---------------------------------------------------------------------------
check "쉼표와 공백 철자가 같은 토큰 집합으로 읽힌다" "$(dep_tokens 'SA, SB')" "SA SB"
check "공백만으로 구분한 철자도 같다" "$(dep_tokens 'SA SB')" "SA SB"
check "슬라이스 접두사가 벗겨진다" "$(dep_tokens '슬라이스 SA, 슬라이스 SB')" "SA SB"
check "널 sentinel 은 토큰 단위로 떨어진다" "$(dep_tokens '없음,SA')" "SA"
check "괄호 친 없음도 널이다" "$(dep_tokens '(없음)')" ""
check "대시도 널이다" "$(dep_tokens '-')" ""
check "빈 값도 널이다" "$(dep_tokens '')" ""
# 세 소비처가 전부 그 하나를 거치는지 — 이 항목의 값은 정규화 자체가 아니라
# 정규화가 한 곳에 있다는 사실이므로, 판독기가 다시 갈라지면 여기서 잡힌다.
for fn in deps_satisfied cross_repo_deps radius_park; do
  if sed -n "/^$fn()/,/^}/p" "$DRIVER" | grep_all_q 'dep_tokens'; then
    ok "$fn 이 dep_tokens 를 거친다"
  else
    bad "선행 판독기" "$fn 이 자기 정규화를 갖고 있다"
  fi
done
# 그리고 게이트의 sentinel 집합과 축자로 같은지. 두 번 적은 합의는 누군가 한쪽을
# 고치기 전까지만 합의이므로, 우연처럼 보이게 두지 않는다.
GATE_SH="$(dirname "$DRIVER")/gate.sh"
sent_run=$(sed -n '/^dep_tokens()/,/^}/p' "$DRIVER" | grep -cF "''|'-'|'없음'|'(없음)'" || true)
sent_gate=$(sed -n '/^gate_dep_tokens()/,/^}/p' "$GATE_SH" | grep -cF "''|'-'|'없음'|'(없음)'" || true)
if [ "${sent_run:-0}" -ge 1 ] && [ "$sent_run" = "$sent_gate" ]; then
  ok "두 판독기의 널 sentinel 집합이 축자로 같다"
else
  bad "sentinel 일치" "run.sh ${sent_run}회 vs gate.sh ${sent_gate}회"
fi
if sed -n '/^gate_dep_tokens()/,/^}/p' "$GATE_SH" | grep_all_q '슬라이스'; then
  ok "게이트의 판독기도 슬라이스 접두사를 벗긴다"
else
  bad "접두사 일치" "게이트 쪽은 여전히 슬라이스 접두사를 토큰의 일부로 읽는다"
fi
# `선행` 하나짜리 목록이 공허하게 충족되지 않는지. 옛 형태는 파이프 오른쪽의
# `read` 가 개행 없는 마지막 줄에서 비영으로 끝나 마지막 항목을 건너뛰었고, 그래서
# 원소가 하나면 의존 가드가 전부 통과해 위상 순회가 임의 순서로 무너졌다.
DONE_SAVE="${RUN_DIR}"
RUN_DIR="$WORK/deps-run"; mkdir -p "$RUN_DIR"
printf 'SA\n' > "$RUN_DIR/done.txt"
if deps_satisfied '없음'; then ok "없음 은 충족으로 읽힌다"; else bad "선행 충족" "없음 이 미충족이 됐다"; fi
if deps_satisfied 'SA'; then ok "착지한 선행 하나는 충족이다"; else bad "선행 충족" "SA 가 done 에 있는데 미충족이다"; fi
if deps_satisfied 'SZ'; then bad "선행 충족" "착지하지 않은 원소 하나짜리 목록이 공허하게 통과했다"; else ok "착지하지 않은 원소 하나짜리 목록은 미충족이다"; fi
if deps_satisfied 'SA,SZ'; then bad "선행 충족" "뒤쪽 원소를 건너뛰었다"; else ok "목록의 뒤쪽 원소도 검사된다"; fi
if deps_satisfied '슬라이스 SA'; then ok "슬라이스 접두사를 쓴 선행도 충족으로 해소된다"; else bad "선행 충족" "접두사가 붙으면 미충족이 된다"; fi
RUN_DIR="$DONE_SAVE"

# ---------------------------------------------------------------------------
# 24. 아침 리포트가 게이트의 종단 줄을 싣는다
#
# 열린 물음과 그것이 붙들고 있는 종료 절은 전부 `done` 파일에만 있었고, 사람이
# 읽는 유일한 면인 아침 리포트에는 한 글자도 닿지 않았다. 물음 셋을 남기고 끝난
# 런과 하나도 남기지 않은 런이 같은 리포트를 썼다.
# ---------------------------------------------------------------------------
RUN_DIR_SAVE3="$RUN_DIR"; BASE_SAVE3="$BASE"; RUN_ID_SAVE3="$RUN_ID"
RUN_DIR="$WORK/res-run"; mkdir -p "$RUN_DIR"
BASE="$WORK/res-base"; RUN_ID="resrun"
report_run_residual
if [ -f "$(report_path)" ]; then
  bad "종료 잔여" "done 파일이 없는데 리포트를 만들었다"
else
  ok "done 파일이 없으면 조용히 건너뛴다 (제안하지 않은 런의 정상 경로다)"
fi
printf '2026-09-02T00:00:00Z 종단 — 질의 잔여 2건 · 승인 J-aaaa1111 J-bbbb2222 · 보류 절 K1(J-aaaa1111) K2(J-bbbb2222) · 근거 x\n' \
  > "$RUN_DIR/done"
report_run_residual
RES_REPORT="$(report_path)"
if [ -f "$RES_REPORT" ] && grep_all_q -F '질의 잔여 2건' < "$RES_REPORT"; then
  ok "종단 줄의 질의 잔여가 리포트에 도달한다"
else
  bad "종료 잔여" "$(cat "$RES_REPORT" 2>/dev/null || printf '(리포트 없음)')"
fi
if grep_all_q -F '보류 절 K1(J-aaaa1111) K2(J-bbbb2222)' < "$RES_REPORT"; then
  ok "보류 절 항목과 승인 id 가 축자로 도달한다 (재구성이 아니라 전달이다)"
else
  bad "종료 잔여" "$(cat "$RES_REPORT" 2>/dev/null || printf '(리포트 없음)')"
fi
RUN_DIR="$RUN_DIR_SAVE3"; BASE="$BASE_SAVE3"; RUN_ID="$RUN_ID_SAVE3"
# 종료 요약의 단어. `보류` 는 사람의 답을 기다리는 종료 절의 처분이고 이 계수기는
# 드라이버가 park 한 세그먼트를 센다 — 같은 리포트에 둘 다 나오므로, 한 단어가 두
# 뜻을 가지면 읽는 사람이 줄마다 어느 쪽인지 짐작해야 한다.
if grep -qF 'park ${parked}건' "$DRIVER"; then
  ok "종료 요약이 park 된 세그먼트를 park 이라 부른다"
else
  bad "종료 요약" "park 계수기의 이름이 park 이 아니다"
fi
if grep -qF '보류 ${parked}건' "$DRIVER"; then
  bad "종료 요약" "park 계수기를 아직 보류 라고 부른다 — 종료 절의 보류와 한 단어다"
else
  ok "park 계수기가 종료 절의 보류와 다른 단어를 쓴다"
fi

# ---------------------------------------------------------------------------
# The detach path is gone, and its absence is asserted rather than assumed.
#
# The run is driven by the main session's model now. Detaching would move the
# deciding turn somewhere nobody can see, which is the one thing that silently
# undoes the reason for this shape — so a re-introduced flag has to fail a test
# rather than merely contradict a comment.
# ---------------------------------------------------------------------------
if grep -qE '(^[^#]*--detach\)|DETACH=)' "$DRIVER"; then
  bad "detach 제거" "--detach 가 다시 들어왔다 — 판단하는 턴이 보이지 않는 곳으로 간다"
else
  ok "detach 경로가 없다 (라우터가 이 세션이므로 떼어 낼 것이 없다)"
fi

printf '\ntest-run: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
