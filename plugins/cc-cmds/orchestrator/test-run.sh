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

# ---------------------------------------------------------------------------
# 22. 레인 지속화 — 4단 리졸버, 런 상태 프로브, 형제 레인 훅 구멍
#
# 세 표면이 한 절에 있는 이유는 셋이 한 성질의 세 면이기 때문이다: 한 런이 어느
# 레인을 쓰는가를 (a) 결정하고 (b) 밖에서 읽을 수 있게 하고 (c) 다른 레인을
# 건드리지 못하게 한다. 어느 하나만 서면 나머지 둘이 조용히 무의미해진다.
# ---------------------------------------------------------------------------
LD="$WORK/lane"
mkdir -p "$LD/env" "$LD/rundir" "$LD/norun" "$LD/home/.claude" \
         "$LD/xdg/cc-cmds" "$LD/xdgempty" "$LD/xdgbad/cc-cmds" \
         "$LD/runrec" "$LD/homerec"
printf '%s\n' "$LD/runrec"  > "$LD/rundir/config-dir"
printf '%s\n' "$LD/homerec" > "$LD/xdg/cc-cmds/config-dir"

# --- T1~T4: 네 단이 각각 선택된다 -----------------------------------------
v=$(CLAUDE_CONFIG_DIR="$LD/env" RUN_DIR="$LD/rundir" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdg" resolve_account)
check "T1 리졸버 1단: 환경변수가 아래 세 단을 모두 이긴다" "$v" "$LD/env"
v=$( unset CLAUDE_CONFIG_DIR; RUN_DIR="$LD/rundir" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdg" resolve_account )
check "T2 리졸버 2단: 런 디렉터리의 config-dir" "$v" "$LD/runrec"
v=$( unset CLAUDE_CONFIG_DIR; RUN_DIR="$LD/norun" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdg" resolve_account )
check "T3 리졸버 3단: 홈 아래 설정 파일" "$v" "$LD/homerec"
v=$( unset CLAUDE_CONFIG_DIR; RUN_DIR="$LD/norun" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdgempty" resolve_account )
check "T4 리졸버 4단: 기본값" "$v" "$LD/home/.claude"

# --- T5: 3단은 폴백하지 않는다 ---------------------------------------------
# 기대값의 절반은 「비영으로 끝난다」가 아니라 「4단의 기본값을 내지 않는다」이다.
# 폴백하면 운영자가 의도적으로 보낸 런이 조용히 반대 레인의 할당량을 쓴다.
: > "$LD/notadir"
printf '%s\n' "$LD/notadir" > "$LD/xdgbad/cc-cmds/config-dir"
v=$( unset CLAUDE_CONFIG_DIR; RUN_DIR="$LD/norun" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdgbad" resolve_account 2>/dev/null )
rc=$?
check "T5 3단 fail-closed: 비영으로 끝난다" "$rc" "1"
check "T5 3단 fail-closed: 4단의 기본값을 내지 않는다" "$v" ""

# --- T6: 2단도 폴백하지 않는다 ---------------------------------------------
# 2단의 값이 깨졌을 때 폴백하면 같은 런의 스테이지들이 서로 다른 레인에 앉는데,
# 그것이 정확히 2단을 둔 이유이므로 여기서 폴백하는 것은 기전의 자기 부정이다.
mkdir -p "$LD/rundirbad"
printf '%s\n' "$LD/notadir" > "$LD/rundirbad/config-dir"
v=$( unset CLAUDE_CONFIG_DIR; RUN_DIR="$LD/rundirbad" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdg" resolve_account 2>/dev/null )
rc=$?
check "T6 2단 fail-closed: 비영으로 끝난다" "$rc" "1"
check "T6 2단 fail-closed: 3·4단으로 내려가지 않는다" "$v" ""

# --- T7: 환경변수 경로는 변경 전과 바이트 동일 -----------------------------
# 기대 문자열을 손으로 적지 않고 변경 전 구현을 그 자리에서 다시 유도한다.
# 하드코딩한 기대값은 두 구현이 함께 틀려도 통과한다.
want=$(CLAUDE_CONFIG_DIR="$LD/env" HOME="$LD/home" \
       /usr/bin/env sh -c 'printf %s "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"')
got=$(CLAUDE_CONFIG_DIR="$LD/env" RUN_DIR="$LD/rundir" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdg" resolve_account)
check "T7 1단의 반환값이 변경 전 구현과 바이트 동일" "$got" "$want"

# --- T7b: init 이 쓰는 값이 init 이 읽는 술어를 만족한다 --------------------
# 이것을 **왕복**으로 재지 않으면 잡히지 않는다. 4단은 `$HOME/.claude` 를 검증 없이
# 내고 `rundir_init` 은 그것을 그대로 영속화하는데, 같은 함수가 다음 진입에서 그
# 기록에 `[ -d ]` 를 요구했다. 그래서 1회차는 rc=0 으로 조용히 성공하고 2회차부터
# 죽는다 — 운영자가 보는 증상은 「설치 실패」가 아니라 「한 번 됐던 런이 다음부터
# 안 됨」이고, 기록이 `XDG_STATE_HOME` 아래라 재부팅으로도 사라지지 않는다.
#
# 발화 조건은 `CLAUDE_CONFIG_DIR` 도 3단 기록도 `$HOME/.claude` 도 없는 호스트이며,
# 새 설치·컨테이너·서비스 계정·CI 러너가 정확히 그 집합이다. 위 `$LD` 픽스처는
# `$LD/home/.claude` 를 **항상** 미리 만들어 이 조건 자체를 배제하고 있었고, 그래서
# 로컬 초록과 CI 빨강이 동시에 참이 됐다. 기존 픽스처를 고치는 대신 이 조건을 갖는
# 픽스처를 새로 세운다 — 기존 것을 바꾸면 그것이 지키던 단언들이 함께 움직인다.
RTH="$WORK/rt-home"; mkdir -p "$RTH"                     # `.claude` 를 만들지 않는다
RTS="$WORK/rt-state"; mkdir -p "$RTS"
rt_init() (
  unset CLAUDE_CONFIG_DIR
  HOME="$RTH" XDG_STATE_HOME="$RTS" XDG_CONFIG_HOME="$WORK/rt-xdg-absent" \
    RUN_ID=rt-run ORCH_DIR="$script_dir" rundir_init
)
rt_init >/dev/null 2>&1; rc=$?
check "T7b init 1회차는 성공한다" "$rc" "0"
rt_init >/dev/null 2>&1; rc=$?
check "T7b init 2회차도 성공한다 (자기가 쓴 기록을 자기가 거부하지 않는다)" "$rc" "0"
# 두 번 다 rc=0 이면서 기록이 비어 있으면 위 두 단언은 공허하다.
check "T7b 기록이 실제로 쓰였다" \
  "$(sed -n '1p' "$RTS/cc-cmds/run/rt-run/config-dir" 2>/dev/null)" "$RTH/.claude"
check "T7b 기록이 가리키는 디렉터리가 실재한다 (쓰는 값이 읽는 술어를 만족한다)" \
  "$( [ -d "$RTH/.claude" ] && printf yes || printf no )" "yes"
t_mode() {
  # t_mode <경로> — 이 러너에서 통하는 철자로 8진 모드를 낸다. `t_ino` 와 같은
  # 이유로 두 철자를 쓴다: BSD 와 GNU 의 포맷 플래그가 다르고, 한 철자만 적으면
  # 다른 쪽에서 에러 없이 엉뚱한 것을 찍는다.
  local out
  out=$(stat -f '%Lp' "$1" 2>/dev/null)   # lint-bash-portability: disable=stat -f
  case "$out" in [0-7][0-7][0-7]) printf '%s' "$out"; return 0 ;; esac
  out=$(stat -c '%a' "$1" 2>/dev/null)    # lint-bash-portability: disable=stat -c
  case "$out" in [0-7][0-7][0-7]) printf '%s' "$out"; return 0 ;; esac
  return 1
}
# 4단 경로에서 만들어지는 것은 CLI 자신의 디렉터리이고 CLI 는 그것을 0700 으로
# 만든다. 이 팔이 도는 조건이 곧 「그 디렉터리가 아직 없다」이므로 드라이버가 CLI
# 보다 먼저 만드는 것이 정상 경로이고, umask 에 좌우되는 0755 는 CLI 가 고르지
# 않은 넓힘이다. `$RTH/.claude` 는 바로 위 1회차 진입이 만든 것이다.
check "T7b 새로 만든 레인 디렉터리의 모드가 0700 이다" "$(t_mode "$RTH/.claude")" "700"
# 음성 대조군. 이미 있는 디렉터리의 모드는 건드리지 않는다 — 운영자가 자기 레인을
# 0755 로 두고 쓰는 것은 이 기기의 실제 레인 두 곳이 그렇듯 평범한 상태이고,
# `[ -d ]` 가 참인 가지에서 모드를 바꾸면 그것은 이 수정이 요구한 적 없는 변경이다.
EXH="$WORK/ex-home"; mkdir -p "$EXH/.claude"; chmod 755 "$EXH/.claude"
EXS="$WORK/ex-state"; mkdir -p "$EXS"
( unset CLAUDE_CONFIG_DIR
  HOME="$EXH" XDG_STATE_HOME="$EXS" XDG_CONFIG_HOME="$WORK/ex-xdg-absent" \
    RUN_ID=ex-run ORCH_DIR="$script_dir" rundir_init ) >/dev/null 2>&1
check "T7b 음성 대조군: 이미 있는 레인 디렉터리의 모드는 그대로다" \
  "$(t_mode "$EXH/.claude")" "755"

# --- T7d: 값 술어의 나머지 다리 — 절대 경로와 제어 문자 --------------------
# 읽는 쪽이 **값**에 거는 술어는 셋이다(비어 있지 않음·제어문자 없음·디렉터리).
# 위 T7b 가 재는 것은 셋째 하나뿐이고, 나머지 둘에서 같은 회귀가 그대로 재현됐다 —
# 1회차는 조용히 rc=0 이고 이후 진입이 자기 기록에 죽는다. 셋 다 리졸버 1단
# (`CLAUDE_CONFIG_DIR`)을 통해서만 닿으므로 픽스처도 그 단으로 구동한다.
#
# **정지가 1회차로 앞당겨지는 것**이 이 단언들의 요점이다. 오염된 기록이 애초에
# 영속되지 않으므로 「한 번 됐던 런이 다음부터 안 됨」이라는 증상 자체가 생기지
# 않는다. 그래서 rc 만이 아니라 기록의 **부재**를 함께 단언한다.
VT=$(printf '\t')
VNL='
'
vd_init() (
  # $1 — CLAUDE_CONFIG_DIR 값, $2 — 런 id
  HOME="$WORK/vd-home" XDG_STATE_HOME="$WORK/vd-state" \
    XDG_CONFIG_HOME="$WORK/vd-xdg-absent" CLAUDE_CONFIG_DIR="$1" \
    RUN_ID="$2" ORCH_DIR="$script_dir" rundir_init
)
mkdir -p "$WORK/vd-home/.claude" "$WORK/vd-state/cc-cmds/run/vd-rel" \
         "$WORK/vd-state/cc-cmds/run/vd-tab" "$WORK/vd-state/cc-cmds/run/vd-nl" \
         "$WORK/vd-state/cc-cmds/run/vd-ok"
vd_out=$(vd_init "rel-lane" vd-rel 2>&1); rc=$?
check "T7d 상대 경로 레인은 1회차에서 거부된다" "$rc" "1"
check "T7d 그리고 그 값이 기록에 영속되지 않는다" \
  "$( [ -e "$WORK/vd-state/cc-cmds/run/vd-rel/config-dir" ] && printf yes || printf no )" "no"
case "$vd_out" in
  *'절대 경로여야 합니다'*) ok "T7d 거부가 절대 경로 팔의 것이다" ;;
  *) bad "T7d 상대 경로 거부 사유" "다른 팔이 먼저 거부했다 — 이 단언이 공허하다: $vd_out" ;;
esac
# 상대 문자열이 cwd 아래에 디렉터리를 만들어 두지도 않는다. 만들어 두면 그 값이
# 그 cwd 에서만 해소되는 기록으로 남고, 프로브의 한 줄 계약은 그것을 다른
# 프로세스·다른 cwd 의 소비자에게 마지막 필드로 발행한다.
check "T7d 상대 경로 레인 디렉터리가 만들어지지 않는다" \
  "$( [ -e "rel-lane" ] && printf yes || printf no )" "no"
vd_out=$(vd_init "$WORK/vd-tab${VT}lane" vd-tab 2>&1); rc=$?
check "T7d 탭을 담은 레인은 1회차에서 거부된다" "$rc" "1"
check "T7d 그리고 그 값이 기록에 영속되지 않는다 (탭)" \
  "$( [ -e "$WORK/vd-state/cc-cmds/run/vd-tab/config-dir" ] && printf yes || printf no )" "no"
case "$vd_out" in
  *'제어 문자가 있습니다'*) ok "T7d 탭 거부가 제어 문자 팔의 것이다" ;;
  *) bad "T7d 탭 거부 사유" "다른 팔이 먼저 거부했다 — 이 단언이 공허하다: $vd_out" ;;
esac
# 개행은 탭의 부분집합이 아니라 별도의 실패 양식이다. 기록을 읽는 쪽의
# `sed -n '1p'` 이 값을 조용히 절단하므로, 쓰기 쪽에서 막지 않으면 기록이 「쓴 것과
# 다른 경로」를 지목한 채 판정되고 제어 문자 팔은 서지도 못한다. 절단값이 우연히
# 실재하는 디렉터리이면 거부조차 나지 않고 런이 잘못된 레인에서 돈다.
vd_out=$(vd_init "$WORK/vd-nl-lane${VNL}second" vd-nl 2>&1); rc=$?
check "T7d 개행을 담은 레인은 1회차에서 거부된다" "$rc" "1"
check "T7d 그리고 그 값이 기록에 영속되지 않는다 (개행)" \
  "$( [ -e "$WORK/vd-state/cc-cmds/run/vd-nl/config-dir" ] && printf yes || printf no )" "no"
case "$vd_out" in
  *'제어 문자가 있습니다'*) ok "T7d 개행 거부도 제어 문자 팔의 것이다 (절단 뒤 「디렉터리 아님」이 아니다)" ;;
  *) bad "T7d 개행 거부 사유" "절단이 먼저 일어나 다른 팔이 답했다: $vd_out" ;;
