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

# (w) THE WINDOW RECORD IS NOT A LIVENESS INPUT. The launcher writes
#     `<seg>.window` (effective compaction window, lane) beside the pid record,
#     and the recorder reads it back for the outcome row. It says nothing about
#     whether the process is running, so its presence beside a live and a reused
#     pid must change neither verdict, and a segment that has ONLY this file —
#     a launch that never got as far as the pid — is not a stage at all.
printf '300000(argv)\n~\n' > "$RD/SB.window"
printf '300000(argv)\n~\n' > "$RD/SC.window"
printf '300000(argv)\n~\n' > "$RD/SE.window"

check "죽은 프로세스와 pid 재사용만 고아로 잡힌다" "$(orphans_of "$RD")" "SA,SC"
case "$(orphans_of "$RD")" in
  *SE*) bad "창 기록만 있는 세그먼트" "SE 가 고아로 보고됐다 — .window 는 생존 판정의 입력이 아니다" ;;
  *)    ok ".window 만 있고 .pid 가 없는 세그먼트는 고아가 아니다" ;;
esac

# --- the supervisor condition -----------------------------------------------
#
# THE SUPERVISOR WRITES THE ROW FIRST AND REMOVES THE RECORD AFTER, so there is
# a window in which the CLI is gone and the row is being written. Read on the
# pid alone that window is an orphan, and a settler acting on it writes a false
# `외부 종료` beside the real row about to land. Where `<seg>.sup` names a live
# supervisor the record is therefore NOT an orphan; where both are gone it is,
# and a directory with no `.sup` at all behaves exactly as it did before.

RD_SUP="$WORK/run-sup"; mkdir -p "$RD_SUP"

# (f) dead CLI, LIVE supervisor with a matching fingerprint — not an orphan.
printf '%s\n' "$DEAD" > "$RD_SUP/SF.pid"
printf 'Fri Sep 4 00:00:00 2026\n' > "$RD_SUP/SF.start"
printf '%s\n' "$$"               > "$RD_SUP/SF.sup"
cc_proc_fingerprint "$$"         > "$RD_SUP/SF.sup.start"

# (g) dead CLI, dead supervisor — an orphan.
printf '%s\n' "$DEAD" > "$RD_SUP/SG.pid"
printf 'Fri Sep 4 00:00:00 2026\n' > "$RD_SUP/SG.start"
printf '%s\n' "$DEAD"            > "$RD_SUP/SG.sup"
printf 'Fri Sep 4 00:00:00 2026\n' > "$RD_SUP/SG.sup.start"

# (h) dead CLI, no `.sup` at all — the old directory shape, unchanged.
printf '%s\n' "$DEAD" > "$RD_SUP/SH.pid"
printf 'Fri Sep 4 00:00:00 2026\n' > "$RD_SUP/SH.start"

check ".sup 조건 — 살아 있는 감독자 옆의 죽은 CLI 는 고아가 아니다" "$(orphans_of "$RD_SUP")" "SG,SH"

# (i) A SUPERVISOR PID THAT WAS REUSED is not a supervisor. Without the
# fingerprint compare, any live process holding that number would keep the
# record out of the alarm for good.
printf '%s\n' "$DEAD" > "$RD_SUP/SI.pid"
printf 'Fri Sep 4 00:00:00 2026\n' > "$RD_SUP/SI.start"
printf '%s\n' "$$"               > "$RD_SUP/SI.sup"
printf 'Mon Jan 1 00:00:00 2020\n' > "$RD_SUP/SI.sup.start"
check "감독자 pid 가 재사용됐으면 감독자가 아니다" "$(orphans_of "$RD_SUP")" "SG,SH,SI"
rm -f "$RD_SUP/SI.pid" "$RD_SUP/SI.start" "$RD_SUP/SI.sup" "$RD_SUP/SI.sup.start"

# (j) AN EMPTY FINGERPRINT FALLS BACK TO `kill -0` ALONE. A supervisor that
# exited between pid capture and fingerprint capture leaves the file empty;
# demanding a fingerprint there would call a live supervisor dead.
printf '%s\n' "$DEAD" > "$RD_SUP/SJ.pid"
printf 'Fri Sep 4 00:00:00 2026\n' > "$RD_SUP/SJ.start"
printf '%s\n' "$$"               > "$RD_SUP/SJ.sup"
: > "$RD_SUP/SJ.sup.start"
check "지문이 비어 있으면 kill -0 만으로 판정한다" "$(orphans_of "$RD_SUP")" "SG,SH"
rm -f "$RD_SUP/SJ.pid" "$RD_SUP/SJ.start" "$RD_SUP/SJ.sup" "$RD_SUP/SJ.sup.start"

# --- the stalled pre-emption reclaim -----------------------------------------
#
# A settler pre-empts a record by renaming its pid file to
# `<seg>.pid.settling.<pid>`; a settler that dies before its append leaves that
# name behind, and no `*.pid` glob walks it — so a VISIBLE orphan silently
# becomes an invisible one. The reclaim lives inside the enumeration so the
# alarm, the snapshot and the settlement all inherit it; the mtime is what asks
# "is this PRE-EMPTION alive", so a fresh marker is left alone.
RD_RC="$WORK/run-reclaim"; mkdir -p "$RD_RC"
printf '%s\n' "$DEAD" > "$RD_RC/SK.pid.settling.99999"
printf 'Fri Sep 4 00:00:00 2026\n' > "$RD_RC/SK.start"
check "갓 찍힌 선점 표식은 회수하지 않는다" "$(orphans_of "$RD_RC")" ""
perl -e 'my ($f, $s) = @ARGV; my $t = time() - $s; utime $t, $t, $f or die "utime: $!";' \
  "$RD_RC/SK.pid.settling.99999" 120
