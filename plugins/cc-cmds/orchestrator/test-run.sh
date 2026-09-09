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

# THE RUN NOTIFIER IS OFF FOR THIS WHOLE PROCESS. The gate, the driver and the
# watcher all raise real banners, and their fire path prepends the Homebrew
# directories to PATH itself — so a stub this suite puts on PATH is shadowed by
# whatever is really installed, and an ordinary `make test` reaches the user.
# Measured on this tree: two banners arrived from a test run, one with sound.
#
# Exported rather than set per call, because the call sites cannot be made
# exhaustive — a new invocation is a normal thing to write and would silently
# not carry the guard. This suite asserts nothing about banner content, so
# turning the channel off costs it nothing.
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY


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

# ---------------------------------------------------------------------------
# 12c. 리뷰에 실리는 base 는 분기점이지 재개 시점의 HEAD 가 아니다
# ---------------------------------------------------------------------------
# 이 결함은 코드 모양이 아니라 값 흐름이다 — 플래그도 함수도 제자리에 있고
# 실리는 값만 틀리므로, 본문 스캔만으로는 틀린 값이 실린 채 초록이 된다.
# 그래서 두 값이 실제로 갈라지는 트리를 만들어 구별부터 세우고, 그다음 파견
# 줄이 어느 쪽 이름을 싣는지 본다.
#
# 재개된 런은 이미 있는 워크트리를 그대로 돌려받으므로 그때의 HEAD 는
# 브랜치 팁이다. 그 값은 분기점의 후손이라 세 리뷰 팔이 처방하는
# `--is-ancestor` 를 통과한다 — 가드가 걸리지 않고 리뷰 범위만 조용히 좁는다.
BW="$WORK/basewt"
rm -rf "$BW"; mkdir -p "$BW"
( cd "$BW" && git init -q . && git config user.email t@t && git config user.name t \
  && : > a.txt && git add a.txt && git commit -qm base \
  && git branch -q -f seg/x && git checkout -q seg/x \
  && : > b.txt && git add b.txt && git commit -qm ontop ) >/dev/null 2>&1
BP=$( cd "$BW" && git rev-parse HEAD~1 )
TIP=$( cd "$BW" && git rev-parse HEAD )
if [ -n "$BP" ] && [ "$BP" != "$TIP" ]; then
  ok "분기점과 재개 시점 HEAD 는 서로 다른 값이다 (구별이 성립한다)"
else
  bad "분기점과 재개 시점 HEAD" "두 값이 같아 이 단언이 아무것도 구별하지 못한다"
fi
if ( cd "$BW" && git merge-base --is-ancestor "$TIP" seg/x ) >/dev/null 2>&1; then
  ok "재개 HEAD 는 조상 검사를 통과한다 (가드가 걸리지 않는다)"
else
  bad "재개 HEAD 의 조상 검사" "통과하지 않는다 — 이 결함의 전제가 성립하지 않는다"
fi
# 그리고 파견 줄이 싣는 것은 분기점 쪽 이름이어야 한다.
if sed -n '/^segment_cycle()/,/^}/p' "$DRIVER" | grep_all_q -- '--base-sha \$seg_base'; then
  ok "리뷰 파견이 분기점 값을 싣는다"
else
  bad "리뷰 파견의 base" "분기점이 아닌 값을 싣는다 — 재개 워크트리에서 범위가 조용히 좁아진다"
fi
if sed -n '/^segment_cycle()/,/^}/p' "$DRIVER" | grep_all_q -- '--base-sha \$pre_head'; then
  bad "리뷰 파견의 base" "사전 HEAD 를 싣고 있다"
else
  ok "리뷰 파견이 사전 HEAD 를 싣지 않는다"
fi
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

# 대상 행이 가리키는 레포는 픽스처다. 이 스위트의 초록을 주변 클론에 어떤 이름의
# 브랜치가 있는지에 묶으면 안 된다 — `actions/checkout` 의 기본 얕은 단일 ref
# 체크아웃에는 `refs/heads/master` 도 `refs/remotes/origin/master` 도 없고, 그 위에서
# 대상 행이 실제 체크아웃을 가리키면 CI 가 이 스위트에서 깨진다. 형제 스냅숏 픽스처가
# 브랜치를 고정하는 것과 같은 이유이며, 같은 방식으로 고정한다.
#
# `origin-worktree=` 는 실행 중인 레포여야 한다(그 자리는 현재 공통 git 디렉터리와
# 대조된다). 그래서 헤더는 `$HERE` 로 두고 대상 행만 떼어 낸다.
#
# 원격 추적 ref 를 손으로 만들어 둔다. 베이스 브랜치 검사는 `base_sha` 가 소비할 수
# 있는 형태 — `refs/remotes/origin/…` — 만 받으므로, 로컬 헤드만 있는 픽스처는 검사를
# 통과하지 못한다.
MF_REPO="$WORK/manifest-repo"; mkdir -p "$MF_REPO"
( cd "$MF_REPO" \
  && git init -q . \
  && git config user.email t@example.invalid \
  && git config user.name  T \
  && git commit -q --allow-empty --no-gpg-sign -m init \
  && git branch -M main \
  && git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1
MF_CG=$(cd "$MF_REPO" && git rev-parse --path-format=absolute --git-common-dir)
# 핀이 실패해도 조용하다 — 위 체인은 출력을 버리고 종료 상태를 아무도 읽지 않는다.
# 그래서 핀을 반증 가능하게 만드는 단언을 여기 둔다.
check "매니페스트 픽스처 레포의 베이스 브랜치가 고정됐다" \
  "$( cd "$MF_REPO" && git rev-parse --abbrev-ref HEAD )" "main"

write_manifest() {   # write_manifest <출력> [대상맵다이제스트override] [계획다이제스트override] [베이스브랜치] [설계문서]
  # 넷째 인자는 베이스 브랜치를 갈아 끼운다. 기본값은 픽스처 레포에 고정해 둔 이름이라
  # 기존 호출은 넷을 세지 않은 채 그대로 성립하고, 해소되지 않는 값을 넣어야만 하는
  # 절만 명시한다. 다섯째는 헤더의 `owner-doc=` 과 본문의 「설계 문서」를 함께 움직인다
  # — 프리플라이트가 그 둘을 대조하므로 한쪽만 바꾸면 검사가 그 불일치에서 멈춘다.
  local out="$1" tdig="${2:-}" pdig="${3:-}" bb="${4:-main}" doc="${5:-(없음)}"
  local trow="- \`target\` | 별칭=home | 메인 워크트리=$MF_REPO | 공통 git 디렉터리=$MF_CG | 베이스 브랜치=$bb | 홈=예 | 원격 슬러그=Nharu/cc-cmds | 절단점=머지 | 말단 행위 상한=없음"
  local plan='{ "steps": ["audit", "implement"] }'
  [ -n "$tdig" ] || tdig=$(printf '%s\n' "$trow" | sed 's/[[:space:]]\{1,\}/ /g' | sort | shasum -a 256 | cut -d' ' -f1)
  # An empty third argument means "omit the binding digest"; a non-empty one is
  # written verbatim so a WRONG value can be exercised.
  {
    printf '# 파이프라인 런 매니페스트 — 20260825-deadbeef\n'
    printf '<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=20260825-deadbeef;\n'
    printf '     anchor-kind=repo; anchor-key=Nharu/cc-cmds;\n'
    printf '     owner-doc=%s; origin-worktree=%s;\n' "$doc" "$HERE"
    printf '     NOT a design doc; mechanism-local, never staged by a skill -->\n\n'
    printf '## 런 정체\n**킥오프 일시**: 2026-08-25T00:00:00Z\n**런 id**: 20260825-deadbeef\n'
    printf '**앵커 종류**: repo\n**앵커 키**: Nharu/cc-cmds\n**사용자 확인 문면**: 돌려라\n\n'
    printf '## 대상\n**대상 맵 다이제스트**: %s\n%s\n\n' "$tdig" "$trow"
    printf '## 요소\n**설계 문서**: %s\n**적용 주체**: (해당 없음)\n\n' "$doc"
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

# 헤더의 `owner-doc=` 은 게이트가 인가 판정의 유일 권위로 쓰는 필드인데, 프리플라이트가
# 다른 헤더 필드는 전부 본문과 대조하면서 이 하나만 보지 않았다. 그런 매니페스트는
# 검사를 통과해 런이 시작되고, 그다음 게이트가 그 런의 모든 행위를 거부한다.
write_manifest "$MF"; sed 's/ owner-doc=[^;]*;//' "$MF" > "$MF.x" && mv "$MF.x" "$MF"
if ( check_manifest ) >/dev/null 2>&1; then
  bad "소유 증명" "owner-doc= 없이 통과했다 — 게이트가 빈 값으로 모든 행위를 거부한다"
else
  ok "헤더 owner-doc= 부재는 fail-closed"
fi
write_manifest "$MF"; sed 's/^\*\*설계 문서\*\*: .*/**설계 문서**: docs\/다른문서.md/' "$MF" > "$MF.x" && mv "$MF.x" "$MF"
if ( check_manifest ) >/dev/null 2>&1; then
  bad "소유 증명" "헤더 owner-doc= 와 본문 설계 문서가 달라도 통과했다"
else
  ok "헤더 owner-doc= 와 본문 설계 문서의 불일치가 거부된다"
fi
write_manifest "$MF" "" "" "" "docs/x.md"
if ( check_manifest ) >/dev/null 2>&1; then
  ok "헤더와 본문이 같은 문서를 가리키면 통과한다 (검사가 공허하지 않다)"
else
  bad "소유 증명" "일치하는데 거부됐다: $( ( check_manifest ) 2>&1 | tail -1 )"
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
write_manifest "$MF"; sed "s|메인 워크트리=$MF_REPO|메인 워크트리=/없는/경로|" "$MF" > "$MF.x" && mv "$MF.x" "$MF"
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
# 상한을 넘는 값 하나는 이제 거절이 아니라 사이드카로 빠지고, 행은 기록된다. 이
# 절이 재는 것은 그 처분이 아니라 이 절의 전제다 — 값이 아무리 길어도 행 문법은
# 한 줄로 남는다. 처분 자체는 22b 가 잰다.
LONGV=$(printf '%1100s' '' | tr ' ' 'x')
( ledger_row 'segment' "id=SL" "사유=$LONGV" ) >/dev/null 2>&1
check "상한을 넘는 값 하나는 행을 죽이지 않는다" "$?" "0"
check "그 행은 원장에 한 줄로 남는다" "$(grep -cF 'id=SL' "$LEDGER" || true)" "1"
LEDGER="$LEDGER_SAVE"

# ---------------------------------------------------------------------------
# 22a. 킥오프의 경계 없는 필드는 사이드카로 빠지고 행은 상한 안에 든다
#
# 앞 절의 마지막 단언은 이미 상한을 넘긴 값을 밀어 넣고 거절되는지만 본다. 그것은
# 바닥이 있다는 사실을 재지 여유를 재지 않는다. 그런데 이 상한은 `die` 이고
# `die` 는 `exit 1` 이라, 선언 파일이 스무 개인 평범한 킥오프 하나가 무인 런
# 전체를 첫 행에서 끝냈다 — 한글 경로는 글자당 세 바이트라 그 수는 멀리 있지
# 않다. 게이트는 같은 상한을 도입할 때 목록을 런 디렉터리로 빼는 탈출구를 함께
# 두었고, 이쪽은 바닥만 복제하고 그 탈출구를 복제하지 않았다.
# ---------------------------------------------------------------------------
LEDGER_SAVE="$LEDGER"; RUN_DIR_SAVE="${RUN_DIR:-}"
LEDGER="$WORK/ledger-headroom.md"; : > "$LEDGER"
RUN_DIR="$WORK/rundir-headroom"; mkdir -p "$RUN_DIR"
DECL=""; i=1
while [ "$i" -le 20 ]; do
  DECL="${DECL:+$DECL, }plugins/cc-cmds/오케스트레이터/구현-파일-$i.sh"
  i=$((i + 1))
done
DECLN=$(printf '%s' "$DECL" | wc -c | tr -d ' ')
if [ "${DECLN:-0}" -gt "$RUN_ROW_MAX" ]; then
  ok "선언 목록 자체가 행 상한보다 길다 ($DECLN 바이트 — 여유를 재는 전제다)"
else
  bad "여유 전제" "선언 목록이 $DECLN 바이트뿐이라 이 절이 아무것도 재지 못한다"
fi
( ledger_row 'segment' "id=SH" "상태=계획됨" \
    "선언 파일 집합=$(declared_field_for_row SH "$DECL")" \
    "레포=cc-cmds" "선행=없음" "절단점=커밋" \
    "plan-binding-digest=0000000000000000000000000000000000000000000000000000000000000000" \
    "워크트리=$WORK/wt-SH" ) >/dev/null 2>&1
check "선언 파일이 스무 개인 킥오프 행은 드라이버를 죽이지 않는다" "$?" "0"
ROWLEN=$( { grep -F 'id=SH ' "$LEDGER" || true; } | wc -c | tr -d ' ')
if [ "${ROWLEN:-0}" -gt 0 ] && [ "${ROWLEN:-0}" -le "$RUN_ROW_MAX" ]; then
  ok "그 행은 원장 행 상한 안에 든다 ($ROWLEN 바이트)"
else
  bad "행 길이" "$ROWLEN 바이트 (상한 $RUN_ROW_MAX)"
fi
if [ -f "$RUN_DIR/declared.SH" ] && grep -qF "$DECL" "$RUN_DIR/declared.SH"; then
  ok "전체 목록이 런 디렉터리에 축자로 남는다"
else
  bad "사이드카" "$RUN_DIR/declared.SH 에 전체 목록이 없다"
fi
case "$( { grep -F 'id=SH ' "$LEDGER" || true; } )" in
  *"declared.SH"*) ok "행이 전체 목록이 있는 자리를 지목한다" ;;
  *) bad "사이드카 지목" "$( { grep -F 'id=SH ' "$LEDGER" || true; } )" ;;
esac
# 사이드카를 쓸 수 없을 때 킥오프가 죽으면 고치려는 것과 같은 형상이 된다.
RUN_DIR="$WORK/rundir-absent"
( ledger_row 'segment' "id=SH2" "상태=계획됨" \
    "선언 파일 집합=$(declared_field_for_row SH2 "$DECL")" ) >/dev/null 2>&1
check "런 디렉터리가 없어도 킥오프 행은 써진다" "$?" "0"
# 그리고 바닥 자체는 백스톱으로 남는다. 닿는 조건은 「긴 필드 하나」가 아니라
# 「빼낼 곳이 없고 필드가 여럿」이다 — 사이드카가 써지면 행에는 지목만 남아 넷을
# 실어도 상한 아래로 내려가므로, 런 디렉터리가 없는 상태를 그대로 이어 쓴다. 그
# 때는 이 층에서 더 할 수 있는 것이 없으므로 여전히 거절하고, 거절 문면은 어느
# 필드가 넘쳤는지 이름으로 지목한다.
LONGV2=$(printf '%1100s' '' | tr ' ' 'x')
LONGOUT=$( { ledger_row 'segment' "id=SL2" "사유=$LONGV2" "관측=$LONGV2" \
               "근거=$LONGV2" "비고=$LONGV2"; } 2>&1 || true)
case "$LONGOUT" in
  *"가장 긴 필드는 「사유」"*) ok "상한 거절이 어느 필드가 넘쳤는지 지목한다" ;;
  *) bad "상한 문면" "$LONGOUT" ;;
