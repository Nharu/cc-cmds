#!/usr/bin/env bash
# lint-bash-portability: self-skip
# The lost-dispatch alarm — one condition, two surfaces, and the discrimination
# that makes the alarm mean something.
#
# WHY THIS SUITE EXISTS. A dispatch whose record outlives its process was
# silent at every layer that could have spoken: the tool result reported
# `is_error=false`, the dispatching shift ended normally with a terminal line in
# its own stream, and the seat received rc=0. Nothing was wrong with any one
# report — the outcome row simply was never written, because the line that
# writes it comes after a block the process never returned from. Measured: three
# dispatches lost this way in one run, zero rows, zero commits, a whole night.
#
# So the alarm is the fix's other half, and an alarm needs two assertions rather
# than one: that it fires on the condition, AND that it stays quiet without it.
# A detector that reports every pid record would pass the first alone while
# teaching its reader to ignore it.
#
# THE NEGATIVE CASES ARE NOT DECORATION. `cc_orphan_stages` is deliberately
# narrower than `! cc_stage_is_live`: a run directory laid down before
# fingerprints were recorded makes that predicate false with nothing wrong, and
# calling those lost would raise the alarm on healthy trees. The two negative
# fixtures below are what hold that narrowing in place.
#
# Usage: bash scripts/test-lost-dispatch.sh

set -uo pipefail

# The watcher raises real banners and prepends the Homebrew directories to PATH
# itself, so a stub alone is not enough — the channel is closed for the whole
# process. This suite asserts nothing about banners, so that costs it nothing.
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
LIVENESS="$repo_root/plugins/cc-cmds/orchestrator/liveness.sh"
WATCH="$repo_root/plugins/cc-cmds/orchestrator/watch.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-lost-dispatch.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/terminal-notifier" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$WORK/bin/terminal-notifier"
PATH="$WORK/bin:$PATH"
CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1
export PATH CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND

passed=0; failed=0
ok()    { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

. "$LIVENESS"

# A pid that is certainly not running. Picking a number and hoping is how this
# assertion becomes flaky on a busy host; a child that has already been reaped
# is gone by construction.
sh -c 'exit 0' & DEAD=$!; wait "$DEAD" 2>/dev/null || true

orphans_of() { { cc_orphan_stages "$1" || true; } | paste -sd, -; }

# --- discrimination ---------------------------------------------------------

RD="$WORK/run-mixed"; mkdir -p "$RD"

# (a) the failure itself — the record outlived the process.
printf '%s\n' "$DEAD" > "$RD/SA.pid"
printf 'Fri Sep 4 00:00:00 2026\n'  > "$RD/SA.start"

# (b) a healthy live stage — this shell stands in for one.
printf '%s\n' "$$" > "$RD/SB.pid"
cc_proc_fingerprint "$$"           > "$RD/SB.start"

# (c) pid reuse — the pid is alive but it is somebody else now. Without this the
#     detector could be `kill -0` alone, which reports a run directory that
#     survived a reboot as healthy for as long as the number happens to be held.
printf '%s\n' "$$" > "$RD/SC.pid"
printf 'Mon Jan 1 00:00:00 2020\n'  > "$RD/SC.start"

# (d) unverifiable — a directory from before fingerprints were recorded. Not an
#     orphan: nothing here says the process is gone.
printf '%s\n' "$$" > "$RD/SD.pid"

# (e) the watcher's own record, which is not a stage.
printf '%s\n' "$DEAD" > "$RD/watch.pid"
printf 'Fri Sep 4 00:00:00 2026\n'  > "$RD/watch.start"

check "죽은 프로세스와 pid 재사용만 고아로 잡힌다" "$(orphans_of "$RD")" "SA,SC"

# AND THE SET, not just its membership. "contains SA" survives a detector that
# reports everything, which is the failure this suite's negative half exists to
# catch — so the assertion is the whole list and its order.
case "$(orphans_of "$RD")" in
  *SB*) bad "살아 있는 스테이지" "SB 가 고아로 보고됐다 — 탐지기가 살아 있는 것까지 잡는다" ;;
  *)    ok "살아 있는 스테이지는 고아가 아니다" ;;