check "60초를 넘긴 선점 표식은 다시 열거된다" "$(orphans_of "$RD_RC")" "SK"

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
printf '300000(argv)\n~\n'          > "$RD_OK/SB.window"
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
# THE WORDING SAYS ONLY WHAT THE PREDICATE KNOWS. The old tail named one cause
# ("look at the dispatch mode, not the stage") and was wrong on a measured case;
# with the supervisor detached that cause cannot produce an orphan at all, so
# the sentence would point at a removed cause. And the settlement token has to
# be IN the banner — it is the string a person who saw it at 3am greps for.
case "$out_bad" in
  *"원인은 이 술어의 입력에 없습니다"*) ok "경보가 원인을 단정하지 않는다" ;;
  *) bad "경보 문면" "원인 미상 절이 없다: $(printf '%s' "$out_bad" | grep '잃어버린 파견' || true)" ;;
esac
case "$out_bad" in
  *"외부 종료"*) ok "경보가 정산 토큰을 문면에 싣는다 (아침에 grep 할 문자열)" ;;
  *) bad "경보 문면" "외부 종료 토큰이 없다" ;;
esac
case "$out_bad" in
  *"파견 방식을 보세요"*) bad "경보 문면" "제거된 원인(파견 방식)을 여전히 지목한다" ;;
  *) ok "제거된 원인을 지목하지 않는다" ;;
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

# --- the instruction that no longer has to prevent it ------------------------
#
# THESE FOUR ASSERTIONS ARE INVERTED, AND THE INVERSION IS THE POINT. The
# dispatch instruction used to carry the stage's survival: dispatch as a
# HARNESS-TRACKED BACKGROUND task, then hold the session with an active tool
# call, because ending the turn ends the session. Measured afterwards, that
# was the mode that DIES — the harness reaps a tracked task's process tree —
# while an ordinary background child survived. The gate now cuts the
# supervisor's lineage before the dispatch returns, so no instruction governs
# the stage's survival, and therefore no instruction can kill it.
#
# The requirement is asserted on the DISPATCH SENTENCE rather than on the file.
# The `wait` instruction used to be the one place a tracked background job was
# right, on the ground that a `wait` must die with its shift. Measured, it dies
# BEFORE it reports: a print-mode shift ends the moment it stops producing
# output, the harness reaps the tracked job with it, and no shift ever observes
# a stage terminate — so the seat starts successor after successor, each dying
# in the same place. That instruction is now a bounded FOREGROUND wait, and the
# two assertions at the end of this file hold that shape.
SHIFT_SKILL="$repo_root/plugins/cc-cmds/skills/autopilot-router-shift/SKILL.md"
dispatch_lines() { { grep -n -- '--kind skill' "$SHIFT_SKILL" || true; }; }
dl=$(dispatch_lines)
if [ -n "$dl" ]; then
  ok "교대 스킬에 파견 문장이 있다 (반전 단언의 대상이 실재한다)"
else
  bad "교대 스킬" "파견 문장을 찾지 못했다 — 아래 반전 단언이 전부 공허하다"
fi
for lit in 'HARNESS-TRACKED BACKGROUND' 'HOLD THE SESSION'; do
  if printf '%s' "$dl" | grep -qF "$lit"; then
    bad "교대 스킬" "파견 문장에 「${lit}」 가 남아 있다 — 그것이 실측상 죽는 모드다"
  else
    ok "파견 문장에 「${lit}」 가 없다"
  fi
done
for lit in 'ending your turn ends your session' 'Monitor(command: "tail -f'; do
  if grep -qF "$lit" "$SHIFT_SKILL"; then
    bad "교대 스킬" "「${lit}」 가 남아 있다 — 스테이지 생존을 산문에 거는 지시다"
  else
    ok "「${lit}」 가 파일에서 사라졌다"
  fi
done
# AND THE REPLACEMENT IS THERE. Deleting the old instruction without the new
# one leaves a shift that dispatches and then has nothing to do but poll.
if grep -q 'gate.sh wait' "$SHIFT_SKILL"; then
  ok "교대 스킬이 gate.sh wait 발행 문단을 갖고 있다"
else
  bad "교대 스킬" "wait 발행 형태가 없다 — 파견 뒤 기다리는 경로가 문서에 없다"
fi
if grep -q 'in the FOREGROUND, and never as a background job' "$SHIFT_SKILL"; then
  ok "그 wait 은 전경으로 낸다 (print-mode 교대는 출력을 멈추는 순간 끝난다)"
else
  bad "교대 스킬" "wait 을 어떻게 내는지가 없다"
fi
# AND IT IS BOUNDED. A foreground call over the harness's own ceiling never
# returns a usable result, so the loop only works with a timeout under it.
if grep -q -- '--timeout 540' "$SHIFT_SKILL"; then
  ok "그 wait 은 하네스 전경 상한 아래로 끊긴다 (13 을 받고 다시 기다리는 루프)"
else
  bad "교대 스킬" "전경 wait 에 상한이 없다 — 하네스 상한에 걸려 결과를 못 읽는다"
fi

printf '\n통과 %s · 실패 %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