esac
RUN_DIR="$RUN_DIR_SAVE"
LEDGER="$LEDGER_SAVE"

# ---------------------------------------------------------------------------
# 22b. 상한이 죽이던 자리는 park 로 가는 길이었다
#
# 22a 는 킥오프의 선언 집합 하나에 탈출구를 뒀고 이탈 행에는 두지 않았다. 그
# 행은 선언 집합·실제 편집 집합·이탈 목록 셋을 함께 싣고 셋 다 같은 선언과 함께
# 자라므로, 선언이 긴 세그먼트에서 이탈이 나면 그 행이 상한을 넘었다 — 그리고
# 그 상한은 `die` 였다. 죽는 자리가 하필 park 로 가는 길이라, 정지해야 할 런이
# 정지하는 대신 드라이버째 끝났다.
#
# 그래서 탈출구를 호출부마다 배선하는 대신 `ledger_row` 자신이 흘리게 한다.
# 호출부 배선은 새 writer 가 생길 때마다 같은 누락을 되풀이하고, 그 되풀이가
# 바로 이 절이 재는 결함의 이력이다.
# ---------------------------------------------------------------------------
LEDGER_SAVE="$LEDGER"; RUN_DIR_SAVE="$RUN_DIR"; BASE_SAVE="$BASE"
LEDGER="$WORK/ledger-escape.md"; : > "$LEDGER"
RUN_DIR="$WORK/rundir-escape"; mkdir -p "$RUN_DIR"
BASE="$WORK/base-escape"; mkdir -p "$BASE/docs"
ESC_WT="$WORK/wt-escape"; mkdir -p "$ESC_WT"
( cd "$ESC_WT" && git init -q . && git config user.email t@t && git config user.name t ) \
  >/dev/null 2>&1
# 선언 스무 개와 선언 밖 스무 개. 셋 다 경계가 필요하다는 것이 이 절의 전제이므로
# 세 필드가 모두 필드 상한을 넘도록 양쪽을 함께 키운다. 한글 경로는 글자당 세
# 바이트라 그 수는 멀리 있지 않다.
ESC_DECL=""; i=1
while [ "$i" -le 20 ]; do
  printf 'x\n' > "$ESC_WT/오케스트레이터-구현-$i.sh"
  printf 'x\n' > "$ESC_WT/오케스트레이터-선언밖-$i.sh"
  ESC_DECL="${ESC_DECL:+$ESC_DECL, }오케스트레이터-구현-$i.sh"
  i=$((i + 1))
done
( cd "$ESC_WT" && git add -A && git commit -q -m init ) >/dev/null 2>&1
i=1
while [ "$i" -le 20 ]; do
  printf 'y\n' > "$ESC_WT/오케스트레이터-선언밖-$i.sh"
  i=$((i + 1))
done
# 서브셸로 부르는 것은 실패 처분이 `die` 로 되돌아가도 스위트가 그 자리에서
# 끝나지 않게 하려는 것이다 — 원장·사이드카는 파일이라 서브셸 밖에 남는다.
( fileset_escape SE "$ESC_DECL" "$ESC_WT" ) >/dev/null 2>&1
check "선언이 긴 세그먼트의 이탈이 드라이버를 죽이지 않고 park 를 반환한다" "$?" "1"
ESC_ROW=$( { grep -F 'id=SE ' "$LEDGER" || true; } | tail -1)
case "$ESC_ROW" in
  *'상태=park'*) ok "이탈이 세그먼트를 park 상태로 원장에 남긴다" ;;
  *) bad "이탈 행" "$ESC_ROW" ;;
esac
ESC_LEN=$(printf '%s' "$ESC_ROW" | wc -c | tr -d ' ')
if [ "${ESC_LEN:-0}" -gt 0 ] && [ "${ESC_LEN:-0}" -le "$RUN_ROW_MAX" ]; then
  ok "그 행은 원장 행 상한 안에 든다 ($ESC_LEN 바이트)"
else
  bad "이탈 행 길이" "$ESC_LEN 바이트 (상한 $RUN_ROW_MAX)"
fi
# 세 필드가 각자 제 사이드카를 갖는다. 접두사가 `declared` 로 고정돼 있던 동안은
# 셋 중 하나만 경계를 받았고, 나머지 둘이 같은 행을 그대로 넘겼다.
for pfx in declared actual escape; do
  if [ -f "$RUN_DIR/$pfx.SE" ]; then
    ok "이탈 행의 $pfx 필드가 런 디렉터리에 전체로 남는다"
  else
    bad "이탈 사이드카" "$RUN_DIR/$pfx.SE 가 없다"
  fi
done
# park 에 넘긴 관측 문자열도 같은 경계를 받는다 — `park` 는 제 원장 행을 쓰므로
# 여기서 경계를 주지 않으면 이탈 행을 살려 두고 그 다음 행에서 죽는다.
BLOCKED_ROW=$( { grep -F '대상=SE ' "$LEDGER" || true; } | tail -1)
BLOCKED_LEN=$(printf '%s' "$BLOCKED_ROW" | wc -c | tr -d ' ')
if [ "${BLOCKED_LEN:-0}" -gt 0 ] && [ "${BLOCKED_LEN:-0}" -le "$RUN_ROW_MAX" ]; then
  ok "park 이 쓴 blocked 행도 상한 안에 든다 ($BLOCKED_LEN 바이트)"
else
  bad "blocked 행 길이" "$BLOCKED_LEN 바이트 (상한 $RUN_ROW_MAX)"
fi
# 그리고 `ledger_row` 자신이 흘린다 — 경계를 거치지 않고 들어온 값 하나로 직접
# 부른다. 호출부가 아무것도 하지 않아도 행이 남고 전체 값을 지목한다는 것이
# 구조적 폐쇄의 내용이다.
: > "$LEDGER"
RAWV=$(printf '%1100s' '' | tr ' ' 'z')
( ledger_row 'segment' "id=SR" "사유=$RAWV" ) >/dev/null 2>&1
check "경계 없는 값을 직접 실어도 ledger_row 는 죽지 않는다" "$?" "0"
RAW_ROW=$( { grep -F 'id=SR ' "$LEDGER" || true; } | tail -1)
RAW_LEN=$(printf '%s' "$RAW_ROW" | wc -c | tr -d ' ')
if [ "${RAW_LEN:-0}" -gt 0 ] && [ "${RAW_LEN:-0}" -le "$RUN_ROW_MAX" ]; then
  ok "그 행도 상한 안에 든다 ($RAW_LEN 바이트)"
else
  bad "흘린 행 길이" "$RAW_LEN 바이트 (상한 $RUN_ROW_MAX)"
fi
case "$RAW_ROW" in
  *"(전체: $RUN_DIR/row.segment."*) ok "흘린 행이 전체 값이 있는 자리를 지목한다" ;;
  *) bad "흘림 지목" "$RAW_ROW" ;;
esac
# 상한 아래의 행은 바이트가 달라지지 않는다 — 이것이 흘림이 기존 단언을 조용히
# 바꾸지 않았다는 상한이다.
: > "$LEDGER"
ledger_row 'segment' "id=SS" "상태=계획됨" "레포=cc-cmds"
check "상한 아래 행은 바이트가 그대로다" \
  "$( { grep -F 'id=SS ' "$LEDGER" || true; } )" \
  '- `segment` | id=SS | 상태=계획됨 | 레포=cc-cmds'
LEDGER="$LEDGER_SAVE"; RUN_DIR="$RUN_DIR_SAVE"; BASE="$BASE_SAVE"

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
# 순회 꼬리와 EXIT 경로가 둘 다 이 보고를 부른다. 정상으로 끝난 런에서는 두 경로가
# 겹치므로, 겹침이 아침에 같은 잔여를 두 줄로 만들지 않는지가 두 경로를 둔 값을
# 결정한다.
report_run_residual
res_n=$( { grep -cF '종단 — 질의 잔여 2건' "$RES_REPORT" || true; } )
if [ "${res_n:-0}" = "1" ]; then
  ok "겹쳐 불려도 종단 줄은 리포트에 한 번만 실린다"
else
  bad "종료 잔여" "종단 줄이 ${res_n}회 실렸다 — 두 경로가 같은 줄을 두 번 쓴다"
fi
# 그 두 경로 중 하나가 EXIT 경로다. 순회 꼬리 하나만 있던 동안은 die·신호·예산으로
# 끝난 런이 `done` 파일을 쓰고도 아침 리포트에는 한 글자도 넘기지 못했다 — 무언가
# 잘못된 밤에만 잔여가 사라졌다.
if grep -qF "trap 'report_run_residual || true' EXIT" "$DRIVER"; then
  ok "드라이버가 종료 잔여 보고를 EXIT 경로에 건다"
else
  bad "종료 잔여" "EXIT 경로에 보고가 걸려 있지 않다 — 순회 꼬리에 닿지 못한 런의 잔여는 아침에 도달하지 않는다"
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
# 25. 설계 문서 없는 런, 그리고 전사가 실행 버전을 갖는다
#
# 이 절이 잡는 부류는 둘이다. 하나는 「매니페스트 문법이 1급으로 받는 형태에 실행
# 경로가 없다」 — 문서 없는 런은 다섯 앵커 중 넷의 정상 형태인데 원장 첫 행에서
# 죽거나 감사에서 런 스코프로 park 됐다. 다른 하나는 「재파견이 앞 시도의 유일한
# 관측을 지운다」 — 무인 런에서 그 전사를 대체할 관측은 없다.
# ---------------------------------------------------------------------------
DOC_SAVE25="${DOC:-}"; DOC_KEY_SAVE25="${DOC_KEY:-}"
RUN_DIR_SAVE25="$RUN_DIR"; LEDGER_SAVE25="$LEDGER"
MANIFEST_SAVE25="${MANIFEST:-}"; RUN_ID_SAVE25="$RUN_ID"
GRANT_SAVE25="${GRANT:-}"

# --- 25a 문서 없는 런의 다이제스트 ------------------------------------------
# 두 다이제스트 함수가 `$DOC` 를 가드 없이 넘겨, 문서 없는 런은 첫 원장 행에서
# 죽었다. `binding_digest` 쪽은 더 나쁘다 — awk 에 파일 피연산자가 없으면 stdin 을
# 읽으므로 죽는 대신 영원히 멈춘다. 그래서 이 단언은 `</dev/null` 로 돌려, 가드가
# 없을 때 하네스가 매달리는 대신 틀린 값으로 실패하게 한다.
DOC=""
check "문서 없는 런의 전체 다이제스트는 센티널이다"   "$(whole_digest)"              "(없음)"
check "문서 없는 런의 구속 다이제스트는 센티널이다" "$(binding_digest </dev/null)" "(없음)"
# 가드는 접근자 안에만 있어야 한다. 호출부가 원시 해시를 다시 쓰면 그 자리만 다시
# 문서 없는 런에서 죽고, 접근자는 통과하므로 위 두 단언은 아무 말도 하지 않는다.
RAW25=$( { grep -cF 'shasum -a 256 "$DOC"' "$DRIVER" || true; } )
check "문서 다이제스트의 원시 호출은 접근자 안 한 곳뿐" "$RAW25" "1"

# --- 25b 문서 없는 런의 owner-doc -------------------------------------------
# 쓰는 쪽 틀은 `owner-doc=<document key> | (없음)` 이라 문서가 없으면 `(없음)` 을
# 넣게 되는데, 읽는 쪽은 앵커 키를 기대했다. 두 값이 같은 런을 가리키는데 하나만
# 통과했다.
#
# 그리고 이 필드의 판독기는 둘이다 — 드라이버의 킥오프 대조와 게이트의 매 행위 대조.
# 한쪽만 통과한 런은 시작된 뒤 모든 행위가 거부되고, 스테이지는 아무것도 못 한 채
# 깨끗이 끝나 공허한 성공으로 분류되므로 원장에 진짜 원인이 남지 않는다. 그래서 이
# 절은 두 판독기가 공유하는 수용 집합(`owner_doc_match`)을 재고, 권위를 매니페스트
# 헤더 하나로 고정한다.
GR25="$WORK/grant-docless.md"
write_grant25() {   # write_grant25 <owner-doc 값>
  { printf '# 인가 기록\n'
    printf '<!-- cc-pipeline-grant v1; owner-doc=%s; writer=autopilot -->\n\n' "$1"
    printf '## 인가 %s\n**권한 절단점**: PR\n' "$RUN_ID"
  } > "$GR25"
}
# 매니페스트가 권위이므로 이 절은 그것을 명시적으로 세운다. 문서 없는 런의 헤더는
# `(없음)` 이다.
write_manifest "$MF"; MANIFEST="$MF"
RUN_ID="docless-run"; GRANT="$GR25"; DOC=""; DOC_KEY="Nharu/cc-cmds"
# 두 철자가 같은 값으로 접히는지부터 잰다 — 두 판독기가 이 함수를 함께 쓰므로, 여기서
# 갈리면 그 아래 단언들은 한쪽 판독기만 재게 된다.
if owner_doc_match '(없음)' '(없음)' && owner_doc_match '(없음)' 'Nharu/cc-cmds'; then
  ok "문서 없는 런의 두 철자가 같은 수용 집합에 든다"
else
  bad "인가 owner-doc" "두 철자 중 하나가 수용 집합 밖이다 — 판독기 둘이 갈린다"
fi
if owner_doc_match 'docs/x.md' '(없음)'; then
  bad "인가 owner-doc" "문서 있는 런에서 (없음) 이 접혔다 — 인가가 아무 문서에나 붙는다"