esac
# 음성 대조군. 이것이 없으면 위 셋의 통과가 「1단을 통째로 거부한다」와 구별되지
# 않고, 통째 거부는 운영자가 환경변수로 레인을 고르는 지원되는 사용법을 없앤다.
( vd_init "$WORK/vd-good-lane" vd-ok ) >/dev/null 2>&1; rc=$?
check "T7d 음성 대조군: 유효한 절대 경로는 1회차에서 통과한다" "$rc" "0"
check "T7d 음성 대조군: 그리고 그 값이 실제로 기록된다" \
  "$(sed -n '1p' "$WORK/vd-state/cc-cmds/run/vd-ok/config-dir" 2>/dev/null)" "$WORK/vd-good-lane"
( vd_init "$WORK/vd-good-lane" vd-ok ) >/dev/null 2>&1; rc=$?
check "T7d 음성 대조군: 2회차도 자기 기록 위에서 통과한다" "$rc" "0"

# --- T7c: 깨진 기록에서의 정지가 들린다 ------------------------------------
# 정지한다는 결정 자체는 설계가 요구한 것이라 문제가 아니다. 문제는 그 정지가 아무
# 내구적 기록도 남기지 않는다는 것이었다 — 무인 런에서 stderr 는 아무도 보지 않으므로,
# 그 실패는 「시끄럽게 실패하라」가 막으려던 조용한 실패와 관측상 구별되지 않는다.
BKH="$WORK/bk-home"; mkdir -p "$BKH/.claude"
BKS="$WORK/bk-state"; mkdir -p "$BKS/cc-cmds/run/bk-run"
BKREC="$BKS/cc-cmds/run/bk-run/config-dir"
printf '%s\n' "$WORK/bk-absent-lane" > "$BKREC"
bk_init() (
  unset CLAUDE_CONFIG_DIR
  HOME="$BKH" XDG_STATE_HOME="$BKS" XDG_CONFIG_HOME="$WORK/bk-xdg-absent" \
    RUN_ID=bk-run ORCH_DIR="$script_dir" BASE="$WORK/bk-base" rundir_init
)
bk_out=$(bk_init 2>&1); rc=$?
check "T7c 깨진 기록에서는 그대로 정지한다" "$rc" "1"
case "$bk_out" in
  *"rm \"$BKREC\""*) ok "T7c 거부 문면이 회복 명령을 축자로 싣는다" ;;
  *) bad "T7c 회복 명령" "거부 문면이 무엇을 지워야 하는지 말하지 않는다" ;;
esac
# 그리고 `ledger-path` 가 이미 있으면 그 정지가 원장에 한 행을 남긴다. 이것이 이
# 잔여를 닫을 수 있는 이유다 — 위 발화 형상에서 1회차 진입은 성공하므로 그 파일이
# 이미 디스크에 있다.
BKL="$WORK/bk-ledger.md"; printf '# 원장\n\n## 실행 bk-run\n' > "$BKL"
printf '%s\n' "$BKL" > "$BKS/cc-cmds/run/bk-run/ledger-path"
bk_before=$(wc -l < "$BKL" | tr -d ' ')
bk_init >/dev/null 2>&1; rc=$?
bk_after=$(wc -l < "$BKL" | tr -d ' ')
check "T7c ledger-path 가 있어도 정지 자체는 그대로다" "$rc" "1"
check "T7c 그 정지가 원장에 한 행을 남긴다" "$((bk_after - bk_before))" "1"
case "$(sed -n '$p' "$BKL")" in
  *'blocked'*'재개 명령=rm '*) ok "T7c 그 행이 park 이고 회복 명령을 싣는다" ;;
  *) bad "T7c park 행" "마지막 행이 회복 명령을 실은 blocked 행이 아니다: $(sed -n '$p' "$BKL")" ;;
esac
# 음성 대조군. `ledger-path` 가 없으면 적을 원장이 없는 것이고, 그때 없는 파일에
# 행을 만들어 내면 그것은 park 가 아니라 새 상태의 발명이다.
rm -f "$BKS/cc-cmds/run/bk-run/ledger-path"
bk_before=$(wc -l < "$BKL" | tr -d ' ')
bk_init >/dev/null 2>&1
bk_after=$(wc -l < "$BKL" | tr -d ' ')
check "T7c 음성 대조군: ledger-path 가 없으면 원장에 아무 행도 남기지 않는다" \
  "$((bk_after - bk_before))" "0"

# --- T7e: 그 park 팔의 ledger-path 읽기 실패가 조용하지 않다 ----------------
# 「읽을 수 없음」을 「없음」으로 접으면 park 가 서지 않고 원장 증가 0 으로 조용히
# 죽는다 — 이 팔이 존재하는 유일한 목적이 「정지가 내구적 기록을 남기게」인데 그
# 목적이 무산되고, 무인 런은 아침에 아무것도 못 본다. 이 파일이 `lane_record_read`
# 를 도입하며 금지한다고 명시적으로 적어 둔 형태이기도 하다.
#
# 폴백 자체는 유지된다(적을 원장이 진짜로 없을 수 있다). 재는 것은 그 폴백이
# **들리는가**이다.
printf '%s\n' "$BKL" > "$BKS/cc-cmds/run/bk-run/ledger-path"
chmod 000 "$BKS/cc-cmds/run/bk-run/ledger-path"
if [ -r "$BKS/cc-cmds/run/bk-run/ledger-path" ]; then
  # root 로 돌면 mode 000 도 읽히므로 이 픽스처가 재려는 상태가 성립하지 않는다.
  bad "T7e 픽스처" "mode 000 파일이 읽혀 읽기 실패 상태를 만들지 못했다 (root 로 실행 중인가)"
else
  bk_before=$(wc -l < "$BKL" | tr -d ' ')
  bk_out=$(bk_init 2>&1); rc=$?
  bk_after=$(wc -l < "$BKL" | tr -d ' ')
  check "T7e 읽을 수 없는 ledger-path 에서도 정지 자체는 그대로다" "$rc" "1"
  case "$bk_out" in
    *'원장 경로 기록을 읽을 수 없습니다'*)
      ok "T7e 그 읽기 실패가 경고 한 줄로 들린다 (부재로 접히지 않는다)" ;;
    *) bad "T7e 읽기 실패 경고" "읽을 수 없는 ledger-path 가 없는 것과 같게 조용히 접혔다" ;;
  esac
  # 그리고 최악은 여전히 막혀 있다 — 회복 명령은 `lp` 가 무엇이든 나간다.
  case "$bk_out" in
    *"rm \"$BKREC\""*) ok "T7e 회복 명령은 원장을 잃어도 그대로 나간다" ;;
    *) bad "T7e 회복 명령" "읽기 실패 경로에서 거부 문면이 회복 명령을 잃었다" ;;
  esac
  # park 는 서지 못한다. 읽지 못한 경로를 원장으로 삼는 것은 park 가 아니라 추측이다.
  check "T7e park 가 서지 못하므로 원장은 늘지 않는다" "$((bk_after - bk_before))" "0"
fi
chmod 644 "$BKS/cc-cmds/run/bk-run/ledger-path"
rm -f "$BKS/cc-cmds/run/bk-run/ledger-path"

# --- T8: 런당 1회가 아니라 스테이지 디스패치마다 ---------------------------
# 이 단언은 **계수**한다. 이전 형태는 `stage_spawn` 본문을 `resolve_account`
# 토큰으로 grep 했는데, 그것은 의무가 이름 붙인 성질 — 런당 1회가 아니라 디스패치
# 마다 해소된다 — 을 재지 않는다. 실측으로 확정됐다: `stage_spawn` 에 런당 1회
# 캐싱을 심고 토큰은 본문에 남겨 두면 스위트가 그대로 초록이었고, 반대로 토큰만
# 지우면 실패했는데 그 실패 메시지가 스스로 「런당 1회로 굳는다」라고 적었다 —
# 단언이 자기가 탐지하지 못하는 조건의 이름을 부르고 있었던 셈이다.
#
# 그래서 리졸버를 계수 스텁으로 갈아 끼우고 디스패치를 두 번 태운다. seam 은
# `stage_spawn` 이 리졸버를 부른 **직후**에 있는 두 이른 반환이다 — `CLI_BIN` 이
# 비면 그 자리에서 127 로 돌아오므로, 프로세스를 하나도 띄우지 않고 디스패치
# 경로를 실제로 가로지른다. 스위트가 `reap_orphan` 감시 스텁에 이미 쓰는 기법이다.
T8DIR="$WORK/t8"; mkdir -p "$T8DIR/log"
T8_COUNT="$T8DIR/resolve-calls"; : > "$T8_COUNT"
T8_RUN_SAVE="$RUN_DIR"; RUN_DIR="$T8DIR"
T8_CLI_SAVE="${CLI_BIN:-}"; CLI_BIN=""
# 정의를 **먼저 떠 둔다.** bash 에는 함수 섀도잉이 없어 덮어쓰면 원본이 이
# 프로세스에서 사라지고, 아래 T8b 와 프로브 절과 훅 절이 전부 진짜 리졸버를
# 부르므로 복원은 선택이 아니다. 파일에서 다시 읽는 대신 `declare -f` 로 뜨는
# 이유는 그쪽이 파일의 줄 배치에 기대지 않기 때문이다.
T8_ORIG=$(declare -f resolve_account)
resolve_account() { printf 'call\n' >> "$T8_COUNT"; printf '%s' "$LD/env"; }
stage_spawn "t8-implement-a" "$WORK" "prompt" >/dev/null 2>&1
stage_spawn "t8-implement-b" "$WORK" "prompt" >/dev/null 2>&1
check "T8a 리졸버가 디스패치마다 해소된다 (런당 1회로 굳지 않는다)" \
  "$(grep -c . "$T8_COUNT" || true)" "2"
eval "$T8_ORIG"
RUN_DIR="$T8_RUN_SAVE"; CLI_BIN="$T8_CLI_SAVE"
# 복원됐는지 값으로 확인한다. 스텁이 남아 있으면 아래 T8b 는 두 호출이 같은
# 스텁 값을 내어 통과하면서 아무것도 검증하지 않는다.
check "T8a 뒤 진짜 리졸버가 복원됐다 (스텁이 남아 있지 않다)" \
  "$( unset CLAUDE_CONFIG_DIR; RUN_DIR="$LD/rundir" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdg" resolve_account )" \
  "$LD/runrec"