esac
case "$(orphans_of "$RD")" in
  *SD*) bad "판정 불가" "SD 가 고아로 보고됐다 — 지문 없는 옛 디렉터리는 판정 대상이 아니다" ;;
  *)    ok "지문이 없는 기록은 판정하지 않는다" ;;
esac
case "$(orphans_of "$RD")" in
  *watch*) bad "감시자 기록" "watch 가 스테이지로 세어졌다" ;;
  *)       ok "감시자 자신의 기록은 스테이지가 아니다" ;;
esac

# --- the quiet tree ---------------------------------------------------------
#
# The negative case carries a LIVE stage rather than being empty. An empty
# directory would make "no alarm" true for the wrong reason, and the assertion
# would then hold just as well against a detector that had been deleted.

RD_OK="$WORK/run-clean"; mkdir -p "$RD_OK"
printf '%s\n' "$$" > "$RD_OK/SB.pid"
cc_proc_fingerprint "$$"           > "$RD_OK/SB.start"
check "깨끗한 런에는 고아가 없다"          "$(orphans_of "$RD_OK")" ""
check "그 런에 살아 있는 스테이지가 실제로 있다" "$(cc_live_stages "$RD_OK")" "1"

# --- the watcher's surface --------------------------------------------------

ledger_at() {
  printf '# 파이프라인 런 보고서 — T\n' > "$1"
  printf -- '- `run` | 교대=0 | run-id=T | prev=x\n' >> "$1"
}

watch_once() {
  ledger_at "$WORK/led-$2.md"
  bash "$WATCH" --run-dir "$1" --ledger "$WORK/led-$2.md" --once 2>&1 || true
}

out_bad=$(watch_once "$RD" mixed)
out_ok=$(watch_once "$RD_OK" clean)

case "$out_bad" in
  *"잃어버린 파견"*) ok "감시자가 잃어버린 파견을 이름 대어 보고한다" ;;
  *) bad "감시자 경보" "고아가 있는데 경보 줄이 없다" ;;
esac
case "$out_bad" in
  *SA*) ok "그 보고가 세그먼트를 지목한다" ;;
  *)    bad "감시자 경보" "경보에 세그먼트 이름이 없다 — 어느 파견인지 알 수 없다" ;;
esac
case "$out_ok" in
  *"잃어버린 파견"*) bad "감시자 침묵" "고아가 없는데 경보가 났다" ;;
  *) ok "고아가 없으면 그 줄은 아예 나오지 않는다" ;;
esac
# The quiet pass must still be a pass that RAN — otherwise "no alarm" is
# indistinguishable from a watcher that failed to start.
case "$out_ok" in
  *"살아 있음"*) ok "그 침묵한 패스가 실제로 돈 패스다" ;;
  *) bad "감시자 침묵" "하트비트 줄이 없다 — 감시자가 돌지 않았으므로 위 침묵은 증거가 아니다" ;;
esac

# --- the instruction that prevents it ---------------------------------------
#
# The alarm reports the loss; only the dispatch instruction stops it happening.
# It lived in the kickoff skill, which the shift never reads, and that gap is
# the whole root cause — so the assertion is that the shift's own file carries
# it.
SHIFT_SKILL="$repo_root/plugins/cc-cmds/skills/autopilot-router-shift/SKILL.md"
if grep -q 'HARNESS-TRACKED BACKGROUND' "$SHIFT_SKILL"; then
  ok "교대 스킬이 파견을 하네스 추적 백그라운드로 내라고 적고 있다"
else
  bad "교대 스킬" "파견 방식 지시가 없다 — 지시는 킥오프 스킬에만 있고 교대는 그 파일을 읽지 않는다"
fi

printf '\n통과 %s · 실패 %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