else
  ok "접기는 문서 없는 런에 한정된다"
fi
# 게이트 쪽 판독기가 같은 함수를 지난다. 다른 철자로 다시 쓰면 두 집합이 또 갈린다.
if sed -n '/^gate_check_grant()/,/^}/p' "$script_dir/gate.sh" | grep_all_q -F 'owner_doc_match "$mowner" "$gowner"'; then
  ok "게이트의 owner-doc 판정이 드라이버와 같은 수용 집합을 지난다"
else
  bad "인가 owner-doc" "게이트가 자기 철자로 다시 비교한다 — 두 판독기가 갈린다"
fi
write_grant25 '(없음)'
if ( check_grant ) >/dev/null 2>&1; then
  ok "문서 없는 런에서 owner-doc=(없음) 이 통과한다"
else
  bad "인가 owner-doc" "킥오프 틀이 지시하는 값이 거부된다: $( ( check_grant ) 2>&1 | tail -1 )"
fi
write_grant25 'Nharu/cc-cmds'
if ( check_grant ) >/dev/null 2>&1; then
  ok "문서 없는 런에서 앵커 키 표기도 통과한다"
else
  bad "인가 owner-doc" "드라이버가 채우는 값이 거부된다: $( ( check_grant ) 2>&1 | tail -1 )"
fi
# 완화가 아니라 두 표기의 수용이다 — 어긋난 키는 여전히 하드 스톱이어야 한다.
write_grant25 'other/repo#9'
if ( check_grant ) >/dev/null 2>&1; then
  bad "인가 owner-doc" "다른 런의 문서 키가 통과했다 — 출처 가드가 무력해졌다"
else
  ok "문서 없는 런에서도 어긋난 키는 거부된다"
fi
# `(없음)` 의 수용은 문서가 실제로 없을 때로 한정된다. 이 조건이 빠지면 문서 있는
# 런의 인가가 아무 문서에나 붙는다.
write_manifest "$MF" "" "" "" "docs/x.md"
DOC="$WORK/base/docs/x.md"; DOC_KEY="docs/x.md"
write_grant25 '(없음)'
if ( check_grant ) >/dev/null 2>&1; then
  bad "인가 owner-doc" "문서 있는 런이 (없음) 인가를 물려받았다"
else
  ok "문서 있는 런에서는 (없음) 이 여전히 거부된다"
fi
# 앵커 키 철자도 문서 있는 런에서는 접히지 않는다 — 접기가 문서 유무와 무관해지면
# 위 단언 하나만으로는 그 사실이 드러나지 않는다.
write_grant25 'Nharu/cc-cmds'
if ( check_grant ) >/dev/null 2>&1; then
  bad "인가 owner-doc" "문서 있는 런이 앵커 키 인가를 물려받았다"
else
  ok "문서 있는 런에서는 앵커 키 표기도 거부된다"
fi
write_manifest "$MF"
DOC=""; DOC_KEY="Nharu/cc-cmds"

# --- 25c 문서 없는 런의 실행 경로 -------------------------------------------
# 소비자는 전부 경로를 받는다 — 판단 호출은 입력을 파일에서 읽고, 스테이지 프롬프트는
# 첫 토큰으로 문서 경로를 끼운다. 빈 문자열을 넘기면 뒤따르는 인용 인자가 문서 경로
# 자리로 읽힌다.
RUN_DIR="$WORK/docless-run"; mkdir -p "$RUN_DIR"
MANIFEST="$MF"; ANCHOR_KIND="repo"; ANCHOR_KEY="Nharu/cc-cmds"
BRIEF25=$(doc_arg)
if [ -f "$BRIEF25" ]; then
  ok "문서 없는 런의 문서 인자가 실재하는 파일이다"
else
  bad "앵커 브리프" "문서 인자가 실재하지 않는다: '$BRIEF25'"
fi
case "$BRIEF25" in
  *.md) ok "문서 인자가 .md 토큰으로 읽힌다 (스킬의 첫 토큰 파스가 성립한다)" ;;
  *)    bad "앵커 브리프" ".md 로 끝나지 않는다: $BRIEF25" ;;
esac
if grep_all_q -F "$ANCHOR_KEY" < "$BRIEF25"; then
  ok "브리프가 앵커 키를 담는다 (계획기가 무엇에 대한 런인지 읽을 수 있다)"
else
  bad "앵커 브리프" "앵커 키가 브리프에 없다"
fi
check "브리프는 런당 하나이고 재호출에 같은 경로를 낸다" "$(doc_arg)" "$BRIEF25"
DOC="$WORK/base/docs/x.md"
check "문서가 있으면 접근자는 그 문서를 낸다" "$(doc_arg)" "$WORK/base/docs/x.md"
DOC=""
# 접근자가 있어도 호출부가 `$DOC` 를 그대로 끼우면 아무것도 달라지지 않는다.
check "구현 스테이지 두 자리가 접근자를 쓴다" \
  "$( { grep -cF 'implement-unattended $(doc_arg)' "$DRIVER" || true; } )" "2"
check "리뷰 스테이지가 접근자를 쓴다" \
  "$( { grep -cF '설계는 $(doc_arg)' "$DRIVER" || true; } )" "2"
check "재수렴 스테이지가 접근자를 쓴다" \
  "$( { grep -cF 'design-reconverge $(doc_arg)' "$DRIVER" || true; } )" "1"
# 감사와 계획, 두 지점 모두가 문서 부재를 분기해야 한다. 하나만 있으면 런은 앞
# 지점을 지나고 다음 지점에서 같은 이유로 멈춘다 — 감사만 고쳤을 때가 정확히
# 그랬다.
check "main_loop 이 감사와 계획 두 지점에서 문서 부재를 분기한다" \
  "$( sed -n '/^main_loop()/,/^}/p' "$DRIVER" | { grep -cF 'if [ -z "$DOC" ]; then' || true; } )" "2"

# --- 25d 베이스 브랜치는 얼기 전에 대조된다 ---------------------------------
# 이 필드만 디스크와 대조되지 않은 채 구속 다이제스트에 얼었다. 그래서 오타나 다른
# 레포의 브랜치명이 「검증된 값」과 구별되지 않게 고정됐고, 어디서도 그 사실이
# 드러나지 않았다.
write_manifest "$MF" "" "" "존재하지-않는-브랜치"
MANIFEST="$MF"
if ( check_base_branches ) >/dev/null 2>&1; then
  bad "베이스 브랜치 검증" "레포에 없는 브랜치명이 통과했다 — 대조 없이 불변식으로 승격된다"
else
  BBMSG25=$( ( check_base_branches ) 2>&1 | tail -1 )
  case "$BBMSG25" in
    *"원격 추적 ref 로 해소되지 않습니다"*) ok "레포에 없는 베이스 브랜치가 지명되어 거부된다" ;;
    *) bad "베이스 브랜치 검증" "거부는 됐으나 다른 이유였다: $BBMSG25" ;;
  esac
fi
write_manifest "$MF"
MANIFEST="$MF"
if ( check_base_branches ) >/dev/null 2>&1; then
  ok "실재하는 베이스 브랜치는 그대로 통과한다 (검사가 공허하지 않다)"
else
  bad "베이스 브랜치 검증" "실재하는 브랜치가 거부됐다: $( ( check_base_branches ) 2>&1 | tail -1 )"
fi
# 수용 집합이 소비 집합보다 넓으면 거절이 아니라 과수용으로 샌다. `base_sha` 는
# `refs/remotes/origin/…` 만 해소하므로, 로컬 헤드에만 있는 이름은 킥오프를 통과한 뒤
# 세그먼트 워크트리 생성에서 죽는다 — 얼기 전에 대조한다는 취지가 정확히 거기서 깨진다.
( cd "$MF_REPO" && git branch local-only-branch ) >/dev/null 2>&1
check "픽스처에 로컬 헤드만 있는 이름을 만들었다" \
  "$( cd "$MF_REPO" && git rev-parse --verify --quiet refs/heads/local-only-branch >/dev/null 2>&1 && printf 있음 )" "있음"
write_manifest "$MF" "" "" "local-only-branch"
MANIFEST="$MF"
if ( check_base_branches ) >/dev/null 2>&1; then
  bad "베이스 브랜치 검증" "로컬 헤드에만 있는 이름이 통과했다 — 소비자가 해소하지 못하는 값을 얼린다"
else
  ok "로컬 헤드에만 있는 베이스 브랜치가 거부된다 (소비 집합과 같은 집합을 받는다)"
fi
# 소비 집합은 fetch **이후**의 원격 추적 ref 집합이다 — 소비 지점이 `base_fetch` 를
# 먼저 부르고 그다음 `base_sha` 를 부른다. 킥오프가 fetch 이전의 것을 보면 수용 집합이
# 진부분집합이 되어, 서버에는 있는데 이 클론이 아직 가져오지 않은 베이스 브랜치가
# 완주하던 자리에서 하드 스톱된다 — 단일 브랜치 클론, 클론 이후 서버에서 만들어진
# 브랜치, 좁혀진 fetch refspec 이 전부 그 형상이다.
#
# 원격은 `$MF_REPO` 에서 **클론**한다. 별도 `git init` 으로 만들면 공통 조상이 없는
# 커밋이 나오고, 바로 아래 `check_base_branches` 가 부르는 `base_fetch` 가 기본
# refspec 의 강제 갱신으로 픽스처가 맨 처음 손수 심어 둔 `refs/remotes/origin/main`
# (= 이 레포 자신의 HEAD) 을 그 무관한 커밋으로 갈아 끼운다. 지금은 그 아래에
# `base_sha` 를 보는 절이 없어 깨지는 단언이 없지만, 픽스처의 기본 불변식이 절
# 중간에서 조용히 뒤집히는 것이라 나중에 여기 단언을 더하는 쪽이 재현하기 어려운
# 자리에서 막힌다. 클론이면 fetch 뒤에도 같은 커밋이라 불변식이 유지된다.
#
# 클론은 대상 디렉터리를 스스로 만들고, HEAD 도 원본의 것을 따라가므로 호스트의
# `init.defaultBranch` 에 기대지 않는다.
MF_ORIGIN="$WORK/manifest-origin"
git clone -q "$MF_REPO" "$MF_ORIGIN" >/dev/null 2>&1
( cd "$MF_ORIGIN" \
  && git config user.email t@example.invalid \
  && git config user.name  T \
  && git branch server-only ) >/dev/null 2>&1
check "픽스처 원격이 이 레포에서 클론돼 같은 커밋을 가리킨다" \
  "$( cd "$MF_ORIGIN" && git rev-parse --abbrev-ref HEAD )/$( cd "$MF_ORIGIN" && git rev-parse HEAD )" \
  "main/$( cd "$MF_REPO" && git rev-parse HEAD )"
( cd "$MF_REPO" && git remote add origin "$MF_ORIGIN" ) >/dev/null 2>&1
if ( cd "$MF_REPO" && git rev-parse --verify --quiet refs/remotes/origin/server-only >/dev/null 2>&1 ); then
  bad "베이스 브랜치 검증" "픽스처가 이미 가져온 상태다 — fetch 이전 상태를 재지 못한다"
else
  ok "픽스처에 서버에만 있고 아직 가져오지 않은 브랜치를 만들었다"
fi
write_manifest "$MF" "" "" "server-only"
MANIFEST="$MF"
if ( check_base_branches ) >/dev/null 2>&1; then
  ok "아직 가져오지 않은 베이스 브랜치가 킥오프를 통과한다 (소비자가 부르는 fetch 를 검사도 부른다)"
else
  bad "베이스 브랜치 검증" "가져오지 않은 ref 가 거부됐다 — 완주하던 형태가 하드 스톱된다: $( ( check_base_branches ) 2>&1 | tail -1 )"
fi
# 위 fetch 가 픽스처의 기본 불변식을 뒤집지 않았는지 확인한다 — 원격이 클론이 아니면
# 여기서 두 값이 갈린다.
check "fetch 뒤에도 origin/main 은 이 레포 자신의 HEAD 다" \
  "$( cd "$MF_REPO" && git rev-parse refs/remotes/origin/main )" \
  "$( cd "$MF_REPO" && git rev-parse HEAD )"
# 이 검사가 모든 게이트 호출마다 돌면, 베이스 브랜치가 런 도중 해소 불가가 됐을 때
# 이후 모든 행위가 하드 스톱되고 값이 구속 다이제스트에 얼어 있어 복구할 길이 없다.
# 그래서 검사는 킥오프 경로에만 있어야 한다 — 게이트가 부르는 것은 `check_manifest` 다.
write_manifest "$MF" "" "" "존재하지-않는-브랜치"
MANIFEST="$MF"
if ( check_manifest ) >/dev/null 2>&1; then
  ok "매니페스트 검사는 베이스 브랜치를 보지 않는다 (게이트 경로가 런 중에 막히지 않는다)"
else
  bad "베이스 브랜치 검증" "게이트가 부르는 검사에 남아 있다: $( ( check_manifest ) 2>&1 | tail -1 )"
fi
if sed -n '/^check_manifest()/,/^}/p' "$DRIVER" | grep_all_q -F 'refs/remotes/origin/$bb'; then
  bad "베이스 브랜치 검증" "매니페스트 검사 안에 베이스 브랜치 해소가 남아 있다"
else
  ok "베이스 브랜치 해소가 매니페스트 검사 밖에 있다"
fi
# `(없음)` 은 검사에서만 면제되고 소비 경로에서는 면제되지 않았다 — 검사가 유일하게
# 확인하지 않기로 한 철자가 정확히 소비자가 다루지 못하는 철자였다.
write_manifest "$MF" "" "" "(없음)"
MANIFEST="$MF"
if [ "$( ( RUN_DIR=""; BASE_BRANCH=""; base_branch home ) )" = "(없음)" ]; then
  bad "베이스 브랜치 (없음)" "센티널이 브랜치명으로 새어 나간다 — base_sha 가 refs/remotes/origin/(없음) 을 찾는다"
else
  ok "베이스 브랜치 (없음) 은 선언 부재로 읽혀 유도로 넘어간다"