# 그리고 그 반복 호출이 같은 답을 낸다는 것이 2단의 존재 이유다. 아래 두 호출은
# 3단의 설정이 서로 다른데, 런 기록이 있으므로 값이 갈리지 않아야 한다.
v1=$( unset CLAUDE_CONFIG_DIR; RUN_DIR="$LD/rundir" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdg"      resolve_account )
v2=$( unset CLAUDE_CONFIG_DIR; RUN_DIR="$LD/rundir" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdgempty" resolve_account )
check "T8b 3단이 달라도 런 기록이 있으면 한 런의 스테이지가 갈리지 않는다" "$v1" "$v2"

# --- 런 디렉터리 초기화가 레인과 오케스트레이터를 남긴다 -------------------
RI_SAVE="$RUN_DIR"; RID_SAVE="$RUN_ID"
RUN_ID="lane-init"
( unset CLAUDE_CONFIG_DIR
  XDG_STATE_HOME="$LD/state" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdg" rundir_init ) >/dev/null 2>&1
RI="$LD/state/cc-cmds/run/lane-init"
check "rundir_init 이 레인을 기록한다" "$(cat "$RI/config-dir" 2>/dev/null)" "$LD/homerec"
check "rundir_init 이 오케스트레이터 디렉터리를 기록한다" "$(cat "$RI/orchestrator-dir" 2>/dev/null)" "$ORCH_DIR"
# 재기동한 드라이버가 살아 있는 스테이지의 레인을 옮기면 안 된다.
printf '%s\n' "$LD/runrec" > "$RI/config-dir"
( unset CLAUDE_CONFIG_DIR
  XDG_STATE_HOME="$LD/state" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdg" rundir_init ) >/dev/null 2>&1
check "rundir_init 은 이미 있는 레인 기록을 덮지 않는다" "$(cat "$RI/config-dir" 2>/dev/null)" "$LD/runrec"

# --- 「읽을 수 없었다」는 「없었다」가 아니다 --------------------------------
# 두 단은 「기록이 없음」을 파일을 읽을 수 있었는지가 아니라 `sed` 가 낸 값으로
# 판정했다. 읽을 수 없는 파일은 `sed` 를 실패시키고 `2>/dev/null` 이 사유를 버리므로
# 값이 비어, 기록이 없었던 것처럼 그 단이 건너뛰어지고 경고 한 줄 없이 기본 레인으로
# 폴백했다. 읽을 수 없는 기록은 없는 것도 빈 것도 아니라 존재하지만 읽히지 않는
# 기록이고, 그 폴백은 바로 위 주석이 금지한다고 적은 그것이다.
mkdir -p "$LD/rundirblind" "$LD/xdgblind/cc-cmds"
printf '%s\n' "$LD/runrec"  > "$LD/rundirblind/config-dir"
printf '%s\n' "$LD/homerec" > "$LD/xdgblind/cc-cmds/config-dir"
chmod 000 "$LD/rundirblind/config-dir" "$LD/xdgblind/cc-cmds/config-dir" 2>/dev/null
if [ -r "$LD/rundirblind/config-dir" ]; then
  printf 'NOTE: 읽을 수 없는 기록 분기를 만들 수 없다 (이 사용자는 권한을 무시한다 — root 로 보인다)\n'
else
  v=$( unset CLAUDE_CONFIG_DIR; RUN_DIR="$LD/rundirblind" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdg" resolve_account 2>/dev/null )
  rc=$?
  check "읽을 수 없는 2단 기록은 비영으로 끝난다" "$rc" "1"
  check "그리고 기본 레인을 내지 않는다" "$v" ""
  v=$( unset CLAUDE_CONFIG_DIR; RUN_DIR="$LD/norun" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdgblind" resolve_account 2>/dev/null )
  rc=$?
  check "읽을 수 없는 3단 기록도 같은 처리를 받는다 (한쪽만 고쳐지지 않았다)" "$rc" "1"
  check "3단도 기본 레인을 내지 않는다" "$v" ""
  # 사유가 stderr 로 나가는지. 조용한 거부는 무인 런에서 조용한 폴백과 구별되지
  # 않는다 — 실측된 결함의 절반이 「stderr 에 아무것도 나오지 않았다」였다.
  errtxt=$( unset CLAUDE_CONFIG_DIR; RUN_DIR="$LD/rundirblind" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdg" resolve_account 2>&1 >/dev/null )
  case "$errtxt" in
    *'읽을 수 없습니다'*) ok "읽을 수 없는 기록의 거부가 사유를 남긴다" ;;
    *) bad "읽기 실패 사유" "stderr 가 비었거나 다른 사유다: '$errtxt'" ;;
  esac
fi
chmod 644 "$LD/rundirblind/config-dir" "$LD/xdgblind/cc-cmds/config-dir" 2>/dev/null
# 대조군. 「디렉터리가 아닌 값」은 종전대로 거부돼야 하고(T5·T6 가 재고 있다),
# 「읽을 수 있고 유효한 값」은 종전대로 통과해야 한다 — 이것이 없으면 위 단언들의
# 통과가 「2단을 통째로 거부한다」와 구별되지 않는다.
check "대조군: 읽을 수 있는 유효한 2단 기록은 그대로 통과" \
  "$( unset CLAUDE_CONFIG_DIR; RUN_DIR="$LD/rundirblind" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdg" resolve_account )" \
  "$LD/runrec"

# --- 제어 문자를 담은 레인 값은 두 단 모두에서 거부된다 ---------------------
# 이 값은 프로브의 네 필드 계약에서 마지막 필드로 발행되므로, 탭 하나가 필드를
# 하나 늘리고 개행 하나가 레코드를 통째로 만들어 낸다. 계약 헤더는 이 값이
# 상류에서 거부된다고 적고 있었는데 어디에서도 거부되지 않았다.
#
# 픽스처의 값은 **실재하는 디렉터리**여야 한다. 탭을 담았지만 실재하지 않는 경로를
# 쓰면 기존 `[ -d "$v" ]` 가 먼저 거부하므로, 제어 문자 검사를 지워도 단언이 통과해
# 아무것도 재지 못한다 — 실측으로 확인한 자리다.
TABLANE="$LD/lane$(printf '\t')tabbed"
mkdir -p "$TABLANE" 2>/dev/null
if [ -d "$TABLANE" ]; then
  mkdir -p "$LD/rundirtab"
  printf '%s\n' "$TABLANE" > "$LD/rundirtab/config-dir"
  v=$( unset CLAUDE_CONFIG_DIR; RUN_DIR="$LD/rundirtab" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdg" resolve_account 2>/dev/null )
  rc=$?
  check "탭을 담은 2단 기록은 실재하는 디렉터리라도 거부된다" "$rc" "1"
  check "그리고 기본 레인을 내지 않는다 (탭)" "$v" ""
  errtxt=$( unset CLAUDE_CONFIG_DIR; RUN_DIR="$LD/rundirtab" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdg" resolve_account 2>&1 >/dev/null )
  case "$errtxt" in
    *'제어 문자'*) ok "그 거부가 제어 문자 검사의 것이다" ;;
    *) bad "탭 거부 사유" "다른 검사가 먼저 거부했다 — 위 단언이 공허하다: '$errtxt'" ;;
  esac
else
  printf 'NOTE: 탭을 담은 디렉터리를 만들지 못해 제어 문자 거부를 건너뛴다\n'
fi

# --- 0바이트 기록은 복구되고, 깨진 기록은 init 에서 런을 세운다 -------------
# 리다이렉션이 `printf` 전에 파일을 만들고 자르므로 그 순간 죽은 드라이버는
# 0바이트 기록을 남기는데, `[ ! -f ]` 는 0바이트 파일에 대해 거짓이라 재기동한
# 드라이버가 복구하지 못했다. 그리고 리졸버가 그 빈 파일을 「없음」으로 읽고
# 폴백하므로 이후 모든 디스패치가 환경과 머신 설정에서 레인을 다시 결정했다 —
# 2단을 둔 이유의 정반대다.
RUN_ID="lane-init"
: > "$RI/config-dir"
( unset CLAUDE_CONFIG_DIR
  XDG_STATE_HOME="$LD/state" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdg" rundir_init ) >/dev/null 2>&1
check "0바이트로 잘린 레인 기록은 재기동한 드라이버가 복구한다" \
  "$(cat "$RI/config-dir" 2>/dev/null)" "$LD/homerec"
# 그리고 그 쓰기가 원자적인지 — 임시 파일이 남지 않는다.
check "레인 기록 쓰기가 임시 파일을 남기지 않는다" \
  "$(ls "$RI"/config-dir.tmp.* 2>/dev/null | grep -c . || true)" "0"
# 실재하지 않는 디렉터리를 가리키는 기록 위에서는 init 이 실패해야 한다. 종전에는
# rc=0 으로 성공하고 `started-at`·EXIT 트랩·`check_grant`·`ledger_init`·
# `notify_probe` 가 모두 돈 뒤 첫 디스패치에서 죽었다.
printf '%s\n' "$LD/absent-lane" > "$RI/config-dir"
( unset CLAUDE_CONFIG_DIR
  XDG_STATE_HOME="$LD/state" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdg" rundir_init ) >/dev/null 2>&1
rc=$?
if [ "$rc" != "0" ]; then
  ok "깨진 레인 기록 위에서는 init 이 런을 세운다 (첫 디스패치까지 끌고 가지 않는다)"
else
  bad "init 검증" "실재하지 않는 디렉터리를 가리키는 기록 위에서 rundir_init 이 성공했다"
fi
# 음성 대조군: 유효한 기록 위에서는 init 이 그대로 성공하고 값을 유지한다.
printf '%s\n' "$LD/runrec" > "$RI/config-dir"
( unset CLAUDE_CONFIG_DIR
  XDG_STATE_HOME="$LD/state" HOME="$LD/home" XDG_CONFIG_HOME="$LD/xdg" rundir_init ) >/dev/null 2>&1
rc=$?
check "음성 대조군: 유효한 기록 위에서 init 은 그대로 성공한다" "$rc" "0"
check "음성 대조군: 그 값도 그대로다" "$(cat "$RI/config-dir" 2>/dev/null)" "$LD/runrec"
RUN_DIR="$RI_SAVE"; RUN_ID="$RID_SAVE"

# --- T9~T12: 프로브 ---------------------------------------------------------
PROBE="$script_dir/lane-probe.sh"
if [ -x "$PROBE" ]; then ok "프로브에 실행 비트가 있다"; else bad "프로브" "실행 비트가 없다: $PROBE"; fi
if env -i PATH="$SANITIZED_PATH" /usr/bin/env bash -n "$PROBE" 2>/dev/null; then
  ok "정제 PATH가 고르는 인터프리터에서 프로브가 파싱된다"
else
  bad "프로브 파싱" "bash -n 실패 — bash 4 전용 문법이 섞였을 수 있음"
fi

FR="$WORK/probe-root"
mkdir -p "$FR/cc-cmds/run/R-live" "$FR/cc-cmds/run/R-dead" "$FR/cc-cmds/run/R-odd" \
         "$FR/cc-cmds/run/R-spawning" "$FR/cc-cmds/run/R-watcher" \
         "$FR/cc-cmds/run/R-spacey"
# 살아 있는 스테이지: 기록된 pid 가 살아 있고 시작시각 지문이 일치해야 한다.
# 지문은 드라이버가 쓰는 것과 같은 형태로 만든다 — 다른 형태로 만들면 이 픽스처가
# 검증하는 것은 오라클이 아니라 이 하네스 자신이 된다.
sleep 45 &
LIVE_PID=$!
printf '%s\n' "$LIVE_PID" > "$FR/cc-cmds/run/R-live/S1.pid"
ps -o lstart= -p "$LIVE_PID" 2>/dev/null \
  | sed 's/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//' > "$FR/cc-cmds/run/R-live/S1.start"
printf '%s\n' "$LD/runrec" > "$FR/cc-cmds/run/R-live/config-dir"
# 죽은 pid: 형상은 인식되므로 판정 불가가 아니라 「아님」이다. 지문 파일은 비워 두지
# 않고 그럴듯한 값으로 채운다 — 비워 두면 「pid 가 죽었다」와 「지문이 비어 있다」는
# 두 독립 원인이 같은 기대값을 내고, 그러면 이 픽스처는 어느 쪽도 고정하지 못한다.
printf '999999\n' > "$FR/cc-cmds/run/R-dead/S1.pid"
printf '%s\n' 'Mon Jan 1 00:00:00 2001' > "$FR/cc-cmds/run/R-dead/S1.start"
# 인식되지 않는 형상: pid 파일이 비어 있다. 스포너의 리다이렉션이 쓰기 전에 파일을
# 만들기 때문에 실재하는 창이고, 여기서 0 을 세면 그 답이 스왑을 인가한다.
: > "$FR/cc-cmds/run/R-odd/S1.pid"
# 막 뜬 스테이지: 살아 있는 pid 가 기록됐는데 형제 지문이 아직 없다. 두 스포너가
# 이 파일들을 반대 순서로 쓰기 때문에 실재하는 창이며, 센서스는 형제 없는 pid 를
# 세지 않으므로 0 이 나온다 — 형태 검사가 이것을 통과시키면 그 0 이 「아님」으로
# 발행되고, 그 값이 스왑을 인가한다.
printf '%s\n' "$LIVE_PID" > "$FR/cc-cmds/run/R-spawning/S1.pid"
# 그리고 그 대조군. 같은 살아 있는 pid 를 워처의 이름으로 기록한다 — 워처는 형제
# 지문을 원래 남기지 않으므로 이쪽은 「아님 0」이어야 한다. 이 둘이 함께 있어야
# 위 픽스처의 통과가 「형제 없는 pid 는 전부 판정 불가」와 구별되고, 그 해석은
# 온디스크의 워처 전용 디렉터리를 영구히 판정 불가로 만든다.
printf '%s\n' "$LIVE_PID" > "$FR/cc-cmds/run/R-watcher/watch.pid"
# 공백을 담은 레인 경로. macOS 에서 `Library/Application Support` 아래 레인은 이상한
# 설정이 아니고, 마지막 필드가 무경계라는 사실 자체가 계약이 깨지는 넓은 쪽이다 —
# 이 픽스처가 없으면 아래 필드 수 단언이 오늘의 픽스처에서 우연히 통과한다.
printf '%s\n' "$LD/lane with space" > "$FR/cc-cmds/run/R-spacey/config-dir"
# 형상 검사가 센서스와 **같은 것**을 요구하는가. 센서스는 형제 핸들이 비어 있지
# 않을 것을 요구하는데 형상 검사는 존재만 보았고, 그래서 빈 `.start` 가 통과해
# 센서스의 `.pgid` 폴백으로 떨어졌다 — 게이트는 `.pgid` 를 아예 쓰지 않으므로
# 센서스가 0 을 내고 프로브가 `아님` 을 찍었다. 살아 있는 스테이지 위에서 스왑을
# 인가하는 값이다. 빈 `.start` 는 좁은 경주가 아니다: 게이트 스포너의 `.start` 는
# `ps | sed` 파이프라인의 리다이렉션 대상이라 셸이 `ps` 보다 먼저 파일을 만들고
# 잘라 내며, `ps` 가 아무것도 내지 않으면 그 상태가 스테이지 수명 내내 지속된다.
mkdir -p "$FR/cc-cmds/run/R-emptystart" "$FR/cc-cmds/run/R-emptypgid"
printf '%s\n' "$LIVE_PID" > "$FR/cc-cmds/run/R-emptystart/S1.pid"
: > "$FR/cc-cmds/run/R-emptystart/S1.start"
# 그리고 합집합이 필요한 이유를 고정하는 대조군. 빈 `.start` 옆에 유효한 `.pgid`
# 가 있으면 센서스는 살아 있다고 답하므로, 형상 검사를 `[ -s .start ]` 단독으로
# 고치면 드라이버가 남긴 `.pgid` 계열 디렉터리가 새로 판정 불가로 뒤집힌다.
printf '%s\n' "$LIVE_PID" > "$FR/cc-cmds/run/R-emptypgid/S1.pid"
: > "$FR/cc-cmds/run/R-emptypgid/S1.start"
ps -o pgid= -p "$LIVE_PID" 2>/dev/null | tr -d '[:space:]' > "$FR/cc-cmds/run/R-emptypgid/S1.pgid"
# 레코드 위조. 디렉터리 이름은 이 프로그램이 만드는 것이 아니라 정리되지 않는 공유
# 루트에서 열거한 값이고, 탭은 필드를 하나 늘리고 개행은 **레코드를 통째로 만들어
# 낸다** — 심어 둔 디렉터리 하나가 존재하지 않는 run id 에 대해 문법적으로 완전한
# 줄을 exit 0 으로 배달한다. 소비자는 레포 밖 스왑 스케줄러이고, 위조된 줄은
# 문법적으로 완전하므로 더 조심스럽게 파싱해도 걸러지지 않는다.
# 레인 필드 쪽의 같은 벡터. 프로브는 `config-dir` 을 `[ -d ]` 없이 읽어 마지막
# 필드로 발행하므로, 리졸버가 거부하는 값이라도 이 경로로는 그대로 나갔다 —
# 상류 거부만으로는 닫히지 않는 자리이고, 그래서 발행 지점에도 검사가 필요하다.
mkdir -p "$FR/cc-cmds/run/R-tablane"
printf '%s\n' "$LD/lane$(printf '\t')tabbed" > "$FR/cc-cmds/run/R-tablane/config-dir"
FORGE_TAB=$(printf 'R\tTABBED')
FORGE_NL=$(printf 'R-x\n20260101-victimrun\t아님\t0\t%s' "$LD/attacker-lane")
mkdir -p "$FR/cc-cmds/run/$FORGE_TAB" "$FR/cc-cmds/run/$FORGE_NL" 2>/dev/null
FORGE_OK=0
{ [ -d "$FR/cc-cmds/run/$FORGE_TAB" ] && [ -d "$FR/cc-cmds/run/$FORGE_NL" ]; } && FORGE_OK=1

probe_out=$(XDG_STATE_HOME="$FR" bash "$PROBE" 2>/dev/null)
probe_rc=$?
check "T9 프로브 정상 종료" "$probe_rc" "0"
if [ "$FORGE_OK" = "1" ]; then
  check "T9 런 11개에 열한 줄" "$(printf '%s\n' "$probe_out" | grep -c .)" "11"
else
  printf 'NOTE: 제어 문자를 담은 디렉터리를 만들지 못해 위조 픽스처를 건너뛴다\n'
  check "T9 런 9개에 아홉 줄" "$(printf '%s\n' "$probe_out" | grep -c .)" "9"
fi
# 추출도 탭으로 한다. 첫 공백까지를 떼어 내던 이전 형태는 상태 토큰의 공백에서도
# 레인 경로의 공백에서도 성립하지 않았고, 기대값을 서로 다른 필드 수로 나란히
# 박아 둔 채 한 번도 비교하지 않았다.
TAB=$(printf '\t')
probe_field() {
  # probe_field <run-id> — 그 런의 줄에서 run-id 를 뗀 나머지를 탭 그대로 낸다.
  printf '%s\n' "$probe_out" | awk -F'\t' -v r="$1" '$1==r{print $2 FS $3 FS $4}'
}
check "T9 살아 있는 런은 도는중 / 스테이지 1 / 기록된 레인" \
  "$(probe_field R-live)" "도는중${TAB}1${TAB}$LD/runrec"
check "T9 죽은 pid 의 런은 아님 / 0 / 미기록" \
  "$(probe_field R-dead)" "아님${TAB}0${TAB}(미기록)"
check "T10 인식되지 않는 형상은 판정 불가이고 개수를 세지 않는다" \
  "$(probe_field R-odd)" "판정 불가${TAB}?${TAB}(미기록)"
check "T10 형제 지문이 없는 살아 있는 pid 는 판정 불가다 (아님이 아니다)" \
  "$(probe_field R-spawning)" "판정 불가${TAB}?${TAB}(미기록)"
check "T10 대조군: 같은 모양이라도 워처 pid 는 아님 0 이다" \
  "$(probe_field R-watcher)" "아님${TAB}0${TAB}(미기록)"
check "T9 공백을 담은 레인 경로도 마지막 한 필드로 남는다" \
  "$(probe_field R-spacey)" "아님${TAB}0${TAB}$LD/lane with space"
check "빈 형제 핸들은 판정 불가다 (살아 있는 스테이지를 아님 0 으로 부르지 않는다)" \
  "$(probe_field R-emptystart)" "판정 불가${TAB}?${TAB}(미기록)"
check "대조군: 빈 .start 옆에 유효한 .pgid 가 있으면 도는중이다" \
  "$(probe_field R-emptypgid)" "도는중${TAB}1${TAB}(미기록)"
check "탭을 담은 레인 값은 발행 지점에서 고정 리터럴로 대체된다" \
  "$(probe_field R-tablane)" "아님${TAB}0${TAB}(비정규 레인)"
if [ "$FORGE_OK" = "1" ]; then
  # 세 단언이다 — (a) 두 위조 이름이 고정 리터럴로 나오고, (b) 위조된 바이트가
  # 출력 어디에도 나타나지 않으며, (c) 존재하지 않는 run id 의 줄이 배달되지 않는다.
  check "제어 문자를 담은 디렉터리 이름은 고정 리터럴로 발행된다" \
    "$(printf '%s\n' "$probe_out" | awk -F'\t' '$1=="(비정규 이름)"' | grep -c . || true)" "2"
  check "위조된 run id 바이트가 출력에 나타나지 않는다" \
    "$(printf '%s\n' "$probe_out" | grep -c 'victimrun' || true)" "0"
  check "위조된 레인 경로도 출력에 나타나지 않는다" \
    "$(printf '%s\n' "$probe_out" | grep -c 'attacker-lane' || true)" "0"
fi
# 그리고 철자와 독립적으로 필드 수 자체를 잰다. 기본 FS 로 재면 공백을 담은 레인
# 에서 이 단언 자신이 거짓 실패를 낸다 — 계약이 탭이므로 재는 것도 탭이어야 한다.
check "프로브의 모든 줄이 네 필드다" \
  "$(printf '%s\n' "$probe_out" | awk -F'\t' 'NF!=4' | grep -c . || true)" "0"

# 부분 설치본: 의존 소싱 실패는 「런 없음」이 아니라 열거 실패다. 프로브는 언제나
# 완전한 설치본 옆에서만 돌았다. 소싱 실패를 확인하지 않으면 `cc_live_stages` 가
# 미정의인 채로 센서스에 도달해 빈 문자열을 내고, 그 값이 `아님 0` 으로 발행되며
# 종료 코드는 0 으로 나간다 — 살아 있는 런 위에서 스왑을 인가하는 답이다. 위
# 픽스처가 아직 살아 있는 동안 재야 그 답이 실제로 위험한 답인지가 드러난다.
PP="$WORK/probe-partial"; mkdir -p "$PP"
cp "$PROBE" "$script_dir/run.sh" "$PP/" 2>/dev/null
part_out=$(XDG_STATE_HOME="$FR" bash "$PP/lane-probe.sh" 2>/dev/null); part_rc=$?
check "liveness.sh 가 없는 설치본은 열거 실패로 끝난다" "$part_rc" "3"
check "그리고 아무것도 출력하지 않는다 (살아 있는 런을 아님 0 으로 부르지 않는다)" \
  "$part_out" ""
PP2="$WORK/probe-partial2"; mkdir -p "$PP2"
cp "$PROBE" "$script_dir/liveness.sh" "$PP2/" 2>/dev/null
part2_out=$(XDG_STATE_HOME="$FR" bash "$PP2/lane-probe.sh" 2>/dev/null); part2_rc=$?
check "run.sh 가 없는 설치본도 같은 형태로 열거 실패다" "$part2_rc" "3"
check "그리고 아무것도 출력하지 않는다" "$part2_out" ""

kill "$LIVE_PID" 2>/dev/null
wait "$LIVE_PID" 2>/dev/null

# T11 — 런 0개의 정상 종료와 열거 실패는 **출력이 같고 종료 코드만 다르다**.
EMPTY="$WORK/probe-empty"; mkdir -p "$EMPTY/cc-cmds/run"
zero_out=$(XDG_STATE_HOME="$EMPTY" bash "$PROBE" 2>/dev/null); zero_rc=$?
check "T11 런 0개: 출력 없음" "$zero_out" ""
check "T11 런 0개: 정상 종료" "$zero_rc" "0"
MISSING="$WORK/probe-missing"; mkdir -p "$MISSING"
miss_out=$(XDG_STATE_HOME="$MISSING" bash "$PROBE" 2>/dev/null); miss_rc=$?
check "T11 런 루트 부재는 미지가 아니라 런 0개다" "$miss_rc" "0"
check "T11 런 루트 부재: 출력 없음" "$miss_out" ""
BLIND="$WORK/probe-blind"; mkdir -p "$BLIND/cc-cmds/run/R1"
chmod 000 "$BLIND/cc-cmds/run" 2>/dev/null
if [ -r "$BLIND/cc-cmds/run" ]; then
  printf 'NOTE: 열거 실패 분기를 만들 수 없다 (이 사용자는 권한을 무시한다 — root 로 보인다)\n'
else
  blind_out=$(XDG_STATE_HOME="$BLIND" bash "$PROBE" 2>/dev/null); blind_rc=$?
  check "T10 열거 실패: 판정 불가 코드" "$blind_rc" "3"
  check "T10 열거 실패: 아무것도 출력하지 않는다" "$blind_out" ""
  if [ "$blind_out" = "$zero_out" ] && [ "$blind_rc" != "$zero_rc" ]; then
    ok "T11 런 0개와 열거 실패는 출력이 같고 종료 코드만으로 갈린다"
  else
    bad "T11 구별" "출력 '$blind_out' vs '$zero_out', 코드 $blind_rc vs $zero_rc"
  fi
fi
chmod 755 "$BLIND/cc-cmds/run" 2>/dev/null

# T12 — `--resolve` 는 런이 하나도 없을 때의 답이다.
res_out=$(XDG_STATE_HOME="$EMPTY" CLAUDE_CONFIG_DIR="$LD/env" bash "$PROBE" --resolve 2>/dev/null)
res_rc=$?
check "T12 --resolve 종료 0" "$res_rc" "0"
check "T12 --resolve 가 리졸버 결과 한 줄을 낸다" "$res_out" "$LD/env"
res_out=$(env -u CLAUDE_CONFIG_DIR PATH="$PATH" HOME="$LD/home" \
            XDG_STATE_HOME="$EMPTY" XDG_CONFIG_HOME="$LD/xdg" bash "$PROBE" --resolve 2>/dev/null)
check "T12 환경변수가 없으면 아래 단이 답한다" "$res_out" "$LD/homerec"

# --- T13~T16: 형제 레인의 훅 판정 -------------------------------------------
HOOK="$repo_root/plugins/cc-cmds/hooks/gate-pretool.sh"
HH="$WORK/hookhome"
mkdir -p "$HH/.claude-x" "$HH/.claude-y/projects" "$HH/.claude-y/todos"
hook_decide() {
  # hook_decide <편집 대상 경로> — 스테이지는 레인 x 에서 돌고 y 는 형제다.
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" \
    | HOME="$HH" CLAUDE_CONFIG_DIR="$HH/.claude-x" \
      bash "$HOOK" --run-dir "$RUN_DIR" --gate "$script_dir/gate.sh" \
    | jq -r '.hookSpecificOutput.permissionDecision'
}
t_ino() {
  # t_ino <경로> — 이 러너에서 통하는 철자로 dev:ino 를 낸다. 통하는 철자가 없으면
  # 아무것도 내지 않는다. BSD 는 `-f` 가 포맷 지정자이고 GNU 는 `-f` 가
  # `--file-system` 이라, 한 철자만 적으면 다른 쪽에서는 에러 없이 엉뚱한 것을 찍는다.
  local out
  out=$(stat -L -f '%d:%i' "$1" 2>/dev/null)   # lint-bash-portability: disable=stat -f
  case "$out" in [0-9]*:[0-9]*) printf '%s' "$out"; return 0 ;; esac
  out=$(stat -L -c '%d:%i' "$1" 2>/dev/null)   # lint-bash-portability: disable=stat -c
  case "$out" in [0-9]*:[0-9]*) printf '%s' "$out"; return 0 ;; esac
  return 1
}
# 훅 판정 단언들보다 먼저 아이노드 계층의 생존 자체를 잰다. 계층이 통째로 죽으면
# 아래 철자 단언들은 어휘 계층만 검증하게 되는데, 그때 붉어지는 것은 한둘뿐이고
# 그 문면은 읽는 사람을 진짜 원인에서 멀어지게 한다 — 「심링크가 안 막힌다」로
# 읽히지 「이 러너의 stat 이 다른 철자를 쓴다」로 읽히지 않는다.
if [ -n "$(t_ino "$WORK")" ]; then
  ok "아이노드 계층이 이 러너에서 dev:ino 를 낸다"
else
  bad "아이노드 계층" "이 러너에서 stat 이 어느 철자로도 dev:ino 를 내지 않는다 — 아래 철자 단언들은 어휘 계층만 검증한다"
fi
check "T13 형제 레인의 settings.json 은 거부" "$(hook_decide "$HH/.claude-y/settings.json")" "deny"
check "T14 형제 레인의 settings.local.json 은 거부" "$(hook_decide "$HH/.claude-y/settings.local.json")" "deny"
check "T15 형제 레인의 트랜스크립트는 거부" "$(hook_decide "$HH/.claude-y/projects/abc.jsonl")" "deny"
# 음성 대조군. 이것이 없으면 위 셋의 통과는 「형제 레인을 통째로 거부한다」와
# 구별되지 않고, 통째 거부는 스테이지가 자기 일을 못 하게 만든다.
check "T16 형제 레인의 강제 표면 아닌 경로는 여전히 허용" "$(hook_decide "$HH/.claude-y/todos/t.json")" "allow"
check "자기 레인의 settings.json 은 그대로 거부 (기존 분기 존치)" \
  "$(hook_decide "$HH/.claude-x/settings.json")" "deny"
# 아직 없는 레인 디렉터리를 만들면서 그 안에 쓰는 경로도 막혀야 한다 — 존재를
# 조건으로 걸면 가드가 새 레인에서만 사라지고, 그때가 아무도 안 보는 때다.
mkdir -p "$HH/.claude-z"
check "존재하지 않던 형제 레인도 덮는다" "$(hook_decide "$HH/.claude-z/settings.json")" "deny"
# 그리고 디렉터리조차 만들지 않은 레인. 위 픽스처는 mkdir 을 하므로 훅의 글롭에
# 잡히고, 그래서 「글롭이 내지 못하는 레인」은 위 단언이 덮지 못한다.
check "디렉터리가 아직 없는 형제 레인도 덮는다" \
  "$(hook_decide "$HH/.claude-nonexistent/settings.json")" "deny"

# --- 경로 철자: 같은 파일에 이르는 다른 철자도 같은 판정을 받아야 한다 --------
: > "$HH/.claude-y/settings.json"
check "상위 참조를 담은 철자도 거부" \
  "$(hook_decide "$HH/.claude-y/../.claude-y/settings.json")" "deny"
check "중복 구분자와 현재 디렉터리 참조를 담은 철자도 거부" \
  "$(hook_decide "$HH/.claude-y//./settings.json")" "deny"
# 데이터 볼륨 대체 절대 철자. 이 철자가 실제로 같은 파일로 해소될 때만 의미가
# 있으므로, 해소되지 않으면 건너뛰되 건너뛴 사실을 한 줄로 남긴다 — 세지 않는
# 건너뜀은 커버리지가 사라진 것과 구별되지 않는다.
HHP=$(cd "$HH/.claude-y" 2>/dev/null && pwd -P)
FIRM="/System/Volumes/Data${HHP:-$HH/.claude-y}/settings.json"
# 건너뜀 술어는 `t_ino` 로 판정한다. 한 철자만 쓰면 이 단언 — 훅이 철자가 아니라
# 아이노드로 판정한다는 것을 증명하는 유일한 단언 — 이 그 철자가 통하지 않는
# 플랫폼에서 계층 사망과 함께 조용히 사라진다. 계층 사망은 위에서 따로 보고한다.
if [ -n "$(t_ino "$FIRM")" ] \
   && [ "$(t_ino "$FIRM")" = "$(t_ino "$HH/.claude-y/settings.json")" ]; then
  check "데이터 볼륨 대체 절대 철자도 거부 (철자가 아니라 아이노드로 판정한다)" \
    "$(hook_decide "$FIRM")" "deny"
else
  printf 'NOTE: 데이터 볼륨 대체 철자가 이 경로에 해소되지 않아 건너뛴다 (%s)\n' "$FIRM"
fi
# 심링크 꼬리. 앵커된 분기는 아이노드로 비교하므로 이것도 닫힌다.
ln -sfn "$HH/.claude-y/settings.json" "$WORK/lane-link" 2>/dev/null
if [ -e "$WORK/lane-link" ]; then
  check "심링크를 통한 철자도 거부" "$(hook_decide "$WORK/lane-link")" "deny"
else
  printf 'NOTE: 심링크를 만들지 못해 건너뛴다\n'
fi
# 심링크 디렉터리를 낀 상위 참조. 어휘 정규화는 파일시스템을 읽지 않고 `..` 를
# 접으므로, 커널이 여는 파일과 훅이 재는 파일이 갈릴 수 있다 — 갈리면 판정할
# 근거가 없으므로 거부여야 한다.
mkdir -p "$HH/.claude-y/x"
ln -sfn "$HH/.claude-y/x" "$WORK/lanedir-link" 2>/dev/null
if [ -d "$WORK/lanedir-link" ]; then
  check "심링크 디렉터리를 낀 상위 참조 철자도 거부" \
    "$(hook_decide "$WORK/lanedir-link/../settings.json")" "deny"
else
  printf 'NOTE: 디렉터리 심링크를 만들지 못해 건너뛴다\n'
fi
# 대소문자 변형. 파일시스템이 대소문자를 무시하면 진짜 형제 레인에 착지하고,
# 무시하지 않으면 아직 없는 형제 레인이다 — 어느 쪽이든 거부여야 하므로 이
# 단언은 조건 없이 선다.
check "대소문자를 바꾼 형제 레인 철자도 거부 (실재하는 레인)" \
  "$(hook_decide "$HH/.Claude-y/settings.json")" "deny"
check "대소문자를 바꾼 형제 레인 철자도 거부 (디렉터리가 없는 레인)" \
  "$(hook_decide "$HH/.Claude-zzz/settings.json")" "deny"
# 이 음성 대조군이 없으면 위 둘의 통과가 「대소문자 변형을 통째로 거부한다」와
# 구별되지 않는다.
check "음성 대조군: 대소문자를 바꿔도 강제 표면이 아닌 이름은 허용" \
  "$(hook_decide "$HH/.Claude-y/todos/t.json")" "allow"

# --- 런 디렉터리는 허용 목록이다 --------------------------------------------
# 게이트가 매 행위마다 되읽는 기준선이 스테이지에게 쓰기 가능하면, 강제 표면
# 검사가 자기 자신을 기준으로 다시 잡힌다.
check "런 디렉터리의 구속면 다이제스트는 거부" "$(hook_decide "$RUN_DIR/surface-digest")" "deny"
check "런 디렉터리의 레인 기록은 거부" "$(hook_decide "$RUN_DIR/config-dir")" "deny"
check "런 디렉터리의 원장 경로 기록은 거부" "$(hook_decide "$RUN_DIR/ledger-path")" "deny"
check "런 설정 디렉터리는 그대로 거부 (기존 분기 존치)" "$(hook_decide "$RUN_DIR/settings/x.json")" "deny"
# 그리고 음성 대조군. 이 둘이 막히면 파이프라인 자신이 멈춘다 — 스테이지가
# 중단 기록을 남길 수도, 계획을 방출할 수도 없게 된다.
check "런 디렉터리의 중단 기록은 허용" "$(hook_decide "$RUN_DIR/halt/impl.md")" "allow"
check "런 디렉터리의 계획 파일은 허용" "$(hook_decide "$RUN_DIR/slice-D.plan.md")" "allow"

# 대체 철자는 픽스처 런 디렉터리에서 잰다. 라이브 런 디렉터리 안에는 심링크와
# 하위 디렉터리를 만들 수 없다 — 훅과 게이트가 스테이지의 그 쓰기를 막고, 막지
# 않더라도 라이브 런 상태를 오염시킨다. 위 여섯 단언은 그대로 둔다: 라이브
# 디렉터리에 대한 리터럴 판정이 픽스처와 같은 답을 내는지가 별개의 정보다.
hook_decide_rd() {
  # hook_decide_rd <런 디렉터리> <편집 대상 경로>
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$2" \
    | HOME="$HH" CLAUDE_CONFIG_DIR="$HH/.claude-x" \
      bash "$HOOK" --run-dir "$1" --gate "$script_dir/gate.sh" \
    | jq -r '.hookSpecificOutput.permissionDecision'
}
FRD="$WORK/fixrun"; mkdir -p "$FRD/halt/deep" "$FRD/sub"
: > "$FRD/surface-digest"
ln -sfn "$FRD/surface-digest" "$FRD/x.plan.md" 2>/dev/null
ln -sfn "$FRD" "$WORK/rd-link" 2>/dev/null
# 매달린 심링크: 표적이 실재하지 않는다. 살아 있는 심링크만으로는 말단 판정이
# `-L` 인지 `-e` 인지 갈리지 않는다 — 실재하는 표적을 가리키는 링크는 두 판정
# 모두에서 참이기 때문이다. 표적을 런 설정 디렉터리에 두는 이유는 이 벡터가
# 실제로 열렸을 때 착지하는 곳이 거기이기 때문이다.
ln -sfn "$FRD/settings/absent.json" "$FRD/dangling.plan.md" 2>/dev/null

check "픽스처 런 디렉터리에서도 구속면 다이제스트는 거부" \
  "$(hook_decide_rd "$FRD" "$FRD/surface-digest")" "deny"
check "허용 이름이라도 말단이 심링크면 거부" \
  "$(hook_decide_rd "$FRD" "$FRD/x.plan.md")" "deny"
if [ -L "$FRD/dangling.plan.md" ]; then
  check "허용 이름이라도 말단이 매달린 심링크면 거부" \
    "$(hook_decide_rd "$FRD" "$FRD/dangling.plan.md")" "deny"
else
  printf 'NOTE: 매달린 심링크를 만들지 못해 건너뛴다\n'
fi
check "음성 대조군: 진짜 계획 파일은 허용" \
  "$(hook_decide_rd "$FRD" "$FRD/slice-D.plan.md")" "allow"
check "중단 기록의 깊이는 한 단계뿐" \
  "$(hook_decide_rd "$FRD" "$FRD/halt/deep/nested.md")" "deny"
check "음성 대조군: 한 단계 중단 기록은 그대로 허용" \
  "$(hook_decide_rd "$FRD" "$FRD/halt/impl.md")" "allow"
check "런 매니페스트 plan.md 는 계획 파일이 아니다" \
  "$(hook_decide_rd "$FRD" "$FRD/plan.md")" "deny"
check "하위 디렉터리의 계획 파일은 거부" \
  "$(hook_decide_rd "$FRD" "$FRD/sub/x.plan.md")" "deny"
check "상위 참조를 낀 런 디렉터리 철자도 거부" \
  "$(hook_decide_rd "$FRD" "$FRD/../fixrun/surface-digest")" "deny"
if [ -d "$WORK/rd-link" ]; then
  check "런 디렉터리로의 심링크를 통한 철자도 거부" \
    "$(hook_decide_rd "$FRD" "$WORK/rd-link/surface-digest")" "deny"
else
  printf 'NOTE: 런 디렉터리 심링크를 만들지 못해 건너뛴다\n'
fi

# 조상 앵커. 런 설정 디렉터리는 런 디렉터리 안에서 아이노드 앵커가 없는 유일한
# 게이트 소유 디렉터리였고, 그래서 중간 성분이 그리로 해소되면 꼬리가 허용
# 이름으로 나와 허용 팔이 답했다 — 같은 파일의 직접 철자는 거부되므로 허용
# 목록 자신의 거부 팔이 철자만으로 우회됐다. 앵커를 지우면 이 둘만 붉어진다.
ARD="$WORK/ancrun"; mkdir -p "$ARD/settings"
: > "$ARD/settings/keep.json"
ln -sfn "$ARD/settings" "$ARD/halt" 2>/dev/null
if [ -L "$ARD/halt" ] && [ -d "$ARD/halt" ]; then
  check "중간 성분이 런 설정 디렉터리로 해소되는 철자는 거부" \
    "$(hook_decide_rd "$ARD" "$ARD/halt/evil.json")" "deny"
  # 새 파일과 기존 파일을 갈라 잰다. 착지가 아니라 덮어쓰기가 이 벡터의 해악이다.
  check "그 철자가 설정 디렉터리의 기존 파일을 겨눠도 거부" \
    "$(hook_decide_rd "$ARD" "$ARD/halt/keep.json")" "deny"
else
  printf 'NOTE: 런 설정 디렉터리로의 심링크를 만들지 못해 건너뛴다\n'
fi
# 음성 대조군. 이것이 없으면 위 둘의 통과가 「halt 아래를 통째로 거부한다」와
# 구별되지 않고, 통째 거부는 스테이지가 중단 기록을 남기지 못하게 만든다.
NRD="$WORK/ancrun-neg"; mkdir -p "$NRD/settings" "$NRD/halt"
check "음성 대조군: 진짜 halt 디렉터리 아래 중단 기록은 그대로 허용" \
  "$(hook_decide_rd "$NRD" "$NRD/halt/impl.md")" "allow"
check "음성 대조군: 설정 디렉터리가 있어도 직접 철자의 거부 문면은 그대로" \
  "$(hook_decide_rd "$NRD" "$NRD/settings/x.json")" "deny"

# --- 그 허용 목록은 **이** 런 하나로만 파라미터화돼 있었다 -------------------
# 위 단언들은 전부 편집 대상이 자기 런 디렉터리 아래일 때의 판정이다. 한 디렉터리
# 건너 — 다른 런의 디렉터리 — 는 어느 팔에도 걸리지 않고 마지막 허용에 떨어졌다.
# 거기 있는 것은 부수적인 파일이 아니다: `<런>/settings/<종류>.json` 은 그 런
# 스테이지의 훅·권한 설정 자체이고, `<런>/config-dir` 은 그 런의 모든 디스패치가
# 계정을 해소하는 레인 기록이다. 링크도 셸 라이더도 없는 평문 절대 경로 한 번이면
# 둘 다 닿고, 훅의 Write/Edit 절반에는 원장 요구가 없어 행도 남지 않는다.
RR="$WORK/runroot"
mkdir -p "$RR/cc-cmds/run/mine/halt" "$RR/cc-cmds/run/mine/settings" \
         "$RR/cc-cmds/run/victim/settings" "$RR/cc-cmds/run/victim/halt"
MYRUN="$RR/cc-cmds/run/mine"
hook_decide_rr() {
  # hook_decide_rr <편집 대상 경로> — 런 루트 아래 런이 둘인 픽스처. 스테이지는
  # `mine` 에서 돌고 `victim` 은 형제다. `XDG_STATE_HOME` 을 주는 이유는 훅이
  # 드라이버와 **같은 방식으로** 런 루트를 유도하기 때문이다 — 다른 방식으로
  # 유도하면 이 픽스처가 재는 것은 훅이 아니라 이 하네스 자신이 된다.
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" \
    | XDG_STATE_HOME="$RR" HOME="$HH" CLAUDE_CONFIG_DIR="$HH/.claude-x" \
      bash "$HOOK" --run-dir "$MYRUN" --gate "$script_dir/gate.sh" \
    | jq -r '.hookSpecificOutput.permissionDecision'
}
hook_reason_rr() {
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" \
    | XDG_STATE_HOME="$RR" HOME="$HH" CLAUDE_CONFIG_DIR="$HH/.claude-x" \
      bash "$HOOK" --run-dir "$MYRUN" --gate "$script_dir/gate.sh" \
    | jq -r '.hookSpecificOutput.permissionDecisionReason'
}
check "형제 런의 레인 기록은 거부" \
  "$(hook_decide_rr "$RR/cc-cmds/run/victim/config-dir")" "deny"
check "형제 런의 오케스트레이터 기록은 거부" \
  "$(hook_decide_rr "$RR/cc-cmds/run/victim/orchestrator-dir")" "deny"
check "형제 런의 스테이지 설정 파일은 거부 (그 런의 훅·권한 그 자체다)" \
  "$(hook_decide_rr "$RR/cc-cmds/run/victim/settings/impl.json")" "deny"
# 이 런의 허용 이름이라도 다른 런의 것이면 거부다. 허용 목록은 이름이 아니라
# 「이 런의 그 이름」이므로, 이름만 맞춘 형제 런 경로가 통과하면 위 셋의 통과가
# 「이름으로 거부한다」와 구별되지 않는다.
check "형제 런의 중단 기록도 거부 (허용 이름은 이 런의 것일 때만이다)" \
  "$(hook_decide_rr "$RR/cc-cmds/run/victim/halt/impl.md")" "deny"
check "형제 런의 계획 파일도 거부" \
  "$(hook_decide_rr "$RR/cc-cmds/run/victim/x.plan.md")" "deny"
# 아직 열리지 않은 런. 글롭도 아이노드도 없는 자리이고, 그 창이야말로 이 결정이
# 덮겠다고 선언한 것이다 — 열리지 않은 런에 기록을 심어 두면 그 런의 초기화가
# 그것을 보존한 채 시작한다.
check "아직 만들어지지 않은 런의 디렉터리도 거부" \
  "$(hook_decide_rr "$RR/cc-cmds/run/20260101-deadbeef/config-dir")" "deny"
# 음성 대조군 셋. 이것들이 없으면 위 여섯의 통과가 「런 루트 아래를 통째로
# 거부한다」와 구별되지 않고, 통째 거부는 스테이지가 중단 기록도 계획도 남기지
# 못하게 만들어 파이프라인 자신을 멈춘다.
check "음성 대조군: 자기 런의 중단 기록은 그대로 허용" \
  "$(hook_decide_rr "$MYRUN/halt/impl.md")" "allow"
check "음성 대조군: 자기 런의 계획 파일은 그대로 허용" \
  "$(hook_decide_rr "$MYRUN/slice-D.plan.md")" "allow"
check "음성 대조군: 런 루트 밖의 평범한 경로는 그대로 허용" \
  "$(hook_decide_rr "$WORK/runroot-outside.txt")" "allow"
# 자기 런의 기준선은 종전 문면으로 거부돼야 한다. 두 팔이 같은 문면을 내면 새 팔이
# 옛 팔을 삼켰는지 알 수 없다.
check "자기 런의 레인 기록은 그대로 거부" \
  "$(hook_decide_rr "$MYRUN/config-dir")" "deny"
case "$(hook_reason_rr "$RR/cc-cmds/run/victim/config-dir")" in
  *'다른 런의 디렉터리'*) ok "형제 런 거부가 다른 런을 지목한다" ;;
  *) bad "형제 런 거부 사유" "다른 팔이 먼저 거부했다 — 위 단언들이 공허하다" ;;
esac
case "$(hook_reason_rr "$MYRUN/config-dir")" in
  *'다른 런의 디렉터리'*) bad "자기 런 거부 사유" "새 팔이 자기 런까지 삼켰다 — 순서가 뒤집혔다" ;;
  *) ok "자기 런 거부는 종전 팔이 낸다 (새 팔이 앞으로 오지 않았다)" ;;