fi
# 넘어간 그 파생값도 검증된다. 파생은 `origin/HEAD` 의 축약 이름이고, 그 심볼릭 ref 는
# `git clone` 이 만들고 `git init` + `remote add` 로 만든 레포에는 없으므로 파생은
# **메인 워크트리에 사람이 체크아웃해 둔 HEAD 의 이름**으로 내려간다. 그 값은
# `$RUN_DIR/base-branch.<별칭>` 으로 동결돼 워크트리 분기점·원장의 베이스 sha·외부
# 드리프트 비교·rebase 대상에 전부 실린다 — 검증에서 면제하면 시끄럽게 실패하던 경로가
# 조용한 호스트 의존 추측이 된다.
#
# 그 전제는 이 절이 **직접 세운다.** 앞 절들이 이 레포에 `refs/remotes/origin/HEAD` 를
# 남기고, 그것이 있으면 유도는 첫 팔에서 해소돼 체크아웃된 이름까지 내려가지 않는다 —
# 즉 이 절이 재려는 상태가 아예 만들어지지 않는다. 실측: 그 ref 가 남은 채로는
# 유도가 `main` 으로 해소되고 `refs/remotes/origin/main` 이 실재해 검사가 통과한다.
# 원격 자체를 잠시 떼어 낸다. ref 만 지우면 `check_base_branches` 가 맨 먼저 부르는
# `base_fetch` 가 실제 origin 에서 그것을 되살려, 유도가 다시 첫 팔에서 해소된다 —
# 실측: 지운 직후 `refs/remotes/origin/HEAD` 가 없다가 그 호출 뒤 되살아났다.
#
# 원격 제거가 그 원격의 원격 추적 브랜치까지 함께 지우므로 `git update-ref -d` 로
# `origin/HEAD`·`origin/main` 을 따로 지우던 두 줄은 이미 없는 것을 지우는 죽은 줄이었다.
# 그 둘이 있어야 전제가 선다고 읽히기 쉬워 지웠고, 전제 자체는 아래 `check` 가 잡는다.
( cd "$MF_REPO" \
  && git remote remove origin \
  && git checkout -q -b derived-only ) >/dev/null 2>&1
# 전제가 실제로 섰는지 반증 가능하게 확인한다 — 위 체인은 출력을 버리므로 실패해도 조용하다.
check "유도가 체크아웃된 이름으로 내려가는 상태다" \
  "$( cd "$MF_REPO" && git rev-parse --abbrev-ref HEAD )/$( cd "$MF_REPO" && git rev-parse --verify --quiet refs/remotes/origin/HEAD >/dev/null 2>&1 && printf 있음 || printf 없음 )/$( cd "$MF_REPO" && git remote | grep -c . )" \
  "derived-only/없음/0"
write_manifest "$MF" "" "" "(없음)"
MANIFEST="$MF"
# `RUN_DIR` 를 비워 부른다 — 동결된 사본이 있으면 유도 자체가 일어나지 않아 이 절이
# 재려는 것을 재지 못한다.
if ( RUN_DIR=""; BASE_BRANCH=""; check_base_branches ) >/dev/null 2>&1; then
  bad "베이스 브랜치 (없음)" "해소되지 않는 유도값이 킥오프를 통과했다 — 런이 조용히 체크아웃된 브랜치를 베이스로 삼는다"
else
  ok "해소되지 않는 유도값이 거부된다 ((없음) 분기가 검증에서 면제되지 않는다)"
fi
# 그 거절 문면이 fetch 의 성패를 진술하는가. `base_fetch` 는 `2>/dev/null` 과 `|| true`
# 로 오프라인·자격 만료·원격 부재·해소 불가 별칭을 전부 같은 침묵으로 만드는데, 킥오프는
# 그 침묵에 하드 스톱을 거는 유일한 자리다 — 「fetch 이후에도 없음」이라고 단정하면
# 무인 런에서 아침에 이 줄을 읽는 사람이 브랜치 이름 쪽으로 간다. 이 픽스처는 지금
# 원격이 떼어진 상태이므로 fetch 는 실패한 쪽이어야 한다.
BBMSG25F=$( ( RUN_DIR=""; BASE_BRANCH=""; check_base_branches ) 2>&1 | tail -1 )
case "$BBMSG25F" in
  *"fetch 가 실패했습니다"*) ok "하드 스톱 문면이 fetch 의 성패를 관측대로 진술한다" ;;
  *) bad "베이스 브랜치 문면" "fetch 실패를 브랜치명 오류와 구별하지 않는다: $BBMSG25F" ;;
esac
# 원격을 되돌린다 — 아래 절은 유도값이 해소되는 쪽을 재므로 원격 추적 ref 가 필요하다.
#
# **`main` 을 체크아웃하지 않고 `derived-only` 에 남긴다.** 되돌린 뒤 `main` 위에 서면
# 유도의 두 팔이 — `origin/HEAD` 로 해소하는 팔과 체크아웃된 이름으로 내려가는 팔이 —
# 둘 다 `main` 을 내어, 절 끝의 단언이 자기 라벨이 주장하는 구별을 하지 못한다.
#
# **`origin/HEAD` 는 명시적으로 세운다.** fetch 가 원격 HEAD 를 따라 그것을 만들어 주는
# 것은 비교적 최근 동작이고, 만들지 않는 판본에서는 유도가 둘째 팔로 내려간다. 그러면
# 어느 팔이 답했는지가 호스트마다 갈리는데 두 팔의 답이 같으면 어느 쪽이든 통과해서,
# 그 갈림이 어디에도 드러나지 않는다.
( cd "$MF_REPO" \
  && git remote add origin "$MF_ORIGIN" \
  && git fetch -q origin \
  && git remote set-head origin -a ) >/dev/null 2>&1
# 두 팔이 실제로 다른 값을 내는 상태인지 반증 가능하게 확인한다 — 위 체인도 출력을 버린다.
check "복원 뒤 체크아웃된 이름과 해소되는 이름이 갈린다" \
  "$( cd "$MF_REPO" && git rev-parse --abbrev-ref HEAD )/$( cd "$MF_REPO" && git rev-parse --abbrev-ref origin/HEAD 2>/dev/null )" \
  "derived-only/origin/main"
if ( RUN_DIR=""; BASE_BRANCH=""; check_base_branches ) >/dev/null 2>&1; then
  ok "해소되는 유도값은 그대로 통과한다 (파생값 검증이 공허하지 않다)"
else
  bad "베이스 브랜치 (없음)" "실재하는 유도값이 거부됐다: $( ( check_base_branches ) 2>&1 | tail -1 )"
fi
# 체크아웃된 이름은 `derived-only` 이므로 기대값 `main` 은 첫 팔에서만 나온다.
check "유도된 이름이 체크아웃된 HEAD 가 아니라 해소되는 이름이다" \
  "$( ( RUN_DIR=""; BASE_BRANCH=""; base_branch home ) )" "main"
# 절이 만든 지역 브랜치를 치운다. 되돌림이 ref 집합만 복원하고 지역 브랜치를 남기면
# 다음에 이 레포를 쓰는 절이 「절 이전 형상」을 전제할 수 없다.
( cd "$MF_REPO" \
  && git checkout -q main \
  && git branch -D derived-only ) >/dev/null 2>&1
check "절이 만든 지역 브랜치가 남지 않는다" \
  "$( cd "$MF_REPO" && git rev-parse --abbrev-ref HEAD )/$( cd "$MF_REPO" && git rev-parse --verify --quiet refs/heads/derived-only >/dev/null 2>&1 && printf 있음 || printf 없음 )" \
  "main/없음"
write_manifest "$MF"
MANIFEST="$MF"

# --- 25e 드라이버의 problem 행이 게이트의 동일성 축에 걸린다 ----------------
# 픽스처는 게이트가 쓴 행을 게이트가 읽는 닫힌 고리를 재는데, 실물은 드라이버가 쓴
# 행을 게이트가 읽는다. 그 간극에서 `세그먼트=` 가 통째로 빠져 있었고, 앵커 조회와
# 멤버 추출이 양방향으로 죽어 있었다.
LEDGER="$WORK/ledger-problem.md"; : > "$LEDGER"
ledger_row 'problem' "세그먼트=S4" "동일성=결함-A" "현재 단=R2" "생성 등급=워크트리쓰기" "payload=근본원인"
PIDENT25=$( { grep -F '세그먼트=S4 |' "$LEDGER" || true; } \
            | tr '|' '\n' | sed -n 's/^ *동일성=//p' | sed 's/[[:space:]]*$//' )
check "게이트의 앵커 조회가 드라이버 problem 행을 잡는다" "$PIDENT25" "결함-A"
PSEG25=$( { grep -F '동일성=결함-A |' "$LEDGER" || true; } \
          | sed -n 's/.*세그먼트=\([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//' )
check "게이트의 멤버 추출이 드라이버 problem 행에서 id 를 낸다" "$PSEG25" "S4"
# 위 둘은 필드가 그 자리에 있으면 성립하는 형상 단언이다. 실제 작성 지점이 그 필드를
# 내는지는 따로 봐야 한다 — 빠져 있던 것이 바로 그 지점이었다.
if sed -n '/^segment_cycle()/,/^}/p' "$DRIVER" \
     | grep_all_q -F "ledger_row 'problem' \"세그먼트=\$seg\""; then
  ok "드라이버의 problem 작성 지점이 세그먼트를 첫 필드로 낸다"
else
  bad "problem 행" "작성 지점에 세그먼트= 가 없다 — 동일성 축이 실물 런에서 발화하지 않는다"
fi
# 같은 축의 세 번째 판독기. 게이트 자신의 problem 작성기는 `동일성`·`현재 단`·`생성 등급`
# 셋을 필수로 선언하고, 면제 규칙이 그 `생성 등급` 을 읽는다. 드라이버가 그 필드를
# 빠뜨리면 실물 런이 만든 의무는 닫히지도 면제되지도 않고, 그 런은 done 을 제안할 수
# 없다.
PGRADE25=$( { grep -F '동일성=결함-A |' "$LEDGER" || true; } \
            | tr '|' '\n' | sed -n 's/^ *생성 등급=//p' | sed 's/[[:space:]]*$//' )
case "$PGRADE25" in
  읽기|워크트리쓰기) ok "드라이버 problem 행의 생성 등급이 면제 가능한 축2 등급이다 ($PGRADE25)" ;;
  '') bad "problem 행" "생성 등급이 비어 있다 — 종료 조건 3 이 이 의무를 영원히 면제하지 못한다" ;;
  *)  bad "problem 행" "생성 등급이 면제 어휘 밖이다: $PGRADE25" ;;
esac
if sed -n '/^segment_cycle()/,/^}/p' "$DRIVER" | grep_all_q -F '"생성 등급=워크트리쓰기"'; then
  ok "드라이버의 problem 작성 지점이 생성 등급을 낸다"
else
  bad "problem 행" "작성 지점에 생성 등급= 이 없다 — 픽스처만 그 필드를 싣는다"
fi

# --- 25f 전사는 시도로 스코프되고 잘리지 않는다 -----------------------------
# 이 절은 **드라이버가 실제로 파견하는 id 로** 잰다. 앞 판본은 `SLOG` 같은 종류 하나짜리
# 이름으로 쟀는데, 실물의 파견 id 는 `S4:<세그먼트>:<사이클>` 이고 원장 결과 행은
# 종류(`스테이지=S4`)만 실었다. 그래서 시도 계수가 실물에서는 영원히 1 이었는데도 이
# 절은 전부 초록이었다.
#
# 그리고 파견을 흉내 내는 것이 아니라 **파견이 실제로 쓰는 핀 함수를 태운다**. 앞
# 판본은 하네스가 손으로 쓴 핀을 자기가 다시 읽었을 뿐이라, 스코프를 통째로 되돌려도
# 여덟 단언 중 하나만 빨개졌다.
RUN_DIR="$WORK/logscope"; mkdir -p "$RUN_DIR/log"
LEDGER="$WORK/ledger-logscope.md"; : > "$LEDGER"
SEG25="S4:segA:1"           # 드라이버가 실제로 파견하는 철자
KIND25=S4                   # 원장 결과 행이 싣는 종류
# 핀이 없을 때는 스코프 없는 이름이 답이다 — 이 스코프를 몰랐던 드라이버가 남긴
# 전사와, 하네스가 직접 써 넣는 전사가 그 형태다.
printf '옛 전사\n' > "$RUN_DIR/log/$SEG25.json"
check "핀이 없으면 스코프 없는 전사를 읽는다" "$(stage_log_path "$SEG25")" "$RUN_DIR/log/$SEG25.json"
rm -f "$RUN_DIR/log/$SEG25.json"

# 1회차 파견. 파견이 부르는 함수를 그대로 부른다.
stage_pin_attempt "$SEG25" >/dev/null
P1_25=$(stage_log_path "$SEG25")
printf '{"session_id":"AAAA-attempt1"}\n1회차 전사 %s\n' "$LIT_RECONVERGE_TERMINAL" >> "$P1_25"
BYTES1_25=$(wc -c < "$P1_25" | tr -d ' ')
# 1회차가 park 하고 그 결과가 원장에 남은 뒤 2회차가 파견된다 — 손실이 가장 큰 조합이
# 정확히 이것이다. 왜 멈췄는지는 정지 기록에 남지만 거기까지 어떻게 갔는지는 이
# 전사에만 있다. 행은 드라이버가 쓰는 철자 그대로 — 종류와 파견 id 를 둘 다 싣는다.
ledger_row 'stage-result' "세그먼트=segA" "스테이지=$KIND25" "파견 id=$SEG25" \
  "종료 코드=0" "종단 부류=의도된 park"
check "결과 행이 남으면 시도 계수가 실제 파견 id 로 올라간다" "$(stage_attempt "$SEG25")" "2"

# 2회차 파견. 같은 세그먼트, 같은 사이클 — 재개하면 실제로 이 형태가 된다.
stage_pin_attempt "$SEG25" >/dev/null
P2_25=$(stage_log_path "$SEG25")
printf '{"session_id":"BBBB-attempt2"}\n2회차 전사\n' >> "$P2_25"
if [ "$P1_25" != "$P2_25" ]; then
  ok "재파견이 앞 시도와 다른 전사 경로를 쓴다"
else
  bad "전사 스코프" "두 시도가 같은 경로를 쓴다: $P1_25"
fi
# 아래 넷이 이 이슈의 본론이다. 경로가 갈리지 않으면 덧붙임이 두 전사를 이어 붙이고,
# 파일을 통째로 훑는 판독기들이 앞 시도의 내용을 돌려준다 — 잘림 시절에는 없던 오독이다.
check "1회차 전사가 재파견 뒤에도 바이트 그대로 남아 있다" "$(wc -c < "$P1_25" | tr -d ' ')" "$BYTES1_25"
if grep_all_q -F '2회차 전사' < "$P1_25"; then
  bad "전사 스코프" "2회차가 1회차 파일에 이어 붙었다 — 판독기가 두 시도를 한 전사로 읽는다"
else
  ok "2회차가 1회차 파일에 이어 붙지 않는다"
fi
check "세션 id 판독기가 이 시도의 것을 낸다" "$(stage_session_id "$SEG25")" "BBBB-attempt2"
# `predicate_reconverge` 는 제어 흐름이다. 1회차의 종단 리터럴이 2회차 자리에서 읽히면
# 크래시한 재수렴이 참으로 통과하고 park 가 건너뛰어진다.
if predicate_reconverge "$SEG25"; then
  bad "전사 스코프" "재수렴 술어가 앞 시도의 종단 리터럴로 참이 된다 — park 가 건너뛰어진다"
else
  ok "재수렴 술어가 앞 시도의 종단 리터럴을 읽지 않는다"
fi
# 원장 행이 유실된 재개에서도 핀은 올라가야 한다. 계수만으로는 1 에 머물러 두 파견이
# 한 경로로 떨어지고, 열기가 덧붙임이라 두 전사가 이어 붙는다.
: > "$LEDGER"
stage_pin_attempt "$SEG25" >/dev/null
P3_25=$(stage_log_path "$SEG25")
if [ "$P3_25" != "$P1_25" ] && [ "$P3_25" != "$P2_25" ]; then
  ok "결과 행이 없는 재개에서도 핀이 앞 시도들을 넘어간다"
else
  bad "전사 스코프" "원장 행이 없으면 앞 시도의 경로로 되돌아간다: $P3_25"
fi
# 크기 단조. 세 시도를 태운 뒤 이 스테이지의 전사 코퍼스는 1회차 바이트를 여전히 담고
# 있어야 한다 — 「크기가 단조 증가한다」가 재는 것이 이것이다.
printf '3회차 전사\n' >> "$P3_25"
CORPUS25=$(cat "$RUN_DIR/log/$SEG25"#*.json | wc -c | tr -d ' ')
if [ "$CORPUS25" -gt "$BYTES1_25" ]; then
  ok "전사 코퍼스의 크기가 시도를 거치며 단조 증가한다"
else
  bad "스테이지 스트림" "코퍼스가 1회차보다 작거나 같다 ($CORPUS25 <= $BYTES1_25) — 어느 시도의 바이트가 사라졌다"
fi
# 파견이 핀을 쓰지 않으면 위 단언들은 하네스가 손으로 쓴 핀만 재고 실물은 재지
# 않는다.
if sed -n '/^stage_spawn()/,/^}/p' "$DRIVER" | grep_all_q -F 'attempt=$(stage_pin_attempt "$stage")'; then
  ok "파견이 이 시도의 번호를 핀으로 고정한다"
else
  bad "전사 스코프" "파견이 시도 번호를 고정하지 않는다 — 결과 행이 쌓이면 판독이 어긋난다"
fi
if sed -n '/^stage_spawn()/,/^}/p' "$DRIVER" | grep_all_q -F 'out=$(stage_log_path "$stage")'; then
  ok "파견이 판독기와 같은 경로 규칙을 쓴다"
else
  bad "전사 스코프" "파견과 판독이 다른 경로 규칙을 쓴다"
fi
# 세션 id 도 같은 핀에서 유도돼야 한다. 다시 세면 결과 행이 늘어난 뒤 값이 어긋나고,
# CLI 가 중복 세션을 거부해 재파견이 즉시 죽는다.
if sed -n '/^stage_spawn()/,/^}/p' "$DRIVER" | grep_all_q -F 'session_uuid "$stage" "$attempt"'; then
  ok "파견이 전사 경로와 같은 핀에서 세션 id 를 유도한다"
else
  bad "세션 id" "파견이 세션 id 를 다시 세어 유도한다 — 재파견이 같은 UUID 로 죽는다"
fi
# 드라이버가 실제로 쓰는 결과 행에 파견 id 가 없으면 계수기는 종류만 보게 되고, 이
# 절의 계수 단언은 하네스가 손으로 실은 필드만 재게 된다.
# 개수로 잰다. 존재형이면 세그먼트가 파견하는 두 스테이지 중 하나만 필드를 잃어도
# 나머지 하나가 단언을 통과시킨다 — 잃은 쪽의 시도 계수는 실물에서 다시 1 에 묶인다.
check "드라이버의 세그먼트 결과 행 두 자리가 파견 id 를 싣는다" \
  "$( sed -n '/^segment_cycle()/,/^}/p' "$DRIVER" | { grep -cF '"파견 id=$sid"' || true; } )" "2"
check "감사 결과 행도 파견 id 를 싣는다" \
  "$( { grep -cF '"파견 id=S2"' "$DRIVER" || true; } )" "1"
# 경로가 갈려도 열기가 잘림이면 두 번째 결함은 그대로다. 잘림은 조용하다 — 오프셋을
# 들고 tail 하는 소비자는 파일이 자라는 중에도 영원히 빈 결과를 받는다.
if grep_all_q -F '>> "$out" 2>> "$err"' < "$DRIVER"; then
  ok "스테이지 스트림이 덧붙임으로 열린다"
else
  bad "스테이지 스트림" "잘림 모드로 열린다 — 오프셋 리더가 조용히 귀머거리가 된다"
fi
if grep_all_q -F '> "$out" 2> "$RUN_DIR/log/$stage.err"' < "$DRIVER"; then
  bad "스테이지 스트림" "잘림 리다이렉션이 남아 있다"
else
  ok "잘림 리다이렉션이 남아 있지 않다"
fi

# 중단 기록은 분류의 첫 축이다. 스트림만 시도로 갈리고 이 축이 안 갈리면, 같은 run id
# 로 재개했을 때 `segment_cycle` 이 사이클 0 에서 시작해 같은 파견 id 를 다시 쓰므로
# 2회차가 아무리 정상 종료해도 1회차가 남긴 기록 때문에 `의도된 park` 이 되고, 첫 시도가
# park 한 세그먼트는 재개로 되살아나지 않는다.
mkdir -p "$RUN_DIR/halt"
HALT25=$(halt_record_path "$SEG25")
check "중단 기록 경로가 이 시도로 스코프된다" "$HALT25" "$RUN_DIR/halt/$SEG25#3.md"
printf '# 정지\n**재호출 명령**: /cc-cmds:x\n<!-- /cc-pipeline-halt v1 -->\n' > "$HALT25"
if halt_record_present "$SEG25"; then
  ok "이 시도가 남긴 중단 기록은 이 시도의 판정 입력이다"
else
  bad "중단 기록 스코프" "자기 시도의 중단 기록을 읽지 못한다"
fi
stage_pin_attempt "$SEG25" >/dev/null
if halt_record_present "$SEG25"; then
  bad "중단 기록 스코프" "재파견이 앞 시도의 중단 기록을 자기 것으로 읽는다"
else
  ok "재파견이 앞 시도의 중단 기록을 읽지 않는다"
fi
check "앞 시도가 park 해도 정상 종료한 재파견은 정상 완료로 분류된다" \
  "$(classify_termination "$SEG25" 0 0)" "정상 완료"
# 그 이름은 스테이지가 스스로 짓는다 — 파견이 넘기는 id 에 시도가 없으면 모든 시도의
# 기록이 한 경로에 앉고 위 단언들이 잴 것이 없어진다.
if sed -n '/^stage_spawn()/,/^}/p' "$DRIVER" | grep_all_q -F 'CC_PIPELINE_STAGE_ID="$stage#$attempt"'; then
  ok "파견이 스테이지에 시도까지 실은 id 를 넘긴다"
else
  bad "중단 기록 스코프" "파견이 무스코프 id 를 넘겨 모든 시도의 중단 기록이 한 경로에 앉는다"
fi

# --- 25g 세그먼트 결과 행의 세션 계보 ---------------------------------------
# `segment_cycle` 의 지역 변수는 `sid` 다. 스코프에 없는 이름을 넘기면 `set -u` 아래에서
# 명령 치환 서브셸이 죽고 필드가 조용히 빈 값이 된다 — 부모 셸은 계속 돈다.
check "세그먼트 결과 행 두 자리가 스코프 안의 파견 id 로 세션 id 를 유도한다" \
  "$( sed -n '/^segment_cycle()/,/^}/p' "$DRIVER" | { grep -cF 'stage_session_id "$sid"' || true; } )" "2"
check "세그먼트 안에 스코프 밖 이름으로 세션 id 를 유도하는 자리가 없다" \
  "$( sed -n '/^segment_cycle()/,/^}/p' "$DRIVER" | { grep -cF 'stage_session_id "$stage"' || true; } )" "0"
check "세그먼트 결과 행 두 자리가 부모를 싣는다" \
  "$( sed -n '/^segment_cycle()/,/^}/p' "$DRIVER" | { grep -cF '"부모=$(stage_parent_id)"' || true; } )" "2"
# 그 값에 하중을 건 소비자 둘을 실제로 태운다. 형상 단언만으로는 필드가 실려도 소비자가
# 요구하는 형태인지 알 수 없다 — 재부착 검증은 값 뒤의 공백을 요구하고, 머지 규칙은 빈
# 계보를 통과가 아니라 거절로 처리한다.
LEDGER="$WORK/ledger-lineage.md"; : > "$LEDGER"
ledger_row 'stage-result' "세그먼트=segL" "스테이지=S4" "파견 id=S4:segL:0" "종료 코드=0" \
  "아티팩트 술어 결과=0" "세션 id=SID-IMPL" "부모=SID-ROUTER" "종단 부류=정상 완료"
ledger_row 'stage-result' "세그먼트=segL" "스테이지=S5" "파견 id=S5:segL:0" "종료 코드=0" \
  "아티팩트 술어 결과=0" "세션 id=SID-REV" "부모=SID-ROUTER" "종단 부류=정상 완료"
check "게이트의 재부착 검증이 리뷰 스테이지의 세션을 이 세그먼트의 것으로 찾는다" \
  "$( { grep -E '^- `stage-result`' "$LEDGER" | grep -F '세그먼트=segL ' || true; } \
      | { grep -cF '세션 id=SID-REV ' || true; } )" "1"
if GATE_ACT=머지 GATE_SEGMENT=segL GATE_LEDGER="$LEDGER" /bin/sh "$script_dir/rules/구현-리뷰-분리.sh" 2>/dev/null; then
  ok "세션 계보가 실리면 고정 그래프 경로의 머지가 통과한다"
else
  bad "세션 계보" "계보가 실려도 머지가 거절된다: $( GATE_ACT=머지 GATE_SEGMENT=segL GATE_LEDGER="$LEDGER" /bin/sh "$script_dir/rules/구현-리뷰-분리.sh" 2>&1 | tail -1 )"
fi
# 반대 방향 — 필드가 비면 그 규칙은 통과가 아니라 거절이다. 이것이 이 절이 재는 손실의
# 실체이며, 이 단언이 없으면 위 통과가 규칙이 공허해서 나온 것인지 구별되지 않는다.
: > "$LEDGER"
ledger_row 'stage-result' "세그먼트=segL" "스테이지=S4" "파견 id=S4:segL:0" "종료 코드=0" \
  "아티팩트 술어 결과=0" "세션 id=" "부모=SID-ROUTER" "종단 부류=정상 완료"
ledger_row 'stage-result' "세그먼트=segL" "스테이지=S5" "파견 id=S5:segL:0" "종료 코드=0" \
  "아티팩트 술어 결과=0" "종단 부류=정상 완료"
if GATE_ACT=머지 GATE_SEGMENT=segL GATE_LEDGER="$LEDGER" /bin/sh "$script_dir/rules/구현-리뷰-분리.sh" 2>/dev/null; then
  bad "세션 계보" "빈 계보를 통과로 처리한다 — 규칙이 공허하게 참이 된다"
else
  ok "빈 계보는 통과가 아니라 거절이다 (필드가 비면 머지가 매번 막힌다)"
fi

# --- 25h 게이트의 스테이지 런처도 같은 규칙으로 연다 ------------------------
# 스테이지 스트림의 작성자가 둘인데 위 스트림 단언 둘은 `run.sh` 만 본다. 라우터 경로에서
# 실제로 스테이지를 띄우는 것은 게이트이고, 그쪽이 무스코프 잘림으로 열면 한 세그먼트의
# 모든 파견이 같은 파일 하나를 매번 잘라 쓴다 — 구현 스테이지의 전사가 같은 세그먼트의
# 리뷰 스테이지에 지워진다.
GATE25="$script_dir/gate.sh"
if grep_all_q -F '> "$RUN_DIR/log/$seg.json" 2> "$RUN_DIR/log/$seg.err"' < "$GATE25"; then
  bad "스테이지 스트림" "게이트 런처에 무스코프 잘림 경로가 남아 있다"
else
  ok "게이트 런처에 무스코프 잘림 경로가 남아 있지 않다"
fi
# 런처가 그 두 함수를 **부른다**는 사실. 아래 번인은 함수를 직접 태우므로 런처와 함수
# 사이의 이음매는 재지 않고, 드라이버 쪽 대칭 자리(`stage_spawn()`)가 같은 두 줄을 재는
# 동안 게이트 쪽만 비어 있었다 — 시도 번호를 상수로, 전사 경로를 무스코프 이름으로
# 되돌려도 전 스위트가 초록이었다. 그 이음매가 정확히 이 절이 고치려던 실패 양상이다.
if sed -n '/^gate_launch_stage()/,/^}/p' "$GATE25" | grep_all_q -F 'attempt=$(gate_pin_attempt "$seg")'; then
  ok "게이트 런처가 이 시도의 번호를 핀으로 고정한다"
else
  bad "전사 스코프" "게이트 런처가 시도 번호를 고정하지 않는다 — 두 파견이 한 경로에 앉는다"
fi
if sed -n '/^gate_launch_stage()/,/^}/p' "$GATE25" | grep_all_q -F 'out=$(stage_log_path "$seg")'; then
  ok "게이트 런처가 판독기와 같은 경로 규칙을 쓴다"
else
  bad "전사 스코프" "게이트 런처와 판독이 다른 경로 규칙을 쓴다"
fi
# 아래 두 줄은 형상 단언으로 남고, 이유는 둘이 서로 다르다.
#
# 리다이렉션 연산자 — 태워도 갈리지 않는다. 전진 루프가 이미 있는 `.json`·`.err` 를
# 건너뛰므로 런처가 여는 것은 언제나 **아직 없는 경로**이고, 없는 파일에 대해 잘림과
# 덧붙임의 관측 결과는 같다. 덧붙임은 핀이 틀렸을 때를 위한 두 번째 방어선이라 소스 문면
# 말고는 증인이 없다.
#
# 결과 기록기 인자 — 이쪽은 태울 수 있고, 게이트 스위트가 스텁 CLI 로 실제로 태운다.
# 인자를 빼면 기록기가 무스코프 이름으로 되돌아가 결과 줄을 못 읽고 세션 id 가 `미상` 이
# 되며, 그 자리에서 빨개진다. 여기 남는 형상 단언은 인자 나열 자체를 이름으로 집을 뿐
# 하중은 그 실행 단언이 진다.
if sed -n '/^gate_launch_stage()/,/^}/p' "$GATE25" | grep_all_q -F '>> "$out" 2>> "$err"'; then
  ok "게이트 런처가 덧붙임으로 연다"
else
  bad "스테이지 스트림" "게이트 런처가 잘림 모드로 연다"
fi
if sed -n '/^gate_launch_stage()/,/^}/p' "$GATE25" \
     | grep_all_q -F 'gate_record_stage_outcome "$alias" "$seg" "$kind" "$attempt" "$rc" "$n_rows_before" "$out"'; then
  ok "게이트의 결과 기록기가 이 파견이 실제로 쓴 스트림을 받는다"
else
  bad "스테이지 스트림" "결과 기록기가 스트림 경로를 다시 유도한다"
fi

# 여기부터는 게이트의 함수를 **실제로 태운다.**
#
# 앞 판본의 다섯 단언은 전부 `gate.sh` 소스를 `grep -F` 하는 형상 단언이었고, 형상은
# 리터럴만 보존되면 초록이다 — 시도 전진 루프만 지워 두 파견이 한 경로로 떨어지게 만들어도
# 다섯이 전부 통과했다. 「고쳤다」가 거짓이었던 자리가 정확히 여기인데 새 펜스가 그 거짓을
# 잡지 못했다.
#
# 별도 프로세스인 이유: 게이트를 소싱하면 드라이버가 다시 소싱되며 이 하네스가 이미 세워
# 둔 `RUN_DIR`·`LEDGER`·`PATH` 가 초기화된다. 소싱 시임은 게이트가 이미 싣고 있다.
GB25="$WORK/gate-burn"
mkdir -p "$GB25/log"
# 1회차의 바이트를 디스크에 심어 둔다. 전진 루프가 없으면 2회차가 이 경로에 앉는다.
printf 'ATTEMPT1\n' > "$GB25/log/segB#1.json"
: > "$GB25/log/segB#1.err"
: > "$GB25/ledger.md"
cat > "$GB25/burn.sh" <<'GBEOF'
#!/usr/bin/env bash
# 25h 번인 — 하네스가 런타임에 쓰고 별도 프로세스로 태운다.
set -uo pipefail
GATE="$1"; RD="$2"; MFP="$3"
# 드라이버는 자기 하위 프로세스를 위해 PATH 를 정제 집합으로 고정하고, 소싱하면 그것까지
# 들어온다 — 그러면 `jq` 가 사라져 결과 줄 파싱이 조용히 빈 값을 낸다.
HP="$PATH"
CC_GATE_SOURCE_ONLY=1
export CC_GATE_SOURCE_ONLY
# shellcheck disable=SC1090
. "$GATE" || exit 9
PATH="$HP"
unset CC_GATE_SOURCE_ONLY CC_ORCH_SOURCE_ONLY
# 소싱은 드라이버의 `-e` 도 들여온다. 아래는 실패를 기대하는 호출을 포함한다.
set +e
# 경로 변수는 소싱 **뒤에** 세운다 — 드라이버가 로딩 중 자기 경로 변수를 빈 문자열로
# 다시 초기화하므로 앞에 세우면 조용히 지워진다.
RUN_DIR="$RD"
LEDGER="$RD/ledger.md"
MANIFEST="$MFP"
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY

# (A) 시도 유도가 디스크에 있는 1회차를 넘어 전진하는가, 그 번호를 핀으로 남기는가,
#     1회차 바이트는 그대로인가, 그리고 판독기의 경로 함수가 같은 이름을 내는가.
a=$(gate_pin_attempt segB)
p=$(stage_log_path segB)
printf 'A %s %s %s %s\n' \
  "$a" "$(cat "$RUN_DIR/segB.attempt" 2>/dev/null)" \
  "$(cat "$RUN_DIR/log/segB#1.json" 2>/dev/null)" "${p#$RUN_DIR/}"

# (B) 핀이 2 이고 접미 중단 기록이 없는데 **무접미 기록만** 디스크에 있을 때, 결과
#     기록기가 그것을 자기 것으로 읽지 않는가. 읽으면 `의도된 park` 이 나온다.
mkdir -p "$RUN_DIR/halt"
printf '# 정지\n<!-- /cc-pipeline-halt v1 -->\n' > "$RUN_DIR/halt/segB.md"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"session_id":"SID-B","total_cost_usd":0}' > "$p"
gate_record_stage_outcome home segB review 2 0 0 "$p" >/dev/null 2>&1
printf 'B %s\n' "$( { grep -E '^- `stage-result`' "$LEDGER" 2>/dev/null || true; } \
                    | sed -n 's/.*종단 부류=\([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//' | tail -1)"