esac

# --- 그리고 그 앵커는 심링크 **조상**으로 통째로 우회됐다 --------------------
# 위 열두 단언은 전부 직접 철자이고 이 절에 `ln -s` 가 한 줄도 없었다. 아이노드 팔은
# 조상 성분을 아이노드로 비교하되 사슬을 거슬러 오르는 것은 **어휘적**이라, 앵커된
# 디렉터리를 *가리키는* 링크는 잡히고 그 **안쪽**을 가리키는 링크는 잡히지 않는다 —
# `$RUN_DIR` 은 보호 대상이 바로 안에 있는 말단 앵커지만 런 루트는 한 단계 더 깊은
# 비말단 앵커라, 그 한 단계를 링크로 건너뛰면 앵커가 사슬에 아예 등장하지 않는다.
# 실제 `Write` 도구가 그 링크를 관통해 피해 런 안에 파일을 만드는 것까지 확인된
# 벡터이고, 착지하는 것은 그 런의 훅·권한 설정과 레인 기록이다.
ln -sfn "$RR/cc-cmds/run/victim" "$WORK/L-victim" 2>/dev/null
ln -sfn "$MYRUN"                 "$WORK/L-self"   2>/dev/null
ln -sfn "$RR/cc-cmds/run"        "$WORK/L-root"   2>/dev/null
if [ -L "$WORK/L-victim" ] && [ -d "$WORK/L-victim" ]; then
  check "형제 런을 가리키는 심링크 조상을 통한 철자도 거부" \
    "$(hook_decide_rr "$WORK/L-victim/config-dir")" "deny"
  check "그 심링크를 통한 스테이지 설정 파일도 거부 (그 런의 훅·권한 그 자체다)" \
    "$(hook_decide_rr "$WORK/L-victim/settings/impl.json")" "deny"
  check "그 심링크를 통한 오케스트레이터 기록도 거부" \
    "$(hook_decide_rr "$WORK/L-victim/orchestrator-dir")" "deny"
  check "런 루트를 가리키는 심링크를 통한 철자도 거부" \
    "$(hook_decide_rr "$WORK/L-root/victim/config-dir")" "deny"
  # `deny` 만 재면 어느 팔이 답했는지 모른다. 사이클 2 가 실측으로 확정한 것이
  # 정확히 이것이다 — 한쪽 팔은 `deny` 단언으로 잡히지 않고 사유 문면 단언만이 잡는다.
  case "$(hook_reason_rr "$WORK/L-victim/config-dir")" in
    *'다른 런의 디렉터리'*) ok "심링크 조상 거부가 형제 런 팔의 것이다" ;;
    *) bad "심링크 조상 거부 사유" "다른 팔이 먼저 거부했다 — 이 단언들이 공허하다" ;;
  esac
  # 음성 대조군 넷. 없으면 위 넷의 통과가 「런 루트 밖 링크를 통째로 거부한다」와
  # 구별되지 않고, 통째 거부는 파이프라인 자신이 쓰는 경로를 함께 막는다.
  check "음성 대조군: 자기 런을 가리키는 심링크 조상의 중단 기록은 그대로 허용" \
    "$(hook_decide_rr "$WORK/L-self/halt/impl.md")" "allow"
  check "음성 대조군: 자기 런을 가리키는 심링크 조상의 계획 파일도 그대로 허용" \
    "$(hook_decide_rr "$WORK/L-self/slice-D.plan.md")" "allow"
  check "음성 대조군: 자기 런을 가리키는 심링크의 기준선은 그대로 거부" \
    "$(hook_decide_rr "$WORK/L-self/config-dir")" "deny"
  case "$(hook_reason_rr "$WORK/L-self/config-dir")" in
    *'다른 런의 디렉터리'*) bad "자기 런 심링크 거부 사유" "새 팔이 자기 런까지 삼켰다" ;;
    *) ok "자기 런 심링크 거부는 종전 팔이 낸다" ;;
  esac
else
  printf 'NOTE: 형제 런 심링크 픽스처를 만들지 못해 건너뛴다\n'
fi
# 물리화가 「부모가 실재할 때만 판정한다」로 퇴화하면 이것이 함께 막힌다. 아직
# 만들어지지 않은 디렉터리 아래로 쓰는 것은 이 트리 어디서나 정당하다.
check "음성 대조군: 아직 없는 디렉터리 아래의 평범한 쓰기는 그대로 허용" \
  "$(hook_decide_rr "$WORK/no-such-dir-yet/deep/new.txt")" "allow"

# --- 그리고 **말단** 링크로도 통째로 우회됐다 (한 뿌리의 둘째 기전) ----------
# 위 절이 닫은 것은 조상 링크가 앵커의 **안쪽**을 가리키는 경우다. 같은 뿌리
# (`hook_under` 가 조상 성분을 아이노드로 비교하되 사슬은 어휘적으로 오른다)에서
# 나오는 둘째 기전은 **말단** 링크가 앵커 안의 **파일**을 가리키는 것이고, 조상
# 물리화는 실재하는 가장 깊은 **디렉터리**에서만 접으므로 파일 말단은 어휘 꼬리로
# 남아 그것을 닫지 못했다.
#
# 실측된 규칙이 깔끔했다 — **파일 앵커가 있는 자리는 닫히고 디렉터리 앵커만 있는
# 자리는 열리며, 런 디렉터리에는 파일 앵커가 하나도 없었다.** 아래 일곱 행이 그
# 표 자신이다. 여섯은 `allow` 였고, 파일 앵커가 함께 있던 일곱째만 `deny` 였다.
# 그리고 `allow` 뒤의 쓰기가 실제로 링크를 관통해 피해 런의 `config-dir` 을 바꿨다.
#
# 왜 눈에 띄지 않았는지도 이 표가 설명한다 — **매달린** 말단은 이미 `deny` 였다.
# 더 어려운 경우가 닫히고 더 쉬운 경우가 열린 역전이라, 스위트의 초록이 이 부류를
# 재고 있다는 착시를 만들었다. 그 매달린 팔은 되돌리지 않으며 위쪽에 그대로 있다.
mkdir -p "$RR/cc-cmds/run/victim/settings" "$HH/.claude-x/projects/p" \
         "$HH/.claude-y/projects" "$HH/.config/cc-cmds/lanes"