# (C) 반대 방향 — 자기 시도의 기록은 읽어야 한다. 이것이 없으면 (B) 는 「중단 기록을
#     아예 안 본다」로도 통과한다.
b1=없음; b2=있음
printf '# 정지\n<!-- /cc-pipeline-halt v1 -->\n' > "$RUN_DIR/halt/segB#2.md"
halt_record_present segB && b1=있음
rm -f "$RUN_DIR/halt/segB#2.md"
halt_record_present segB || b2=없음
printf 'C %s/%s\n' "$b1" "$b2"
GBEOF
GB25_OUT=$(bash "$GB25/burn.sh" "$GATE25" "$GB25" "$MF" </dev/null 2>/dev/null)
check "게이트의 시도 유도가 디스크의 1회차를 넘어 전진하고 핀과 판독기 경로가 그 번호로 맞는다" \
  "$(printf '%s\n' "$GB25_OUT" | sed -n 's/^A //p')" "2 2 ATTEMPT1 log/segB#2.json"
check "핀이 있으면 결과 기록기가 앞 시도의 무접미 중단 기록을 자기 것으로 읽지 않는다" \
  "$(printf '%s\n' "$GB25_OUT" | sed -n 's/^B //p')" "공허한 성공"
check "자기 시도의 중단 기록은 읽는다 (B 가 중단 기록을 무시해서 통과한 것이 아니다)" \
  "$(printf '%s\n' "$GB25_OUT" | sed -n 's/^C //p')" "있음/없음"

DOC="$DOC_SAVE25"; DOC_KEY="$DOC_KEY_SAVE25"
RUN_DIR="$RUN_DIR_SAVE25"; LEDGER="$LEDGER_SAVE25"
MANIFEST="$MANIFEST_SAVE25"; RUN_ID="$RUN_ID_SAVE25"; GRANT="$GRANT_SAVE25"

# ---------------------------------------------------------------------------
# The detach path is gone, and its absence is asserted rather than assumed.
# 26. The detach flag stays absent — in the driver AND in the gate.
#
# THE SUCCESS LINE NAMES THE FILE IT ACTUALLY SCANNED. It used to read "the
# router is this session, so there is nothing to detach", which stated a premise
# rather than a finding — and under the headless-shift shape that premise
# evaporated while this check went on printing green. A false sentence in a CI
# log is worse than a wrong comment: nobody re-reads a comment, and everybody
# trusts a green line.
#
# AND THE SCOPE IS BOTH FILES. The shift launcher lives in `gate.sh`, not in the
# driver, so a driver-only scan can only ever say something about a file the
# change does not touch. The range is not the launcher alone either — it is
# every enforcement device that goes into the gate.
# ---------------------------------------------------------------------------
for detach_f in "$DRIVER" "$GATE_SH"; do
  if grep -qE '(^[^#]*--detach\)|DETACH=)' "$detach_f"; then
    bad "detach 제거" "$(basename "$detach_f") 에 --detach 가 다시 들어왔다 — 판단하는 턴이 보이지 않는 곳으로 간다"
  else
    ok "$(basename "$detach_f") 에 detach 경로가 없다"
  fi
done

# ---------------------------------------------------------------------------
# 27. The three shift-safety properties, asserted rather than assumed.
#
# Each of these is a property the shift shape rests on and that nothing else in
# this suite would notice breaking. They replace what the detach assertion used
# to be standing in for.
# ---------------------------------------------------------------------------

# (a) THE SNAPSHOT DIGEST DOES NOT MOVE WITH THE SESSION ID. This is what makes
# a successor shift able to act at all: it reads the snapshot and carries `H`
# into its first gate call, and if the session id were an input the digest would
# differ by construction and every shift would be refused with exit 4. The
# fixture is a ledger and a manifest, so the ONLY thing differing between the
# two runs below is the session id.
SNAPFIX="$WORK/snapdig"; mkdir -p "$SNAPFIX"
cat > "$SNAPFIX/manifest.md" <<'SNAPMF'
# 파이프라인 매니페스트 — fixture

## 인가 fixrun
- 종료 지점: 픽스처 종료 지점
SNAPMF
cat > "$SNAPFIX/ledger.md" <<'SNAPLG'
# 파이프라인 런 원장 — fixture

## 실행 fixrun
- `run` | 교대=0 | run-id=fixrun | prev=aaaa
- `segment` | 교대=0 | id=SA | 상태=계획됨 | 워크트리=/tmp/x | 선행=없음 | prev=bbbb
SNAPLG
# ONLY the gate is sourced. It sources the driver itself, and the driver
# declares `readonly` names — so sourcing both makes the second one die on a
# readonly reassignment, and the digest comes back empty. That failure looks
# exactly like "the digest does not depend on the session id", which is why the
# emptiness check below is a `bad` rather than a skip.
#
# `set --` clears the positional parameters before either file is read: `.`
# leaves the caller's arguments in place, and a sourced driver that sees a stray
# argument parses it.
snapdig_of() {
  MANIFEST="$SNAPFIX/manifest.md" LEDGER="$SNAPFIX/ledger.md" \
  RUN_DIR="$SNAPFIX" CLAUDE_CODE_SESSION_ID="$1" \
  CC_ORCH_SOURCE_ONLY=1 CC_GATE_SOURCE_ONLY=1 \
  bash -c 'g="$1"; set --; . "$g" >/dev/null 2>&1; gate_snapshot_digest' \
    _ "$GATE_SH" 2>/dev/null
}
snapdig_a=$(snapdig_of 11111111-1111-1111-1111-111111111111)
snapdig_b=$(snapdig_of 22222222-2222-2222-2222-222222222222)
if [ -z "$snapdig_a" ]; then
  bad "스냅숏 다이제스트" "픽스처에서 다이제스트가 나오지 않았다 — 이 단언은 공허하게 통과할 뻔했다"
elif [ "$snapdig_a" = "$snapdig_b" ]; then
  ok "세션 id 가 달라도 스냅숏 다이제스트가 같다 (교대가 exit 4 를 내지 않는다)"
else
  bad "스냅숏 다이제스트" "세션 id 로 값이 갈렸다 — 후임 샤드의 모든 행위가 exit 4 로 거절된다"
fi

# (b) THE SHIFT MARKER KEEPS THE SHIFT OUT OF `session-lineage`. Lineage is what
# the approval reader searches, so every id in it is an id allowed to ANSWER. A
# shift is a router by every other measure and walks straight through a guard
# that tests only for the stage marker — and once enrolled, its own transcript
# is read as a person's reply. That is the self-approval path the whole
# separation exists to keep shut.
# The needle is the RECORDING call, which is a different function from the
# reader: enrolment is a side effect no read path may have, so the writer has
# its own name and this is the one call site of it. Located with `awk` rather
# than `grep -n | head -1` — an early-terminating reader on the right of a pipe
# fails the pipeline under `pipefail` for the case where it found something.
lineage_ln=$(awk 'index($0, "|| gate_session_lineage_record") { print NR; exit }' "$GATE_SH")
if [ -n "$lineage_ln" ]; then
  lineage_txt=$(sed -n "$((lineage_ln - 1)),$((lineage_ln))p" "$GATE_SH")
  if printf '%s' "$lineage_txt" | grep_all_q -F 'CC_PIPELINE_STAGE_ID' \
     && printf '%s' "$lineage_txt" | grep_all_q -F 'CC_PIPELINE_SHIFT_ID'; then
    ok "lineage 등재 관문이 스테이지와 샤드를 둘 다 배제한다"
  else
    bad "샤드 lineage" "관문이 두 마커를 함께 보지 않는다: $lineage_txt"
  fi
else
  bad "샤드 lineage" "lineage 등재 지점을 찾지 못했다"
fi
if sed -n '/^gate_launch_shift()/,/^}/p' "$GATE_SH" | grep_all_q -F 'CC_PIPELINE_SHIFT_ID='; then
  ok "교대 런처가 샤드 마커를 실제로 내보낸다 (관문이 볼 값이 존재한다)"
else
  bad "샤드 마커" "런처가 마커를 내보내지 않으면 위 관문은 아무것도 배제하지 않는다"
fi

# (c) `shift.in-progress` SUPPRESSES THE AFTER-STAGE ARM, AND IT EXPIRES. The
# arm's condition is "a stage's terminal row is the last row, nothing is alive,
# and the router has not acted" — which is a shift changeover exactly. But
# `RUN_DIR` is never pruned, so a marker tested with `[ -f ]` alone survives a
# shift that died right after its handoff and disarms the arm for the rest of
# the night. The three cases below are the whole of that distinction.
WATCH_SH="$(dirname "$DRIVER")/watch.sh"
if sed -n '/watch.announced-after-stage/,/^  fi$/p' "$WATCH_SH" | grep_all_q -F 'shift_active' \
   || sed -n '/^  if \[ "\$live" = "0" \] \&\& \[ "\$pend" = "0" \] \&\& \[ "\$age" -ge "\$AFTER_STAGE" \]/,/^  fi$/p' "$WATCH_SH" | grep_all_q -F 'shift_active'; then
  ok "after-stage 아암이 교대 가드를 거친다"
else
  bad "교대 가드" "after-stage 아암이 shift_active 를 보지 않는다 — 교대가 라우터 무응답으로 기록된다"
fi
SHIFT_SAVE="${RUN_DIR:-}"
RUN_DIR="$WORK/shift-run"; mkdir -p "$RUN_DIR"
eval "$(sed -n '/^now_epoch()/,/^}/p' "$WATCH_SH")"
eval "$(sed -n '/^shift_active()/,/^}/p' "$WATCH_SH")"
if shift_active; then
  bad "교대 가드" "마커가 없는데 교대 중이라고 답했다"