: > "$RR/cc-cmds/run/victim/config-dir"
: > "$RR/cc-cmds/run/victim/settings/impl.json"
: > "$MYRUN/config-dir"
: > "$HH/.claude-x/projects/p/a.jsonl"
: > "$HH/.claude-y/projects/a.jsonl"
: > "$HH/.config/cc-cmds/lanes/x.json"
: > "$HH/.claude-x/settings.json"
leaf_n=0
leaf_row() {
  # leaf_row <단언 이름> <표적의 직접 철자> <기대 거부 문면 조각>
  #
  # 표적을 가리키는 말단 링크를 앵커 **밖**($WORK)에 만들어 두 철자를 함께 잰다 —
  # 직접 철자와 링크 철자가 **같은 문면으로** 거부돼야 한다. 판정만 재면 두 팔이
  # 갈린 것을 못 보고, 문면까지 재면 1차·2차 패스의 앵커 목록이 발산하는 순간
  # 붉어진다. 나란한 두 목록 중 한쪽만 고쳐도 초록인 실패 방식이 이 파일이 이미
  # 여러 자리에 적어 둔 것이다.
  leaf_n=$((leaf_n + 1))
  local nm="$1" tgt="$2" frag="$3" lnk="$WORK/LEAF-$leaf_n"
  ln -sfn "$tgt" "$lnk" 2>/dev/null
  if [ ! -L "$lnk" ] || [ ! -e "$lnk" ]; then
    bad "말단 링크 픽스처: $nm" "링크를 만들지 못했거나 표적이 실재하지 않는다: $tgt"
    return
  fi
  check "말단 링크: $nm 은 거부" "$(hook_decide_rr "$lnk")" "deny"
  case "$(hook_reason_rr "$lnk")" in
    *"$frag"*) ok "말단 링크: $nm 의 거부 문면이 그 자리의 것이다" ;;
    *) bad "말단 링크 거부 사유: $nm" "다른 팔이 먼저 거부했다 — 이 단언이 공허하다: $(hook_reason_rr "$lnk")" ;;
  esac
  check "직접 철자: $nm 도 같은 판정" "$(hook_decide_rr "$tgt")" "deny"
  case "$(hook_reason_rr "$tgt")" in
    *"$frag"*) ok "직접 철자: $nm 의 거부 문면이 링크 철자의 것과 같다" ;;
    *) bad "두 철자 발산: $nm" "직접 철자와 링크 철자가 다른 팔에 답해진다 — 앵커 목록이 갈렸다" ;;
  esac
}
leaf_row "형제 런의 레인 기록"        "$RR/cc-cmds/run/victim/config-dir"        '다른 런의 디렉터리'
leaf_row "형제 런의 스테이지 설정"    "$RR/cc-cmds/run/victim/settings/impl.json" '다른 런의 디렉터리'
leaf_row "자기 런의 레인 기록"        "$MYRUN/config-dir"                        '런 디렉터리에서 스테이지가 쓰도록 선언된 것은'
leaf_row "자기 레인의 트랜스크립트"   "$HH/.claude-x/projects/p/a.jsonl"         '세션 트랜스크립트는 승인 판독 채널'
leaf_row "형제 레인의 트랜스크립트"   "$HH/.claude-y/projects/a.jsonl"           '형제 레인의 세션 트랜스크립트'
leaf_row "운영자 스코프의 레인 기록"  "$HH/.config/cc-cmds/lanes/x.json"         '운영자 스코프 설정 디렉터리'
# 일곱째. 이것만 종전에도 `deny` 였고 — 그 자리에 파일 앵커가 있었기 때문이다 —
# 이번 변경 뒤에도 **같은 문면**이어야 한다. 2차 패스를 1차 **뒤**에 두는 것이
# 그것을 보장하고, 앞에 두면 이 행의 사유 단언이 함께 붉어진다.
leaf_row "사용자 스코프 설정"         "$HH/.claude-x/settings.json"              '사용자 스코프 설정은 훅 설치 채널'
# 자기 런 거부가 형제 런 팔에 삼켜지지 않았는지. `$RUN_DIR` 이 런 루트 아래라
# 순서가 뒤집히면 이 런의 허용 이름까지 형제 런 문면으로 거부된다.
case "$(hook_reason_rr "$WORK/LEAF-3")" in
  *'다른 런의 디렉터리'*) bad "말단 링크 순서" "자기 런의 말단 링크가 형제 런 문면으로 거부됐다 — 2차 패스의 순서가 뒤집혔다" ;;
  *) ok "말단 링크: 자기 런 거부가 형제 런 팔에 삼켜지지 않는다" ;;
esac

# 거짓 양성 대조군. 이것들이 없으면 위 일곱의 통과가 「말단이 심링크면 통째로
# 거부한다」와 구별되지 않고, 통째 거부는 이 런의 스테이지가 아무것도 못 하게
# 만든다 — 파이프라인 자신이 멈춘다.
: > "$WORK/leaf-plain.txt"
ln -sfn "$WORK/leaf-plain.txt" "$WORK/LEAF-ok-plain" 2>/dev/null
check "음성 대조군: 앵커 어디에도 닿지 않는 표적을 가리키는 말단 링크는 허용" \
  "$(hook_decide_rr "$WORK/LEAF-ok-plain")" "allow"
ln -sfn "$HH/.claude-y/todos/t.json" "$WORK/LEAF-ok-lane" 2>/dev/null
mkdir -p "$HH/.claude-y/todos"; : > "$HH/.claude-y/todos/t.json"
check "음성 대조군: 레인 안이라도 강제 표면이 아닌 파일을 가리키는 말단 링크는 허용" \
  "$(hook_decide_rr "$WORK/LEAF-ok-lane")" "allow"
ln -sfn "$MYRUN" "$WORK/LEAF-ok-selfdir" 2>/dev/null
check "음성 대조군: 자기 런 디렉터리 자신을 가리키는 말단 링크는 허용" \
  "$(hook_decide_rr "$WORK/LEAF-ok-selfdir")" "allow"