else
  ok "마커가 없으면 교대 중이 아니다"
fi
printf '%s\n' "$(( $(date +%s) + 300 ))" > "$RUN_DIR/shift.in-progress"
if shift_active; then
  ok "만료 전 마커는 교대 중으로 읽힌다"
else
  bad "교대 가드" "살아 있는 마커를 못 읽었다 — 가드가 아무것도 막지 못한다"
fi
printf '%s\n' "$(( $(date +%s) - 10 ))" > "$RUN_DIR/shift.in-progress"
if shift_active; then
  bad "교대 가드" "만료된 마커가 아직 교대 중으로 읽힌다 — RUN_DIR 은 prune 되지 않으므로 아암이 밤 내내 죽는다"
else
  ok "만료된 마커는 스스로 풀린다 (죽은 샤드가 아암을 영구 무력화하지 않는다)"
fi
RUN_DIR="$SHIFT_SAVE"

# ---------------------------------------------------------------------------
# 28. The feed's fence, which no lint can hold.
#
# `feed.sh` cannot raise a banner because it does not source the emitter and
# does not name its two functions. The banner-site lint counts occurrences of
# the notifier BINARY, so a sourcing path is invisible to it — these two
# assertions are the fence itself rather than a supplement to one.
# ---------------------------------------------------------------------------
FEED_SH="$(dirname "$DRIVER")/feed.sh"
if [ -f "$FEED_SH" ]; then
  ok "진행 채널 스크립트가 있다"
  # A WHITELIST, NOT A DENYLIST. Asking "does it source the emitter" only closes
  # the door that is already named; asking "is `liveness.sh` the only thing it
  # sources" also closes the one a future emitter under another name would use.
  feed_src_other=$( { grep -nE '^[[:space:]]*(\.|source)[[:space:]]' "$FEED_SH" || true; } \
                    | { grep -v 'liveness\.sh' || true; } )
  if [ -n "$feed_src_other" ]; then
    bad "피드 울타리" "feed.sh 가 liveness.sh 밖의 것을 소스한다: $feed_src_other"
  else
    ok "feed.sh 가 소스하는 것은 liveness.sh 뿐이다 — notify-run.sh 를 소스하지 않는다"
  fi
  # And the name reaches no executable line. A header sentence explaining the
  # fence is not a breach of it, so the comment lines are excluded rather than
  # the file being required never to mention what it refuses to load.
  feed_notify_code=$( { grep -n 'notify-run\.sh' "$FEED_SH" || true; } \
                      | { grep -vE '^[0-9]+:[[:space:]]*#' || true; } )
  if [ -n "$feed_notify_code" ]; then
    bad "피드 울타리" "주석이 아닌 줄이 notify-run.sh 를 이름으로 담는다: $feed_notify_code"
  else
    ok "feed.sh 의 실행 줄 어디에도 notify-run.sh 가 없다"
  fi
  if grep -q 'cc_notify_fire\|cc_notify_clear' "$FEED_SH"; then
    bad "피드 울타리" "feed.sh 가 방출 함수를 이름으로 담고 있다"
  else
    ok "feed.sh 가 방출 함수를 이름으로도 부르지 않는다"
  fi
else
  bad "진행 채널" "feed.sh 가 없다 — 라우팅이 리드를 떠난 밤에 사람이 볼 것이 없다"
fi


# ---------------------------------------------------------------------------
# 29. The progress channel survives its own unclean death.
#
# `feed.lock` used to be removed only by a trap installed AFTER the lock was
# taken, and no trap covers SIGKILL or SIGHUP. A feed that died uncleanly left the
# file behind, every later re-arm took the "the lock is here and its owner is not"
# branch and exited 3, and the instruction that branch printed was to delete the
# file by hand — on a path that runs while the only person who could is asleep.
# The watcher's sixth arm exists to DETECT that death and then tells the lead to
# re-arm, so detection and recovery sat on two sides of one defect. §27 asserts
# the fence; nothing asserted the lifecycle.
# ---------------------------------------------------------------------------
if [ -f "$FEED_SH" ]; then
  FEED_RD=$(mktemp -d "${TMPDIR:-/tmp}/cc-feed-lock.XXXXXX")
  FEED_LG="$FEED_RD/ledger.md"
  printf -- '- `run` | 교대=0 | run-id=feedlock | prev=aaaa\n' > "$FEED_LG"
  # A pid that is certainly gone: started and reaped right here.
  ( : ) & dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  printf '%s\n' "$dead_pid" > "$FEED_RD/feed.lock"
  mkdir -p "$FEED_RD/feed.lock.d"
  feed_rc=0
  bash "$FEED_SH" --run-dir "$FEED_RD" --ledger "$FEED_LG" --once \
    > "$FEED_RD/out" 2> "$FEED_RD/err" || feed_rc=$?
  if [ "$feed_rc" = "0" ]; then
    ok "주인이 사라진 락을 회수하고 재장전이 성공한다"
  else
    bad "피드 락" "고아 락에서 재장전이 rc=$feed_rc 로 실패했다 — 무인 경로에는 손으로 지울 사람이 없다: $(tr '\n' ' ' < "$FEED_RD/err")"
  fi
  if grep -q '회수' "$FEED_RD/err" 2>/dev/null; then
    ok "회수했다는 사실이 한 줄로 남는다"
  else
    bad "피드 락" "락을 조용히 덮어썼다 — 앞선 채널이 깨끗하지 않게 죽었다는 사실이 아침에 남지 않는다"
  fi
  if [ -f "$FEED_RD/feed.lock" ]; then
    bad "피드 락" "깨끗하게 끝난 실행이 자기 락을 남겼다"
  else
    ok "깨끗하게 끝난 실행은 자기 락을 지운다"
  fi

  # THE OTHER BRANCH MUST NOT REGRESS. A live holder still stops a second
  # instance, and it does so with 0 — the lead re-arms up to three times on a
  # healthy night, and a non-zero there files three false failures.
  printf '%s\n%s\n' "$$" \
    "$(LC_ALL=C ps -o lstart= -p $$ 2>/dev/null | sed 's/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//')" \
    > "$FEED_RD/feed.lock"
  mkdir -p "$FEED_RD/feed.lock.d"
  feed_rc2=0
  bash "$FEED_SH" --run-dir "$FEED_RD" --ledger "$FEED_LG" --once \
    > "$FEED_RD/out2" 2> "$FEED_RD/err2" || feed_rc2=$?
  if [ "$feed_rc2" = "0" ]; then
    ok "살아 있는 주인이 있으면 재장전은 0 으로 물러난다"
  else
    bad "피드 락" "건강한 밤의 재장전이 rc=$feed_rc2 로 실패를 보고했다"
  fi
  if [ -f "$FEED_RD/feed.lock" ]; then
    ok "물러난 인스턴스는 살아 있는 주인의 락을 지우지 않는다"
  else
    bad "피드 락" "물러나면서 남의 락을 지웠다 — 락이 막으려던 이중 실행이 바로 그 상태다"
  fi

  # The ordering, and the signal set. Neither closes the SIGKILL window — nothing
  # in a shell can — but installing the trap after the lock widens a window that
  # costs nothing to close.
  # `-m1` AND NOT `| head -1`. `head` closes the pipe on its first line, `cut`
  # takes SIGPIPE, and `pipefail` hands the whole substitution a non-zero status
  # — so the line lookup failed on exactly the files where the pattern matched
  # more than once. Stopping the search at the first match asks for the same
  # value without anyone closing a pipe early.
  feed_trap_ln=$( { grep -n -m1 "^trap 'release_lock'" "$FEED_SH" || true; } | cut -d: -f1)
  feed_take_ln=$( { grep -n -m1 '^take_lock$' "$FEED_SH" || true; } | cut -d: -f1)
  if [ -n "$feed_trap_ln" ] && [ -n "$feed_take_ln" ] && [ "$feed_trap_ln" -lt "$feed_take_ln" ]; then
    ok "트랩이 락 획득보다 먼저 설치된다"
  else
    bad "피드 락" "트랩이 락 획득 뒤에 설치된다 (trap=$feed_trap_ln take=$feed_take_ln)"
  fi
  if { grep -q "^trap 'release_lock' EXIT HUP INT TERM" "$FEED_SH"; }; then
    ok "그 트랩이 HUP 도 덮는다"
  else
    bad "피드 락" "HUP 이 트랩 목록에 없다 — 터미널이 사라지는 흔한 종료가 락을 남긴다"
  fi
  rm -rf "$FEED_RD"
fi

# ---------------------------------------------------------------------------
# 크래시 갈래도 1회 재시도한다 — 인접한 「공허한 성공」 갈래와 같은 패턴으로.
#
# 두 갈래는 세 줄 떨어져 있고 오래 서로 다른 재시도 의미를 가졌다: 깨끗한 종료에
# 산출물이 없는 쪽은 1회 재시도했고, 프로세스가 죽은 쪽은 0회였다. 근거는 반대
# 방향을 가리킨다 — 커밋된 원장 전수에서 크래시한 스테이지의 57.8%가 바로 다음
# 시도에서, 67.0%가 나중 시도에서 정상 완료했다. 그 재시도는 전부 실제로
# 일어났고, 사람이 알아채고 손으로 했다.
#
# 소스 문면으로 단언하는 이유는 이 자리가 세그먼트 루프 한가운데라 스테이지를
# 실제로 띄우지 않고는 구동할 수 없기 때문이며, 이 파일의 다른 갈래 단언들이
# 이미 같은 형태를 쓴다.
# ---------------------------------------------------------------------------
crash_arm=$(sed -n "/^      '크래시')/,/;;/p" "$DRIVER")
if [ -n "$crash_arm" ]; then
  ok "크래시가 자기 case 갈래를 갖는다 (와일드카드에 묻히지 않는다)"
else
  bad "크래시 갈래" "'크래시') 갈래가 없다 — 와일드카드로 park 하면 재시도가 없다"
fi
if printf '%s' "$crash_arm" | grep_all_q 'stage_spawn' && printf '%s' "$crash_arm" | grep_all_q '\.retry'; then
  ok "크래시 갈래가 1회 재시도를 띄운다"
else
  bad "크래시 재시도" "크래시 갈래에 stage_spawn ... .retry 가 없다"
fi
if printf '%s' "$crash_arm" | grep_all_q 'predicate_implement'; then
  ok "재시도 뒤 산출물 술어로 판정한다"
else
  bad "재시도 판정" "재시도 후 predicate_implement 검사가 없다"
fi
if printf '%s' "$crash_arm" | grep_all_q '크래시 2회'; then
  ok "두 번째 실패는 구별되는 park 사유를 쓴다"
else
  bad "park 사유" "크래시 2회의 park 사유가 첫 실패와 구별되지 않는다"
fi
# 재시도는 정확히 1회다. 두 갈래가 각각 하나씩이라 드라이버 전체에서 `.retry`
# 스폰은 둘이어야 하고, 셋이 되면 어느 갈래가 예산을 넘긴 것이다.
check "재시도 스폰은 갈래당 1회 (전체 2회)" \
  "$(grep -c 'stage_spawn "\$sid\.retry"' "$DRIVER")" "2"

# ---------------------------------------------------------------------------
# 30. 리뷰 복구의 읽기 측 — 픽스처 위의 행위 단언
# ---------------------------------------------------------------------------
# 이 절이 파일 끝에 앉는 것은 배치가 아니라 제약이다. 20절의 `unset -f reap_orphan`
# 이 드라이버의 정의를 복원이 아니라 제거하고(배시에 함수 섀도잉이 없다),
# `review_recover` 는 파견 직전에 `reap_orphan` 을 부른다 — 그 줄 이후의 어느
# 자리에서 `review_recover` 를 부르든 미정의 함수를 부르게 된다. 그래서 여기서
# 자기 감시 스텁을 다시 정의하며, 그 스텁은 회수 호출을 관측하는 수단이기도 하다.
#
# 읽기 측은 스테이지를 실제로 띄우지 않고는 구동할 수 없는 것이 아니다 — 호출
# 대상을 전부 스텁으로 갈아 끼우면 분기가 순수 셸이 된다. 그래서 소스 문면 핀이
# 아니라 행위로 고정한다. 핀은 파견 줄에 무엇이 실렸는지를 원리적으로 셀 수 없다.
REC_DIR="$WORK/recover"; mkdir -p "$REC_DIR"
REC_RUN_SAVE="$RUN_DIR"; RUN_DIR="$REC_DIR/run"; mkdir -p "$RUN_DIR/log"
REC_LEDGER_SAVE="$LEDGER"; LEDGER="$REC_DIR/ledger.md"; : > "$LEDGER"
REC_BASE_SAVE="$BASE"; BASE="$REC_DIR/base"; mkdir -p "$BASE/docs"

SIDR="S5:segR:0"; ATTR="4"
REC_RP="$REC_DIR/report.md"; : > "$REC_RP"

mk_wit() {  # mk_wit <디렉터리 이름> <.attempt 내용, 또는 - 로 스탬프 없음>
  mkdir -p "$RUN_DIR/$1"
  [ "$2" = "-" ] || printf '%s\n' "$2" > "$RUN_DIR/$1/.attempt"
}

# --- (1) witness_dirs_for_attempt — 네 경우와 두 방향의 대조군 --------------
mk_wit "cc-team-witness-hit"     "$SIDR#$ATTR"
mk_wit "cc-team-witness-nostamp" -
# 이름은 대상 시도의 것처럼 지었으나 스탬프가 다른 후보. 이름 비교였다면 잡혔다.
mk_wit "cc-team-witness-review-seg-r.S5-segR-0-4" "$SIDR#3"
: > "$RUN_DIR/cc-team-witness-plainfile"   # 이름은 맞지만 디렉터리가 아니다

REC_WD=$(witness_dirs_for_attempt "$SIDR" "$ATTR")
check "스탬프가 맞는 디렉터리만 나온다" "$REC_WD" "$RUN_DIR/cc-team-witness-hit"
check "스탬프 없는 후보는 건너뛴다" \
  "$( { printf '%s\n' "$REC_WD" | grep -c 'nostamp' || true; } )" "0"
check "이름이 맞고 스탬프가 다른 후보는 건너뛴다" \
  "$( { printf '%s\n' "$REC_WD" | grep -c 'seg-r' || true; } )" "0"