# 이 둘은 말단이 심링크가 **아니므로** 2차 패스가 아예 돌지 않아야 한다. 돌기
# 시작하면 스테이지가 중단 기록도 계획도 남기지 못한다.
check "음성 대조군: 자기 런의 중단 기록은 말단 패스 뒤에도 그대로 허용" \
  "$(hook_decide_rr "$MYRUN/halt/impl.md")" "allow"
check "음성 대조군: 자기 런의 계획 파일도 말단 패스 뒤에도 그대로 허용" \
  "$(hook_decide_rr "$MYRUN/slice-D.plan.md")" "allow"
# 그리고 아직 만들어지지 않은 말단. `[ -e ]` 를 조건으로 걸지 않으면 이것이 함께
# 막히고, 아직 없는 디렉터리 아래로 쓰는 것은 이 트리 어디서나 정당하다.
check "음성 대조군: 아직 없는 말단은 말단 패스에 들어가지 않는다" \
  "$(hook_decide_rr "$WORK/leaf-not-yet/deep/new.txt")" "allow"
# 순환 링크는 판정 불가이고, 판정 불가는 허용이 아니다.
ln -sfn "$WORK/LEAF-loop-b" "$WORK/LEAF-loop-a" 2>/dev/null
ln -sfn "$WORK/LEAF-loop-a" "$WORK/LEAF-loop-b" 2>/dev/null
if [ -L "$WORK/LEAF-loop-a" ]; then
  check "순환 말단 링크는 거부 (매달린 팔이 답한다 — 판정 불가는 허용이 아니다)" \
    "$(hook_decide_rr "$WORK/LEAF-loop-a")" "deny"
else
  printf 'NOTE: 순환 링크를 만들지 못해 건너뛴다\n'
fi

# --- Bash 허용 목록은 첫 토큰 뒤도 본다 -------------------------------------
# 첫 토큰 규칙 아래에서 `|`·`;`·`&&`·`&`·개행·`$( )` 는 서로 구별되지 않으므로,
# 하나를 축복하는 것이 전부를 축복하는 것이었다. `<게이트> … ; <임의 명령>` 이
# 통째로 허용됐고 두 절반이 한 셸에서 실행됐으며, 오른쪽 절반은 원장에 행을
# 남기지 않았다 — 이 훅이 보장한다고 적은 유일한 성질이 그 명령들에 대해 거짓이었다.
GATEP="$script_dir/gate.sh"
hook_decide_bash() {
  # hook_decide_bash <명령 문자열> — 명령을 `jq -Rs` 로 인코딩해서 넘긴다.
  # 손으로 이스케이프하면 개행·따옴표 픽스처가 바로 그 이스케이프 버그를 재게 된다.
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(printf '%s' "$1" | jq -Rs .)" \
    | HOME="$HH" CLAUDE_CONFIG_DIR="$HH/.claude-x" \
      bash "$HOOK" --run-dir "$RUN_DIR" --gate "$GATEP" \
    | jq -r '.hookSpecificOutput.permissionDecision'
}
BNL='
'
check "맨 게이트 호출은 허용" "$(hook_decide_bash "$GATEP snapshot --manifest m")" "allow"
# 특례는 하나뿐이고 꼬리에서만 성립한다. 거부 문면이 처방하는 1번 명령이 이
# 파이프를 쓰므로, 전면 거부하면 허용 목록이 자기 처방을 다시 거부한다.
check "특례 파이프 '| jq -r .H' 는 허용" \
  "$(hook_decide_bash "$GATEP snapshot --manifest m | jq -r .H")" "allow"
check "특례 파이프의 후행 공백도 허용" \
  "$(hook_decide_bash "$GATEP snapshot --manifest m | jq -r .H  ")" "allow"
check "세미콜론 체인은 거부" "$(hook_decide_bash "$GATEP snapshot; touch $WORK/rider")" "deny"
check "AND 체인은 거부" "$(hook_decide_bash "$GATEP snapshot && touch $WORK/rider")" "deny"
check "백그라운드+체인은 거부" "$(hook_decide_bash "$GATEP snapshot & touch $WORK/rider")" "deny"
check "개행 체인은 거부" "$(hook_decide_bash "$GATEP snapshot${BNL}touch $WORK/rider")" "deny"
check "명령 치환 인자는 거부" "$(hook_decide_bash "$GATEP exec --rationale \$(whoami) -- ls")" "deny"
check "백틱 인자는 거부" "$(hook_decide_bash "$GATEP exec --rationale \`whoami\` -- ls")" "deny"
check "특례가 아닌 파이프는 거부" "$(hook_decide_bash "$GATEP snapshot | grep x")" "deny"
check "리다이렉션도 거부 (원장 없이 셸이 파일을 여는 자리다)" \
  "$(hook_decide_bash "$GATEP snapshot > $WORK/rider")" "deny"
check "특례 뒤에 이어 붙인 체인은 거부 (특례는 꼬리에서 한 번뿐이다)" \
  "$(hook_decide_bash "$GATEP snapshot | jq -r .H; touch $WORK/rider")" "deny"
# 인용된 제어 문자는 게이트의 정당한 인자다. 이 둘이 없으면 위 거부들의 통과가
# 「세미콜론을 통째로 거부한다」와 구별되지 않고, 통째 거부는 이 훅이 처방하는
# `--rationale` 을 스테이지가 쓸 수 없게 만든다.
check "음성 대조군: 큰따옴표 안의 세미콜론은 허용" \
  "$(hook_decide_bash "$GATEP exec --rationale \"왜; 이 명령이 필요한가\" -- ls")" "allow"
check "음성 대조군: 홑따옴표 안의 세미콜론은 허용" \
  "$(hook_decide_bash "$GATEP exec --rationale '가;나' -- ls")" "allow"
check "음성 대조군: 인용해서 게이트에 넘긴 파이프라인은 허용" \
  "$(hook_decide_bash "$GATEP exec --rationale r -- bash -c 'a | b'")" "allow"
# 종전 거부들이 그대로인지. 새 검사가 앞에 서면서 이 셋의 사유가 바뀌면 안 된다.
check "평문 명령은 그대로 거부" "$(hook_decide_bash "ls -la")" "deny"
check "선행 환경변수 할당은 그대로 거부" "$(hook_decide_bash "FOO=1 $GATEP snapshot")" "deny"
check "bash -c 는 그대로 거부" "$(hook_decide_bash "bash -c '$GATEP snapshot'")" "deny"
# 그리고 그 거부가 새 검사의 것인지 확인한다. 종전의 「게이트 호출이 아님」 팔이
# 먼저 답하면 위 체인 단언들은 통과하면서 아무것도 검증하지 않는다.
case "$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
          "$(printf '%s' "$GATEP snapshot; touch $WORK/rider" | jq -Rs .)" \
        | HOME="$HH" bash "$HOOK" --run-dir "$RUN_DIR" --gate "$GATEP" \
        | jq -r '.hookSpecificOutput.permissionDecisionReason')" in
  *'인용되지 않은 셸 제어 연산자'*) ok "체인 거부가 새 검사의 것이다" ;;
  *) bad "체인 거부 사유" "다른 팔이 먼저 거부했다 — 위 체인 단언들이 공허하다" ;;
esac

# --- 그 인용 상태 기계는 ANSI-C 인용을 몰랐다 -------------------------------
# 위 열여덟 단언은 거부 기대가 전부 인용 없는 평문 연산자이고 허용 기대가 전부 짝이
# 맞는 평범한 인용이다. bash 에서 `$'…'` 안의 `\'` 는 이스케이프된 작은따옴표라
# `$'\''` 가 한 단어로 닫히는데, 세 상태 스캐너는 상태 `s` 에서 백슬래시를 무시하므로
# 그 `'` 가 인용을 닫고 이어지는 `'` 가 다시 연다 — 스캐너가 문자열 끝까지 인용 안에
# 갇히고 그 뒤 연산자가 전부 보이지 않는다. 여섯 글자로 열린 형태가 실측 13종이고,
# 세미콜론·AND·파이프·개행 체인만이 아니라 리다이렉션·명령 치환·임의 인터프리터까지
# 같은 여섯 글자로 열렸다.
#
# **술어는 홀짝이 아니다.** `$'a\'b\'c'` 는 `\'` 가 짝수인데도 우회한다 — 두 `\'` 가
# 각각 상태 `s` 와 `u` 에서 소비되어 상쇄되지 않기 때문이다. 픽스처를 홀짝으로 세우면
# 이 부류를 통째로 놓치므로, 조건은 「`$'…'` 안에 `\'` 가 하나라도 있으면」이다.
# 중첩 인용이 깨지기 쉬운 자리라 변수로 한 단계 뺀다.
ANSIQ=$(printf '%s' "\$'\\''")
ANSIQ3=$(printf '%s' "\$'a\\'b\\'c'")
ANSIQ2=$(printf '%s' "\$'ab'")
check "ANSI-C 인용을 낀 세미콜론 체인은 거부" \
  "$(hook_decide_bash "$GATEP snapshot $ANSIQ ; touch $WORK/rider")" "deny"
check "백슬래시-쿼트가 짝수여도 거부 (홀짝이 아니라 존재가 술어다)" \
  "$(hook_decide_bash "$GATEP snapshot $ANSIQ3 ; touch $WORK/rider")" "deny"
check "ANSI-C 인용을 낀 리다이렉션도 거부" \
  "$(hook_decide_bash "$GATEP snapshot $ANSIQ > $WORK/rider")" "deny"
check "ANSI-C 인용을 낀 명령 치환도 거부" \
  "$(hook_decide_bash "$GATEP snapshot $ANSIQ \$(touch $WORK/rider)")" "deny"
check "ANSI-C 인용을 낀 임의 인터프리터도 거부" \
  "$(hook_decide_bash "$GATEP snapshot $ANSIQ | sh -c 'touch $WORK/rider'")" "deny"
check "인자 자리의 ANSI-C 인용도 거부" \
  "$(hook_decide_bash "$GATEP exec --rationale $ANSIQ ; touch $WORK/rider")" "deny"
# 원천 차단은 상태 `u` 에서 `$` 다음의 `'` 를 무조건 막으므로 **짝이 맞는** ANSI-C
# 인용 하나도 거부다. 리뷰가 제안한 기대값은 `allow` 였는데 그것은 그물만 넣었을 때의
# 값이고, 여기서는 원천 차단을 함께 넣기로 했으므로 픽스처를 선택한 수정안에 맞춘다.
# 정당 행위를 막지 않는다는 근거는 아래 대조군들과, 이 파이프라인이 실제로 발행하는
# 게이트 명령에 `$'`·`$"` 가 0회라는 실측이 진다.
check "짝이 맞는 ANSI-C 인용 하나도 원천 차단으로 거부" \
  "$(hook_decide_bash "$GATEP exec --rationale $ANSIQ2 -- ls")" "deny"
# 그물 단독의 하중. 이 둘에는 `$'` 가 없어 원천 차단이 서지 않고, 오직 종단 상태가
# `u` 가 아니라는 것만으로 거부된다 — 그물을 빼면 이 둘만 붉어진다. 잃는 것은 없다:
# 미종료 인용은 bash 가 문법 오류로 거절하므로 실행 가능한 명령이 아니다.
check "닫히지 않은 홑따옴표는 종단 상태 그물이 거부한다" \
  "$(hook_decide_bash "$GATEP snapshot 'abc ; touch $WORK/rider")" "deny"
check "닫히지 않은 큰따옴표도 종단 상태 그물이 거부한다" \
  "$(hook_decide_bash "$GATEP snapshot \"abc ; touch $WORK/rider")" "deny"
# 그물의 음성 대조군. `'…'\''…'` 이어붙임은 종단 상태가 `u` 라 그대로 허용돼야 한다 —
# 그물이 「따옴표가 하나라도 있으면 거부」로 퇴화하면 이것이 붉어진다.
check "음성 대조군: 홑따옴표 이어붙임은 그대로 허용" \
  "$(hook_decide_bash "$GATEP exec --rationale 'a'\\''b' -- ls")" "allow"
# 그리고 그 거부가 어느 팔의 것인지 가른다. 종전 팔이 먼저 답하면 위 단언들이 전부
# 공허하다.
case "$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
          "$(printf '%s' "$GATEP snapshot $ANSIQ ; touch $WORK/rider" | jq -Rs .)" \
        | HOME="$HH" bash "$HOOK" --run-dir "$RUN_DIR" --gate "$GATEP" \
        | jq -r '.hookSpecificOutput.permissionDecisionReason')" in
  *'인용되지 않은 셸 제어 연산자'*) ok "ANSI-C 라이더 거부가 새 검사의 것이다" ;;
  *) bad "ANSI-C 라이더 거부 사유" "다른 팔이 먼저 거부했다 — 위 단언들이 공허하다" ;;
esac

# 새 fail-closed 분기의 도달 가능성. 이 러너에서는 stat 이 정상이라 자연히
# 도달하지 않으므로, 항상 실패하는 stat 을 PATH 앞에 심는다 — 훅이 자기 PATH 를
# 앞에 붙이는 것을 끄지 않으면 진짜 stat 이 먼저 잡혀 이 픽스처가 무력해진다.
# 대상 경로는 평소 허용되는 이름이라, 거부가 나온다면 그것은 이 분기의 것이다.
mkdir -p "$WORK/stubbin"
printf '#!/bin/sh\nexit 1\n' > "$WORK/stubbin/stat"
chmod +x "$WORK/stubbin/stat"
stat_probe_out=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$HH/.claude-y/todos/t.json" \
  | CC_CMDS_GATE_PATH_DISABLE_PREPEND=1 PATH="$WORK/stubbin:$PATH" HOME="$HH" \
    CLAUDE_CONFIG_DIR="$HH/.claude-x" bash "$HOOK" --run-dir "$RUN_DIR" --gate "$script_dir/gate.sh")
check "stat 이 dev:ino 를 내지 못하면 판정하지 않고 거부한다" \
  "$(printf '%s' "$stat_probe_out" | jq -r '.hookSpecificOutput.permissionDecision')" "deny"
# 그리고 그 거부가 이 분기의 것인지 확인한다. 다른 분기가 먼저 거부하면 위
# 단언은 통과하면서 아무것도 검증하지 않는다.
case "$(printf '%s' "$stat_probe_out" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in
  *'디바이스:아이노드'*) ok "그 거부가 stat 철자 확정 실패를 지목한다" ;;
  *) bad "stat 부재 거부 사유" "다른 분기가 먼저 거부했다 — 위 단언이 공허하다" ;;
esac

# --- 운영자 스코프 설정 디렉터리 --------------------------------------------
hook_decide_xdg() {
  # hook_decide_xdg <XDG_CONFIG_HOME> <편집 대상 경로>
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$2" \
    | HOME="$HH" CLAUDE_CONFIG_DIR="$HH/.claude-x" XDG_CONFIG_HOME="$1" \
      bash "$HOOK" --run-dir "$RUN_DIR" --gate "$script_dir/gate.sh" \
    | jq -r '.hookSpecificOutput.permissionDecision'
}
mkdir -p "$HH/xdg/cc-cmds" "$HH/xdg/other"
check "운영자 스코프의 레인 기록은 거부 (런보다 오래 사는 편집이다)" \
  "$(hook_decide_xdg "$HH/xdg" "$HH/xdg/cc-cmds/config-dir")" "deny"
check "아직 없는 이웃 파일도 같은 디렉터리라 거부" \
  "$(hook_decide_xdg "$HH/xdg" "$HH/xdg/cc-cmds/무엇이든")" "deny"
check "음성 대조군: 그 옆 디렉터리는 여전히 허용" \
  "$(hook_decide_xdg "$HH/xdg" "$HH/xdg/other/f.json")" "allow"
# 환경변수가 없을 때의 기본 자리. 하네스 자신의 XDG_CONFIG_HOME 이 새어 들어오면
# 훅이 다른 디렉터리를 보게 되므로 여기서만 명시적으로 지운다.
check "XDG 가 없으면 홈 아래 기본 자리를 본다" \
  "$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$HH/.config/cc-cmds/config-dir" \
     | env -u XDG_CONFIG_HOME HOME="$HH" CLAUDE_CONFIG_DIR="$HH/.claude-x" \
       bash "$HOOK" --run-dir "$RUN_DIR" --gate "$script_dir/gate.sh" \
     | jq -r '.hookSpecificOutput.permissionDecision')" "deny"

# --- 매달린 말단 심링크: 아이노드 계층이 통째로 죽는 자리 --------------------
# 말단이 심링크이고 표적이 실재하지 않으면 BSD 의 `stat -L` 은 lstat 판독으로
# 떨어져 링크 자신의 값을 rc=0 으로 내고 GNU 는 줄을 내지 않는다 — 어느 쪽이든
# 파일 앵커가 전부 죽는다. 링크가 레인 밖에 앉으면 조상 사슬이 겹치지 않아
# 디렉터리 앵커도 걸리지 않고, 철자는 링크 자신의 것이라 어휘 팔도 걸리지 않는다.
# 그 상태로 허용하면 커널이 링크를 따라가 강제 표면 안에 파일을 만든다. 아래 표적
# 넷은 그렇게 열려 있던 표면 그대로다.
DL="$WORK/dangling"; mkdir -p "$DL"
ln -sfn "$HH/.claude-y/settings.local.json"     "$DL/sib-local" 2>/dev/null
ln -sfn "$HH/.claude-x/settings.local.json"     "$DL/own-local" 2>/dev/null
ln -sfn "$HH/.claude-nonexistent/settings.json" "$DL/newlane"   2>/dev/null
ln -sfn "$HH/xdg/cc-cmds/absent.json"           "$DL/xdg-absent" 2>/dev/null
if [ -L "$DL/sib-local" ] && [ ! -e "$DL/sib-local" ]; then
  check "매달린 심링크: 형제 레인의 settings.local.json 을 향해도 거부" \
    "$(hook_decide "$DL/sib-local")" "deny"
  check "매달린 심링크: 살아 있는 레인의 settings.local.json 을 향해도 거부" \
    "$(hook_decide "$DL/own-local")" "deny"
  check "매달린 심링크: 아직 없는 형제 레인의 settings.json 을 향해도 거부" \
    "$(hook_decide "$DL/newlane")" "deny"
  check "매달린 심링크: 운영자 스코프 안을 향해도 거부" \
    "$(hook_decide_xdg "$HH/xdg" "$DL/xdg-absent")" "deny"
  # 대조군. 표적이 실재하는 같은 자리의 링크는 오늘도 거부되며 그 답은 새 팔이
  # 아니라 파일 앵커가 낸다 — 이것이 없으면 위 넷의 통과가 「새 팔이 답했다」와
  # 구별되지 않는다.
  : > "$HH/.claude-y/settings.local.json"
  ln -sfn "$HH/.claude-y/settings.local.json" "$DL/sib-local-live" 2>/dev/null
  check "대조군: 표적이 실재하는 같은 링크도 거부 (파일 앵커가 답한다)" \
    "$(hook_decide "$DL/sib-local-live")" "deny"
else
  printf 'NOTE: 매달린 심링크를 만들지 못해 레인 표면 격자를 건너뛴다\n'
fi

# --- 어휘 해소와 커널 해소를 화해시키는 두 팔에 하중을 건다 -----------------
# 이 두 팔은 「불일치는 훅 앞에 파일이 둘 있다는 뜻이라 어느 쪽도 판정 대상으로
# 삼을 근거가 없다」를 참으로 만드는 계층인데, 둘 다 `|| true` 로 바꿔도 스위트가
# 초록이었다. 이유는 도달성이다 — 위 픽스처들은 전부 형제 레인 파일 앵커에 먼저
# 답해지므로 이 팔들이 발화할 기회가 없었다. 그 사실은 같은 배치의 음성 대조군이
# 증명했다: 형제 레인 파일 앵커를 끄면 정확히 그 두 단언이 거부에서 허용으로
# 뒤집혀 실패했으므로, 하네스는 이 파일의 편집을 볼 수 있고 위 초록은 진짜 구멍이다.
#
# 그래서 착지하는 두 파일이 **어떤 강제 표면에도 속하지 않게** 만든다. 그러면
# 어느 앵커도 먼저 답할 수 없고, 남는 것은 이 두 팔뿐이다.
hook_reason() {
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" \
    | HOME="$HH" CLAUDE_CONFIG_DIR="$HH/.claude-x" \
      bash "$HOOK" --run-dir "$RUN_DIR" --gate "$script_dir/gate.sh" \
    | jq -r '.hookSpecificOutput.permissionDecisionReason'
}
LK="$WORK/lexker"; mkdir -p "$LK/sub/other"
ln -sfn "$LK/sub/other" "$LK/dirlink" 2>/dev/null
if [ -d "$LK/dirlink" ] && [ -L "$LK/dirlink" ]; then
  # 말단 대조용. `$LK/dirlink/../plain.txt` 의 어휘 해소는 `$LK/plain.txt` 이고
  # 커널 해소는 `$LK/sub/plain.txt` 다 — `..` 를 어휘로 접으면 링크를 따라가지
  # 않고, 커널은 따라간 뒤 접기 때문이다. 두 파일을 모두 실재시켜야 두 아이노드가
  # 둘 다 비지 않아 이 팔이 실제로 값을 비교한다.
  : > "$LK/plain.txt"
  : > "$LK/sub/plain.txt"
  check "어휘 해소와 커널 해소가 다른 파일을 가리키면 거부" \
    "$(hook_decide "$LK/dirlink/../plain.txt")" "deny"
  case "$(hook_reason "$LK/dirlink/../plain.txt")" in
    *'어휘 해소와 커널 해소가 다른 파일'*) ok "그 거부가 말단 해소 대조의 것이다" ;;
    *) bad "말단 해소 대조 사유" "다른 팔이 먼저 거부했다 — 위 단언이 공허하다" ;;
  esac
  # 상위 대조용. 같은 철자에서 말단만 양쪽 다 부재하게 하면 위 팔은 두 값이 함께
  # 비어 통과하고, 상위 디렉터리의 아이노드가 갈려 이 팔이 발화한다.
  check "상위 디렉터리가 어휘 해소와 커널 해소에서 다르면 거부" \
    "$(hook_decide "$LK/dirlink/../absent.txt")" "deny"
  case "$(hook_reason "$LK/dirlink/../absent.txt")" in
    *'상위 디렉터리가 어휘 해소와 커널 해소'*) ok "그 거부가 상위 해소 대조의 것이다" ;;
    *) bad "상위 해소 대조 사유" "다른 팔이 먼저 거부했다 — 위 단언이 공허하다" ;;
  esac
  # 음성 대조군. 링크를 끼지 않은 같은 자리의 파일은 그대로 허용돼야 한다 —
  # 이것이 없으면 위 넷의 통과가 「이 디렉터리를 통째로 거부한다」와 구별되지 않는다.
  check "음성 대조군: 링크를 끼지 않은 같은 자리의 파일은 허용" \
    "$(hook_decide "$LK/plain.txt")" "allow"
  check "음성 대조군: 아직 없는 말단도 링크를 끼지 않으면 허용" \
    "$(hook_decide "$LK/absent.txt")" "allow"
else
  printf 'NOTE: 디렉터리 심링크를 만들지 못해 어휘/커널 해소 격자를 건너뛴다\n'
fi

# --- T17: 등재된 예외가 자체 점검에 있다 ------------------------------------
env -u CC_ORCH_SOURCE_ONLY CC_CMDS_ORCH_HOST_OS=Darwin bash "$DRIVER" --self-check > "$SC_OUT" 2>&1
sc_rc2=$?
check "T17 자체 점검이 통과한다" "$sc_rc2" "0"
if grep -q '등재된 예외: 구속면 다이제스트의 입력에 오케스트레이터 소스가 없다' "$SC_OUT"; then
  ok "T17 구속면 다이제스트에서 빠진 것이 등재된 예외로 진술된다"
else
  bad "T17 등재된 예외" "다이제스트 쪽 진술이 없다 — 빠진 것과 일부러 뺀 것을 구별할 수 없다"
fi
if grep -q '등재된 예외: 훅 거부 목록에 오케스트레이터 소스가 없다' "$SC_OUT"; then
  ok "T17 훅 거부 목록에서 빠진 것이 등재된 예외로 진술된다"
else
  bad "T17 등재된 예외" "훅 쪽 진술이 없다"
fi
# 그리고 그 단언이 실제로 대조한다. 결함을 심지 않은 통과는 공허할 수 있으므로,
# 플러그인 배치를 그대로 흉내 낸 픽스처에서 훅의 룰 분기를 오케스트레이터 전체로
# 넓히고 같은 점검을 다시 돌린다 — 등재된 예외의 문면과 어긋났으니 잡혀야 한다.
FX="$WORK/hookfix"
mkdir -p "$FX/orchestrator" "$FX/hooks"
cp "$script_dir"/*.sh "$FX/orchestrator/" 2>/dev/null
cp -R "$script_dir/prompts" "$FX/orchestrator/" 2>/dev/null || true
sed 's#\*/orchestrator/rules/\*)#*/orchestrator/*)#' "$HOOK" > "$FX/hooks/gate-pretool.sh"
if grep -q '\*/orchestrator/\*' "$FX/hooks/gate-pretool.sh"; then
  env -u CC_ORCH_SOURCE_ONLY CC_CMDS_ORCH_HOST_OS=Darwin \
    bash "$FX/orchestrator/run.sh" --self-check > "$SC_OUT" 2>&1
  fx_rc=$?
  if [ "$fx_rc" != "0" ] && grep -q '등재된 예외의 문면과 어긋난다' "$SC_OUT"; then
    ok "T17 훅 거부 분기를 넓히면 등재된 예외 항목이 잡는다"
  else
    bad "T17 등재된 예외" "넓힌 훅을 놓쳤다 (rc=$fx_rc) — 위 통과가 공허하다"
  fi
else
  bad "T17 픽스처" "훅의 룰 분기를 넓히지 못했다 — 대조가 성립하지 않는다"
fi
# 그리고 두 번째 변이. 위 변이는 분기를 **교체**하므로 가드가 세는 두 수를 함께
# 움직이고, 그래서 줄을 세든 출현을 세든 잡힌다. 분기를 제자리에서 **합집합으로
# 넓히는** 변이는 다르다 — 같은 줄에 룰 패턴을 남긴 채 오케스트레이터 전체를
# 더하므로, 줄을 세는 가드에서는 두 수가 함께 1로 남아 통과한다. 열리는 구멍은
# 위 변이와 같은데 대조군은 하나뿐이었다.
FX2="$WORK/hookfix-union"
mkdir -p "$FX2/orchestrator" "$FX2/hooks"
cp "$script_dir"/*.sh "$FX2/orchestrator/" 2>/dev/null
cp -R "$script_dir/prompts" "$FX2/orchestrator/" 2>/dev/null || true
sed 's#\*/orchestrator/rules/\*)#*/orchestrator/rules/*|*/orchestrator/*)#' "$HOOK" > "$FX2/hooks/gate-pretool.sh"
if grep -q '\*/orchestrator/rules/\*|\*/orchestrator/\*' "$FX2/hooks/gate-pretool.sh"; then
  env -u CC_ORCH_SOURCE_ONLY CC_CMDS_ORCH_HOST_OS=Darwin \
    bash "$FX2/orchestrator/run.sh" --self-check > "$SC_OUT" 2>&1
  fx2_rc=$?
  if [ "$fx2_rc" != "0" ] && grep -q '등재된 예외의 문면과 어긋난다' "$SC_OUT"; then
    ok "T17 훅 거부 분기를 합집합으로 넓혀도 등재된 예외 항목이 잡는다"
  else
    bad "T17 등재된 예외" "합집합으로 넓힌 훅을 놓쳤다 (rc=$fx2_rc) — 줄을 세는 가드는 제자리 확장을 보지 못한다"
  fi
else
  bad "T17 픽스처" "훅의 룰 분기를 합집합으로 넓히지 못했다 — 대조가 성립하지 않는다"
fi

printf '\ntest-run: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