check "cc-team-witness-* 이름의 파일은 건너뛴다" \
  "$( { printf '%s\n' "$REC_WD" | grep -c 'plainfile' || true; } )" "0"
check "일치하는 스탬프가 없으면 빈 출력" "$(witness_dirs_for_attempt "$SIDR" 99)" ""

# 주석이 주장하는 「이름이 아니라 스탬프로 맞춘다」를 반대 방향에서 단언한다 —
# 이름은 전혀 다른 시도의 것이고 `.attempt` 내용만 맞는 후보가 잡혀야 한다.
mk_wit "cc-team-witness-unrelated-name.SX-9" "$SIDR#$ATTR"
check "이름이 어긋나도 스탬프가 맞으면 잡힌다" \
  "$( { witness_dirs_for_attempt "$SIDR" "$ATTR" | grep -c . || true; } )" "2"
rm -rf "$RUN_DIR/cc-team-witness-unrelated-name.SX-9"

# --- (2) review_recover 의 다섯 분기 ----------------------------------------
REC_PARK=""; REC_SPAWN=""; REC_CALLS=""; REC_ROWS=""; REC_REAPED=""
REC_PRED=1                 # predicate_review 의 반환값 (0 = 술어 줄이 이미 있음)
REC_RCLASS="정상 완료"

rec_reset() { REC_PARK=""; REC_SPAWN=""; REC_CALLS=""; REC_ROWS=""; REC_REAPED=""; }

# --- (2a) reap_orphan 의 효과 — 진짜 함수를 구동한다 -------------------------
# 아래 (3) 의 단언들은 스파이가 설치된 뒤의 관측이라 호출 지점의 위치만 고정할 수
# 있다. 효과는 여기서 고정한다. 이 자리가 스파이 설치보다 앞이라는 것이 요점이며
# 20절과 같은 이유다 — `rec_install_spies` 아래로 내려가는 순간 `reap_orphan` 은
# 무조건 기록하는 스텁이 되어 진짜 함수가 무엇을 하든 통과한다.
#
# 20절의 `unset -f reap_orphan` 은 복원이 아니라 제거이므로 이 자리에는 진짜
# 정의가 없다. 드라이버에서 그 함수만 다시 읽어 온다 — `watch.sh` 의 두 함수를
# 가져오는 자리와 같은 형태다. `log` 도 같은 이유로 없을 수 있어 스텁을 둔다.
eval "$(sed -n '/^reap_orphan()/,/^}/p' "$DRIVER")"
log() { :; }

# pid 파일이 없는 경우를 **조용한 무동작으로서** 단언한다. 이번 사이클의 발견이
# 정확히 「도달 가능한 모든 경로가 이 형상이다」이므로, 그 삼킴 가드가 스위트에
# 보이지 않으면 다음 사람이 같은 자리를 다시 연다.
REC_ORPH_NONE="S5:orph-none:0"
rm -f "$RUN_DIR/$REC_ORPH_NONE.pid" "$RUN_DIR/$REC_ORPH_NONE.reaped"
reap_orphan "$REC_ORPH_NONE"; REC_RC=$?
check "pid 파일이 없으면 reap_orphan 은 0 으로 반환한다" "$REC_RC" "0"
check "pid 파일이 없으면 스탬프도 남지 않는다 (조용한 무동작)" \
  "$( { [ -e "$RUN_DIR/$REC_ORPH_NONE.reaped" ] && printf 'yes' || printf 'no'; } )" "no"

# pid 파일이 있고 그 pid 가 이미 죽은 경우 — 판정이 스탬프로 남고 pid 는 지워진다.
# 스탬프가 없으면 「이미 죽어 있었다」와 「회수가 아예 없었다」가 구별되지 않는다.
REC_ORPH_DEAD="S5:orph-dead:0"; REC_DEAD_PID=999999
rm -f "$RUN_DIR/$REC_ORPH_DEAD.reaped"
printf '%s\n' "$REC_DEAD_PID" > "$RUN_DIR/$REC_ORPH_DEAD.pid"
reap_orphan "$REC_ORPH_DEAD"
check "죽은 pid 는 dead 로 스탬프된다" \
  "$( { cat "$RUN_DIR/$REC_ORPH_DEAD.reaped" 2>/dev/null || true; } )" "$REC_DEAD_PID dead"
check "회수 뒤 pid 파일은 사라진다 (이후의 생존성 오라클이 없어진다)" \
  "$( { [ -e "$RUN_DIR/$REC_ORPH_DEAD.pid" ] && printf 'yes' || printf 'no'; } )" "no"

# 살아 있는 경우 — 이 스위트가 직접 띄운 자식이라 신호가 밖으로 나가지 않는다.
REC_ORPH_LIVE="S5:orph-live:0"
rm -f "$RUN_DIR/$REC_ORPH_LIVE.reaped"
sleep 30 &
REC_LIVE_PID=$!
printf '%s\n' "$REC_LIVE_PID" > "$RUN_DIR/$REC_ORPH_LIVE.pid"
reap_orphan "$REC_ORPH_LIVE" 2>/dev/null
check "살아 있는 pid 는 alive 로 스탬프된다" \
  "$( { cat "$RUN_DIR/$REC_ORPH_LIVE.reaped" 2>/dev/null || true; } )" "$REC_LIVE_PID alive"
wait "$REC_LIVE_PID" 2>/dev/null || true
check "살아 있던 자식은 실제로 종료했다" \
  "$( { kill -0 "$REC_LIVE_PID" 2>/dev/null && printf 'yes' || printf 'no'; } )" "no"
rm -f "$RUN_DIR/$REC_ORPH_LIVE.reaped" "$RUN_DIR/$REC_ORPH_DEAD.reaped"

# THE SPIES ARE INSTALLED FROM INSIDE A FUNCTION, and the indentation is the
# whole reason. Two of these names — `park` and `ledger_row` — are real
# functions this file sources from the driver and calls at top level in earlier
# sections. A column-zero definition of either down here reads, to the
# called-before-defined check, as a call above its own definition: that check
# scans column zero precisely because a top-level call runs where it is written,
# and it cannot see that the earlier calls resolve to the sourced originals.
# Defining them one level in keeps the check honest — it still catches the shape
# it exists for — while bash installs them globally the moment this runs.
rec_install_spies() {
  park()                { REC_PARK="$REC_PARK|$*"; REC_CALLS="$REC_CALLS park"; return 0; }
  predicate_review()    { return "$REC_PRED"; }
  stage_attempt_pinned(){ printf '%s' "$ATTR"; }
  stage_spawn()         { REC_SPAWN="$REC_SPAWN|$*"; REC_CALLS="$REC_CALLS stage_spawn"; return 0; }
  stage_wait_all()      { REC_CALLS="$REC_CALLS stage_wait_all"; return 0; }
  classify_termination(){ printf '%s' "$REC_RCLASS"; }
  # 인자를 버리면 행에 무엇이 실렸는지 원리적으로 셀 수 없다 — 누산한다.
  ledger_row()          { REC_ROWS="$REC_ROWS|$*"; REC_CALLS="$REC_CALLS ledger_row"; return 0; }
  stage_session_id()    { printf 'SID'; }
  stage_parent_id()     { printf 'PID'; }
  log()                 { :; }
  doc_arg()             { printf '%s/docs/x.md' "$BASE"; }
  reap_orphan()         { REC_REAPED="$REC_REAPED $1"; REC_CALLS="$REC_CALLS reap_orphan"; }
}
rec_install_spies

# 1. 비크래시 종단 부류 — 아무것도 띄우지 않고 park 한다.
rec_reset
review_recover segR 0 "$SIDR" "$REC_RP" "$REC_DIR" segbranch "정상 완료"; REC_RC=$?
check "비크래시 종단 부류는 반환 1" "$REC_RC" "1"
check "비크래시 종단 부류는 파견 0회" "$REC_SPAWN" ""

# 2. 술어 줄이 이미 있는 크래시 — 원 스테이지가 리포트를 남기고 죽은 경우.
rec_reset; REC_PRED=0
review_recover segR 0 "$SIDR" "$REC_RP" "$REC_DIR" segbranch "크래시"; REC_RC=$?
check "술어 줄 선재는 반환 1" "$REC_RC" "1"
check "술어 줄 선재는 파견 0회" "$REC_SPAWN" ""
if printf '%s' "$REC_PARK" | grep_all_q '종료 술어 줄이 이미 있어'; then
  ok "술어 줄 선재의 park 사유가 그 사실을 지명한다"
else
  bad "park 사유" "술어 줄 선재인데 사유가 그것을 말하지 않는다: $REC_PARK"
fi
REC_PRED=1

# 3. 위트니스 디렉터리 0개 — Step 4 에 닿기 전에 죽었다.
rec_reset; ATTR=99
review_recover segR 0 "$SIDR" "$REC_RP" "$REC_DIR" segbranch "크래시"; REC_RC=$?
check "디렉터리 0개는 반환 1" "$REC_RC" "1"
check "디렉터리 0개는 파견 0회" "$REC_SPAWN" ""
if printf '%s' "$REC_PARK" | grep_all_q 'Step 4 미도달'; then
  ok "디렉터리 0개의 park 사유가 Step 4 미도달이다"
else
  bad "park 사유" "디렉터리 0개인데 Step 4 미도달을 말하지 않는다: $REC_PARK"
fi
ATTR=4

# 4. 디렉터리 2개 이상 — 지명할 수 없고, 후보가 전부 사유에 실린다.
rec_reset; mk_wit "cc-team-witness-second" "$SIDR#$ATTR"
review_recover segR 0 "$SIDR" "$REC_RP" "$REC_DIR" segbranch "크래시"; REC_RC=$?
check "디렉터리 2개는 반환 1" "$REC_RC" "1"
check "디렉터리 2개는 파견 0회" "$REC_SPAWN" ""
if printf '%s' "$REC_PARK" | grep_all_q 'cc-team-witness-hit' \
   && printf '%s' "$REC_PARK" | grep_all_q 'cc-team-witness-second'; then
  ok "지명 불가 park 사유에 후보가 전부 열거된다"
else
  bad "park 사유" "후보 열거가 빠졌다: $REC_PARK"
fi
rm -rf "$RUN_DIR/cc-team-witness-second"

# 5. 디렉터리 1개 — 행복 경로. 파견 줄에 세 인자가 전부 실렸는가.
# 앞선 회수가 남겼을 스탬프를 픽스처로 깐다. 실제 런에서 이 값을 쓰는 것은
# `stage_wait_all` 안의 회수이고, 여기 스파이는 그것을 대신하지 않으므로 파일로
# 세운다 — 단언 대상은 「분기가 스탬프를 읽어 행에 싣는가」다.
printf '4242 dead\n' > "$RUN_DIR/$SIDR.reaped"
rec_reset
review_recover segR 0 "$SIDR" "$REC_RP" "$REC_DIR" segbranch "크래시"; REC_RC=$?
check "행복 경로는 반환 0" "$REC_RC" "0"
check "행복 경로는 정확히 1회 파견한다" \
  "$( { printf '%s' "$REC_SPAWN" | grep -c 'review-unattended' || true; } )" "1"
for want in '--recover' "--scratch-dir $RUN_DIR/cc-team-witness-hit" "--report-path $REC_RP"; do
  if printf '%s' "$REC_SPAWN" | grep_all_q -F -- "$want"; then
    ok "파견 줄이 $want 를 싣는다"
  else
    bad "파견 줄" "$want 가 없다: $REC_SPAWN"
  fi
done

# --- (3) 회수 호출 지점과 허용 목록 ------------------------------------------
# 5번과 같은 픽스처의 관측이다 — `rec_reset` 을 사이에 두지 않는다.
# **이 절이 고정하는 것은 호출 지점의 위치이지 회수의 효과가 아니다.** 스파이가
# pid 파일을 보지 않고 무조건 기록하므로 진짜 `reap_orphan` 이 무엇을 하든 아래
# 두 단언은 통과한다. 효과는 (2a) 가 진짜 함수 위에서 고정한다.
check "원 스테이지를 정확히 한 번 회수 호출한다" "$REC_REAPED" " $SIDR"
if printf '%s' "$REC_CALLS" | grep_all_q -F 'reap_orphan stage_spawn'; then
  ok "회수 호출이 파견보다 앞선다"
else
  bad "회수 순서" "reap_orphan 이 stage_spawn 앞에 오지 않는다: $REC_CALLS"
fi

# 행에 실리는 것 — 스파이가 인자를 누산하므로 이제 셀 수 있다.
for want in "복구 scratch=$RUN_DIR/cc-team-witness-hit" '원회수=dead' '종단 부류=정상 완료'; do
  if printf '%s' "$REC_ROWS" | grep_all_q -F -- "$want"; then
    ok "stage-result 행이 $want 를 싣는다"
  else
    bad "stage-result 행" "$want 가 없다: $REC_ROWS"
  fi
done

# 스탬프가 없으면 행은 `미상` 을 싣는다 — 「모른다」가 원장에 남아야 한다.
rm -f "$RUN_DIR/$SIDR.reaped"
rec_reset
review_recover segR 0 "$SIDR" "$REC_RP" "$REC_DIR" segbranch "크래시" >/dev/null
if printf '%s' "$REC_ROWS" | grep_all_q -F -- '원회수=미상'; then
  ok "회수 스탬프가 없으면 행이 미상 을 싣는다"
else
  bad "stage-result 행" "스탬프 부재인데 미상 이 없다: $REC_ROWS"
fi
if kill_permitted "S5R:segR:0"; then
  ok "복구 파견 id 가 경계 멱등으로 인정된다 (정체하면 신호를 받는다)"
else
  bad "허용 목록" "S5R 이 목록 밖이라 정체한 복구가 백오프를 전소한다"
fi
if kill_permitted "S9:segR:0"; then
  bad "허용 목록" "목록 밖 접두까지 허용됐다 — 넓힌 것이 S5R 하나가 아니다"
else
  ok "대조군: 목록 밖 접두는 여전히 거부된다"
fi

# 20절과 같은 이유로 `unset -f` 는 복원이 아니라 제거다. 이 절이 마지막이라
# 이후에 이 이름들을 부르는 단언이 없고, 아래 요약 출력만 남는다.
unset -f park predicate_review stage_attempt_pinned stage_spawn stage_wait_all \
         classify_termination ledger_row stage_session_id stage_parent_id log \
         doc_arg reap_orphan mk_wit rec_reset
RUN_DIR="$REC_RUN_SAVE"; LEDGER="$REC_LEDGER_SAVE"; BASE="$REC_BASE_SAVE"

printf '\ntest-run: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
