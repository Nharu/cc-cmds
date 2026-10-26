#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test the status line, the shared wrapper grammar, and the apply path that
# installs it.
#
# TWO GUARANTEES THAT DO NOT COVER EACH OTHER. The apply proves the settings
# file ends up correct and no worse than it started; this suite proves the
# script is TOTAL — that every degraded input still yields one valid line and
# exit 0. The apply's own verify run only happens on a first install now, and
# even there it exercises whichever branch the installed path reaches on that
# machine, so it can never stand in for the cases below.
#
# WHAT THE ISOLATION HIDES. Every case here sets `XDG_STATE_HOME`, so the real
# environment's branch — the variable unset, falling back to `$HOME/.local/state`
# — is never executed for the run index. That shape is pinned by a separate
# textual assertion rather than left to the fixture, which by construction cannot
# reach it. The borrow record's path is the exception: SB05 renders with the
# variable unset and `HOME` pointed at a fixture, so its fallback branch runs.
#
# THE HAND-WRITTEN COPY OF THE WRAPPER GRAMMAR LIVES HERE, and this is one of
# exactly two files allowed to hold one. A suite that sourced the implementation
# it is testing would turn every comparison into a tautology.
# `scripts/lint-statusline-wrapper-pins.sh` pins both production rules against
# this file and asserts that no third file carries the literal.
#
# Usage: bash scripts/test-statusline.sh

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

# AND THE STAGE GUARD IS CLEARED FOR THIS WHOLE PROCESS. The hook exits
# immediately when it sees a pipeline stage session, and this suite is run from
# one — inside a stage every case that drives the hook would observe a silent
# rc 0 and read it as the behaviour under test. The guard itself is exercised by
# the hook suite, which sets the variable deliberately.
unset CC_PIPELINE_STAGE_ID


script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
SL="$repo_root/plugins/cc-cmds/orchestrator/statusline.sh"
APPLY="$repo_root/plugins/cc-cmds/orchestrator/apply-statusline.sh"
CMDLIB="$repo_root/plugins/cc-cmds/orchestrator/statusline-command.sh"
LIVENESS="$repo_root/plugins/cc-cmds/orchestrator/liveness.sh"
HOOK="$repo_root/plugins/cc-cmds/hooks/statusline-sessionstart.sh"
. "$repo_root/scripts/run-fixture.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-statusline-test.XXXXXX")
XDG_STATE_HOME="$WORK/state"
export XDG_STATE_HOME
mkdir -p "$XDG_STATE_HOME"
# The session's config directory decides whose view of a borrow the line shows,
# and a stage running this suite carries its own. Unset, every case below that
# does not name one sees what a session with none would.
unset CLAUDE_CONFIG_DIR
trap 'fx_reap; chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# THE APPLY CASES INSTALL FROM A COPY, NOT FROM THIS CHECKOUT. `--plugin-dir`
# parks on a linked git worktree, and this suite is run from one about as often
# as from a clone — pointing the apply at its own tree would make every case
# below pass or park depending on where somebody happened to check the
# repository out. The copy is made here rather than carried in the repository so
# it cannot drift from the files it is a copy of.
#
# THE SHARED GRAMMAR FILE IS PART OF THE COPY. The installer sources it out of
# `--plugin-dir`, so a plugin tree without it is a partial checkout.
#
# AND SO IS THE INSTALLER ITSELF, because the hook resolves it out of the same
# `--plugin-dir` rather than being told where it is. A tree without it makes
# every hook-driven case end at an exit code outside the verdict band, which
# looks exactly like a hook that decided to do nothing.
APLUG="$WORK/plugin"
mkdir -p "$APLUG/orchestrator"
cp "$SL" "$LIVENESS" "$CMDLIB" "$APPLY" "$APLUG/orchestrator/"
chmod +x "$APLUG/orchestrator/statusline.sh"

# A plugin directory that does NOT exist, standing in for the older cache
# version an installed wrapper points at after a marketplace update. It is never
# created: the recogniser must not stat the path it recognises.
OLDPLUG="$WORK/oldplug"
OLDSL="$OLDPLUG/orchestrator/statusline.sh"

passed=0; failed=0; skipped=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
skip() { skipped=$((skipped + 1)); printf 'SKIP: %s — %s\n' "$1" "${2:-}"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
differ(){ if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "두 값이 같다: '$2'"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "'$2' 에 '$3' 없음" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "'$2' 에 '$3' 가 있음" ;; *) ok "$1" ;; esac; }

# TWO RENDERS TAKEN A MOMENT APART ARE NOT ONE OBSERVATION. A case that compares
# one render against another is asking which script produced the bytes, but the
# line carries two slots no script owns: the elapsed a live stage gets from
# `ps -o etime=` and the ledger age computed against a wall clock, both at
# one-second resolution. A second boundary falling between the two command
# substitutions turns one fact into two strings — measured as a red suite in
# roughly one run of seven, at three different cases. Stripping the slots from
# BOTH sides costs those assertions nothing, because neither slot names a script.
#
# NO COMPARISON THROUGH THIS FUNCTION RUNS WITH A BORROW RECORD PRESENT. The
# borrow segment can end the line in a `홈 HH:MM` clock, which is exactly the
# trailing digit run the first expression removes, so the SB cases compare
# literals and never call it.
strip_clock() { sed -e 's/ [0-9][0-9:-]*$//' -e 's/원장 [0-9][^ ]* 전/원장 N/'; }

# AND THE STRIPPING IS PINNED HERE, BECAUSE NOWHERE ELSE CAN PIN IT. Turned into
# a no-op this function fails none of the three cases that call it — it only
# makes them disagree when a second boundary falls between their two command
# substitutions, which is a red about one run in seven and a green the rest, so
# the suite reports the defect as flake rather than as a broken scrubber.
# Measured: with the body replaced by `cat` this suite is 100 green.
#
# The pair below differs in the two slots and in nothing else, so it has to
# collapse to one line — and it has to have been two lines to begin with, or it
# would prove nothing about what was removed.
#
# AND THE LINE IT COLLAPSES TO IS SPELLED OUT, rather than compared against the
# other side. Both sides are outputs of this function, so a body that emits
# NOTHING satisfies them — `"" = ""` — and an empty scrubber is what a `sed`
# typo, a deleted function and a missing `sed` all produce. Measured: with the
# body replaced by one that writes nothing, this suite stayed at its baseline
# green. Every other reading of this function in this file is stripped-against-
# stripped too, and so is the real-render case below, which a `stripped` that is
# empty also satisfies — so this is the one place the direction can be closed.
# A literal on the right cannot be produced by an absent scrubber, and it is
# still wrong for a scrubber that does nothing, so one assertion closes both.
_sc_a='⟳ run-live S1 · 원장 5초 전 00:03'
_sc_b='⟳ run-live S1 · 원장 6초 전 00:04'
_sc_want='⟳ run-live S1 · 원장 N'
if [ "$_sc_a" != "$_sc_b" ]; then
  ok "시계 슬롯 대조쌍이 벗기기 전에는 서로 다르다"
else
  bad "시계 슬롯 대조쌍" "두 줄이 이미 같다 — 이 쌍은 벗기기를 재지 못한다"
fi
check "시계 슬롯을 벗기면 앞 시점이 알려진 한 줄이 된다" \
  "$(printf '%s\n' "$_sc_a" | strip_clock)" "$_sc_want"
check "시계 슬롯을 벗기면 뒤 시점이 같은 그 한 줄이 된다" \
  "$(printf '%s\n' "$_sc_b" | strip_clock)" "$_sc_want"

# The "no run" line. Byte-identical to every degraded path's output when no
# borrow record is present, which is the property cases 10-13 exist to hold in
# place.
#
# THIS IDENTITY IS ABOUT THE DEGRADED PATHS OF `statusline.sh`, NOT ABOUT THE
# INSTALLED WRAPPER'S TWO BRANCHES. On a machine that already had a status line
# the wrapper's fallback is the user's previous command and the identity holds
# there too; on a machine that had none the fallback is `true` and emits
# nothing, which is exactly the difference the first install's verify run is
# still there to see.
#
# THE REFERENCE IS IN THE REPOSITORY, and it is executed on every run. Taken
# only from the install target it is absent on the CI runner, where the
# reference then degrades to the script's OWN no-run output and every case below
# compares the script against itself — a tautology that passes green on exactly
# the defect these cases exist to catch. Measured: the ANSI escapes stripped
# from `emit_fallback` fail six cases against a real reference and zero against
# the degraded one.
#
# A constant typed inline here is what let the escapes go missing before; a
# committed file whose only content is the command is not that, because changing
# it is a diff somebody has to justify. What guards it against drifting away
# from the machine it describes is the case laid on top of it, just below.
REF_CMD_FIXTURE="$repo_root/scripts/statusline-pre-apply-command.sh"
FALLBACK=$(bash "$REF_CMD_FIXTURE" </dev/null)
check "폴백이 적용 전 명령의 출력과 바이트 동일" "$(bash "$SL" </dev/null)" "$FALLBACK"

# The same comparison against what is ACTUALLY installed, wherever there is
# something installed to read. On top of the reference above rather than in
# place of it: this is the reading that would notice the fixture drifting, and
# it is the one that cannot run on CI.
#
# `</dev/null` IS NOT OPTIONAL. Reading the session JSON off stdin is what a
# status line command normally does — this repository's own begins with `cat` —
# so a reference command that inherits this suite's stdin waits for an EOF that
# never arrives, and the whole run hangs with no diagnostic printed.
REF_SETTINGS="${CC_SL_REF_SETTINGS:-$HOME/.claude-cc/settings.json}"
ref_cmd=$(jq -r '.statusLine.command // ""' "$REF_SETTINGS" 2>/dev/null || true)
case "$ref_cmd" in "[ -x "*) ref_cmd=${ref_cmd#*" || "} ;; esac
if [ -n "$ref_cmd" ] && [ "$ref_cmd" != "true" ]; then
  check "설치 대상의 적용 전 명령도 같은 바이트를 낸다" \
    "$(sh -c "$ref_cmd" </dev/null 2>/dev/null)" "$FALLBACK"
else
  skip "설치 대상의 적용 전 명령과 대조" "$REF_SETTINGS 에서 기준 명령을 읽을 수 없다"
fi

sl() { fx_statusline_stdin "$1" | bash "$SL"; }

# ---------------------------------------------------------------------------
# 1-2. No run for this session
# ---------------------------------------------------------------------------
check "1 이 세션의 런 없음 — 적용 전과 같은 한 줄" "$(sl sess-none)" "$FALLBACK"

fx_session_index sess-ghost "런이-없는-id"
check "2 색인은 있으나 런 디렉터리가 없음 — 훑지 않고 폴백" "$(sl sess-ghost)" "$FALLBACK"

# ---------------------------------------------------------------------------
# 3-5. The three stage states the liveness predicate separates
# ---------------------------------------------------------------------------
fx_mkrun run-live; fx_ledger_path; fx_session_index sess-live run-live
fx_segment S1 실행중
fx_stage_live S1
fx_heartbeat 0 5
out=$(sl sess-live)
has "3 살아 있는 pid + 지문 일치 — 도는 중 형태" "$out" "⟳"
has "3 살아 있는 pid + 지문 일치 — 세그먼트 id 를 싣는다" "$out" "S1"

fx_mkrun run-dead; fx_ledger_path; fx_session_index sess-dead run-dead
fx_segment S1 실행중
fx_stage_dead S1
fx_heartbeat 0 5
out=$(sl sess-dead)
has "4 pid 파일은 있으나 프로세스가 죽음 — 살아 있는 스테이지로 세지 않는다" "$out" "스테이지 0"
hasnt "4 죽은 스테이지를 세그먼트 슬롯에 싣지 않는다" "$out" "run-dead S1"

fx_mkrun run-reused; fx_ledger_path; fx_session_index sess-reused run-reused
fx_segment S1 실행중
fx_stage_reused S1
fx_heartbeat 0 5
out=$(sl sess-reused)
has "5 pid 재사용(지문 불일치) — 살아 있는 스테이지로 세지 않는다" "$out" "스테이지 0"

# ---------------------------------------------------------------------------
# 6. Approvals
# ---------------------------------------------------------------------------
fx_mkrun run-appr; fx_ledger_path; fx_session_index sess-appr run-appr
fx_segment S1 실행중
fx_approval A1 대기
fx_approval A2 대기
fx_heartbeat 0 5
has "6 대기 승인 2건" "$(sl sess-appr)" "⏸"
has "6 대기 승인 건수를 싣는다" "$(sl sess-appr)" "승인 대기 2건"

# ---------------------------------------------------------------------------
# 7. The staleness mark
# ---------------------------------------------------------------------------
fx_mkrun run-7a; fx_ledger_path; fx_session_index sess-7a run-7a
fx_segment S1 실행중
fx_heartbeat 0 200
out_7a=$(sl sess-7a)
has "7a 원장 미성장 200초 — 정지 경고" "$out_7a" "⚠"

fx_mkrun run-7b; fx_ledger_path; fx_session_index sess-7b run-7b
fx_segment S1 실행중
fx_heartbeat 0 100
hasnt "7b 원장 미성장 100초 — 정지 경고 아님" "$(sl sess-7b)" "⚠"

# The confirmed wording draws no line between a park and a stall, so the
# implementation does not invent one.
fx_mkrun run-7c; fx_ledger_path; fx_session_index sess-7c run-7c
fx_segment S2 실행중
fx_segment S1 park
fx_heartbeat 0 200
out_7c=$(sl sess-7c)
check "7c 마지막 행이 park 여도 7a 와 같은 표시" \
  "$(printf '%s' "$out_7c" | sed 's/run-7c/RID/')" \
  "$(printf '%s' "$out_7a" | sed 's/run-7a/RID/')"

# `n_seg ≥ 1` is written into the predicate but until now nothing proved it: on
# an empty set "every segment is terminal" is vacuously true.
fx_mkrun run-7d; fx_ledger_path; fx_session_index sess-7d run-7d
fx_heartbeat 0 200
hasnt "7d 세그먼트 행이 0개인 갓 킥오프된 런 — 종료로 접히지 않는다" "$(sl sess-7d)" "✓"

# ---------------------------------------------------------------------------
# 8. Terminal
# ---------------------------------------------------------------------------
fx_mkrun run-8a; fx_ledger_path; fx_session_index sess-8a run-8a
fx_segment S1 실행중
fx_done
fx_heartbeat 0 900
has "8a done 존재 — 종료" "$(sl sess-8a)" "✓"
hasnt "8a done 이 있으면 원장이 멎어도 정지 경고가 아니다" "$(sl sess-8a)" "⚠"

fx_mkrun run-8b; fx_ledger_path; fx_session_index sess-8b run-8b
fx_segment S1 머지됨
fx_heartbeat 0 900
has "8b done 없이 유도 종단 술어만으로 종료" "$(sl sess-8b)" "✓"

fx_mkrun run-8c; fx_ledger_path; fx_session_index sess-8c run-8c
fx_segment S1 실행중
fx_heartbeat 0 900
out=$(sl sess-8c)
hasnt "8c 유도 술어 불성립 — 종료 아님" "$out" "✓"
has "8c 유도 술어 불성립인데 원장만 오래됨 — 정지 경고" "$out" "⚠"

# A run a person has to touch does not quietly become "finished".
fx_mkrun run-8d; fx_ledger_path; fx_session_index sess-8d run-8d
fx_segment S1 머지됨
fx_blocked "라이브니스 침묵" 불명
fx_heartbeat 0 900
hasnt "8d 미해소 런 스코프 blocked 가 있으면 종료가 아니다" "$(sl sess-8d)" "✓"

fx_mkrun run-8e; fx_ledger_path; fx_session_index sess-8e run-8e
fx_segment S1 머지됨
fx_blocked "라이브니스 침묵" 불명
fx_blocked "라이브니스 침묵" 해소
fx_heartbeat 0 900
has "8e 사람이 해소한 뒤에는 게이트와 같이 종료로 판정한다" "$(sl sess-8e)" "✓"

# The watcher exits when the run ends, so a finished run's heartbeat goes stale
# by design. Reporting that as a missing watcher reads a clean finish as a fault.
fx_mkrun run-8f; fx_ledger_path; fx_session_index sess-8f run-8f
fx_segment S1 머지됨
fx_done
fx_heartbeat 300 900
fx_watch_pid dead
out=$(sl sess-8f)
has "8f 종료한 런 — 하트비트가 노후해도 종료로 보인다" "$out" "✓"
hasnt "8f 종료한 런에는 워처 접미사가 붙지 않는다" "$out" "워처"

fx_mkrun run-8g; fx_ledger_path; fx_session_index sess-8g run-8g
fx_segment S1 머지됨
fx_done
out=$(sl sess-8g)
has "8g 하트비트도 pid 도 없는 종료 런 — 종료로 보인다" "$out" "✓"
hasnt "8g 종료한 런에는 미기동 접미사도 붙지 않는다" "$out" "워처"

# ---------------------------------------------------------------------------
# 8h-8m. Settlement — a run carrying `ends-on-done` ends on `done` only
# ---------------------------------------------------------------------------
# The marker is what the gate writes when the seat launches a shift. Such a run
# settles its exit clauses after the last segment, so "every segment merged"
# opens a settlement window instead of ending it, and `done` with a shift still
# alive is the done-tail. Both read as `⟳ <rid> 정산 중`.
#
# A LIVE SHIFT IS ITS OWN HANDLE, not a stage pid: `shift.live` carries the pid
# and its start fingerprint, and the name is outside the `*.pid` glob.
sl_shift_live() {
  local pid
  sleep 120 &
  pid=$!
  { printf '%s\n' "$pid"
    LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null | sed 's/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//'
  } > "$FX_RUN_DIR/shift.live"
  FX_PIDS="${FX_PIDS:-}$pid "
  export FX_PIDS
}

fx_mkrun run-8h; fx_ledger_path; fx_session_index sess-8h run-8h
printf '1\n' > "$FX_RUN_DIR/ends-on-done"
fx_segment S1 머지됨
fx_heartbeat 0 5
out=$(sl sess-8h)
has "8h 표지·머지된 세그먼트·done 없음·갓 쓴 원장 — 정산 중" "$out" "⟳ run-8h 정산 중"
hasnt "8h 정산 창은 종료가 아니다" "$out" "✓"

fx_mkrun run-8i; fx_ledger_path; fx_session_index sess-8i run-8i
printf '1\n' > "$FX_RUN_DIR/ends-on-done"
fx_segment S1 머지됨
fx_done
sl_shift_live
fx_heartbeat 0 900
out=$(sl sess-8i)
has "8i 표지·done·살아 있는 교대 — 정산 중(나이 사다리 없음)" "$out" "⟳ run-8i 정산 중"
hasnt "8i done 꼬리에는 워처 접미사가 없다(갓 쓴 하트비트)" "$out" "워처"

# THE WATCHER SLOT FOLLOWS THE HEARTBEAT ON THIS ARM, as it does on 진행중: a
# live watcher keeps beating through the done-tail, and a dead one shows.
fx_mkrun run-8j; fx_ledger_path; fx_session_index sess-8j run-8j
printf '1\n' > "$FX_RUN_DIR/ends-on-done"
fx_segment S1 머지됨
fx_done
sl_shift_live
fx_heartbeat 300 900
fx_watch_pid dead
out=$(sl sess-8j)
has "8j done 꼬리·낡은 하트비트 — 정산 중" "$out" "⟳ run-8j 정산 중"
has "8j done 꼬리·낡은 하트비트 — 워처 없음" "$out" "· 워처 없음"

fx_mkrun run-8k; fx_ledger_path; fx_session_index sess-8k run-8k
printf '1\n' > "$FX_RUN_DIR/ends-on-done"
fx_segment S1 머지됨
fx_done
fx_heartbeat 0 900
has "8k 표지·done·교대 없음 — 종료" "$(sl sess-8k)" "✓ run-8k 종료"

fx_mkrun run-8l; fx_ledger_path; fx_session_index sess-8l run-8l
printf '1\n' > "$FX_RUN_DIR/ends-on-done"
fx_segment S1 머지됨
fx_heartbeat 0 200
has "8l 표지·정산 창·원장 200초 — 정지 경고" "$(sl sess-8l)" "⚠ run-8l"

fx_mkrun run-8m; fx_ledger_path; fx_session_index sess-8m run-8m
printf '1\n' > "$FX_RUN_DIR/ends-on-done"
fx_segment S1 머지됨
fx_heartbeat 0 4000
has "8m 표지·정산 창·원장 4000초 — 방치" "$(sl sess-8m)" "⊘ run-8m 방치"

# ---------------------------------------------------------------------------
# 9. Watcher freshness — twice the pinned `--interval`
# ---------------------------------------------------------------------------
fx_mkrun run-9; fx_ledger_path; fx_session_index sess-9 run-9
fx_segment S1 실행중
fx_heartbeat 300 5
fx_watch_pid dead
has "9 하트비트 노후 — 워처 없음" "$(sl sess-9)" "· 워처 없음"

fx_mkrun run-9b; fx_ledger_path; fx_session_index sess-9b run-9b
fx_segment S1 실행중
fx_heartbeat 30 5
hasnt "9b 임계 미만의 하트비트에는 접미사가 붙지 않는다" "$(sl sess-9b)" "워처"

# `watch.pid` is the handle that keeps these two apart; without it both are
# silence, and silence from a watcher that never started means something else.
fx_mkrun run-9c; fx_ledger_path; fx_session_index sess-9c run-9c
fx_segment S1 실행중
has "9c 하트비트도 pid 도 없음 — 미기동" "$(sl sess-9c)" "· 워처 미기동"

# ---------------------------------------------------------------------------
# 10-13. The degraded paths — all four land on the same bytes
# ---------------------------------------------------------------------------
out=$(printf '%s' '{"cwd":"/tmp","session_i' | bash "$SL"); rc=$?
check "10 깨진 stdin JSON — exit 0" "$rc" "0"
check "10 깨진 stdin JSON — 폴백과 바이트 동일" "$out" "$FALLBACK"

# Truncated AFTER the field is a different case from truncated before it, and
# worth pinning separately: the id is still recoverable, so the line resolves
# the run rather than degrading. Both must exit 0 — that is what the scenario
# is about — but only the unrecoverable one owes a fallback.
out=$(printf '%s' '{"session_id": "sess-live", broken' | bash "$SL"); rc=$?
check "10b session_id 뒤에서 끊긴 JSON — exit 0" "$rc" "0"
has "10b session_id 가 살아 있으면 런을 해소한다" "$out" "⟳"

# `jq` is not merely absent here — it is present and poisonous. If the script
# reached for it the output would be wrong rather than missing, which is a
# stronger statement than an empty PATH can make.
mkdir -p "$WORK/poison"
cat > "$WORK/poison/jq" <<'STUB'
#!/usr/bin/env bash
printf 'JQ-WAS-CALLED\n'; exit 1
STUB
chmod +x "$WORK/poison/jq"
out=$(PATH="$WORK/poison:$PATH" sl sess-live)
has "11 jq 부재 — 크래시 없이 유효한 출력" "$out" "⟳"
hasnt "11 상태줄은 jq 를 부르지 않는다" "$out" "JQ-WAS-CALLED"

if [ "$(id -u)" = "0" ]; then
  skip "12 런 디렉터리 읽기 실패" "root 로는 권한 비트가 강제되지 않는다"
else
  fx_mkrun run-12; fx_ledger_path; fx_session_index sess-12 run-12
  fx_segment S1 실행중
  chmod 000 "$FX_RUN_DIR"
  out=$(sl sess-12); rc=$?
  chmod u+rwx "$FX_RUN_DIR"
  check "12 런 디렉터리 읽기 실패 — exit 0" "$rc" "0"
  check "12 런 디렉터리 읽기 실패 — 폴백" "$out" "$FALLBACK"
fi

# The hole the installed `[ -x statusline.sh ]` guard cannot see.
mkdir -p "$WORK/partial"
cp "$SL" "$WORK/partial/statusline.sh"
out=$(fx_statusline_stdin sess-live | bash "$WORK/partial/statusline.sh"); rc=$?
check "13 liveness.sh 부재, statusline.sh 존재 — exit 0" "$rc" "0"
check "13 liveness.sh 부재 — 한 줄 폴백" "$out" "$FALLBACK"

# ---------------------------------------------------------------------------
# 14-17. The index is a list
# ---------------------------------------------------------------------------
fx_mkrun run-14; fx_ledger_path
fx_segment S1 실행중
fx_heartbeat 0 5
fx_session_index sess-14-a run-14
fx_session_index sess-14-b run-14
check "14 --resume 으로 갈린 세션 id 둘이 같은 런으로 해소된다" \
  "$(sl sess-14-a | strip_clock)" "$(sl sess-14-b | strip_clock)"

fx_mkrun run-15-term; fx_ledger_path; fx_segment S1 머지됨; fx_heartbeat 0 5
fx_mkrun run-15-live; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 5
fx_session_index sess-15 run-15-term run-15-live
out=$(sl sess-15)
has "15 같은 세션의 런 둘 중 비종단을 표시한다" "$out" "run-15-live"
hasnt "15 종단한 쪽을 표시하지 않는다" "$out" "run-15-term"

fx_mkrun run-16-old; fx_ledger_path; fx_segment S1 머지됨; fx_heartbeat 0 5
fx_age_file "$FX_LEDGER" 3600
fx_mkrun run-16-new; fx_ledger_path; fx_segment S1 머지됨; fx_heartbeat 0 5
fx_session_index sess-16 run-16-old run-16-new
out=$(sl sess-16)
has "16 둘 다 종단이면 더 최근에 종단한 쪽" "$out" "run-16-new"
hasnt "16 더 오래된 종단을 표시하지 않는다" "$out" "run-16-old"

# The decoy is recent, non-terminal and belongs to somebody else.
fx_mkrun run-17-decoy; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 5
out=$(sl sess-17-empty)
check "17 미끼가 있어도 런 없는 세션은 폴백 형태" "$out" "$FALLBACK"
hasnt "17 미끼를 절대 언급하지 않는다" "$out" "run-17-decoy"

# ---------------------------------------------------------------------------
# E1-E2. Terminal renders, and stays
# ---------------------------------------------------------------------------
fx_mkrun run-e1; fx_ledger_path; fx_session_index sess-e1 run-e1
fx_segment S1 머지됨
fx_heartbeat 0 5
before=$(sl sess-e1)
has "E1 종단한 런 하나 — 종료가 렌더된다" "$before" "✓"
fx_age_file "$FX_LEDGER" 7200
fx_heartbeat 0 7200
check "E1 픽스처 시계를 진행시켜도 바뀌지 않는다" "$(sl sess-e1)" "$before"

fx_mkrun run-e2-old; fx_ledger_path; fx_segment S1 머지됨; fx_heartbeat 0 5
fx_age_file "$FX_LEDGER" 7200
fx_mkrun run-e2-new; fx_ledger_path; fx_segment S1 머지됨; fx_heartbeat 0 5
fx_session_index sess-e2 run-e2-old run-e2-new
out=$(sl sess-e2)
has "E2 둘 다 종단 — 더 최근 쪽의 종료가 남는다" "$out" "✓ run-e2-new 종료"

# ---------------------------------------------------------------------------
# A1-A11. The six-rank grade, and the render for the bottom rank
# ---------------------------------------------------------------------------
#
# THE AXIS THESE CASES PIN IS EVIDENCE, NOT ABSENCE. Selection used to rank on
# "shows no sign of having finished", so a run that never opened a segment —
# which can satisfy neither the derived terminal test nor the `done` shortcut —
# was permanently non-terminal and permanently first. Every case below fixes one
# rank boundary or one tie-break inside a rank; recency is only ever allowed to
# decide between two runs of the SAME rank.

# A1. The repro's own shape: no segment row, no live stage, no approval, no
# `done`, and a ledger that stopped moving. It loses to a finished run. This
# takes a different arm from case 15 — `n_seg = 0` there, `nonterm > 0` here —
# so without it the zero-segment arm is the one the suite never walks.
fx_mkrun run-a1-orphan; fx_ledger_path
fx_age_file "$FX_LEDGER" 7200
fx_mkrun run-a1-term; fx_ledger_path; fx_segment S1 머지됨; fx_heartbeat 0 5
fx_session_index sess-a1 run-a1-orphan run-a1-term
out=$(sl sess-a1)
has "A1 세그먼트 0개에 원장이 멎은 런은 종단 런에게 진다" "$out" "run-a1-term"
hasnt "A1 그 런을 표시하지 않는다" "$out" "run-a1-orphan"

# A2. Three ranks in one session, indexed against the grade order, so a loop
# that picked on position rather than on rank would pick a different one.
fx_mkrun run-a2-live; fx_ledger_path; fx_stage_live S1; fx_heartbeat 0 5
fx_mkrun run-a2-term; fx_ledger_path; fx_segment S1 머지됨; fx_heartbeat 0 5
fx_mkrun run-a2-pend; fx_ledger_path; fx_approval A1 대기; fx_heartbeat 0 5
fx_session_index sess-a2 run-a2-live run-a2-term run-a2-pend
out=$(sl sess-a2)
has "A2 라이브 · 승인대기 · 종단 중 라이브가 선택된다" "$out" "run-a2-live"
hasnt "A2 종단을 표시하지 않는다" "$out" "run-a2-term"
hasnt "A2 승인대기를 표시하지 않는다" "$out" "run-a2-pend"

# A3. Rank beats recency. Case 15's non-terminal run has no live pid, so nothing
# until now asserted that a genuinely running stage outranks a MORE RECENT
# finish.
fx_mkrun run-a3-live; fx_ledger_path; fx_stage_live S1; fx_heartbeat 0 5
fx_age_file "$FX_LEDGER" 7200
fx_mkrun run-a3-term; fx_ledger_path; fx_segment S1 머지됨; fx_heartbeat 0 5
fx_session_index sess-a3 run-a3-live run-a3-term
out=$(sl sess-a3)
has "A3 라이브 스테이지가 더 최근의 종단 런을 이긴다" "$out" "run-a3-live"
hasnt "A3 더 최근이어도 종단을 표시하지 않는다" "$out" "run-a3-term"

# A4. Recency still decides INSIDE a rank. Case 16 already covers the terminal
# rank, so it is cited rather than re-derived; these are the two ranks it does
# not reach.
fx_mkrun run-a4-pend-old; fx_ledger_path; fx_approval A1 대기; fx_heartbeat 0 5
fx_age_file "$FX_LEDGER" 7200
fx_mkrun run-a4-pend-new; fx_ledger_path; fx_approval A1 대기; fx_heartbeat 0 5
fx_session_index sess-a4p run-a4-pend-old run-a4-pend-new
out=$(sl sess-a4p)
has "A4 승인대기 둘 중 더 최근" "$out" "run-a4-pend-new"
hasnt "A4 승인대기 둘 중 더 오래된 쪽은 아니다" "$out" "run-a4-pend-old"

fx_mkrun run-a4-live-old; fx_ledger_path; fx_stage_live S1; fx_heartbeat 0 5
fx_age_file "$FX_LEDGER" 7200
fx_mkrun run-a4-live-new; fx_ledger_path; fx_stage_live S1; fx_heartbeat 0 5
fx_session_index sess-a4l run-a4-live-old run-a4-live-new
out=$(sl sess-a4l)
has "A4 살아있음 둘 중 더 최근" "$out" "run-a4-live-new"
hasnt "A4 살아있음 둘 중 더 오래된 쪽은 아니다" "$out" "run-a4-live-old"

# A5. The refuted claim, guarded. A watcher beating every few seconds over a
# ledger that has not moved in over an hour was observed on this host with zero
# live stages and no `done` — so heartbeat freshness is not an input to the
# grade, and this run must lose to a finished one.
fx_mkrun run-a5-guard; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 4000
fx_mkrun run-a5-term; fx_ledger_path; fx_segment S1 머지됨; fx_heartbeat 0 5
fx_session_index sess-a5 run-a5-guard run-a5-term
out=$(sl sess-a5)
has "A5 신선한 하트비트 + 노후한 원장 성장 — 종단 런이 이긴다" "$out" "run-a5-term"
hasnt "A5 하트비트 신선도는 등급의 입력이 아니다" "$out" "run-a5-guard"

# A6. A3's other direction. An off-by-one in the rank numbers shows up in one of
# the two and not both.
fx_mkrun run-a6-pend; fx_ledger_path; fx_approval A1 대기; fx_heartbeat 0 5
fx_mkrun run-a6-live; fx_ledger_path; fx_stage_live S1; fx_heartbeat 0 5
fx_age_file "$FX_LEDGER" 7200
fx_session_index sess-a6 run-a6-pend run-a6-live
out=$(sl sess-a6)
has "A6 살아있음이 더 최근의 승인대기를 이긴다" "$out" "run-a6-live"
hasnt "A6 더 최근이어도 승인대기를 표시하지 않는다" "$out" "run-a6-pend"

# A7. Case 8a's sibling — the placement invariant's regression test. The 버려짐
# arms sit below the terminal block, so a finished run never becomes abandoned;
# put the other way round, the watcher's `= "종단"` compare would stop
# announcing finished runs.
fx_mkrun run-a7-aband; fx_ledger_path; fx_segment S1 실행중
fx_age_file "$FX_LEDGER" 7200
fx_mkrun run-a7-term; fx_ledger_path; fx_segment S1 머지됨; fx_heartbeat 0 5
fx_session_index sess-a7 run-a7-aband run-a7-term
out=$(sl sess-a7)
has "A7 종단이 버려짐보다 앞선다" "$out" "run-a7-term"
hasnt "A7 버려진 런을 표시하지 않는다" "$out" "run-a7-aband"

# And the render for that bottom rank, on a session where there is nothing to
# outrank — which is the half the ordering cannot reach at all. Measured on this
# host: 20 single-run sessions hold exactly one abandoned run.
fx_session_index sess-a7-solo run-a7-aband
out=$(sl sess-a7-solo)
has "A7 버려진 런 하나뿐인 세션 — 움직이지 않는 글리프" "$out" "⊘"
has "A7 버려진 런 — 방치로 읽힌다" "$out" "방치"
hasnt "A7 버려진 팔은 도는 글리프를 쓰지 않는다" "$out" "⟳"
hasnt "A7 버려진 팔에서는 워처 슬롯이 억제된다" "$out" "워처"
# NOT `emit_fallback`. Routing this arm there is byte-legal — those are the
# "this session has no run" bytes — so every other assertion in this suite would
# stay green while the line said the opposite of what it means.
if [ "$out" = "$FALLBACK" ]; then
  bad "A7 버려진 팔이 폴백으로 새지 않는다" "런 없음 줄과 바이트 동일"
else
  ok "A7 버려진 팔이 폴백으로 새지 않는다"
fi

fx_mkrun run-a7-blocked; fx_ledger_path; fx_segment S1 실행중
fx_blocked "픽스처 차단" 불명
fx_age_file "$FX_LEDGER" 7200
fx_session_index sess-a7-blocked run-a7-blocked
out=$(sl sess-a7-blocked)
has "A7 미해소 run 스코프 blocked 가 있는 버려진 런 — 같은 글리프" "$out" "⊘"
has "A7 그 런은 방치가 아니라 차단으로 읽힌다" "$out" "차단"
hasnt "A7 차단 줄에 방치가 함께 실리지 않는다" "$out" "방치"

# And the arm one step further down: a run with NO CLOCK AT ALL. Every 버려짐
# run above reaches that token the other way — A1, A5 and A7 all carry a
# `ledger-path` and an old-but-present ledger, so they enter through
# `idle ≥ abandon`. The arm that returns 버려짐 because NEITHER the heartbeat
# field NOR a ledger file exists is the one the design calls the strongest idle
# signal and the one whose own comment reads `EMPTY IS STILL A VERDICT`, and
# until now no assertion walked it: regress it or reorder it and every A7
# assertion above still passes. Measured on this host, 55 runs have no
# `ledger-path` at all, so this is not a corner.
#
# The last assertion is the observation that tells this arm apart from A7's.
# With no clock `age_slot` stays empty, so the line has no `· 원장 …` slot —
# a distinct render shape that nothing in this suite had ever seen.
fx_mkrun run-a7-noclock
fx_session_index sess-a7-noclock run-a7-noclock
out=$(sl sess-a7-noclock)
has   "A7 판정할 시계가 없는 런 — 같은 글리프" "$out" "⊘"
has   "A7 판정할 시계가 없는 런 — 방치로 읽힌다" "$out" "방치"
hasnt "A7 시계가 없으면 나이 슬롯이 통째로 빠진다" "$out" "원장"
# Worth more here than on A7's line, not less: with no age slot either, this
# line is one step CLOSER to the fallback bytes.
if [ "$out" = "$FALLBACK" ]; then
  bad "A7 시계 없는 팔이 폴백으로 새지 않는다" "런 없음 줄과 바이트 동일"
else
  ok "A7 시계 없는 팔이 폴백으로 새지 않는다"
fi

# A8. The fifth rank's whole reason for existing. Between two stages there is no
# live pid for an instant, and a literal four-rank grade drops that run to the
# bottom — handing the screen to a run that finished yesterday. The signal here
# is the LEDGER'S GROWTH, not the watcher's pulse, which is why A5 above does
# not cover this: A5's run is the one whose ledger is stale.
fx_mkrun run-a8-fresh; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 5
fx_age_file "$FX_LEDGER" 7200
fx_mkrun run-a8-term; fx_ledger_path; fx_segment S1 머지됨; fx_heartbeat 0 5
fx_session_index sess-a8 run-a8-fresh run-a8-term
out=$(sl sess-a8)
has "A8 신선 단이 더 최근의 종단 단을 이긴다" "$out" "run-a8-fresh"
hasnt "A8 더 최근이어도 종단을 표시하지 않는다" "$out" "run-a8-term"

# A9. And recency decides inside that new rank too.
fx_mkrun run-a9-old; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 5
fx_age_file "$FX_LEDGER" 1800
fx_mkrun run-a9-new; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 5
fx_session_index sess-a9 run-a9-old run-a9-new
out=$(sl sess-a9)
has "A9 신선 둘 중 더 최근" "$out" "run-a9-new"
hasnt "A9 신선 둘 중 더 오래된 쪽은 아니다" "$out" "run-a9-old"

# A10. The boundary itself. Idle exactly at the mark falls on the stall side,
# and the assertion survives a second boundary crossing between the fixture and
# the render because elapsing time only pushes idle further past the mark.
#
# THAT IS A SAFETY PROPERTY AND NOT A DISCRIMINATION ONE, and the difference is
# the known limit of this case. The fixture writes growth at `T − 180` and the
# predicate reads its own `now = T + δ`, so idle is `180 + δ` where δ counts the
# second boundaries crossed in between — and the moment idle is 181 this case
# tests "past the mark" rather than "at" it, which is exactly what it was
# written to pin. Measured over 200 dense repetitions: δ=1 about 10% of the time
# on the solo render and about 25% on the second one below, and two reviewers
# detected an inverted comparison in 15 of 16 runs. The decay is green-only, so
# it cannot make this suite flake — it quietly costs sensitivity instead, and
# more of it the slower the runner. Pinning the boundary by CONSTRUCTION means
# calling the predicate directly with a measured elapsed passed as the threshold
# argument, which needs this suite to `source` liveness.sh rather than copy it;
# the design put predicate-level tests in another slice, so that is a follow-up.
# Adding a 179 twin instead is the obvious move and is WRONG: at δ=1 its idle
# becomes 180, it goes red, and a quiet loss of sensitivity turns into a real
# flake.
fx_mkrun run-a10; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 180
fx_session_index sess-a10-solo run-a10
has "A10 원장 유휴가 정확히 stall — 정지 경고 쪽" "$(sl sess-a10-solo)" "⚠"

# AND THE SECOND BLOCK READS THE BOUNDARY'S OTHER SIDE. It used to assert that
# the run at the mark lost to a finished one; 정지경고 now outranks 종단, so it
# asserts the win instead. The discrimination is the glyph and the ABSENCE of the
# loser's id — `has … "run-a10"` would be satisfied by `run-a10-term`, which
# contains it, so the losing run would pass this case by winning it.
fx_mkrun run-a10-term; fx_ledger_path; fx_segment S1 머지됨; fx_heartbeat 0 5
fx_session_index sess-a10 run-a10 run-a10-term
out=$(sl sess-a10)
has "A10 경계의 정지경고 런이 종단 런을 이긴다" "$out" "⚠"
hasnt "A10 더 최근이어도 종단을 표시하지 않는다" "$out" "run-a10-term"

# A11. Issue 825's own shape, and the rank boundary A8 cannot reach. Between two
# stages the ledger goes quiet, and a gap longer than `CC_SL_STALL` is ordinary
# rather than a sign the run died — A8 measures INSIDE the mark (진행중), so the
# band this measures, past `CC_SL_STALL` and short of `CC_SL_ABANDON`, was the
# one no case walked. While 정지경고 ranked below 종단 a run in that band handed
# the line to a run that finished yesterday.
fx_mkrun run-a11-stall; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 900
fx_age_file "$FX_LEDGER" 7200
fx_mkrun run-a11-term; fx_ledger_path; fx_segment S1 머지됨; fx_heartbeat 0 5
fx_session_index sess-a11 run-a11-stall run-a11-term
out=$(sl sess-a11)
has   "A11 스테이지 사이에서 멎은 정지경고 런이 더 최근의 종단 런을 이긴다" "$out" "run-a11-stall"
hasnt "A11 더 최근이어도 종단을 표시하지 않는다" "$out" "run-a11-term"
has   "A11 그 런은 정지 경고 글리프로 렌더된다" "$out" "⚠"

# A12. Issue 723's shape. A run whose watcher died with an approval open held
# rank 2 however long its ledger had been quiet, so it hid every later run in
# the session. With no fresh heartbeat the approval stops counting toward the
# rank and the run goes on the idle ladder like any other quiet run.
fx_mkrun run-a12-dead; fx_ledger_path; fx_segment S1 실행중; fx_approval A1 대기
fx_heartbeat 4000 7200; fx_age_file "$FX_LEDGER" 7200
fx_mkrun run-a12-term; fx_ledger_path; fx_segment S1 머지됨; fx_heartbeat 0 5
fx_session_index sess-a12 run-a12-dead run-a12-term
out=$(sl sess-a12)
has   "A12 워처 없이 멎은 승인대기 런은 종단 런에게 진다" "$out" "run-a12-term"
hasnt "A12 그 승인대기 런을 표시하지 않는다" "$out" "run-a12-dead"

# Inside the stall band it ranks as 정지경고, so a run still moving beats it
# well before the abandon mark — the 19-minute shape the issue measured.
fx_mkrun run-a12-band; fx_ledger_path; fx_segment S1 실행중; fx_approval A1 대기
fx_heartbeat 4000 1140; fx_age_file "$FX_LEDGER" 1140
fx_mkrun run-a12-live; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 5
fx_session_index sess-a12b run-a12-band run-a12-live
out=$(sl sess-a12b)
has   "A12 워처 없는 승인대기 런이 원장이 움직이는 런에게 진다" "$out" "run-a12-live"
hasnt "A12 그 승인대기 런을 표시하지 않는다(정지 구간)" "$out" "run-a12-band"

# The other direction: a watcher still beating keeps an approval at rank 2 over
# a quiet ledger, because a person may answer it in the morning.
fx_mkrun run-a12-wait; fx_ledger_path; fx_segment S1 실행중; fx_approval A1 대기
fx_heartbeat 0 7200; fx_age_file "$FX_LEDGER" 7200
fx_mkrun run-a12-term2; fx_ledger_path; fx_segment S1 머지됨; fx_heartbeat 0 5
fx_session_index sess-a12c run-a12-wait run-a12-term2
out=$(sl sess-a12c)
has   "A12 워처가 살아 있는 승인대기 런은 원장이 오래 멎어도 종단 런을 이긴다" "$out" "run-a12-wait"
has   "A12 그 런은 승인 대기로 렌더된다" "$out" "⏸"

# And alone in its session the demoted run still renders as what it is.
fx_session_index sess-a12d run-a12-dead
has   "A12 홀로 남은 워처 없는 승인대기 런은 여전히 승인 대기로 렌더된다" "$(sl sess-a12d)" "⏸"

# ---------------------------------------------------------------------------
# P1-P4. The pane's field row
# ---------------------------------------------------------------------------
#
# THE ROW IS FOR THE PANE AND NOTHING ELSE. With the variable unset the status
# line still prints the one line it always did, so every case above keeps its
# meaning; with it set, the first line has to be the same bytes and the field
# row comes second. Both renders go through `strip_clock`, because the running
# arm's elapsed can tick between them.
slp() { fx_statusline_stdin "$1" | CC_SL_PANE_FIELDS=1 bash "$SL"; }
first_of() { printf '%s\n' "$1" | sed -n 1p; }
row_of()   { printf '%s\n' "$1" | sed -n 2p; }
fld()      { printf '%s\n' "$2" | cut -f"$1"; }
nlines()   { printf '%s\n' "$1" | grep -c ''; }

# P1. Every arm, and the watcher's four verdicts, on sessions built above.
for p in "sess-live:도는중:도는중:ok" "sess-7b:진행중:진행중:ok" \
         "sess-7a:정지경고:정지경고:ok" "sess-appr:승인대기:승인대기:ok" \
         "sess-8a:종단:종료:none" "sess-a7-solo:버려짐:방치:none" \
         "sess-a7-blocked:버려짐:차단:none" "sess-9:진행중:진행중:stale" \
         "sess-9c:진행중:진행중:unstarted"; do
  s=${p%%:*}; rest=${p#*:}; tok=${rest%%:*}; rest=${rest#*:}
  word=${rest%%:*}; verdict=${rest#*:}
  plain=$(sl "$s"); with=$(slp "$s")
  check "P1 $s — 변수가 없으면 한 줄" "$(nlines "$plain")" "1"
  check "P1 $s — 변수가 있으면 두 줄" "$(nlines "$with")" "2"
  check "P1 $s — 변수 유무와 상관없이 첫 줄이 같다" \
    "$(first_of "$with" | strip_clock)" "$(printf '%s\n' "$plain" | strip_clock)"
  r=$(row_of "$with")
  check "P1 $s — 필드 행은 아홉 칸" "$(printf '%s\n' "$r" | awk -F'\t' '{print NF}')" "9"
  check "P1 $s — 머리 두 칸" "$(fld 1 "$r") $(fld 2 "$r")" "cc-sl 1"
  check "P1 $s — 상태 토큰" "$(fld 4 "$r")" "$tok"
  check "P1 $s — 갈래 단어" "$(fld 5 "$r")" "$word"
  check "P1 $s — 워처 판정" "$(fld 9 "$r")" "$verdict"
  case "$(fld 6 "$r")" in
    ''|*[!0-9]*) bad "P1 $s — <now> 는 에포크 초" "'$(fld 6 "$r")'" ;;
    *) ok "P1 $s — <now> 는 에포크 초" ;;
  esac
  case "$(fld 3 "$r")" in
    run-*) ok "P1 $s — 런 id 칸" ;;
    *) bad "P1 $s — 런 id 칸" "'$(fld 3 "$r")'" ;;
  esac
done

# P2. No run: the field row is not invented, and the line stays the fallback.
out=$(slp sess-none)
check "P2 런 없음 — 변수가 있어도 한 줄" "$(nlines "$out")" "1"
check "P2 런 없음 — 폴백과 바이트 동일" "$out" "$FALLBACK"

# P3. `<hb>` is the heartbeat mtime the watcher verdict read, and `-` when there
# is no heartbeat at all. The expected value comes from the same function the
# script calls, so this pins the slot, not a second reading of the clock.
fx_mkrun run-p3; fx_ledger_path; fx_session_index sess-p3 run-p3
fx_segment S1 실행중
fx_heartbeat 30 5
want_hb=$( . "$LIVENESS"; cc_mtime "$FX_RUN_DIR/watch.heartbeat" )
r=$(row_of "$(slp sess-p3)")
check "P3 <hb> 는 watch.heartbeat 의 mtime" "$(fld 8 "$r")" "$want_hb"
check "P3 <grew> 는 하트비트의 마지막성장" "$(fld 7 "$r")" \
  "$(sed -n 's/.*마지막성장=\([0-9]*\).*/\1/p' "$FX_RUN_DIR/watch.heartbeat")"
r=$(row_of "$(slp sess-a7-noclock)")
check "P3 하트비트가 없으면 <hb> 는 -" "$(fld 8 "$r")" "-"

# ---------------------------------------------------------------------------
# K1-K3. The kind on the running arm comes from `cc_stage_kind`
# ---------------------------------------------------------------------------
#
# The gate leaves `<seg>.kind` beside a stage it launched, so the running row
# names what is running rather than what last finished. An empty record falls
# back to the ledger, and a ledger row that merely QUOTES a stage result — an
# autonomous approval's argv — is not one.
fx_mkrun run-k1; fx_ledger_path; fx_session_index sess-k1 run-k1
fx_segment B 실행중
fx_row 'stage-result' "세그먼트=B" "종류=review" "종료 코드=0"
fx_stage_live B
fx_stage_meta B implement 2
fx_heartbeat 0 5
out=$(sl sess-k1)
has   "K1 .kind 가 마지막 stage-result 와 다르면 .kind 를 쓴다" "$out" "B implement"
hasnt "K1 끝난 종류를 싣지 않는다" "$out" "review"
check "K1 공유 함수도 같은 종류" \
  "$( . "$LIVENESS"; cc_stage_kind "$FX_RUN_DIR" "$FX_LEDGER" B )" "implement"

fx_mkrun run-k2; fx_ledger_path; fx_session_index sess-k2 run-k2
fx_segment B 실행중
fx_row 'stage-result' "세그먼트=B" "종류=review" "종료 코드=0"
fx_stage_live B
fx_stage_meta B "" 2
fx_heartbeat 0 5
has "K2 빈 .kind 는 마지막 stage-result 의 종류로 내려간다" "$(sl sess-k2)" "B review"

fx_mkrun run-k3; fx_ledger_path; fx_session_index sess-k3 run-k3
fx_segment B 실행중
fx_row 'stage-result' "세그먼트=B" "종류=review" "종료 코드=0"
fx_row '자율 승인' "argv=- \`stage-result\` | 세그먼트=B | 종류=decoy" "등급=1"
fx_stage_live B
fx_heartbeat 0 5
out=$(sl sess-k3)
has   "K3 argv 에 stage-result 를 담은 자율 승인 행이 마지막이어도 진짜 행의 종류" "$out" "B review"
hasnt "K3 자율 승인 행의 미끼 종류를 싣지 않는다" "$out" "decoy"

# ---------------------------------------------------------------------------
# The branch the isolation cannot reach
# ---------------------------------------------------------------------------
if grep -qF '${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds' "$SL"; then
  ok "미설정 XDG_STATE_HOME 의 폴백 형태가 고정돼 있다 (픽스처가 태울 수 없는 경로)"
else
  bad "XDG_STATE_HOME 폴백" "관용구가 없다"
fi

# The pair pinned next to the definition is a shape typed by hand, and it stays
# true no matter what the renderer does. What it cannot see is the slot moving:
# a rendered line whose elapsed field is spelled differently, or dropped, leaves
# the scrubber matching nothing, and the comparisons below quietly go back to
# being decided by a clock. So the live render is required to actually lose
# something here.
sl_live_raw=$(sl sess-live)
if [ "$sl_live_raw" != "$(printf '%s\n' "$sl_live_raw" | strip_clock)" ]; then
  ok "실제 렌더에도 시계 슬롯이 실려 있다 (벗기기가 공회전이 아니다)"
else
  bad "시계 슬롯 대조" "'$sl_live_raw' 에서 벗겨지는 것이 없다 — 슬롯 형태가 바뀌었다"
fi

# ---------------------------------------------------------------------------
# F1-F2. The defensive command that gets installed
# ---------------------------------------------------------------------------
# THE EXECUTABLE BIT IS LOAD-BEARING and is not a packaging detail. The command
# that gets installed guards on `[ -x ]`, so a status line shipped without the
# bit makes that guard permanently false: every render takes the fallback, and
# on a machine that already had a status line nothing downstream notices.
# Losing the bit is silent everywhere except here.
if [ -x "$SL" ]; then ok "statusline.sh 에 실행 비트가 있다 (설치되는 가드가 -x 를 본다)"
else bad "statusline.sh 실행 비트" "가드가 영구히 거짓이 된다"; fi

mkdir -p "$WORK/absent"
f1_cmd="[ -x \"$SL\" ] && exec bash \"$SL\" || printf 'PRE-APPLY-LITERAL'"
f2_cmd="[ -x \"$WORK/absent/orchestrator/statusline.sh\" ] && exec bash \"$WORK/absent/orchestrator/statusline.sh\" || printf 'PRE-APPLY-LITERAL'"
check "F1 플러그인 경로가 실행 가능하면 그 스크립트가 불린다" \
  "$(fx_statusline_stdin sess-live | sh -c "$f1_cmd" | strip_clock)" \
  "$(sl sess-live | strip_clock)"
check "F2 플러그인 경로 부재 — 적용 전 리터럴과 바이트 동일" \
  "$(fx_statusline_stdin sess-live | sh -c "$f2_cmd")" "PRE-APPLY-LITERAL"

# ===========================================================================
# The apply path.
#
# A fixture settings file throughout — the real one is never touched.
# ===========================================================================

mk_settings() {
  # mk_settings <path> [command] — a settings file shaped like the real one:
  # several unrelated keys around the one this design owns.
  #
  # ITS VALUE IS FOREIGN UNDER THE PARK PREDICATE, AND IT STAYS THAT WAY. This
  # is the fixture every pre-write park case stands on, and it is the only thing
  # that separates "the four pre-write checks run BEFORE the value is
  # classified" from "they run after": on a writable fixture both orders pass.
  local p="$1" c="${2:-printf 'PRE-APPLY-LITERAL'}"
  jq -n --arg c "$c" \
    '{theme: "dark", model: "opus", statusLine: {type: "command", command: $c}, cleanupPeriodDays: 30}' \
    > "$p"
}

mk_settings_empty() {
  # mk_settings_empty <path> — the same unrelated keys, and NO `statusLine` key
  # at all. Classified empty; a successful apply against it is rc 10.
  jq -n '{theme: "dark", model: "opus", cleanupPeriodDays: 30}' > "$1"
}

mk_settings_ours() {
  # mk_settings_ours <path> [fallback] — a guarded wrapper aimed at an OLDER
  # plugin path, with a named fallback behind it. Classified ours; a successful
  # apply against it is rc 11, and the fallback has to survive the re-point.
  local p="$1" fb="${2:-printf 'USER-CMD'}"
  jq -n --arg c "[ -x \"$OLDSL\" ] && exec bash \"$OLDSL\" || $fb" \
    '{theme: "dark", model: "opus", statusLine: {type: "command", command: $c}, cleanupPeriodDays: 30}' \
    > "$p"
}

mk_fake_plugin() {
  # mk_fake_plugin <dir> <printf-format> — a plugin tree whose status line emits
  # exactly the given bytes. The shared grammar file goes in too: the installer
  # sources it out of `--plugin-dir`.
  local d="$1" fmt="$2"
  mkdir -p "$d/orchestrator"
  cp "$CMDLIB" "$APPLY" "$d/orchestrator/"
  printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf %s\n' "'$fmt'" \
    > "$d/orchestrator/statusline.sh"
  chmod +x "$d/orchestrator/statusline.sh"
}

sha_of()   { shasum -a 256 "$1" | cut -d' ' -f1; }
mtime_of() { perl -e 'print((stat($ARGV[0]))[9])' "$1" 2>/dev/null; }
cmd_of()   { jq -r '.statusLine.command' "$1" 2>/dev/null; }
nglob()    { ls -d "$@" 2>/dev/null | grep -c . || true; }

apply() {
  # apply <settings> <plugin-dir> <require-state> — run the installer and echo
  # its exit code. `2>/dev/null`, NOT `2>&1`: the diagnostics belong on stderr
  # and the cases that assert an empty stdout would otherwise be asserting an
  # empty stderr as well, which would break every case that reads a park reason.
  local s="$1" p="$2" st="$3"
  bash "$APPLY" --apply --settings "$s" --plugin-dir "$p" --require-state "$st" >/dev/null 2>/dev/null
  printf '%s' "$?"
}

probe() {
  local s="$1" p="$2"
  bash "$APPLY" --probe --settings "$s" --plugin-dir "$p" >/dev/null 2>/dev/null
  printf '%s' "$?"
}

drift() {
  # drift <settings> — re-aim the installed wrapper at an older plugin path so
  # the next apply owes a real write. This is the shape a marketplace update
  # leaves behind.
  local s="$1" tmp="$1.drift"
  jq --arg c "[ -x \"$OLDSL\" ] && exec bash \"$OLDSL\" || $(cmd_of "$s" | sed 's/.*|| //')" \
    '.statusLine.command = $c' "$s" > "$tmp" && mv "$tmp" "$s"
}

# ---------------------------------------------------------------------------
# A — the first install, and the argument contract
# ---------------------------------------------------------------------------
A1="$WORK/a1.json"; mk_settings_empty "$A1"
A1_PRE=$(sha_of "$A1")
out=$(bash "$APPLY" --apply --settings "$A1" --plugin-dir "$APLUG" --require-state empty 2>/dev/null); rc=$?
check "A1 statusLine 키 부재 — 최초 설치로 진행한다" "$rc" "10"
check "A8 성공 종단의 stdout 이 정확히 0바이트다" "$(printf '%s' "$out" | wc -c | tr -d ' ')" "0"
has "A3 설치된 명령이 방어적 가드다" "$(cmd_of "$A1")" "[ -x \"$APLUG/orchestrator/statusline.sh\" ]"
has "A4 exec bash 이지 exec <경로> 가 아니다" "$(cmd_of "$A1")" "exec bash \"$APLUG/orchestrator/statusline.sh\""
has "A5 상태줄이 없던 기기의 폴백은 true 다" "$(cmd_of "$A1")" "|| true"
check "A2 무관한 키가 보존된다" "$(jq -r '.theme + "/" + .model' "$A1")" "dark/opus"
check "A2b 키 수가 늘지 않는다" "$(jq -r '[keys[]] | length' "$A1")" "4"

# A8b. THE DISK, NOT THE STDOUT. The two assertions this replaces read a merged
# capture for a substring, so they stayed green for a script that printed
# `백업:` and made no backup at all, and they would have stayed green for one
# that merely moved the same four lines to stderr.
if [ -s "$A1.orig" ]; then ok "A8b 첫 쓰기 스냅숏 슬롯이 대상 파일 옆에 있고 비어 있지 않다"
else bad "A8b 첫 쓰기 스냅숏 슬롯" "$A1.orig 이 없거나 0바이트다"; fi
differ "A8b 설정 파일의 바이트가 실제로 바뀌었다" "$(sha_of "$A1")" "$A1_PRE"
check "A8b 첫 쓰기 스냅숏은 쓰기 이전 바이트를 담는다" "$(sha_of "$A1.orig")" "$A1_PRE"

# The three other shapes of "empty".
for shape in null:'.statusLine = null' emptyobj:'.statusLine = {}' \
             blankcmd:'.statusLine = {type:"command", command:"   "}' \
             nullcmd:'.statusLine = {type:"command", command:null}'; do
  tag=${shape%%:*}; prog=${shape#*:}
  f="$WORK/a1-$tag.json"; mk_settings_empty "$f"
  jq "$prog" "$f" > "$f.t" && mv "$f.t" "$f"
  check "A1 빈 상태의 변형 ($tag) — park 하지 않고 진행한다" "$(apply "$f" "$APLUG" empty)" "10"
done

# A2c. THE POSITIVE HALF STANDS ON A FIXTURE THAT IS ACTUALLY WRITABLE. Left on
# the shared foreign fixture this case parks, and an assertion named "the value
# is installed" that parks is green for the wrong reason.
A2C="$WORK/a2c.json"; mk_settings_empty "$A2C"
check "A2c WRITABLE 픽스처 위에서 값이 그대로 설치된다" "$(apply "$A2C" "$APLUG" empty)" "10"
check "A12 --require-state empty 를 EMPTY 픽스처에 주면 진행한다" "$(cmd_of "$A2C" | grep -c 'exec bash')" "1"

# A2b's negative half. "The unrelated keys are preserved" and "the key count did
# not grow" are both satisfied by an apply that did nothing at all, so each owes
# a park-side reading that separates "the write preserved them" from "there was
# no write".
A2N="$WORK/a2n.json"; mk_settings "$A2N"
check "A2 음성 짝 — park 실행 뒤에도 같은 두 키" "$(apply "$A2N" "$APLUG" empty)" "20"
check "A2 음성 짝 — park 은 무관한 키를 보존하지만 쓰지도 않는다" "$(jq -r '.theme + "/" + .model' "$A2N")" "dark/opus"
check "A2b 음성 짝 — park 실행 뒤 키 수도 그대로" "$(jq -r '[keys[]] | length' "$A2N")" "4"

# A2c-b. The assertion that used to cover three cases covers two: the third is
# now an argument rejection rather than a park, and it has its own case.
A2CB="$WORK/a2cb.json"; mk_settings "$A2CB"; B=$(sha_of "$A2CB")
check "A2c-b 빈 --plugin-dir 은 쓰기 전에 park 한다" "$(apply "$A2CB" "" empty)" "26"
check "A2c-b 상대경로 --plugin-dir 은 쓰기 전에 park 한다" "$(apply "$A2CB" "relative/path" empty)" "26"
check "A2c-b park 한 두 경우 모두 파일을 건드리지 않았다" "$(sha_of "$A2CB")" "$B"

# A9. STRUCTURE, BECAUSE BEHAVIOUR ONLY SEES THE PATHS IT WALKS. `--apply`
# landing with an empty stdout says nothing about a code path this suite has not
# reached, and the whole point of deleting the four success lines is that the
# installer's legal stdout is now the empty string and nothing else.
a9_hits=$(grep -vE '^[[:space:]]*#' "$APPLY" | grep -nE 'printf|echo' | grep -vc '>&2' || true)
check "A9 설치기 안에 >&2 로 리디렉션되지 않은 배출이 0 건이다 (구조)" "$a9_hits" "0"

# A10. STRUCTURE ONLY, AND DELIBERATELY SO. Burning this guard behaviourally
# needs a `--settings` with no slash in it, which the absolute-path requirement
# rejects at the argument parser — so the only way to write that case is to
# weaken the requirement, which is the very change this guard exists to survive.
if grep -qF 'DIR="${SETTINGS%/*}"' "$APPLY" \
   && grep -qE '^[[:space:]]*if \[ -n "\$DIR" \] && \[ "\$DIR" != "\$SETTINGS" \]; then' "$APPLY" \
   && grep -qE '^[[:space:]]*mkdir -p "\$DIR"' "$APPLY"; then
  ok "A10 설정 디렉터리 생성이 두 조건 가드 안에 있다 (구조)"
else
  bad "A10 설정 디렉터리 가드" "무가드 mkdir -p 는 설정 파일 자리에 디렉터리를 만들고 rc 0 으로 끝난다"
fi

# A11. The flag is gone from the tree, and passing it is refused. The structural
# half is what makes the deletion real: a `case` arm left in place with only the
# required-ness check removed would pass the behavioural half.
#
# THE SCAN IS THE FILES THAT TALK TO THE INSTALLER. Other tools in the tree own
# flags of the same spelling (`--expect-sha256`, a tree-hash `--expect`) that
# have nothing to do with this one, so the scan is every file outside this suite
# that names the installer, and the flag is matched as a whole word.
a11_tree=0
for f in $(grep -rlF -- 'apply-statusline' "$repo_root/plugins" "$repo_root/scripts" "$repo_root/Makefile" 2>/dev/null); do
  [ "$f" = "$script_dir/test-statusline.sh" ] && continue
  grep -qE -- '--expect([^-A-Za-z0-9_]|$)' "$f" && a11_tree=$((a11_tree + 1))
done
check "A11 --expect 가 설치기와 그 호출자들에서 0 건이다 (구조)" "$a11_tree" "0"
A11="$WORK/a11.json"; mk_settings_empty "$A11"
bash "$APPLY" --apply --settings "$A11" --plugin-dir "$APLUG" --expect deadbeef >/dev/null 2>/dev/null
check "A11 --expect 를 넘기면 알 수 없는 인자로 거절한다" "$?" "1"

# ---------------------------------------------------------------------------
# B — park
# ---------------------------------------------------------------------------
B1="$WORK/b1.json"; mk_settings "$B1"; B1S=$(sha_of "$B1")
check "B1 제삼자 값에 park 한다" "$(apply "$B1" "$APLUG" empty)" "20"
check "B1 park 뒤 파일이 바이트 동일" "$(sha_of "$B1")" "$B1S"
check "B2 park 에서는 refreshInterval 이 생기지 않는다" "$(jq -r '.statusLine | has("refreshInterval")' "$B1")" "false"
check "B2 park 에서는 설치 이력도 남지 않는다" "$([ -e "$B1.cc-statusline-owned" ] && printf y || printf n)" "n"
check "B3 프로브 — 제삼자 값이면 1(park)" "$(probe "$B1" "$APLUG")" "1"

# B4. THE REVERSE-MIXED WRAPPER — the guard tests OUR path while the exec target
# is somebody else's binary. Dropping the "both P are the same" conjunct accepts
# exactly this value and nothing else, so this case alone holds that conjunct in
# place; a starship-shaped value parks either way.
B4="$WORK/b4.json"
mk_settings "$B4" "[ -x \"$OLDSL\" ] && exec bash \"/usr/local/bin/starship\" || true"
B4S=$(sha_of "$B4")
check "B4 역혼합 래퍼는 우리 것으로 오인되지 않는다" "$(apply "$B4" "$APLUG" ours)" "20"
check "B4 역혼합 래퍼 — 파일이 바이트 동일" "$(sha_of "$B4")" "$B4S"

B5="$WORK/b5.json"
mk_settings "$B5" "[ -x \"/usr/local/bin/starship\" ] && exec bash \"/usr/local/bin/starship\" || true"
check "B5 두 자리 모두 제삼자인 값도 park 한다" "$(apply "$B5" "$APLUG" empty)" "20"

# B6. THE FOUR PRE-WRITE CHECKS RUN BEFORE THE VALUE IS CLASSIFIED, and this is
# the only case that can tell. The fixture is FOREIGN, so if the order were
# reversed every one of these would answer 20 instead of its own code. Reading
# "it parked" would not separate them; reading WHICH REASON does.
mkdir -p "$WORK/b6-partial/orchestrator"
mkdir -p "$WORK/b6-nobit/orchestrator"
cp "$SL" "$LIVENESS" "$CMDLIB" "$APPLY" "$WORK/b6-nobit/orchestrator/"
chmod -x "$WORK/b6-nobit/orchestrator/statusline.sh"
mkdir -p "$WORK/b6-reeval/plug\$d/orchestrator"
cp "$SL" "$LIVENESS" "$CMDLIB" "$APPLY" "$WORK/b6-reeval/plug\$d/orchestrator/"
chmod +x "$WORK/b6-reeval/plug\$d/orchestrator/statusline.sh"
B6="$WORK/b6.json"; mk_settings "$B6"; B6S=$(sha_of "$B6")
for shape in "empty::26" "relative/x::26" "$APLUG/::26" "$WORK/b6-missing::24" \
             "$WORK/b6-partial::24" "$WORK/b6-nobit::24" "$WORK/b6-reeval/plug\$d::25"; do
  dir=${shape%::*}; want=${shape##*::}
  [ "$dir" = "empty" ] && dir=""
  got=$(apply "$B6" "$dir" empty)
  check "B6 사전 park 가 값 분류보다 먼저다 ($want: ${dir:-빈 값})" "$got" "$want"
  differ "B6 그 park 는 foreign 코드가 아니다 (${dir:-빈 값})" "$got" "20"
done
check "B6 일곱 모양 모두 파일을 건드리지 않았다" "$(sha_of "$B6")" "$B6S"

# B7. The window between the hook's classification and the installer's snapshot.
B7="$WORK/b7.json"; mk_settings_empty "$B7"; B7S=$(sha_of "$B7"); B7M=$(mtime_of "$B7")
check "B7 넘긴 상태와 스냅숏 분류가 어긋나면 park 한다" "$(apply "$B7" "$APLUG" ours)" "21"
check "B7 상태 불일치 park — 바이트가 그대로다" "$(sha_of "$B7")" "$B7S"
check "B7 상태 불일치 park — mtime 도 그대로다" "$(mtime_of "$B7")" "$B7M"
check "B7 상태 불일치 park — 소유 비트가 생기지 않는다" "$([ -e "$B7.cc-statusline-owned" ] && printf y || printf n)" "n"

# B8. A trailing slash still resolves to the same directory, so every other
# check passes it. Only this case catches an installer that quietly normalises.
B8="$WORK/b8.json"; mk_settings_empty "$B8"
check "B8 --plugin-dir 에 후행 슬래시가 남아 있으면 park 한다" "$(apply "$B8" "$APLUG/" empty)" "26"
check "B8 후행 슬래시 park — 아무것도 쓰지 않았다" "$(jq -r 'has("statusLine")' "$B8")" "false"

# ---------------------------------------------------------------------------
# C — convergence, idempotence and the sibling files
# ---------------------------------------------------------------------------
C1="$WORK/c1.json"; mk_settings_empty "$C1"
check "C1 최초 설치" "$(apply "$C1" "$APLUG" empty)" "10"
C1S=$(sha_of "$C1"); C1PREV=$(sha_of "$C1.prev"); C1PREVM=$(mtime_of "$C1.prev")
check "C1 재적용은 수렴이고 쓰지 않는다" "$(apply "$C1" "$APLUG" ours)" "0"
check "C1 재적용해도 파일이 바이트 동일" "$(sha_of "$C1")" "$C1S"
check "C2 수렴한 재적용은 직전 스냅숏 슬롯의 내용을 바꾸지 않는다" "$(sha_of "$C1.prev")" "$C1PREV"
check "C2 수렴한 재적용은 직전 스냅숏 슬롯의 mtime 도 바꾸지 않는다" "$(mtime_of "$C1.prev")" "$C1PREVM"
check "C1 재적용 뒤에도 exec bash 가 한 번뿐이다" "$(cmd_of "$C1" | grep -c 'exec bash')" "1"

C3="$WORK/c3.json"; mk_settings_empty "$C3"
jq '.statusLine = {type:"command", command:"", refreshInterval: 5}' "$C3" > "$C3.t" && mv "$C3.t" "$C3"
check "C3 기존 refreshInterval 이 있는 빈 명령 — 설치된다" "$(apply "$C3" "$APLUG" empty)" "10"
check "C3 기존 refreshInterval 값이 그대로다" "$(jq -r '.statusLine.refreshInterval' "$C3")" "5"

# C4. FOUR PARTS, NOT ONE NUMBER. "no more than four siblings" was green while
# seeing none of (b), (c) or (d): a leaked temporary, a stale lock directory and
# a deleted legacy backup all passed it.
C4="$WORK/c4.json"; mk_settings_empty "$C4"
: > "$C4.pre-statusline-1700000000"
: > "$C4.pre-statusline-1700000001"
printf 'legacy-a' > "$C4.pre-statusline-1700000000"
printf 'legacy-b' > "$C4.pre-statusline-1700000001"
C4LEG=$(sha_of "$C4.pre-statusline-1700000000")$(sha_of "$C4.pre-statusline-1700000001")
C4LEGM=$(mtime_of "$C4.pre-statusline-1700000000")
check "C4 12회 실쓰기 — 첫 설치" "$(apply "$C4" "$APLUG" empty)" "10"
i=1
while [ "$i" -lt 12 ]; do
  drift "$C4"
  check "C4 12회 실쓰기 — 재지정 $i" "$(apply "$C4" "$APLUG" ours)" "11"
  i=$((i + 1))
done
c4_persist=0
for name in "$C4.cc-statusline" "$C4.cc-statusline-owned" "$C4.orig" "$C4.prev"; do
  [ -e "$name" ] && c4_persist=$((c4_persist + 1))
done
check "C4 (a) 이 설계의 영속 산출물은 정확히 넷 중 설치기 몫 셋이다" "$c4_persist" "3"
check "C4 (b) 임시 산출물이 0개다" "$(nglob "$C4".cc-statusline.tmp.* "$C4".cc-statusline.bak-tmp.* "$C4".cc-statusline.mk-tmp.*)" "0"
check "C4 (c) 락 디렉터리가 남지 않았다" "$([ -d "$C4.cc-statusline.lock" ] && printf y || printf n)" "n"
check "C4 (d) 레거시 접두 백업의 개수가 변하지 않았다" "$(nglob "$C4".pre-statusline-*)" "2"

# C5. The legacy backups are untouched in BOTH directions. Counting alone passes
# an implementation that deletes and recreates them; a structural grep alone
# passes one that assembles the name indirectly.
check "C5 (구조) 레거시 접두가 파일명을 조립하는 자리에 0 건이다" \
  "$(grep -c 'pre-statusline-' "$APPLY" || true)" "0"
check "C5 (구조) 레거시 접두가 rm·unlink·mv 의 대상으로도 0 건이다" \
  "$(grep -E '(rm|unlink|mv)[^\n]*pre-statusline' "$APPLY" | grep -c . || true)" "0"
check "C5 (행동) 12회 쓰기 뒤 레거시 백업의 바이트가 그대로다" \
  "$(sha_of "$C4.pre-statusline-1700000000")$(sha_of "$C4.pre-statusline-1700000001")" "$C4LEG"
check "C5 (행동) 12회 쓰기 뒤 레거시 백업의 mtime 도 그대로다" \
  "$(mtime_of "$C4.pre-statusline-1700000000")" "$C4LEGM"

# C4b. WHAT A KILLED RUN LEAVES BEHIND MUST BE COVERED BY THE CLEANUP THIS
# DESIGN PUBLISHES. Two lines are published — `rmdir` on the lock first, then
# `rm -f` over the `…cc-statusline*` glob — plus the two backup names, which are
# recovery snapshots and deliberately outside that glob.
C4B="$WORK/c4b.json"; mk_settings_empty "$C4B"
apply "$C4B" "$APLUG" empty >/dev/null
i=0
while [ "$i" -lt 20 ]; do
  drift "$C4B"
  bash "$APPLY" --apply --settings "$C4B" --plugin-dir "$APLUG" --require-state ours >/dev/null 2>/dev/null &
  kp=$!
  kill -9 "$kp" 2>/dev/null
  wait "$kp" 2>/dev/null
  i=$((i + 1))
done
c4b_uncovered=0
for f in "$WORK"/c4b.json*; do
  base=${f##*/}
  case "$base" in
    c4b.json|c4b.json.cc-statusline*|c4b.json.orig|c4b.json.prev) ;;
    *) c4b_uncovered=$((c4b_uncovered + 1)); printf '  c4b: 계약 밖 이름 %s\n' "$base" >&2 ;;
  esac
done
check "C4b SIGKILL 잔재 중 발행된 정리 절차에 잡히지 않는 이름이 0 개다" "$c4b_uncovered" "0"
rmdir "$C4B.cc-statusline.lock" 2>/dev/null
rm -f "$C4B".cc-statusline.tmp.* "$C4B".cc-statusline.bak-tmp.* 2>/dev/null

# ---------------------------------------------------------------------------
# D — refreshInterval
# ---------------------------------------------------------------------------
D1="$WORK/d1.json"; mk_settings_empty "$D1"
apply "$D1" "$APLUG" empty >/dev/null
check "D1 키가 없으면 10 이 들어간다" "$(jq -r '.statusLine.refreshInterval' "$D1")" "10"

D2="$WORK/d2.json"; mk_settings_ours "$D2"
jq '.statusLine.refreshInterval = 5' "$D2" > "$D2.t" && mv "$D2.t" "$D2"
apply "$D2" "$APLUG" ours >/dev/null
check "D2 기존 값 5 는 보존된다" "$(jq -r '.statusLine.refreshInterval' "$D2")" "5"

# `//=` and `// 10` both overwrite this one, and both look right everywhere else.
D3="$WORK/d3.json"; mk_settings_ours "$D3"
jq '.statusLine.refreshInterval = 0' "$D3" > "$D3.t" && mv "$D3.t" "$D3"
apply "$D3" "$APLUG" ours >/dev/null
check "D3 명시적 0 도 「존재」로 보존된다" "$(jq -r '.statusLine.refreshInterval' "$D3")" "0"

D4="$WORK/d4.json"; mk_settings_empty "$D4"
jq '.statusLine = {type:"command", command:"", padding: 1, hideVimModeIndicator: true}' "$D4" > "$D4.t" && mv "$D4.t" "$D4"
apply "$D4" "$APLUG" empty >/dev/null
check "D4 statusLine 안의 형제 키가 보존된다" \
  "$(jq -r '(.statusLine.padding|tostring) + "/" + (.statusLine.hideVimModeIndicator|tostring)' "$D4")" "1/true"

# ---------------------------------------------------------------------------
# E — nesting
# ---------------------------------------------------------------------------
E1="$WORK/e1.json"; mk_settings_ours "$E1"
apply "$E1" "$APLUG" ours >/dev/null
check "E1 경로 갱신 후 exec bash 가 정확히 한 번" "$(cmd_of "$E1" | grep -c 'exec bash')" "1"
has "E2 폴백이 옛 래퍼가 아니라 사용자의 원래 명령이다" "$(cmd_of "$E1")" "|| printf 'USER-CMD'"
drift "$E1"
apply "$E1" "$APLUG" ours >/dev/null
check "E3 연속 두 번 갱신에도 한 겹이다" "$(cmd_of "$E1" | grep -c 'exec bash')" "1"

nest_value() {
  # nest_value <depth> — a value nested <depth> times over the user's command.
  local d="$1" v="printf 'USER-CMD'" i=0
  while [ "$i" -lt "$d" ]; do
    v="[ -x \"$OLDSL\" ] && exec bash \"$OLDSL\" || $v"
    i=$((i + 1))
  done
  printf '%s' "$v"
}

for depth in 2 3; do
  f="$WORK/e-$depth.json"; mk_settings "$f" "$(nest_value "$depth")"
  apply "$f" "$APLUG" ours >/dev/null
  check "E4~E5 ${depth}중 중첩에서 시작해도 한 겹으로 접힌다" "$(cmd_of "$f" | grep -c 'exec bash')" "1"
  has "E4~E5 ${depth}중 중첩 — 사용자 명령이 폴백으로 회수된다" "$(cmd_of "$f")" "|| printf 'USER-CMD'"
done

E6A="$WORK/e6a.json"; mk_settings "$E6A" "$(nest_value 8)"
apply "$E6A" "$APLUG" ours >/dev/null
check "E6 상한 8 에서는 완전히 붕괴한다" "$(cmd_of "$E6A" | grep -c 'exec bash')" "1"
E6B="$WORK/e6b.json"; mk_settings "$E6B" "$(nest_value 9)"
apply "$E6B" "$APLUG" ours >/dev/null
n=$(cmd_of "$E6B" | grep -o 'exec bash' | grep -c . || true)
if [ "$n" -ge 2 ]; then ok "E6 9단에서는 남은 꼬리가 그대로 폴백이 된다 (수용된 결과)"
else bad "E6 9단 중첩" "exec bash 가 $n 개 — 상한에서 park 하거나 꼬리를 잃었다"; fi

E7="$WORK/e7.json"; mk_settings_empty "$E7"
apply "$E7" "$APLUG" empty >/dev/null
e7_len=$(cmd_of "$E7" | wc -c | tr -d ' ')
i=0
while [ "$i" -lt 5 ]; do
  drift "$E7"
  apply "$E7" "$APLUG" ours >/dev/null
  i=$((i + 1))
done
check "E7 5회 연속 드리프트에도 명령 길이가 증가하지 않는다" "$(cmd_of "$E7" | wc -c | tr -d ' ')" "$e7_len"

# ---------------------------------------------------------------------------
# F — the front gate
#
# The gate lives in the hook, and it is read here through an isolated-sourcing
# seam: the region between two marker comments is extracted and sourced on its
# own, so what these cases exercise is the code itself rather than a copy of it.
# The precedent is `scripts/test-liveness-agreement.sh`, which pulls functions
# out of `gate.sh` the same way.
# ---------------------------------------------------------------------------
GATE_BEGIN='# >>> cc-statusline gate region begin'
GATE_END='# <<< cc-statusline gate region end'
GATE_REGION="$WORK/gate-region.sh"
awk -v b="$GATE_BEGIN" -v e="$GATE_END" \
  '$0 == b {inr = 1; next} $0 == e {inr = 0} inr {print}' "$HOOK" > "$GATE_REGION" 2>/dev/null

if [ ! -s "$GATE_REGION" ]; then
  bad "F 앞단 게이트 격리 소싱" "$HOOK 에서 게이트 영역을 뽑을 수 없다 (마커 주석 부재)"
else
  gate_verdict() {
    # gate_verdict <plugin-dir> <config-dir> — the gate's own return code, run
    # with nothing else of the hook around it. An early `exit 0` inside the
    # region ends the subshell, and the empty answer that leaves is observable.
    (
      CLAUDE_CONFIG_DIR="$2"
      export CLAUDE_CONFIG_DIR
      set -uo pipefail
      # shellcheck disable=SC1090
      . "$GATE_REGION" --plugin-dir "$1"
      sl_gate_converged
      printf '%s' "$?"
    ) 2>/dev/null
  }

  # A converged machine: marker present, settings older than it, path and length
  # both agreeing.
  FCFG="$WORK/fcfg"; mkdir -p "$FCFG"
  FSET="$FCFG/settings.json"; mk_settings_empty "$FSET"
  apply "$FSET" "$APLUG" empty >/dev/null
  flen=$(wc -c < "$FSET" | tr -d ' ')
  printf 'schema=1|path=%s/orchestrator/statusline.sh|len=%s|lastAt=0|verdict=installed|reason=|\n' \
    "$APLUG" "$flen" > "$FSET.cc-statusline"
  fx_age_file "$FSET" 5

  check "F10 네 조건이 전부 참일 때만 건너뛴다" "$(gate_verdict "$APLUG" "$FCFG")" "0"

  mv "$FSET.cc-statusline" "$WORK/f-marker.bak"
  check "F6 조건 1 — 마커 부재면 느린 경로" "$(gate_verdict "$APLUG" "$FCFG")" "1"
  mv "$WORK/f-marker.bak" "$FSET.cc-statusline"

  fx_age_file "$FSET.cc-statusline" 5
  touch "$FSET"
  check "F7 조건 2 — 마지막 판정 뒤 설정이 건드려졌으면 느린 경로" "$(gate_verdict "$APLUG" "$FCFG")" "1"
  fx_age_file "$FSET" 5

  check "F8 조건 3 — 플러그인 경로가 움직였으면 느린 경로" "$(gate_verdict "$WORK/moved-plugin" "$FCFG")" "1"

  printf 'schema=1|path=%s/orchestrator/statusline.sh|len=999999|lastAt=0|verdict=installed|reason=|\n' \
    "$APLUG" > "$FSET.cc-statusline"
  fx_age_file "$FSET.cc-statusline" 0
  fx_age_file "$FSET" 5
  check "F9 조건 4 — 같은 초 안의 길이 변경이면 느린 경로" "$(gate_verdict "$APLUG" "$FCFG")" "1"

  # F4. THE FORK COUNT IS A STRUCTURAL ASSERTION, and it covers the PROLOGUE as
  # well as the gate body — the derivation of the target path runs on every
  # startup too, so a command substitution there costs the dominant path a fork
  # while every behavioural case stays green.
  #
  # Membership is decided by asking the shell, not by an enumeration: a word is
  # allowed when `type -t` calls it a builtin or a reserved word, or when the
  # region itself defines it as a function. An enumeration would go stale the
  # first time the prologue grew a line.
  f4_subst=$( { grep -cE '\$\(|`' "$GATE_REGION" || true; } )
  check "F4 격리 영역에 명령 치환과 백틱이 0 건이다 (구조)" "$f4_subst" "0"

  region_funcs=$(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$GATE_REGION" | sed 's/()$//' | tr '\n' ' ')
  f4_external=0
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    case " $region_funcs " in *" $w "*) continue ;; esac
    t=$(type -t "$w" 2>/dev/null)
    case "$t" in
      builtin|keyword) ;;
      *) f4_external=$((f4_external + 1)); printf '  F4: 빌트인이 아닌 명령어 %s (%s)\n' "$w" "${t:-미정의}" >&2 ;;
    esac
  done <<EOF
$(awk '
  {
    line = $0
    if (line ~ /^[[:space:]]*#/) next
    out = ""; q = ""; n = length(line)
    for (i = 1; i <= n; i++) {
      c = substr(line, i, 1)
      if (q != "") { if (c == q) q = ""; out = out "x"; continue }
      if (c == "\"" || c == "\047") { q = c; out = out "x"; continue }
      out = out c
    }
    gsub(/&&|\|\||\|/, "\n", out)
    gsub(/;;|;/, "\n", out)
    m = split(out, parts, "\n")
    for (j = 1; j <= m; j++) {
      w = parts[j]
      gsub(/^[[:space:]]+/, "", w)
      gsub(/[[:space:]]+$/, "", w)
      if (w == "") continue
      k = split(w, f, /[[:space:]]+/)
      idx = 1
      while (idx <= k && f[idx] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) idx++
      if (idx > k) continue
      first = f[idx]
      if (first ~ /\)$/) continue
      if (first ~ /\(\)$/) continue
      print first
    }
  }' "$GATE_REGION")
EOF
  check "F4 격리 영역의 모든 명령어가 빌트인이거나 예약어다 (구조)" "$f4_external" "0"

  # F11. The positive half of the same property: the length is taken with the
  # builtin form rather than with a process.
  if grep -qF '${#buf}' "$GATE_REGION"; then
    ok "F11 길이 계산이 빌트인 경로다 (구조)"
  else
    bad "F11 길이 계산" "\${#buf} 형태가 격리 영역에 없다"
  fi

  # F2/F3. NOT "IT DECIDED TO SKIP" BUT "HAVING SKIPPED, IT DID NOTHING". The
  # architecture's axiom that the gate only ever exits early does not stand in
  # for these: a gate that skipped and still took the lock would satisfy the
  # axiom and fail here.
  F23CFG="$WORK/f23cfg"; mkdir -p "$F23CFG"
  F23SET="$F23CFG/settings.json"; mk_settings_empty "$F23SET"
  CLAUDE_CONFIG_DIR="$F23CFG" bash "$HOOK" --plugin-dir "$APLUG" >/dev/null 2>/dev/null
  f23_sha=$(sha_of "$F23SET"); f23_mtime=$(mtime_of "$F23SET")
  CLAUDE_CONFIG_DIR="$F23CFG" bash "$HOOK" --plugin-dir "$APLUG" >/dev/null 2>/dev/null
  check "F2 수렴한 기동은 설정 파일에 쓰지 않는다" "$(sha_of "$F23SET")" "$f23_sha"
  check "F2 수렴한 기동은 설정 파일의 mtime 도 건드리지 않는다" "$(mtime_of "$F23SET")" "$f23_mtime"
  check "F3 수렴한 기동은 잠금 디렉터리를 만들지도 않는다" "$([ -d "$F23SET.cc-statusline.lock" ] && printf y || printf n)" "n"
fi

# ---------------------------------------------------------------------------
# G — the lock and the work directory
# ---------------------------------------------------------------------------
check "G6 (구조) 락 디렉터리 안에 무언가를 쓰는 자리가 0 건이다" \
  "$(grep -E '>[[:space:]]*"?\$LOCK|\$LOCK/' "$APPLY" | grep -c . || true)" "0"

G1="$WORK/g1.json"; mk_settings_empty "$G1"
apply "$G1" "$APLUG" empty >/dev/null
mkdir "$G1.cc-statusline.lock"
drift "$G1"
check "G 보유 중이면 즉시 포기하고 대기하지 않는다" "$(apply "$G1" "$APLUG" ours)" "30"
check "G6 (행동) 락 디렉터리 안이 비어 있다" "$(ls -A "$G1.cc-statusline.lock" | grep -c . || true)" "0"
check "G11 probe 는 자기가 잡은 적 없는 락을 지우지 않는다 — 먼저 probe" "$(probe "$G1" "$APLUG")" "2"
check "G11 probe 뒤에도 남의 락이 살아 있다" "$([ -d "$G1.cc-statusline.lock" ] && printf y || printf n)" "y"

# H3 rides the same fixture: five minutes older is the stale threshold, and a
# bare `rmdir` is the whole reclaim.
fx_age_file "$G1.cc-statusline.lock" 400
check "H3 5분 넘은 스테일 락은 회수되지만 이번 세션은 포기한다" "$(apply "$G1" "$APLUG" ours)" "30"
check "H3 회수된 락은 사라졌다" "$([ -d "$G1.cc-statusline.lock" ] && printf y || printf n)" "n"
check "H3 회수 다음 실행은 정상 진행한다" "$(apply "$G1" "$APLUG" ours)" "11"

# G7/G7b. The verify run is the first install's, and only the first install's.
mk_fake_plugin "$WORK/p-2nl" 'LINE ONE\nLINE TWO\n'
G7="$WORK/g7.json"; mk_settings_ours "$G7"
check "G7 재지정 경로는 verify 를 건너뛴다" "$(apply "$G7" "$WORK/p-2nl" ours)" "11"
check "G7 재지정 뒤 락이 정상 해제됐다" "$([ -d "$G7.cc-statusline.lock" ] && printf y || printf n)" "n"
G7B="$WORK/g7b.json"; mk_settings_empty "$G7B"
check "G7b EMPTY 경로는 verify 를 수행한다" "$(apply "$G7B" "$WORK/p-2nl" empty)" "40"

# G8. The poll cap moved from three seconds to one, and a status line that takes
# longer than a second has already failed.
mkdir -p "$WORK/p-slow/orchestrator"
cp "$CMDLIB" "$WORK/p-slow/orchestrator/"
printf '#!/usr/bin/env bash\ncat >/dev/null\nsleep 5\nprintf X\n' > "$WORK/p-slow/orchestrator/statusline.sh"
chmod +x "$WORK/p-slow/orchestrator/statusline.sh"
G8="$WORK/g8.json"; mk_settings_empty "$G8"
g8_start=$SECONDS
check "G8 느린 상태줄은 verify 에서 실패한다" "$(apply "$G8" "$WORK/p-slow" empty)" "40"
g8_elapsed=$((SECONDS - g8_start))
if [ "$g8_elapsed" -le 3 ]; then ok "G8 폴링 상한이 1초다 (경과 ${g8_elapsed}초)"
else bad "G8 폴링 상한" "${g8_elapsed}초가 걸렸다 — 상한이 1초로 줄지 않았다"; fi

# G9/G9b. THE WORK DIRECTORY IS CREATED ONLY AFTER THE LOCK ATTEMPT RESOLVES.
# G9b is what fixes the decision: an early `mktemp -d` with a trap passes G9 and
# fails here, because SIGKILL does not run traps.
g9_before=$(nglob "${TMPDIR:-/tmp}"/cc-apply-statusline.*)
G9="$WORK/g9.json"; mk_settings_empty "$G9"; mkdir "$G9.cc-statusline.lock"
i=0
while [ "$i" -lt 20 ]; do
  apply "$G9" "$APLUG" empty >/dev/null
  i=$((i + 1))
done
check "G9 경합 20회 뒤 임시 디렉터리 수가 그대로다" "$(nglob "${TMPDIR:-/tmp}"/cc-apply-statusline.*)" "$g9_before"
check "G9 미리 만들어 둔 락이 살아 있다" "$([ -d "$G9.cc-statusline.lock" ] && printf y || printf n)" "y"
i=0
while [ "$i" -lt 10 ]; do
  bash "$APPLY" --apply --settings "$G9" --plugin-dir "$APLUG" --require-state empty >/dev/null 2>/dev/null &
  kp=$!
  kill -9 "$kp" 2>/dev/null
  wait "$kp" 2>/dev/null
  i=$((i + 1))
done
check "G9b trap 이 돌기 전 SIGKILL 에도 임시 디렉터리 수가 그대로다" "$(nglob "${TMPDIR:-/tmp}"/cc-apply-statusline.*)" "$g9_before"
rmdir "$G9.cc-statusline.lock"

# G10/G12. THE SAME EIGHT TERMINALS, TWO DIFFERENT COLUMNS. G10 reads the work
# directory under `$TMPDIR`; G12 reads the temporary files beside the settings
# file. The compare-and-swap loss must be in the list: it is the only terminal
# that ends with `$T` in existence, so it is the one place the trap's `rm -f`
# does any work.
drive_terminal() {
  # drive_terminal <name> <settings> — drive one of the eight terminals that end
  # with a work directory in existence.
  local name="$1" s="$2"
  case "$name" in
    probe)        probe "$s" "$APLUG" >/dev/null ;;
    foreign)      mk_settings "$s";       apply "$s" "$APLUG" empty >/dev/null ;;
    requirestate) mk_settings_empty "$s"; apply "$s" "$APLUG" ours >/dev/null ;;
    verifyfail)   mk_settings_empty "$s"; apply "$s" "$WORK/p-2nl" empty >/dev/null ;;
    renderfail)   printf '{ this is not json' > "$s"; apply "$s" "$APLUG" empty >/dev/null ;;
    caslost)      cas_race "$s" ;;
    converged)    mk_settings_empty "$s"; apply "$s" "$APLUG" empty >/dev/null
                  apply "$s" "$APLUG" ours >/dev/null ;;
    success)      mk_settings_empty "$s"; apply "$s" "$APLUG" empty >/dev/null ;;
  esac
}

cas_race() {
  # cas_race <settings> — lose the compare-and-swap deterministically. The first
  # install polls its verify run, and that poll is the window: the file is
  # rewritten while the installer is inside it, so the compare finds a different
  # file than the snapshot and nothing is written.
  local s="$1"
  mk_settings_empty "$s"
  mkdir -p "$WORK/p-half/orchestrator"
  cp "$CMDLIB" "$WORK/p-half/orchestrator/"
  printf '#!/usr/bin/env bash\ncat >/dev/null\nsleep 0.4\nprintf ONE-LINE\n' > "$WORK/p-half/orchestrator/statusline.sh"
  chmod +x "$WORK/p-half/orchestrator/statusline.sh"
  bash "$APPLY" --apply --settings "$s" --plugin-dir "$WORK/p-half" --require-state empty >/dev/null 2>/dev/null &
  local ap=$!
  sleep 0.15
  jq '.theme = "moved-under-the-installer"' "$s" > "$s.race" 2>/dev/null && mv "$s.race" "$s"
  wait "$ap"
  CAS_RC=$?
}

CAS_RC=0
cas_race "$WORK/cas-probe.json"
check "G10/G12 전제 — 전체 파일 CAS 패배를 결정적으로 몬다" "$CAS_RC" "31"

g10_before=$(nglob "${TMPDIR:-/tmp}"/cc-apply-statusline.*)
for term in probe foreign requirestate verifyfail renderfail caslost converged success; do
  tf="$WORK/g10-$term.json"
  [ "$term" = probe ] && mk_settings_empty "$tf"
  drive_terminal "$term" "$tf"
  check "G10 종단 $term — TMPDIR 아래 작업 디렉터리 수가 실행 전후로 같다" \
    "$(nglob "${TMPDIR:-/tmp}"/cc-apply-statusline.*)" "$g10_before"
  check "G12 종단 $term — 설정 디렉터리의 임시 파일 수가 실행 전후로 같다" \
    "$(nglob "$tf".cc-statusline.tmp.* "$tf".cc-statusline.bak-tmp.*)" "0"
done

# ---------------------------------------------------------------------------
# H — the atomic write
# ---------------------------------------------------------------------------
if grep -qF 'T=$(mktemp "$SETTINGS.cc-statusline.tmp.XXXXXX")' "$APPLY"; then
  ok "H1 임시 파일이 대상과 같은 디렉터리에서 만들어진다 (구조)"
else
  bad "H1 임시 파일 위치" "다른 파일시스템에서는 mv 가 복사-삭제로 degrade 한다"
fi

# H2. Killed mid-apply, the settings file is one of the two whole states and
# never a third.
H2="$WORK/h2.json"; mk_settings_empty "$H2"
H2_ORIG=$(sha_of "$H2")
apply "$H2" "$APLUG" empty >/dev/null
H2_DONE=$(sha_of "$H2")
h2_bad=0
i=0
while [ "$i" -lt 15 ]; do
  f="$WORK/h2-$i.json"; mk_settings_empty "$f"
  bash "$APPLY" --apply --settings "$f" --plugin-dir "$APLUG" --require-state empty >/dev/null 2>/dev/null &
  kp=$!
  kill -9 "$kp" 2>/dev/null
  wait "$kp" 2>/dev/null
  s=$(sha_of "$f")
  if [ "$s" != "$H2_ORIG" ] && [ "$s" != "$H2_DONE" ]; then
    h2_bad=$((h2_bad + 1))
  fi
  i=$((i + 1))
done
check "H2 적용 도중 SIGKILL — 원본이 온전하거나 완전히 쓰였거나 둘 중 하나다" "$h2_bad" "0"

# H4. BOTH CALLERS SOURCE ONE FILE. A private copy in either of them is the
# failure this design exists to remove, and it is invisible until the two
# recognisers disagree.
check "H4 설치기가 공유 파일을 소스한다" \
  "$(grep -E '^[^#]*(^|[[:space:]&;])\. "\$SL_CMD_LIB"' "$APPLY" | grep -c . || true)" "1"
if [ -f "$HOOK" ]; then
  check "H4 훅도 같은 공유 파일을 소스한다" \
    "$(grep -c 'statusline-command\.sh' "$HOOK" || true)" "1"
else
  bad "H4 훅의 소싱" "$HOOK 이 없다"
fi

# H5. BSD `mv -n` answers rc 0 whether it moved the file or refused to, which
# loses the whole distinction the create path's compare-and-swap is made of.
#
# COMMENT LINES ARE EXCLUDED FROM THE SECOND HALF, because the reason `ln` is
# there is worth writing down next to it and naming the rejected form is how you
# write it down. A check that forbids the spelling everywhere makes the file
# choose between being correct and saying why, and it is not the spelling that
# is dangerous — it is the call.
H5_MVN=$(grep -vE '^[[:space:]]*#' "$APPLY" | grep -cF 'mv -n' || true)
if grep -qE '^[[:space:]]*if ! ln "\$T" "\$SETTINGS"' "$APPLY" && [ "$H5_MVN" = "0" ]; then
  ok "H5 생성 경로가 mv -n 이 아니라 ln 이다 (구조)"
else
  bad "H5 생성 경로의 CAS" "mv -n 은 이미 있는 대상에 rc 0 을 낸다"
fi

# H6. The three-line publication is what makes a slot's replacement atomic; a
# direct `cp` onto a slot has no such property and is invisible until a copy is
# interrupted.
check "H6 (구조) 백업 슬롯을 직접 겨냥한 cp 가 0 건이다" \
  "$(grep -E 'cp[^\n]*"\$SETTINGS\.(orig|prev)"' "$APPLY" | grep -c . || true)" "0"
if grep -qF 'TB=$(mktemp "$SETTINGS.cc-statusline.bak-tmp.XXXXXX")' "$APPLY" \
   && grep -qF 'cp "$WORK/pre" "$TB"' "$APPLY" \
   && grep -qF 'mv "$TB" "$slot"' "$APPLY"; then
  ok "H6 (구조) 슬롯 발행이 mktemp→cp→mv 세 줄 형태다"
else
  bad "H6 슬롯 발행 형태" "임시 파일을 거치지 않으면 파일시스템 경계에서 원자성이 사라진다"
fi

# H7. Each slot is old bytes or new bytes, never something in between.
H7="$WORK/h7.json"; mk_settings_empty "$H7"
apply "$H7" "$APLUG" empty >/dev/null
h7_orig_sha=$(sha_of "$H7.orig")
h7_bad=0
i=0
while [ "$i" -lt 15 ]; do
  drift "$H7"
  h7_prev_before=$(sha_of "$H7.prev")
  h7_expect_new=$(sha_of "$H7")
  bash "$APPLY" --apply --settings "$H7" --plugin-dir "$APLUG" --require-state ours >/dev/null 2>/dev/null &
  kp=$!
  kill -9 "$kp" 2>/dev/null
  wait "$kp" 2>/dev/null
  s=$(sha_of "$H7.prev")
  if [ "$s" != "$h7_prev_before" ] && [ "$s" != "$h7_expect_new" ]; then
    h7_bad=$((h7_bad + 1))
  fi
  i=$((i + 1))
done
check "H7 슬롯 발행 중 SIGKILL — 슬롯이 옛 바이트거나 새 바이트다" "$h7_bad" "0"
check "H7 첫 쓰기 스냅숏은 그 사이에도 바뀌지 않는다" "$(sha_of "$H7.orig")" "$h7_orig_sha"
rmdir "$H7.cc-statusline.lock" 2>/dev/null
rm -f "$H7".cc-statusline.tmp.* "$H7".cc-statusline.bak-tmp.* 2>/dev/null

# ---------------------------------------------------------------------------
# I — the pre-commit verify
#
# THE HEAD ASSERTION IS mtime, NOT BYTES. A byte comparison cannot separate
# "never written" from "written and put back", so it is green under both orders
# and cannot falsify the one this design chose.
# ---------------------------------------------------------------------------
mk_fake_plugin "$WORK/p-empty" ''

I1="$WORK/i1.json"; mk_settings_empty "$I1"
apply "$I1" "$APLUG" empty >/dev/null
i1_orig_sha=$(sha_of "$I1.orig"); i1_orig_m=$(mtime_of "$I1.orig")
i1_prev_sha=$(sha_of "$I1.prev"); i1_prev_m=$(mtime_of "$I1.prev")
i1_set_sha=$(sha_of "$I1");       i1_set_m=$(mtime_of "$I1")
fx_age_file "$I1.orig" 5; fx_age_file "$I1.prev" 5; fx_age_file "$I1" 5
i1_orig_m=$(mtime_of "$I1.orig"); i1_prev_m=$(mtime_of "$I1.prev"); i1_set_m=$(mtime_of "$I1")
# Make the next run a first install again on a machine that already has slots.
jq 'del(.statusLine)' "$I1" > "$I1.t" && mv "$I1.t" "$I1"
fx_age_file "$I1" 5
i1_set_sha=$(sha_of "$I1"); i1_set_m=$(mtime_of "$I1")
check "I1 사전 verify 실패 실행" "$(apply "$I1" "$WORK/p-empty" empty)" "40"
check "I1 앞선 성공이 만든 .orig 이 바이트로 건드려지지 않는다" "$(sha_of "$I1.orig")" "$i1_orig_sha"
check "I1 앞선 성공이 만든 .orig 이 mtime 으로도 건드려지지 않는다" "$(mtime_of "$I1.orig")" "$i1_orig_m"
check "I1b .prev 는 사전 verify 실패 실행에서 갱신되지 않는다 (음성)" "$(mtime_of "$I1.prev")" "$i1_prev_m"
check "I1b .prev 의 바이트도 그대로다 (음성)" "$(sha_of "$I1.prev")" "$i1_prev_sha"
check "I2b 교체 경로 — 설정 파일의 바이트가 그대로다" "$(sha_of "$I1")" "$i1_set_sha"
check "I2b 교체 경로 — 설정 파일의 mtime 도 그대로다" "$(mtime_of "$I1")" "$i1_set_m"

# I1b's POSITIVE half. Without it an implementation that never updates `.prev`
# at all passes the negative one.
check "I1b 실쓰기가 있었던 실행에서는 .prev 가 갱신된다 (양성)" "$(apply "$I1" "$APLUG" empty)" "10"
differ "I1b 실쓰기 뒤 .prev 의 mtime 이 실제로 움직였다" "$(mtime_of "$I1.prev")" "$i1_prev_m"

# I2b's create half: a failing verify leaves NO settings file behind.
I2="$WORK/i2nested/settings.json"
check "I2b 생성 경로 — 사전 verify 실패" "$(apply "$I2" "$WORK/p-empty" empty)" "40"
check "I2b 생성 경로 — 설정 파일이 만들어지지 않았다" "$([ -e "$I2" ] && printf y || printf n)" "n"
check "I2b 생성 경로 — 소유 비트도 생기지 않았다" "$([ -e "$I2.cc-statusline-owned" ] && printf y || printf n)" "n"

# I1c. A publication that fails leaves the slot at its old bytes, which a direct
# copy onto the slot cannot promise.
I1C="$WORK/i1c.json"; mk_settings_empty "$I1C"
apply "$I1C" "$APLUG" empty >/dev/null
i1c_prev=$(sha_of "$I1C.prev")
drift "$I1C"
chmod 500 "$WORK" 2>/dev/null
apply "$I1C" "$APLUG" ours >/dev/null
chmod 700 "$WORK" 2>/dev/null
check "I1c 발행이 실패해도 슬롯이 옛 바이트로 남는다" "$(sha_of "$I1C.prev")" "$i1c_prev"

# I3. THE TWO WRITERS POINT IN OPPOSITE DIRECTIONS, and that is the whole case.
# The marker is never written by the installer — not on failure and not on
# success, or an implementation that kept the marker step on the success path
# would pass. The ownership bit is the mirror image: absent on a failed verify,
# a park and a lost compare-and-swap, and PRESENT on rc 0, 10 and 11.
check "I3 (구조) 설치기 안에 마커 줄을 쓰는 자리가 0 건이다" \
  "$(grep -E '\.cc-statusline"' "$APPLY" | grep -c . || true)" "0"
I3="$WORK/i3.json"; mk_settings_empty "$I3"
apply "$I3" "$WORK/p-empty" empty >/dev/null
check "I3 사전 verify 실패 — 마커가 없다" "$([ -e "$I3.cc-statusline" ] && printf y || printf n)" "n"
check "I3 사전 verify 실패 — 소유 비트도 없다" "$([ -e "$I3.cc-statusline-owned" ] && printf y || printf n)" "n"
apply "$I3" "$APLUG" empty >/dev/null
check "I3 성공 경로 — 설치기는 마커를 만들지 않는다" "$([ -e "$I3.cc-statusline" ] && printf y || printf n)" "n"
check "I3 성공 경로(rc 10) — 소유 비트는 만든다" "$([ -e "$I3.cc-statusline-owned" ] && printf y || printf n)" "y"
I3B="$WORK/i3b.json"; mk_settings_ours "$I3B"
apply "$I3B" "$APLUG" ours >/dev/null
check "I3 rc 11 — 소유 비트를 만든다" "$([ -e "$I3B.cc-statusline-owned" ] && printf y || printf n)" "y"
rm -f "$I3B.cc-statusline-owned"
apply "$I3B" "$APLUG" ours >/dev/null
check "I3 rc 0(수렴) — 소유 비트를 만든다" "$([ -e "$I3B.cc-statusline-owned" ] && printf y || printf n)" "y"
I3C="$WORK/i3c.json"
cas_race "$I3C"
check "I3 CAS 패배 — 소유 비트를 만들지 않는다" "$([ -e "$I3C.cc-statusline-owned" ] && printf y || printf n)" "n"

# ---------------------------------------------------------------------------
# J — the install history
# ---------------------------------------------------------------------------
# J2. Adoption: a machine whose status line is already ours but which has no
# history — the entire installed base at the moment this ships.
J2="$WORK/j2.json"; mk_settings_ours "$J2"
check "J2 이력 없는 ours — 채택하며 재지정한다" "$(apply "$J2" "$APLUG" ours)" "11"
check "J2 채택이 소유 비트를 만든다" "$([ -e "$J2.cc-statusline-owned" ] && printf y || printf n)" "y"

# J2b. The end state is reached by walking the real order, not by writing it.
J2B="$WORK/j2b.json"; mk_settings_empty "$J2B"
apply "$J2B" "$APLUG" empty >/dev/null
jq 'del(.statusLine)' "$J2B" > "$J2B.t" && mv "$J2B.t" "$J2B"
check "J2b 채택 후 사용자가 지우면 최초 설치로 분류되지 않는다" "$(apply "$J2B" "$APLUG" empty)" "10"
check "J2b 그 판정은 훅이 짧게 끊어야 하는 자리다 — 비트가 남아 있다" \
  "$([ -e "$J2B.cc-statusline-owned" ] && printf y || printf n)" "y"

# J7. Two settings files, two histories. A single global marker fails here.
J7A="$WORK/j7a.json"; J7B="$WORK/j7b.json"
mk_settings_empty "$J7A"; mk_settings_empty "$J7B"
apply "$J7A" "$APLUG" empty >/dev/null
check "J7 이력이 설정 파일 경로별로 독립이다 — 다른 파일에는 비트가 없다" \
  "$([ -e "$J7B.cc-statusline-owned" ] && printf y || printf n)" "n"
check "J7 다른 파일도 스스로 최초 설치가 된다" "$(apply "$J7B" "$APLUG" empty)" "10"

# J8. Not making the bit and not writing the marker line are different acts on
# different files; the hook writes the line even here, and without it a machine
# with a broken status line pays the poll on every startup forever.
J8="$WORK/j8.json"; mk_settings_empty "$J8"; j8_sha=$(sha_of "$J8")
fx_age_file "$J8" 5; j8_m=$(mtime_of "$J8")
check "J8 사전 verify 실패 — rc 40" "$(apply "$J8" "$WORK/p-empty" empty)" "40"
check "J8 사전 verify 실패 — 소유 비트를 만들지 않는다" "$([ -e "$J8.cc-statusline-owned" ] && printf y || printf n)" "n"
check "J8 사전 verify 실패 — 바이트가 그대로다" "$(sha_of "$J8")" "$j8_sha"
check "J8 사전 verify 실패 — mtime 도 그대로다" "$(mtime_of "$J8")" "$j8_m"

# J9. FOUR LEGS. The behavioural one walks the real order; the two structural
# ones are where monotonicity actually hangs; the byte one is taken at EVERY
# step, because an end-state reading passes an implementation that deletes the
# bit and makes it again.
J9="$WORK/j9.json"; mk_settings_empty "$J9"
j9_steps_ok=1
apply "$J9" "$APLUG" empty >/dev/null
[ -e "$J9.cc-statusline-owned" ] && [ ! -s "$J9.cc-statusline-owned" ] || j9_steps_ok=0
jq '.statusLine.command = "printf '"'"'SOMEBODY-ELSE'"'"'"' "$J9" > "$J9.t" && mv "$J9.t" "$J9"
apply "$J9" "$APLUG" ours >/dev/null
[ -e "$J9.cc-statusline-owned" ] && [ ! -s "$J9.cc-statusline-owned" ] || j9_steps_ok=0
jq 'del(.statusLine)' "$J9" > "$J9.t" && mv "$J9.t" "$J9"
j9_last=$(apply "$J9" "$APLUG" empty)
[ -e "$J9.cc-statusline-owned" ] && [ ! -s "$J9.cc-statusline-owned" ] || j9_steps_ok=0
check "J9 (1) 설치 → park → 삭제 순서를 실제로 몬다" "$j9_last" "10"
check "J9 (4) 각 단계 뒤에 소유 비트가 존재하고 크기가 0 이다" "$j9_steps_ok" "1"
check "J9 (2) 트리 전체에서 …-owned 에 가해지는 연산이 만들기 하나뿐이다" \
  "$(grep -rE '(rm|unlink|mv|>)[^\n]*cc-statusline-owned' "$repo_root/plugins" "$repo_root/scripts" 2>/dev/null | grep -v ':[[:space:]]*#' | grep -vc 'cc-statusline-owned" \]' || true)" "1"
check "J9 (3) 마커 줄을 쓰는 자리가 apply-statusline.sh 안에 0 건이다" \
  "$(grep -E 'cc-statusline"' "$APPLY" | grep -c . || true)" "0"

# J10. Five parks in a row after an install leave the bit exactly as it was.
J10="$WORK/j10.json"; mk_settings_empty "$J10"
apply "$J10" "$APLUG" empty >/dev/null
j10_m=$(mtime_of "$J10.cc-statusline-owned")
jq '.statusLine.command = "printf '"'"'SOMEBODY-ELSE'"'"'"' "$J10" > "$J10.t" && mv "$J10.t" "$J10"
i=0
while [ "$i" -lt 5 ]; do
  apply "$J10" "$APLUG" empty >/dev/null
  i=$((i + 1))
done
check "J10 설치 뒤 park 를 다섯 번 몰아도 소유 비트가 그대로다" "$(mtime_of "$J10.cc-statusline-owned")" "$j10_m"

# J12. SET EQUALITY, NOT CONTAINMENT. "everything observed is inside the
# vocabulary" is true of an implementation that only ever produces three of the
# verdicts, so a subset check stays green on exactly the regression this case
# exists to catch. Requiring equality turns an unreachable verdict into a
# failure, and it makes visible WHICH verdicts no scenario can reach.
#
# TWO OF THEM CANNOT BE REACHED END TO END, AND THAT IS A FINDING RATHER THAN A
# GAP. `reason=require-state` needs the value to change between the hook's
# classification and the installer's snapshot, which is a race and not a
# scenario; `reason=plugin-dir` needs the installer to receive a trailing slash,
# which the hook normalises away before it ever calls. Both are driven at the
# installer instead, and their names are then taken from the hook's own mapping
# rather than typed here — so the two halves cannot drift.
VERDICT_BEGIN='# >>> cc-statusline verdict region begin'
VERDICT_END='# <<< cc-statusline verdict region end'
VERDICT_REGION="$WORK/verdict-region.sh"
awk -v b="$VERDICT_BEGIN" -v e="$VERDICT_END" \
  '$0 == b {inr = 1; next} $0 == e {inr = 0} inr {print}' "$HOOK" > "$VERDICT_REGION" 2>/dev/null

if [ ! -s "$VERDICT_REGION" ]; then
  bad "J12 판정 어휘" "$HOOK 에서 판정 조립 영역을 뽑을 수 없다 (마커 주석 부재)"
else
  j12_dir="$WORK/j12"
  mkdir -p "$j12_dir"
  j12_obs_v="$WORK/j12-verdicts"
  j12_obs_r="$WORK/j12-reasons"
  : > "$j12_obs_v"; : > "$j12_obs_r"

  j12_run() {
    # j12_run <tag> <plugin-dir> — one startup of the hook against its own
    # configuration directory, then the marker it left.
    # THE DIRECTORY IS BUILT ON THE LINE AFTER THE DECLARATION. `local` is a
    # command, so every one of its arguments is expanded before it runs — a
    # `cfg="$j12_dir/$tag"` in the same statement reads whatever `tag` held
    # OUTSIDE this function, and this suite has such a global. Every scenario
    # then drives the hook against one shared directory and the verdicts collapse
    # to whatever that directory happens to be in.
    local tag="$1" plug="$2" mk cfg
    cfg="$j12_dir/$tag"
    CLAUDE_CONFIG_DIR="$cfg" bash "$HOOK" --plugin-dir "$plug" >/dev/null 2>/dev/null
    mk="$cfg/settings.json.cc-statusline"
    [ -f "$mk" ] || return 1
    sed -e 's/.*|verdict=//' -e 's/|.*//' "$mk" >> "$j12_obs_v"
    sed -e 's/.*|reason=//' -e 's/|.*//' "$mk" | sed 's/^$/-/' >> "$j12_obs_r"
    return 0
  }

  j12_new() { mkdir -p "$j12_dir/$1"; mk_settings_empty "$j12_dir/$1/settings.json"; }

  # THE MARKER IS CLEARED BETWEEN THESE RUNS ON PURPOSE. Left in place the front
  # gate skips the whole slow path — correctly, that is the design — and the
  # marker still holds the PREVIOUS verdict, so a scenario meant to produce a new
  # one silently re-reads the old one. Removing it is what forces the decision to
  # be taken again; the ownership bit is what separates the two verdicts.
  j12_new installed;  j12_run installed "$APLUG"
  rm -f "$j12_dir/installed/settings.json.cc-statusline"
  j12_run installed "$APLUG"                                  # converged
  rm -f "$j12_dir/installed/settings.json.cc-statusline-owned"
  rm -f "$j12_dir/installed/settings.json.cc-statusline"
  j12_run installed "$APLUG"                                  # adopted

  mkdir -p "$j12_dir/adoptrepoint"
  mk_settings_ours "$j12_dir/adoptrepoint/settings.json"
  j12_run adoptrepoint "$APLUG"                               # adopt-repoint

  j12_new driftrepair; j12_run driftrepair "$APLUG"
  drift "$j12_dir/driftrepair/settings.json"
  rm -f "$j12_dir/driftrepair/settings.json.cc-statusline"
  j12_run driftrepair "$APLUG"                                # drift-repair

  j12_new deleted; j12_run deleted "$APLUG"
  jq 'del(.statusLine)' "$j12_dir/deleted/settings.json" > "$j12_dir/deleted/s.t" \
    && mv "$j12_dir/deleted/s.t" "$j12_dir/deleted/settings.json"
  rm -f "$j12_dir/deleted/settings.json.cc-statusline"
  j12_run deleted "$APLUG"                                    # deleted

  mkdir -p "$j12_dir/foreign"; mk_settings "$j12_dir/foreign/settings.json"
  j12_run foreign "$APLUG"                                    # park / foreign

  # THE PLUGIN TREE HAS TO EXIST FOR THE HOOK TO GET THAT FAR. A directory that
  # is not there has no shared grammar file either, so the hook stops at its own
  # source guard and never reaches the installer — and `sl-missing` would then be
  # a verdict no scenario produces. `b6-nobit` is the shape that separates the
  # two: everything present, the status line script without its executable bit.
  j12_new slmissing;  j12_run slmissing "$WORK/b6-nobit"
  j12_new guardreeval; j12_run guardreeval "$WORK/b6-reeval/plug\$d"
  j12_new verifyfail;  j12_run verifyfail "$WORK/p-empty"

  if [ -n "${WT_LINKED_PLUG:-}" ] && [ -x "${WT_LINKED_PLUG:-}/orchestrator/statusline.sh" ]; then
    j12_new worktree; j12_run worktree "$WT_LINKED_PLUG"
  else
    # The worktree verdict is driven at the installer and named through the
    # hook's own mapping, exactly like the two below.
    printf 'park\n' >> "$j12_obs_v"; printf 'worktree\n' >> "$j12_obs_r"
  fi

  j12_map() {
    # j12_map <rc> <had-bit> — the hook's own naming, applied to a return code
    # no hook-driven scenario can produce.
    ( set -uo pipefail; . "$VERDICT_REGION"; verdict_name "$1" "$2" ) 2>/dev/null
  }
  j12_rs="$WORK/j12-rs.json"; mk_settings_empty "$j12_rs"
  j12_rs_rc=$(apply "$j12_rs" "$APLUG" ours)
  check "J12 전제 — 설치기가 상태 불일치를 rc 21 로 낸다" "$j12_rs_rc" "21"
  j12_pd="$WORK/j12-pd.json"; mk_settings_empty "$j12_pd"
  j12_pd_rc=$(apply "$j12_pd" "$APLUG/" empty)
  check "J12 전제 — 설치기가 후행 슬래시를 rc 26 으로 낸다" "$j12_pd_rc" "26"
  for pair in "$j12_rs_rc" "$j12_pd_rc"; do
    m=$(j12_map "$pair" n)
    printf '%s\n' "${m%%|*}" >> "$j12_obs_v"
    printf '%s\n' "${m##*|}" >> "$j12_obs_r"
  done

  j12_seen_v=$(sort -u "$j12_obs_v" | tr '\n' ' ')
  j12_seen_r=$(sort -u "$j12_obs_r" | tr '\n' ' ')
  j12_want_v=$(printf '%s\n' adopt-repoint adopted converged deleted drift-repair installed park verify-failed | sort -u | tr '\n' ' ')
  j12_want_r=$(printf '%s\n' - foreign guard-reeval plugin-dir require-state sl-missing verify worktree | sort -u | tr '\n' ' ')
  check "J12 관측한 판정 이름의 집합이 닫힌 집합과 상등하다" "$j12_seen_v" "$j12_want_v"
  check "J12 관측한 사유 토큰의 집합이 닫힌 집합과 상등하다" "$j12_seen_r" "$j12_want_r"
fi

# ---------------------------------------------------------------------------
# K — broken input and the argument contract
# ---------------------------------------------------------------------------
K1="$WORK/k1.json"; printf '{ this is not json' > "$K1"; K1S=$(sha_of "$K1")
check "K1 깨진 JSON — 쓰기 전에 중단한다" "$(apply "$K1" "$APLUG" empty)" "1"
check "K1 깨진 JSON — 파일이 그대로다" "$(sha_of "$K1")" "$K1S"
check "K1 깨진 JSON — 락을 남기지 않는다" "$([ -d "$K1.cc-statusline.lock" ] && printf y || printf n)" "n"
check "K1 깨진 JSON — 백업도 만들지 않는다" "$(nglob "$K1".orig "$K1".prev)" "0"

# The interpreter is named absolutely: a PATH with nothing on it cannot resolve
# `bash` either, and a 127 from the lookup would look like the script's own
# verdict while proving nothing about it.
K2="$WORK/k2.json"; mk_settings_empty "$K2"; K2S=$(sha_of "$K2")
mkdir -p "$WORK/nojq"
PATH="$WORK/nojq" /bin/bash "$APPLY" --apply --settings "$K2" --plugin-dir "$APLUG" --require-state empty >/dev/null 2>/dev/null
check "K2 jq 부재 — 실패하고 아무것도 쓰지 않는다" "$?" "1"
check "K2 jq 부재 — 파일이 그대로다" "$(sha_of "$K2")" "$K2S"

# K3. THE TWO CODES BOTH MEAN FAILURE, so a loose "not zero" check passes the
# very implementation this leg exists to reject — the one that folds an unknown
# spelling into "mismatch" and has the hook remember it as a park.
K3="$WORK/k3.json"; mk_settings_empty "$K3"
k3_rc=$(apply "$K3" "$APLUG" ALREADY-OURS)
check "K3 어휘 밖 철자는 rc 1 이다" "$k3_rc" "1"
differ "K3 그리고 rc 21 이 아니다" "$k3_rc" "21"
k3b_rc=$(apply "$K3" "$APLUG" EMPTY)
check "K3 대문자 술어 이름도 rc 1 이다" "$k3b_rc" "1"
differ "K3 대문자 술어 이름도 rc 21 이 아니다" "$k3b_rc" "21"

bash "$APPLY" --apply --settings "$K3" --plugin-dir "$APLUG" >/dev/null 2>/dev/null
check "K4 --apply 를 필수 상태 인자 없이 부르면 오류다" "$?" "1"
bash "$APPLY" --probe --settings "$K3" --plugin-dir "$APLUG" --require-state empty >/dev/null 2>/dev/null
check "K5 probe 모드에 그 인자를 동반하면 오류다" "$?" "1"
bash "$APPLY" --apply --settings "relative/settings.json" --plugin-dir "$APLUG" --require-state empty >/dev/null 2>/dev/null
check "K --settings 가 상대경로면 오류다" "$?" "1"

# ---------------------------------------------------------------------------
# M — the guardless value is adopted, not parked
#
# The park predicate exists to avoid overwriting SOMEBODY ELSE'S status line,
# and a value that names our script is not somebody else's. The observability
# document guided exactly this shape of hand installation, which is where the
# population comes from.
# ---------------------------------------------------------------------------
M1="$WORK/m1.json"; mk_settings "$M1" "bash $OLDSL"
check "M1 무가드 맨 호출은 park 하지 않는다" "$(apply "$M1" "$APLUG" ours)" "11"
has "M1 가드 래퍼로 재지정된다" "$(cmd_of "$M1")" "[ -x \"$APLUG/orchestrator/statusline.sh\" ]"
has "M1 무가드 값을 채택하면 폴백이 true 다" "$(cmd_of "$M1")" "|| true"

m2_i=0
for v in "\"$OLDSL\"" "bash \"$OLDSL\"" "sh $OLDSL" "exec bash $OLDSL" "$OLDSL"; do
  m2_i=$((m2_i + 1))
  f="$WORK/m2-$m2_i.json"; mk_settings "$f" "$v"
  check "M2 무가드 변형 $m2_i — M1 과 같은 결과" "$(apply "$f" "$APLUG" ours)" "11"
  has "M2 무가드 변형 $m2_i — 폴백이 true" "$(cmd_of "$f")" "|| true"
done

M3="$WORK/m3.json"; mk_settings "$M3" "  bash $OLDSL  "
check "M3 앞뒤 공백·탭이 붙은 무가드 값도 같은 결과" "$(apply "$M3" "$APLUG" ours)" "11"

# M4. The residue is a guardless call of ours, so the fallback is EMPTIED rather
# than carried — a dead pointer riding behind a guard that is true is invisible.
M4="$WORK/m4.json"
mk_settings "$M4" "[ -x \"$OLDSL\" ] && exec bash \"$OLDSL\" || bash $OLDSL"
check "M4 나머지가 무가드 우리 값인 가드 래퍼 — 한 겹 벗겨진다" "$(apply "$M4" "$APLUG" ours)" "11"
check "M4 폴백이 비워진다 — 죽은 옛 포인터가 남지 않는다" "$(cmd_of "$M4" | grep -c "|| true$")" "1"
hasnt "M4 옛 경로가 명령에 남아 있지 않다" "$(cmd_of "$M4")" "$OLDSL"

# M5. The suffix is two segments, and this is the only case that holds it there.
# The harness documents `~/.claude/statusline.sh` as where a hand-written status
# line goes, so one segment would adopt and overwrite the user's own script.
M5="$WORK/m5.json"; mk_settings "$M5" "bash $WORK/home/.claude/statusline.sh"; M5S=$(sha_of "$M5")
check "M5 한 세그먼트 접미사는 우리 것이 아니다 — park" "$(apply "$M5" "$APLUG" ours)" "20"
check "M5 park — 파일이 바이트 동일" "$(sha_of "$M5")" "$M5S"

m6_i=0
for v in "bash $OLDSL | cat" "bash $OLDSL --flag" "bash $OLDSL && echo hi" "FOO=1 bash $OLDSL"; do
  m6_i=$((m6_i + 1))
  f="$WORK/m6-$m6_i.json"; mk_settings "$f" "$v"
  check "M6 장식이 붙은 무가드 값 $m6_i — park" "$(apply "$f" "$APLUG" ours)" "20"
done

m7_i=0
for v in "bash \$HOME/orchestrator/statusline.sh" "bash \`pwd\`/orchestrator/statusline.sh" "bash rel/orchestrator/statusline.sh"; do
  m7_i=$((m7_i + 1))
  f="$WORK/m7-$m7_i.json"; mk_settings "$f" "$v"
  check "M7 \$·백틱·상대경로가 든 값 $m7_i — park" "$(apply "$f" "$APLUG" ours)" "20"
done

M8="$WORK/m8.json"; mk_settings "$M8" "bash $OLDSL"
apply "$M8" "$APLUG" ours >/dev/null
M8S=$(sha_of "$M8")
apply "$M8" "$APLUG" ours >/dev/null
check "M8 M1 적용 뒤 재적용이 바이트 동일" "$(sha_of "$M8")" "$M8S"

# M9. THE FILE CANNOT TELL THESE TWO APART. A park leaves the file alone and so
# does a converged apply, so M8's byte identity is satisfied by an
# implementation whose own output it then classifies as foreign — which would
# make the machine alternate between re-pointing and parking forever. The probe
# reports the verdict, and that is what separates them.
check "M9 M1 적용 결과물에 probe 를 돌리면 park(1) 가 아니라 수렴(0) 이다" "$(probe "$M8" "$APLUG")" "0"

# ---------------------------------------------------------------------------
# The settings file that does not exist yet
# ---------------------------------------------------------------------------
S6F="$WORK/nested/settings-new.json"
check "대상 파일 부재 — 사전 프로브는 2(진행)" "$(probe "$S6F" "$APLUG")" "2"
check "대상 파일 부재 — 최소 파일을 만든다" "$(apply "$S6F" "$APLUG" empty)" "10"
check "새로 만든 파일은 키 하나뿐이다" "$(jq -r '[keys[]] | join(",")' "$S6F")" "statusLine"
check "새로 만든 뒤 사후 프로브 — 0(수렴)" "$(probe "$S6F" "$APLUG")" "0"
check "생성 경로에는 백업이 없다" "$(nglob "$S6F".orig "$S6F".prev)" "0"

# ---------------------------------------------------------------------------
# The absolute paths that are still wrong, and the ones that only look wrong
# ---------------------------------------------------------------------------
SREF="$WORK/settings-reeval.json"; mk_settings "$SREF"
BREF=$(sha_of "$SREF")

# THE FOURTH NAME PINS THE STRATEGY, NOT A CHARACTER. The three before it are
# the characters a reader would enumerate, so a pre-evaluation rewritten as
# "reject `$`, `"` and a backtick" keeps all three of them red — and installs a
# dead status line for the fourth. Two backslashes pass such an enumeration
# untouched and still collapse to one at the render's second evaluation.
mkdir -p "$WORK/reeval"
for bad_name in 'plug$dollar' 'plug"quote' 'plug`tick`' 'plug\\double'; do
  bad_plug="$WORK/reeval/$bad_name"
  mkdir -p "$bad_plug/orchestrator"
  cp "$SL" "$LIVENESS" "$CMDLIB" "$bad_plug/orchestrator/"
  chmod +x "$bad_plug/orchestrator/statusline.sh"
  check "재평가에서 해석되는 문자가 든 절대경로 ($bad_name) — 쓰기 전에 park 한다" \
    "$(apply "$SREF" "$bad_plug" empty)" "25"
done
check "재평가로 park 한 네 경우 모두 파일을 건드리지 않았다" "$(sha_of "$SREF")" "$BREF"

reeval_ok_case() {
  # reeval_ok_case <tag> <label> <plugin-dir> — a path whose characters survive
  # the render's second evaluation. Two assertions, because a successful apply
  # is not evidence that the guard was true: on this fixture the fallback branch
  # emits the pre-apply literal and would pass a weaker reading. Comparing the
  # installed command's render against the live one separates the branches.
  local tag="$1" label="$2" dir="$3" sf
  mkdir -p "$dir/orchestrator"
  cp "$SL" "$LIVENESS" "$CMDLIB" "$dir/orchestrator/"
  chmod +x "$dir/orchestrator/statusline.sh"
  sf="$WORK/settings-reeval-$tag.json"; mk_settings_empty "$sf"
  check "$label — 적용이 성공한다" "$(apply "$sf" "$dir" empty)" "10"
  check "$label — 설치된 명령이 폴백이 아니라 그 스크립트를 부른다" \
    "$(fx_statusline_stdin sess-live | sh -c "$(cmd_of "$sf")" | strip_clock)" \
    "$(sl sess-live | strip_clock)"
}

# `$(printf ...)` is how the newline gets into the name at all — a literal one
# cannot be written into the word list above without ending it.
reeval_ok_case bs "백슬래시가 든 절대경로" "$WORK/reeval/plug\\back"
reeval_ok_case nl "개행이 든 절대경로" "$(printf '%s/reeval/plug\nnewline' "$WORK")"

# The space that made the installed `[` fail with too many arguments.
SPACED="$WORK/plugin with space"
mkdir -p "$SPACED/orchestrator"
cp "$SL" "$LIVENESS" "$CMDLIB" "$SPACED/orchestrator/"
chmod +x "$SPACED/orchestrator/statusline.sh"
S9F="$WORK/settings-spaced.json"; mk_settings_empty "$S9F"
check "공백이 든 절대경로 — 적용이 성공한다" "$(apply "$S9F" "$SPACED" empty)" "10"
check "공백이 든 절대경로 — 설치된 명령이 폴백이 아니라 그 스크립트를 부른다" \
  "$(fx_statusline_stdin sess-live | sh -c "$(cmd_of "$S9F")" | strip_clock)" \
  "$(sl sess-live | strip_clock)"

# The throwaway worktree — the one shape that passes all three checks above and
# is gone seconds later. Its sibling assertion matters as much: an ordinary
# checkout must NOT park, and the two differ only in how git answers about them.
if command -v git >/dev/null 2>&1; then
  # EVERY PATH BELOW REACHES THE CHECKOUT THROUGH A SYMLINK, and the plugin
  # directory is a SUBDIRECTORY of it. Together those two are the shape
  # `--plugin-dir` actually has, and the only shape in which the two git answers
  # differ as strings while naming one directory.
  mkdir -p "$WORK/wt-real"
  ln -s "$WORK/wt-real" "$WORK/wt-via"
  WT_MAIN="$WORK/wt-via/main"
  WT_MAIN_PLUG="$WT_MAIN/plugins/cc-cmds"
  mkdir -p "$WT_MAIN_PLUG/orchestrator"
  cp "$SL" "$LIVENESS" "$CMDLIB" "$WT_MAIN_PLUG/orchestrator/"
  chmod +x "$WT_MAIN_PLUG/orchestrator/statusline.sh"
  (
    cd "$WT_MAIN" || exit 1
    git init -q .
    git add -A
    git -c user.email=fixture@example.invalid -c user.name=fixture commit -q -m fixture
    git worktree add -q --detach "$WORK/wt-via/linked" HEAD
  ) >/dev/null 2>&1
  WT_LINKED_PLUG="$WORK/wt-via/linked/plugins/cc-cmds"
  if [ -x "$WT_LINKED_PLUG/orchestrator/statusline.sh" ]; then
    S8F="$WORK/settings-wt.json"; mk_settings "$S8F"
    B8S=$(sha_of "$S8F")
    check "임시 워크트리를 가리키는 --plugin-dir — 쓰기 전에 park 한다" \
      "$(apply "$S8F" "$WT_LINKED_PLUG" empty)" "23"
    check "워크트리로 park — 파일을 건드리지 않았다" "$(sha_of "$S8F")" "$B8S"
    S8G="$WORK/settings-wt-main.json"; mk_settings_empty "$S8G"
    check "심링크를 경유한 본 체크아웃의 하위 디렉터리는 park 하지 않는다" \
      "$(apply "$S8G" "$WT_MAIN_PLUG" empty)" "10"
  else
    skip "임시 워크트리 park" "git worktree 를 만들 수 없다"
  fi
else
  skip "임시 워크트리 park" "git 이 없다"
fi

# ---------------------------------------------------------------------------
# 상태 루트 아래를 가리키는 --plugin-dir — 런의 고정 사본이다
# ---------------------------------------------------------------------------
# 고정 런의 apply 스테이지는 `--plugin-dir` 을 `GATE_DIR` 에서 파생하는데, hop 뒤의
# 그 값은 런 디렉터리 안 사본이다. 사본은 존재하고 스크립트를 담고 실행 비트도
# 서 있어 아래 모든 검사를 통과하지만, 리퍼가 런 디렉터리를 걷어 가는 순간 설치된
# 가드는 영구히 거짓이 된다 — 임시 워크트리 케이스와 같은 부류이고, 같은 자리에서
# 같은 방식으로 막아야 한다.
SLST="$WORK/xstate"
SLST_PLUG="$SLST/cc-cmds/run/R/plugin/cc-cmds"
mk_fake_plugin "$SLST_PLUG" 'SLST-LINE'
SSTF="$WORK/settings-state-root.json"
mk_settings_empty "$SSTF"
SST_BEFORE=$(shasum -a 256 "$SSTF" | cut -d' ' -f1)
sl_state_out=$(XDG_STATE_HOME="$SLST" bash "$APPLY" --apply --settings "$SSTF" \
  --plugin-dir "$SLST_PLUG" --require-state empty 2>&1)
check "상태 루트 아래를 가리키는 --plugin-dir — 쓰기 전에 park 한다" "$?" "1"
check "그때 설정 파일은 한 바이트도 바뀌지 않는다" \
  "$(shasum -a 256 "$SSTF" | cut -d' ' -f1)" "$SST_BEFORE"
case "$sl_state_out" in
  *'상태 루트'*) ok "문면이 상태 루트를 지목한다" ;;
  *) bad "문면이 상태 루트를 지목한다" "$sl_state_out" ;;
esac
# 음성 대조군 — 상태 루트를 다른 곳으로 옮기면 같은 디렉터리가 통과한다. 없으면
# 위 단언이 「그 경로는 원래 통과하지 않는다」와 구별되지 않는다.
mk_settings_empty "$SSTF"
XDG_STATE_HOME="$WORK/elsewhere" bash "$APPLY" --apply --settings "$SSTF" \
  --plugin-dir "$SLST_PLUG" --require-state empty >/dev/null 2>&1
check "음성 대조군 — 상태 루트 밖이면 같은 디렉터리가 설치된다" "$?" "10"

# ---------------------------------------------------------------------------
# SB01-SB20. The borrow segment
# ---------------------------------------------------------------------------
#
# A RECORD OF ITS OWN STATE ROOT, AND A DIRECTORY WITH A SHORT NAME. Every render
# below starts in `$BW`, so its fallback line is the known `BFALL` and the
# segment's width is the only thing that moves. Records are written with `printf`
# and heredocs rather than jq, so case 11's poison cannot reach them. Every
# expectation is a literal and never goes through `strip_clock`: the line may end
# in a `홈 HH:MM` clock, which is exactly what that function removes.
XDG_STATE_HOME="$WORK/bstate"
export XDG_STATE_HOME
mkdir -p "$XDG_STATE_HOME"
BREC_DIR="$XDG_STATE_HOME/cc-lane"
BREC="$BREC_DIR/borrow.json"
LANE="$WORK/cfg/lane"; DONOR="$WORK/cfg/u3"; G4="$WORK/cfg/u4"; OTHER="$WORK/cfg/u5"
mkdir -p "$LANE" "$DONOR" "$G4" "$OTHER"
BW="$WORK/bw"; mkdir -p "$BW"
BFALL=$(cd "$BW" && bash "$REF_CMD_FIXTURE" </dev/null)
ROUTE="$repo_root/plugins/cc-cmds/orchestrator/route.sh"
# A backslash built by the shell, so that no editor or document tool can decode
# the unicode escapes written with it.
BS=$'\\'
NOW=$(date -u +%s)

bcanon() {
  # bcanon <state> <trigger> <five_hour epoch> [seven_day epoch] [stage] — the
  # record in cc-lane's pretty form, with `donor.group` naming u3 and u4. The
  # trigger and the epochs are JSON exactly as written into the record.
  cat <<EOF
{
  "schema": "cc-lane-borrow v1",
  "state": "$1",
  "lane_config_dir": "$LANE",
  "donor": {
    "id": "u3",
    "config_dir": "$DONOR",
    "group": [
      {
        "id": "u3",
        "config_dir": "$DONOR"
      },
      {
        "id": "u4",
        "config_dir": "$G4"
      }
    ]
  },
  "trigger_window": $2,
  "home_windows": {
    "five_hour": {
      "utilization_bp": 9100,
      "resets_at_epoch": $3
    },
    "seven_day": {
      "utilization_bp": null,
      "resets_at_epoch": ${4:-null}
    }
  },
  "since_epoch": 1790990000,
  "nonce": "ab12",
  "written_at_epoch": 1790990001,
  "home": "cc",
  "stage": "${5:-$1/steady}",
  "not_before_epoch": null,
  "attempt": 0
}
EOF
}
bclear() { chmod -R u+rwX "$BREC_DIR" 2>/dev/null; rm -rf "$BREC_DIR"; }
# The heredoc ends in a newline and cc-lane's emitter does not; the command
# substitution is what drops it.
bput()  { bclear; mkdir -p "$BREC_DIR"; printf '%s' "$(bcanon "$@")" > "$BREC"; }
bputf() { bclear; mkdir -p "$BREC_DIR"; printf '%s' "$1" > "$BREC"; }
bflat() {
  # bflat <state> <donor id> <five_hour epoch> — the compact form, lane and donor
  # directories the fixed ones.
  printf '{"schema":"cc-lane-borrow v1","state":"%s","lane_config_dir":"%s","donor":{"id":"%s","config_dir":"%s"},"trigger_window":"five_hour","home_windows":{"five_hour":{"resets_at_epoch":%s}}}' \
    "$1" "$LANE" "$2" "$DONOR" "$3"
}

slb() {
  # slb <config dir|-> <session id|stdin JSON> — one render from `$SLB_DIR`
  # (default `$BW`) of `$SLB_SL` (default this checkout's script), with `TZ` at
  # `$SLB_TZ` (default UTC0), `CC_CMDS_AUTOPILOT_TZ` at `$SLB_DTZ` (default
  # unset, so the display zone is KST) and `CLAUDE_CONFIG_DIR` set to the first
  # argument or, for `-`, unset — for this one command only.
  local in="$2" dir="${SLB_DIR:-$BW}"
  case "$in" in
    '{'*) ;;
    *) in=$(fx_statusline_stdin "$2" "$dir") ;;
  esac
  if [ "$1" = - ]; then
    (cd "$dir" && printf '%s' "$in" | env -u CLAUDE_CONFIG_DIR -u CC_CMDS_AUTOPILOT_TZ \
      ${SLB_DTZ:+"CC_CMDS_AUTOPILOT_TZ=$SLB_DTZ"} TZ="${SLB_TZ:-UTC0}" bash "${SLB_SL:-$SL}")
  else
    (cd "$dir" && printf '%s' "$in" | env -u CC_CMDS_AUTOPILOT_TZ \
      ${SLB_DTZ:+"CC_CMDS_AUTOPILOT_TZ=$SLB_DTZ"} CLAUDE_CONFIG_DIR="$1" TZ="${SLB_TZ:-UTC0}" bash "${SLB_SL:-$SL}")
  fi
}
sb_in() { printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s"}' "$1" "$2" "$BW"; }
# The clock oracle is jq's over epoch + 9 hours, the default display zone —
# independent of the formatter under test.
sb_hm()   { jq -rn --argjson e "$(( $1 + 32400 ))" '$e | strftime("%H:%M")'; }
sb_mdhm() { jq -rn --argjson e "$(( $1 + 32400 ))" '$e | strftime("%m/%d %H:%M")'; }
sb_pad()  { local s="$1"; while [ "${#s}" -lt "$2" ]; do s="${s}x"; done; printf '%s' "$s"; }

E=$((NOW + 7200))
E_HM=$(sb_hm "$E")
SEG_LANE=" · cc→u3 · 홈 $E_HM"

# SB01. No record.
check "SB01 cc-lane 디렉터리 없음 — 대체 줄 그대로" "$(slb "$LANE" sess-none)" "$BFALL"
mkdir -p "$BREC_DIR"
check "SB01 cc-lane 디렉터리만 있고 기록 없음 — 대체 줄 그대로" "$(slb "$LANE" sess-none)" "$BFALL"

# SB02. `none`.
bputf '{"schema":"cc-lane-borrow v1","state":"none"}'
check "SB02 최소형 none — 대체 줄 그대로" "$(slb "$LANE" sess-none)" "$BFALL"
bputf "{\"schema\":\"cc-lane-borrow v1\",\"state\":\"none\",\"lane_config_dir\":\"$LANE\",\"donor\":{\"id\":\"u3\",\"config_dir\":\"$DONOR\"}}"
check "SB02 기증자 필드가 남은 none — 대체 줄 그대로" "$(slb "$LANE" sess-none)" "$BFALL"
bputf "{\"schema\":\"cc-lane-borrow v1\",\"state\":\"borrowed\",\"lane_config_dir\":\"$LANE\",\"donor\":{\"id\":\"u3\",\"config_dir\":\"$DONOR\"},\"state\":\"none\"}"
check "SB02 마지막이 none 인 중복 state — 대체 줄 그대로" "$(slb "$LANE" sess-none)" "$BFALL"

# The content fixtures SB03 and SB18 share. Each is the record's bytes, installed
# with `cp` so that a trailing newline survives.
BFX="$WORK/bfx"; mkdir -p "$BFX"
sbf() { printf '%s' "$2" > "$BFX/$1"; }
OKB='"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"id":"u3","config_dir":"/b"}'
sbf corrupt_garbage 'not json'
sbf corrupt_truncated '{"schema":"cc-lane-borrow v1","state":"borr'
: > "$BFX/corrupt_empty"
sbf corrupt_trailing_comma '{"schema":"cc-lane-borrow v1","state":"none",}'
sbf corrupt_trailing_garbage '{"schema":"cc-lane-borrow v1","state":"none"} x'
sbf corrupt_two_docs '{"schema":"cc-lane-borrow v1","state":"none"}{"schema":"cc-lane-borrow v1","state":"none"}'
sbf corrupt_toplevel_array '[{"schema":"cc-lane-borrow v1","state":"none"}]'
sbf corrupt_schema_v2 '{"schema":"cc-lane-borrow v2","state":"borrowed","lane_config_dir":"/a","donor":{"id":"u3","config_dir":"/b"}}'
sbf none_wrong_schema '{"schema":"cc-lane-borrow v2","state":"none"}'
sbf corrupt_schema_missing '{"state":"borrowed","lane_config_dir":"/a","donor":{"id":"u3","config_dir":"/b"}}'
sbf corrupt_state_missing '{"schema":"cc-lane-borrow v1","lane_config_dir":"/a","donor":{"id":"u3","config_dir":"/b"}}'
sbf corrupt_state_unknown '{"schema":"cc-lane-borrow v1","state":"pending","lane_config_dir":"/a","donor":{"id":"u3","config_dir":"/b"}}'
sbf corrupt_state_number '{"schema":"cc-lane-borrow v1","state":3,"lane_config_dir":"/a","donor":{"id":"u3","config_dir":"/b"}}'
sbf corrupt_state_case '{"schema":"cc-lane-borrow v1","state":"Borrowed","lane_config_dir":"/a","donor":{"id":"u3","config_dir":"/b"}}'
sbf corrupt_lane_missing '{"schema":"cc-lane-borrow v1","state":"borrowed","donor":{"id":"u3","config_dir":"/b"}}'
sbf corrupt_lane_empty '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"","donor":{"id":"u3","config_dir":"/b"}}'
sbf corrupt_lane_number '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":7,"donor":{"id":"u3","config_dir":"/b"}}'
sbf corrupt_donor_null '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":null}'
sbf corrupt_donor_string '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":"u3"}'
sbf corrupt_donor_id_missing '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"config_dir":"/b"}}'
sbf corrupt_donor_id_empty '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"id":"","config_dir":"/b"}}'
sbf corrupt_donor_id_number '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"id":3,"config_dir":"/b"}}'
sbf corrupt_donor_dir_missing '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"id":"u3"}}'
sbf corrupt_donor_dir_empty '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"id":"u3","config_dir":""}}'
sbf corrupt_decoy_group_id '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"config_dir":"/b","group":[{"id":"u3","config_dir":"/b"}]}}'
sbf corrupt_dup_donor_stale '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"id":"u3","config_dir":"/b"},"donor":{"config_dir":"/c"}}'
sbf corrupt_bad_literal '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"id":"u3","config_dir":"/b"},"x":tru}'
sbf corrupt_bom $'\xef\xbb\xbf{"schema":"cc-lane-borrow v1","state":"none"}'
sbf corrupt_nan '{"schema":"cc-lane-borrow v1","state":"none","x":NaN}'
sbf x_tab_unrelated "{$OKB,\"x\":\"a"$'\t'"b\"}"
sbf x_lone_surrogate "{$OKB,\"x\":\"${BS}ud800\"}"
SB_CORRUPT="corrupt_garbage corrupt_truncated corrupt_empty corrupt_trailing_comma
corrupt_trailing_garbage corrupt_two_docs corrupt_toplevel_array corrupt_schema_v2
none_wrong_schema corrupt_schema_missing corrupt_state_missing corrupt_state_unknown
corrupt_state_number corrupt_state_case corrupt_lane_missing corrupt_lane_empty
corrupt_lane_number corrupt_donor_null corrupt_donor_string corrupt_donor_id_missing
corrupt_donor_id_empty corrupt_donor_id_number corrupt_donor_dir_missing
corrupt_donor_dir_empty corrupt_decoy_group_id corrupt_dup_donor_stale
corrupt_bad_literal corrupt_bom corrupt_nan x_tab_unrelated x_lone_surrogate"

# Records the reader shows: the writer's grammar and its neighbours.
printf '%s' "$(bcanon intent '"five_hour"' 1791000000 '' intent/admit)" > "$BFX/canon_intent"
printf '%s' "$(bcanon borrowed '"five_hour"' 1791000000)" > "$BFX/canon_borrowed"
printf '%s' "$(bcanon returning '"seven_day"' null '' returning/settle)" > "$BFX/canon_returning"
printf '%s' "$(bcanon borrowed '"rejected"' null)" > "$BFX/canon_rejected"
printf '%s' "$(bcanon borrowed null 1791000000)" > "$BFX/canon_trigger_null"
printf '%s' "$(bcanon borrowed '"five_hour"' 1791000000 '' returning/settle)" > "$BFX/canon_stage_mismatch"
sbf borrowed_compact '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/Users/ian/.claude-cc","donor":{"id":"u3","config_dir":"/Users/ian/.claude-u3"},"trigger_window":"five_hour","home_windows":{"five_hour":{"utilization_bp":9100,"resets_at_epoch":1791000000},"seven_day":{"utilization_bp":null,"resets_at_epoch":null}}}'
sbf borrowed_reordered '{"donor":{"config_dir":"/Users/ian/.claude-u3","id":"u3"},"state":"borrowed","lane_config_dir":"/Users/ian/.claude-cc","schema":"cc-lane-borrow v1"}'
sbf borrowed_minimal_no_windows '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"id":"u3","config_dir":"/b"}}'
# The compact form route's own suite writes with `jq -c`, newline included.
sbf rb1_compact $'{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/lane","donor":{"id":"u3","config_dir":"/h/.claude-u3"},"since_epoch":1}\n'
sbf none_min '{"schema":"cc-lane-borrow v1","state":"none"}'
sbf none_junk_donor '{"schema":"cc-lane-borrow v1","state":"none","donor":"x","lane_config_dir":5}'
sbf dup_state_last_none '{"schema":"cc-lane-borrow v1","state":"borrowed","state":"none"}'
sbf dup_state_last_borrowed '{"schema":"cc-lane-borrow v1","state":"none","state":"borrowed","lane_config_dir":"/a","donor":{"id":"u3","config_dir":"/b"}}'
sbf x_raw_tab_in_id $'{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"id":"u\t3","config_dir":"/b"}}'
sbf x_raw_cr_in_id $'{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"id":"u\r3","config_dir":"/b"}}'
sbf x_raw_esc_in_id $'{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"id":"u\033[31m","config_dir":"/b"}}'
sbf x_raw_del_in_id $'{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"id":"u\177","config_dir":"/b"}}'
sbf x_bad_escape '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"id":"u3","config_dir":"/b"},"x":"\x"}'
sbf x_nul_escape "{$OKB,\"x\":\"${BS}u0000\"}"
sbf x_minus_only "{$OKB,\"n\":-}"
sbf x_ndjson $'{"schema":"cc-lane-borrow v1","state":"none"}\n{"schema":"cc-lane-borrow v1","state":"none"}\n'
sbf x_depth_20 "{$OKB,\"d\":$(printf '[%.0s' $(seq 1 20))1$(printf ']%.0s' $(seq 1 20))}"
sbf x_missing_comma '{"schema":"cc-lane-borrow v1" "state":"borrowed","lane_config_dir":"/a","donor":{"id":"u3","config_dir":"/b"}}'
sbf x_missing_colon '{"schema" "cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"id":"u3","config_dir":"/b"}}'
sbf x_colon_in_array "{$OKB,\"x\":[1:2]}"
sbf x_key_not_string "{$OKB,1:2}"
sbf x_mismatched_close '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"id":"u3","config_dir":"/b"],"x":1}'
sbf x_extra_close "{$OKB}}"
sbf x_donor_nested_decoy '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","x":{"donor":{"id":"u9","config_dir":"/z"}},"donor":{"id":"u3","config_dir":"/b"}}'
sbf x_id_in_nested_array_first '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"group":[{"id":"u9","config_dir":"/z"}],"id":"u3","config_dir":"/b"}}'
sbf x_dup_lane_second_empty '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","lane_config_dir":"","donor":{"id":"u3","config_dir":"/b"}}'
sbf x_dup_donor_object_then_null "{$OKB,\"donor\":null}"
sbf x_dup_state_object_second "{$OKB,\"state\":{}}"
sbf x_u2028_hangul $'{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/\xed\x99\x88","donor":{"id":"u3","config_dir":"/b\xe2\x80\xa8"}}'
sbf x_huge_exponent "{$OKB,\"n\":1e999}"
sbf x_slash_escape_unrelated "{$OKB,\"y\":\"${BS}/\"}"
sbf x_value_missing '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"id":"u3","config_dir":}}'
sbf x_only_open_brace '{'
sbf x_empty_object '{}'
sbf x_true_top 'true'
sbf x_string_top '"x"'
SB_SHOWN="canon_intent canon_borrowed canon_returning canon_rejected canon_trigger_null
canon_stage_mismatch borrowed_compact borrowed_reordered borrowed_minimal_no_windows
rb1_compact none_min none_junk_donor dup_state_last_none dup_state_last_borrowed
x_raw_tab_in_id x_raw_cr_in_id x_raw_esc_in_id x_raw_del_in_id x_bad_escape
x_nul_escape x_minus_only x_ndjson x_depth_20 x_missing_comma x_missing_colon
x_colon_in_array x_key_not_string x_mismatched_close x_extra_close
x_donor_nested_decoy x_id_in_nested_array_first x_dup_lane_second_empty
x_dup_donor_object_then_null x_dup_state_object_second x_u2028_hangul
x_huge_exponent x_slash_escape_unrelated x_value_missing x_only_open_brace
x_empty_object x_true_top x_string_top"

# The declared one-way rows: route says borrowing and the reader shows nothing.
{ printf '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"id":"u3","config_dir":"/b"},"pad":"'
  head -c 70000 /dev/zero | tr '\0' 'a'; printf '"}'; } > "$BFX/oversize"
sbf borrowed_ws_noise $'  \n{ "schema" : "cc-lane-borrow v1" ,\t"state"\n:\n"borrowed" , "lane_config_dir":"/a","donor":{"id":"u3","config_dir":"/b"} }\n\n'
sbf borrowed_id_escape "{\"schema\":\"cc-lane-borrow v1\",\"state\":\"borrowed\",\"lane_config_dir\":\"/a\",\"donor\":{\"id\":\"u${BS}u0033\",\"config_dir\":\"/b\"}}"
sbf borrowed_escaped_slash '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"\/Users\/ian\/.claude-cc","donor":{"id":"u3","config_dir":"\/Users\/ian\/.claude-u3"}}'
sbf x_quote_in_id '{"schema":"cc-lane-borrow v1","state":"borrowed","lane_config_dir":"/a","donor":{"id":"u\"3","config_dir":"/b"}}'
sbf x_id_u001b "{\"schema\":\"cc-lane-borrow v1\",\"state\":\"borrowed\",\"lane_config_dir\":\"/a\",\"donor\":{\"id\":\"u${BS}u001b[31m\",\"config_dir\":\"/b\"}}"
sbf x_crlf_layout $'{\r\n  "schema": "cc-lane-borrow v1",\r\n  "state": "borrowed",\r\n  "lane_config_dir": "/a",\r\n  "donor": {"id": "u3", "config_dir": "/b"}\r\n}'
sbf x_tab_indent $'{\n\t"schema": "cc-lane-borrow v1",\n\t"state": "borrowed",\n\t"lane_config_dir": "/a",\n\t"donor": {"id": "u3", "config_dir": "/b"}\n}'
sbf x_leading_zero "{$OKB,\"n\":01}"
sbf x_number_dot "{$OKB,\"n\":1.}"
sbf x_depth_40 "{$OKB,\"d\":$(printf '[%.0s' $(seq 1 40))1$(printf ']%.0s' $(seq 1 40))}"
sbf x_paired_surrogate "{$OKB,\"x\":\"${BS}ud83d${BS}ude00\"}"
sbf x_schema_u_escape "{\"schema\":\"cc-lane-borrow v${BS}u0031\",\"state\":\"borrowed\",\"lane_config_dir\":\"/a\",\"donor\":{\"id\":\"u3\",\"config_dir\":\"/b\"}}"
sbf x_state_u_escape "{\"schema\":\"cc-lane-borrow v1\",\"state\":\"borrow${BS}u0065d\",\"lane_config_dir\":\"/a\",\"donor\":{\"id\":\"u3\",\"config_dir\":\"/b\"}}"
SB_DECLINE="oversize borrowed_ws_noise borrowed_id_escape borrowed_escaped_slash
x_quote_in_id x_id_u001b x_crlf_layout x_tab_indent x_leading_zero x_number_dot
x_depth_40 x_paired_surrogate x_schema_u_escape x_state_u_escape"

sb_install() { bclear; mkdir -p "$BREC_DIR"; cp "$BFX/$1" "$BREC"; }
sb_cfg_of() {
  # sb_cfg_of <record> — the record's own lane directory as jq reads it, so the
  # view matches whenever the reader accepts it; `$LANE` when jq refuses.
  local v
  v=$(jq -r 'if (.lane_config_dir | type) == "string" and .lane_config_dir != "" then .lane_config_dir else empty end' \
        "$1" 2>/dev/null | sed -n '1p')
  printf '%s' "${v:-$LANE}"
}

# SB03. Document-level corruption, in the lane view the record itself names.
for n in $SB_CORRUPT; do
  sb_install "$n"
  check "SB03 문서 수준 손상 ($n) — 대체 줄 그대로" "$(slb "$(sb_cfg_of "$BREC")" sess-none)" "$BFALL"
done

# SB04. The shell layer: nothing here is opened as a record.
bclear; mkdir -p "$BREC"
out=$(slb "$LANE" sess-none); rc=$?
check "SB04 경로가 디렉터리 — 대체 줄, rc 0" "$rc|$out" "0|$BFALL"
bclear; mkdir -p "$BREC_DIR"; ln -s "$BFX/canon_borrowed" "$BREC"
out=$(slb "$LANE" sess-none); rc=$?
check "SB04 유효 기록으로의 심볼릭 링크 — 대체 줄, rc 0" "$rc|$out" "0|$BFALL"
bclear; mkdir -p "$BREC_DIR"; ln -s "$BFX/missing" "$BREC"
out=$(slb "$LANE" sess-none); rc=$?
check "SB04 끊어진 심볼릭 링크 — 대체 줄, rc 0" "$rc|$out" "0|$BFALL"
# A FIFO blocks whoever opens it. The watchdog bounds the render, which has to
# come back before it.
bclear; mkdir -p "$BREC_DIR"; mkfifo "$BREC"
slb "$LANE" sess-none > "$WORK/sb04-fifo.out" 2>/dev/null &
p=$!
( sleep 5; kill "$p" 2>/dev/null ) &
w=$!
rc=0; wait "$p" || rc=$?
kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
check "SB04 FIFO 는 열지 않고 감시견보다 먼저 대체 줄" "$rc|$(cat "$WORK/sb04-fifo.out")" "0|$BFALL"
if [ "$(id -u)" = "0" ]; then
  skip "SB04 권한 000 기록" "root 로는 권한 비트가 강제되지 않는다"
  skip "SB04 탐색할 수 없는 상위" "root 로는 권한 비트가 강제되지 않는다"
else
  sb_install canon_borrowed; chmod 000 "$BREC"
  out=$(slb "$LANE" sess-none); rc=$?
  check "SB04 권한 000 기록 — 대체 줄, rc 0" "$rc|$out" "0|$BFALL"
  sb_install canon_borrowed; chmod 000 "$BREC_DIR"
  out=$(slb "$LANE" sess-none); rc=$?
  chmod u+rwx "$BREC_DIR"
  check "SB04 탐색할 수 없는 상위 — 대체 줄, rc 0" "$rc|$out" "0|$BFALL"
fi

# SB05. The path rule. A relative state root, and an empty one beside an empty
# `HOME`, both derive no path; with the variable unset the record under
# `$HOME/.local/state` is found.
bclear
mkdir -p "$BW/rel/cc-lane"; cp "$BFX/canon_borrowed" "$BW/rel/cc-lane/borrow.json"
out=$(cd "$BW" && fx_statusline_stdin sess-none "$BW" \
      | env CLAUDE_CONFIG_DIR="$LANE" XDG_STATE_HOME=rel TZ=UTC0 bash "$SL")
check "SB05 상대 XDG_STATE_HOME — 대체 줄 그대로" "$out" "$BFALL"
out=$(cd "$BW" && fx_statusline_stdin sess-none "$BW" \
      | env CLAUDE_CONFIG_DIR="$LANE" XDG_STATE_HOME= HOME= TZ=UTC0 bash "$SL")
check "SB05 빈 XDG_STATE_HOME 과 빈 HOME — 대체 줄 그대로" "$out" "$BFALL"
SBH="$WORK/sbhome"
mkdir -p "$SBH/.local/state/cc-lane"
printf '%s' "$(bcanon borrowed '"five_hour"' "$E")" > "$SBH/.local/state/cc-lane/borrow.json"
out=$(cd "$BW" && fx_statusline_stdin sess-none "$BW" \
      | env -u XDG_STATE_HOME CLAUDE_CONFIG_DIR="$LANE" HOME="$SBH" TZ=UTC0 bash "$SL")
check "SB05 XDG 없이 HOME 아래 차용 기록 — 구간이 붙는다" "$out" "$BFALL$SEG_LANE"
if grep -qF 'if [ -z "${XDG_STATE_HOME:-}" ]; then base="$base/.local/state"; fi' "$SL" \
   && grep -qF 'SL_BFILE="$base/cc-lane/borrow.json"' "$SL"; then
  ok "SB05 차용 기록 경로 규칙의 문면이 고정돼 있다"
else
  bad "SB05 차용 기록 경로 규칙" "route__borrow_path 에서 옮겨 온 문면이 없다"
fi

# SB06. The lane view of `borrowed`, a five-hour reset two hours out.
bput borrowed '"five_hour"' "$E"
check "SB06 레인 보기 borrowed — 홈 리셋 시각" "$(slb "$LANE" sess-none)" "$BFALL$SEG_LANE"

# SB07. The clock's branches.
e=$((NOW + 3 * 86400)); bput borrowed '"five_hour"' "$e"
check "SB07a 사흘 뒤 — 날짜 꼴" "$(slb "$LANE" sess-none)" "$BFALL · cc→u3 · 홈 $(sb_mdhm "$e")"
bput borrowed '"five_hour"' "$((NOW - 60))"
check "SB07b 지난 리셋 — 리셋 지남" "$(slb "$LANE" sess-none)" "$BFALL · cc→u3 · 홈 리셋 지남"
# The script reads its own `now` a moment after this one, so each side of the
# 24-hour mark keeps two minutes of room.
e=$((NOW + 86400 - 120)); bput borrowed '"five_hour"' "$e"
check "SB07c 24시간 안쪽 — 시각 꼴" "$(slb "$LANE" sess-none)" "$BFALL · cc→u3 · 홈 $(sb_hm "$e")"
e=$((NOW + 86400 + 120)); bput borrowed '"five_hour"' "$e"
check "SB07c 24시간 바깥 — 날짜 꼴" "$(slb "$LANE" sess-none)" "$BFALL · cc→u3 · 홈 $(sb_mdhm "$e")"
bput borrowed '"five_hour"' null
check "SB07d 리셋 null — 시각 없는 구간" "$(slb "$LANE" sess-none)" "$BFALL · cc→u3"
e=$((NOW + 5 * 86400)); bput borrowed '"seven_day"' "$((NOW + 3600))" "$e"
check "SB07e seven_day 트리거는 seven_day 의 epoch 을 고른다" \
  "$(slb "$LANE" sess-none)" "$BFALL · cc→u3 · 홈 $(sb_mdhm "$e")"
for t in '"manual"' '"rejected"' null; do
  bput borrowed "$t" "$E"
  check "SB07f 트리거 $t — 시각 없음" "$(slb "$LANE" sess-none)" "$BFALL · cc→u3"
done
for v in "\"$E\"" "$E.5" -60 1791000000000; do
  bput borrowed '"five_hour"' "$v"
  check "SB07g epoch $v — 시각 없는 구간" "$(slb "$LANE" sess-none)" "$BFALL · cc→u3"
done

# SB08. The host `TZ` no longer moves the clock: under a daylight-saving rule
# string both seasons still read KST (2100-01-15T10:20Z and 2100-07-15T10:20Z
# plus nine hours). `CC_CMDS_AUTOPILOT_TZ` is what moves it.
bput borrowed '"five_hour"' 4103691600
check "SB08 TZ 가 일광 절약 규칙이어도 1월은 KST" \
  "$(SLB_TZ='EST5EDT,M3.2.0,M11.1.0' slb "$LANE" sess-none)" "$BFALL · cc→u3 · 홈 01/15 19:20"
check "SB08 CC_CMDS_AUTOPILOT_TZ=-05:00 이면 1월은 05:20" \
  "$(SLB_DTZ=-05:00 slb "$LANE" sess-none)" "$BFALL · cc→u3 · 홈 01/15 05:20"
bput borrowed '"five_hour"' 4119330000
check "SB08 TZ 가 일광 절약 규칙이어도 7월은 KST" \
  "$(SLB_TZ='EST5EDT,M3.2.0,M11.1.0' slb "$LANE" sess-none)" "$BFALL · cc→u3 · 홈 07/15 19:20"
check "SB08 CC_CMDS_AUTOPILOT_TZ=-05:00 이면 7월도 05:20 (서머타임 없음)" \
  "$(SLB_DTZ=-05:00 slb "$LANE" sess-none)" "$BFALL · cc→u3 · 홈 07/15 05:20"

# SB09. `intent` and `returning` carry no clock even with a valid epoch.
bput intent '"five_hour"' "$E" '' intent/admit
check "SB09 레인 보기 intent" "$(slb "$LANE" sess-none)" "$BFALL · cc→u3? (차용 확인 중)"
bput returning '"five_hour"' "$E" '' returning/settle
check "SB09 레인 보기 returning — 반환 중" "$(slb "$LANE" sess-none)" "$BFALL · cc←u3 (반환 중)"

# SB10. The donor view, from the donor account's own directory.
bput intent '"five_hour"' "$E" '' intent/admit
check "SB10 기증자 보기 intent" "$(slb "$DONOR" sess-none)" "$BFALL · 빌려 줌→cc? (차용 확인 중)"
bput borrowed '"five_hour"' "$E"
check "SB10 기증자 보기 borrowed — 시각 없음" "$(slb "$DONOR" sess-none)" "$BFALL · 빌려 줌→cc"
bput returning '"five_hour"' "$E" '' returning/settle
check "SB10 기증자 보기 returning" "$(slb "$DONOR" sess-none)" "$BFALL · 빌려 줌←cc (반환 중)"

# SB11. Whose session this is. Compares are exact strings; the environment beats
# the transcript; a group member lent nothing.
bput borrowed '"five_hour"' "$E"
check "SB11a 무관한 계정 디렉터리 — 대체 줄 그대로" "$(slb "$OTHER" sess-none)" "$BFALL"
check "SB11b donor.group 구성원 — 대체 줄 그대로" "$(slb "$G4" sess-none)" "$BFALL"
check "SB11c 끝 슬래시가 붙은 레인 디렉터리 — 대체 줄 그대로" "$(slb "$LANE/" sess-none)" "$BFALL"
check "SB11d 환경 없음 + 레인 transcript_path — 레인 보기" \
  "$(slb - "$(sb_in sess-none "$LANE/projects/x/s.jsonl")")" "$BFALL$SEG_LANE"
check "SB11e 환경 없음 + 기증자 transcript_path — 기증자 보기" \
  "$(slb - "$(sb_in sess-none "$DONOR/projects/x/s.jsonl")")" "$BFALL · 빌려 줌→cc"
check "SB11f 무관한 환경 + 레인 transcript_path — 환경이 이긴다" \
  "$(slb "$OTHER" "$(sb_in sess-none "$LANE/projects/x/s.jsonl")")" "$BFALL"
check "SB11g 환경 없음 + transcript_path /dev/null — 대체 줄 그대로" "$(slb - sess-none)" "$BFALL"
check "SB11h 환경 없음 + 접두 함정 transcript_path — 대체 줄 그대로" \
  "$(slb - "$(sb_in sess-none "${LANE}2/projects/x/s.jsonl")")" "$BFALL"

# SB12. Case 11's poisoned jq on PATH. The oracle was computed before it.
out=$(PATH="$WORK/poison:$PATH" slb "$LANE" sess-none)
check "SB12 jq 독 아래에서도 구간이 그대로" "$out" "$BFALL$SEG_LANE"
hasnt "SB12 차용 구간은 jq 를 부르지 않는다" "$out" "JQ-WAS-CALLED"

# SB13. The clock is shell arithmetic, so a broken `perl` on the PATH of the one
# render under test changes nothing. The fallback itself carries escapes, so "no
# ESC in the output" would always fail; the literal compare is what shows the
# stub's bytes did not leak.
mkdir -p "$WORK/perl127" "$WORK/perlesc"
printf '#!/bin/sh\nexit 127\n' > "$WORK/perl127/perl"
printf '#!/bin/sh\nprintf '"'"'\\033[31mX'"'"'\n' > "$WORK/perlesc/perl"
chmod +x "$WORK/perl127/perl" "$WORK/perlesc/perl"
out=$(PATH="$WORK/perl127:$PATH" slb "$LANE" sess-none); rc=$?
check "SB13a perl 이 127 이어도 시각을 그대로 그린다" "$rc|$out" "0|$BFALL$SEG_LANE"
out=$(PATH="$WORK/perlesc:$PATH" slb "$LANE" sess-none); rc=$?
check "SB13b perl 이 이스케이프를 내도 시각을 그대로 그리고 새지 않는다" "$rc|$out" "0|$BFALL$SEG_LANE"
# Without `display-tz.sh` beside the script the clock goes and the rest of the
# segment stays: a failed source is not a fallback.
mkdir -p "$WORK/nodtz"
cp "$SL" "$repo_root/plugins/cc-cmds/orchestrator/liveness.sh" "$WORK/nodtz/"
out=$(SLB_SL="$WORK/nodtz/statusline.sh" slb "$LANE" sess-none); rc=$?
check "SB13c display-tz.sh 없음 — 시각만 빠지고 대체 줄로 떨어지지 않는다" "$rc|$out" "0|$BFALL · cc→u3"

# SB14. On a run line the segment is a pure suffix, after the watcher slot too.
# A finished run carries no watcher slot, so the slot case is an approval line.
# That line also carries the ledger age, which can tick between two renders, so
# it is checked by what follows the slot rather than against an earlier render.
bclear
fx_mkrun run-sb14; fx_ledger_path; fx_segment S1 실행중; fx_approval A1 대기
fx_session_index sess-sb14 run-sb14
base14=$(slb "$LANE" sess-sb14)
fx_mkrun run-sb14-nc
fx_session_index sess-sb14-nc run-sb14-nc
base14nc=$(slb "$LANE" sess-sb14-nc)
has "SB14 전제 — 승인 대기 줄" "$base14" "⏸ run-sb14 승인 대기 1건"
check "SB14 전제 — 그 줄이 워처 슬롯으로 끝난다" "${base14##*" · 워처 미기동"}" ""
has "SB14 전제 — 시계 없는 버려짐 줄" "$base14nc" "⊘ run-sb14-nc 방치"
bput borrowed '"five_hour"' "$E"
out14=$(slb "$LANE" sess-sb14)
has "SB14 승인 대기 줄 — 구간을 붙여도 줄은 그대로" "$out14" "⏸ run-sb14 승인 대기 1건"
check "SB14 승인 대기 줄 — 워처 슬롯 바로 뒤에 구간" "${out14##*" · 워처 미기동"}" "$SEG_LANE"
check "SB14 시계 없는 버려짐 줄 — 줄 끝에 구간" "$(slb "$LANE" sess-sb14-nc)" "$base14nc$SEG_LANE"
# The run line drawn without `display-tz.sh`: still the run line, not the
# fallback, with only the clock gone from the segment.
check "SB14 display-tz.sh 없음 — 런 줄 그대로, 시계 없는 구간" \
  "$(SLB_SL="$WORK/nodtz/statusline.sh" slb "$LANE" sess-sb14-nc)" "$base14nc · cc→u3"

# SB15. The width budget. This suite pins no locale, so `${#…}` counts
# characters or bytes depending on the shell that started it, and every length
# below is chosen so that each has/hasnt holds under both counts. The segment
# with its clock is 18 characters / 24 bytes; without it 8 / 11. The 도는중 line
# `⟳ <id> S1 implement MM:SS` is id+21 characters / id+23 bytes, and without its
# kind id+11 / id+13.
sb_run15() {
  # sb_run15 <run id> — a run whose live stage S1 has a recorded kind.
  #
  # The fingerprint is a local start time and `slb` renders under UTC0, so it is
  # recorded under UTC0 too; captured in this shell's zone it would not match,
  # and the stage would quietly not count as live.
  fx_mkrun "$1"; fx_ledger_path; fx_segment S1 실행중
  fx_row 'stage-result' "세그먼트=S1" "종류=implement"
  TZ=UTC0 fx_stage_live S1; fx_heartbeat 0 5
  fx_session_index "sess-$1" "$1"
}
bput borrowed '"five_hour"' "$E"
# (a) id 35: with the detail 74 / 82, over; without it 64 / 69, inside — so the
# detail goes and the kind stays.
rid=$(sb_pad run-sb15a- 35); sb_run15 "$rid"
out=$(slb "$LANE" "sess-$rid")
has   "SB15a 전제 — 스테이지 슬롯이 있는 도는중 줄" "$out" "⟳ $rid S1"
has   "SB15a 세부만 버리면 맞는 도는중 — MARK 가 남는다" "$out" "cc→u3"
hasnt "SB15a 세부가 먼저 버려진다" "$out" "홈 "
has   "SB15a 종류는 남는다" "$out" "implement"
# (b) id 46: the short segment with the kind 75 / 80, over; without the kind
# 65 / 70, inside.
rid=$(sb_pad run-sb15b- 46); sb_run15 "$rid"
out=$(slb "$LANE" "sess-$rid")
has   "SB15b 전제 — 스테이지 슬롯이 있는 도는중 줄" "$out" "⟳ $rid S1"
has   "SB15b 종류까지 버려야 하는 도는중 — MARK 가 남는다" "$out" "cc→u3"
hasnt "SB15b 종류가 버려진다" "$out" "implement"
# (c) id 80: nothing fits, and the mark still stays.
rid=$(sb_pad run-sb15c- 80); sb_run15 "$rid"
has "SB15c 예산을 넘는 극단적인 id 에서도 MARK 가 남는다" "$(slb "$LANE" "sess-$rid")" "cc→u3"
# (d) a fallback line from a directory named with 55 characters: `[cc🎨] <name>`
# is 61 characters / 64 bytes, with the segment 79 / 88.
SBLONG="$WORK/$(sb_pad d 55)"; mkdir -p "$SBLONG"
out=$(SLB_DIR="$SBLONG" slb "$LANE" sess-none)
hasnt "SB15d 긴 이름 디렉터리의 대체 줄 — 세부가 버려진다" "$out" "홈 "
has   "SB15d 긴 이름 디렉터리의 대체 줄 — MARK 가 남는다" "$out" "cc→u3"
# (e) the same fallback with `intent`, whose gloss is 19 characters / 32 bytes
# with its mark: 80 / 96.
bput intent '"five_hour"' "$E" '' intent/admit
out=$(SLB_DIR="$SBLONG" slb "$LANE" sess-none)
hasnt "SB15e intent 의 풀이도 같은 방식으로 버려진다" "$out" "확인 중"
has   "SB15e intent 의 MARK 는 남는다" "$out" "cc→u3?"
# (f) a 도는중 line with no stage slot — the only live pid is the watcher's,
# which the count takes and the slot does not — so the line is
# `⟳ <id> · 원장 N초 전`: id 50 is 62 characters / 73 bytes, with the segment
# 80 / 97. Only the judgement after the arms can drop the detail here.
bput borrowed '"five_hour"' "$E"
rid=$(sb_pad run-sb15f- 50)
fx_mkrun "$rid"; fx_ledger_path; fx_segment S1 실행중
TZ=UTC0 fx_stage_live watch; fx_heartbeat 0 5
fx_session_index "sess-$rid" "$rid"
out=$(slb "$LANE" "sess-$rid")
has   "SB15f 전제 — 슬롯 없는 도는중 줄" "$out" "⟳ $rid · 원장"
has   "SB15f 슬롯 없는 도는중 — MARK 가 남는다" "$out" "cc→u3"
hasnt "SB15f 슬롯 없는 도는중 — 세부가 버려진다" "$out" "홈 "

# SB16. A partial checkout: case 13's copy, with no `liveness.sh` beside it. It
# has no `display-tz.sh` either, so the segment comes without its clock; a copy
# that does have the helper keeps the clock on the fallback line.
bput borrowed '"five_hour"' "$E"
check "SB16 liveness.sh 없는 사본에서도 구간이 붙는다 (도우미도 없어 시계는 없다)" \
  "$(SLB_SL="$WORK/partial/statusline.sh" slb "$LANE" sess-none)" "$BFALL · cc→u3"
mkdir -p "$WORK/partial-dtz"
cp "$WORK/partial/statusline.sh" "$repo_root/plugins/cc-cmds/orchestrator/display-tz.sh" "$WORK/partial-dtz/"
check "SB16 liveness.sh 없고 도우미만 있는 사본은 시계까지 붙는다" \
  "$(SLB_SL="$WORK/partial-dtz/statusline.sh" slb "$LANE" sess-none)" "$BFALL$SEG_LANE"

# SB19. Ids the terminal must not see. Written raw, each is a valid record route
# calls borrowing; the line shows the mark with `?` in the id's place.
for id in 'u 3' 'u$3' '가' "$(sb_pad u 40)"; do
  bputf "$(bflat borrowed "$id" "$E")"
  check "SB19 표시할 수 없는 id ($id) — ? 로 바뀐다" "$(slb "$LANE" sess-none)" "$BFALL · cc→? · 홈 $E_HM"
  if command -v jq >/dev/null 2>&1; then
    check "SB19 그 기록을 route 는 여전히 차용 중으로 본다 ($id)" \
      "$(bash "$ROUTE" borrow-read "$BREC" | jq -r '.state')" "borrowed"
  else
    skip "SB19 route 판정 ($id)" "jq 가 없다"
  fi
done

# SB20. The vocabulary is route's. Read as file text, not run as jq.
n=$(grep -c '^def rt_borrowing:' "$ROUTE")
if [ "$n" = "1" ]; then
  ok "SB20 route.sh 의 rt_borrowing 정의는 정확히 하나다"
  lits=$(grep '^def rt_borrowing:' "$ROUTE" | grep -o '"[a-z]*"')
  check "SB20 rt_borrowing 의 상태 리터럴은 셋이다" "$(printf '%s\n' "$lits" | grep -c .)" "3"
  for lit in $lits; do
    st=${lit//\"/}
    bput "$st" '"five_hour"' "$E" '' "$st/steady"
    has "SB20 route 의 차용 상태 $st 에 구간이 있다" "$(slb "$LANE" sess-none)" "$BFALL · cc"
  done
else
  bad "SB20 route.sh 의 rt_borrowing 정의" "^def rt_borrowing: 줄이 ${n}개다"
fi

# SB18. LIVE equivalence with `route.sh borrow-read`, one check per fixture.
# Soundness always: no segment unless route says borrowing. Everywhere outside
# the declared one-way rows the two agree on showing; on those rows route says
# borrowing and the line shows nothing. A displayable id is route's donor.
sb18_verdict() {
  # sb18_verdict <decline|agree> <route output> <render> <render rc>
  local cls="$1" r="$2" out="$3" rc="$4" st rd rb=0 shown=0 id="" disp=1
  st=$(printf '%s' "$r" | jq -r '.state' 2>/dev/null)
  rd=$(printf '%s' "$r" | jq -r '.donor // ""' 2>/dev/null)
  case "$st" in intent|borrowed|returning) rb=1 ;; esac
  [ "$out" = "$BFALL" ] || shown=1
  case "$out" in
    "$BFALL · cc→"*) id=${out#"$BFALL · cc→"} ;;
    "$BFALL · cc←"*) id=${out#"$BFALL · cc←"} ;;
  esac
  id=${id%%[? ]*}
  case "$rd" in
    ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*) disp=0 ;;
  esac
  [ "${#rd}" -le 32 ] || disp=0
  if [ "$rc" != "0" ]; then printf 'rc=%s' "$rc"
  elif [ "$out" != "${out%$'\n'*}" ]; then printf '여러 줄'
  elif [ "$rb" = 0 ] && [ "$shown" = 1 ]; then printf '건전성 위반: route=%s 인데 구간' "$st"
  elif [ "$cls" = decline ] && { [ "$rb" = 0 ] || [ "$shown" = 1 ]; }; then
    printf '선언된 거절이 아님: route=%s 구간=%s' "$st" "$shown"
  elif [ "$cls" = agree ] && [ "$rb" != "$shown" ]; then printf '불일치: route=%s 구간=%s' "$st" "$shown"
  elif [ "$shown" = 1 ] && [ "$disp" = 1 ] && [ "$id" != "$rd" ]; then
    printf 'id 불일치: 보임=%s route=%s' "$id" "$rd"
  else printf ok
  fi
}
if command -v jq >/dev/null 2>&1; then
  for n in $SB_CORRUPT $SB_SHOWN $SB_DECLINE; do
    cls=agree
    case " $(printf '%s' "$SB_DECLINE" | tr '\n' ' ') " in *" $n "*) cls=decline ;; esac
    sb_install "$n"
    out=$(slb "$(sb_cfg_of "$BREC")" sess-none); rc=$?
    check "SB18 route 동치 ($n)" \
      "$(sb18_verdict "$cls" "$(bash "$ROUTE" borrow-read "$BREC")" "$out" "$rc")" ok
  done

  # The shell layer, in the file-argument form.
  bclear; mkdir -p "$BREC"
  out=$(slb "$LANE" sess-none); rc=$?
  check "SB18 route 동치 (디렉터리)" "$(sb18_verdict agree "$(bash "$ROUTE" borrow-read "$BREC")" "$out" "$rc")" ok
  bclear; mkdir -p "$BREC_DIR"; ln -s "$BFX/canon_borrowed" "$BREC"
  out=$(slb "$LANE" sess-none); rc=$?
  check "SB18 route 동치 (심볼릭 링크)" "$(sb18_verdict agree "$(bash "$ROUTE" borrow-read "$BREC")" "$out" "$rc")" ok
  bclear; mkdir -p "$BREC_DIR"; ln -s "$BFX/missing" "$BREC"
  out=$(slb "$LANE" sess-none); rc=$?
  check "SB18 route 동치 (끊어진 심볼릭 링크)" "$(sb18_verdict agree "$(bash "$ROUTE" borrow-read "$BREC")" "$out" "$rc")" ok
  bclear; mkdir -p "$BREC_DIR"; mkfifo "$BREC"
  check "SB18 route 동치 (FIFO)" \
    "$(sb18_verdict agree "$(bash "$ROUTE" borrow-read "$BREC")" "$(cat "$WORK/sb04-fifo.out")" 0)" ok
  if [ "$(id -u)" != "0" ]; then
    sb_install canon_borrowed; chmod 000 "$BREC"
    out=$(slb "$LANE" sess-none); rc=$?
    check "SB18 route 동치 (권한 000)" "$(sb18_verdict agree "$(bash "$ROUTE" borrow-read "$BREC")" "$out" "$rc")" ok
    sb_install canon_borrowed; chmod 000 "$BREC_DIR"
    out=$(slb "$LANE" sess-none); rc=$?
    r=$(bash "$ROUTE" borrow-read "$BREC"); chmod u+rwx "$BREC_DIR"
    check "SB18 route 동치 (탐색할 수 없는 상위)" "$(sb18_verdict agree "$r" "$out" "$rc")" ok
  fi

  # Path derivation, in the argument-less form under the render's own
  # environment: the file-argument form never derives a path.
  bclear
  out=$(slb "$LANE" sess-none); rc=$?
  check "SB18 route 동치 (기록 디렉터리 없음)" "$(sb18_verdict agree "$(bash "$ROUTE" borrow-read)" "$out" "$rc")" ok
  mkdir -p "$BREC_DIR"
  out=$(slb "$LANE" sess-none); rc=$?
  check "SB18 route 동치 (기록 없음)" "$(sb18_verdict agree "$(bash "$ROUTE" borrow-read)" "$out" "$rc")" ok
  out=$(cd "$BW" && fx_statusline_stdin sess-none "$BW" \
        | env CLAUDE_CONFIG_DIR="$LANE" XDG_STATE_HOME=rel TZ=UTC0 bash "$SL"); rc=$?
  r=$(cd "$BW" && env XDG_STATE_HOME=rel bash "$ROUTE" borrow-read)
  check "SB18 route 동치 (상대 XDG_STATE_HOME)" "$(sb18_verdict agree "$r" "$out" "$rc")" ok
  out=$(cd "$BW" && fx_statusline_stdin sess-none "$BW" \
        | env CLAUDE_CONFIG_DIR="$LANE" XDG_STATE_HOME= HOME= TZ=UTC0 bash "$SL"); rc=$?
  r=$(env XDG_STATE_HOME= HOME= bash "$ROUTE" borrow-read)
  check "SB18 route 동치 (빈 XDG_STATE_HOME 과 빈 HOME)" "$(sb18_verdict agree "$r" "$out" "$rc")" ok
  out=$(cd "$BW" && fx_statusline_stdin sess-none "$BW" \
        | env -u XDG_STATE_HOME CLAUDE_CONFIG_DIR="$LANE" HOME="$SBH" TZ=UTC0 bash "$SL"); rc=$?
  r=$(env -u XDG_STATE_HOME HOME="$SBH" bash "$ROUTE" borrow-read)
  check "SB18 route 동치 (XDG 없이 HOME)" "$(sb18_verdict agree "$r" "$out" "$rc")" ok
else
  skip "SB18 route 동치" "jq 가 없다"
fi
rm -rf "$BW/rel"

# SB17. The segment writes nothing: the renders SB06, SB09, SB10, SB14 and SB16
# make leave every file under the state root and the config directories as they
# were, and every one of them exits 0.
sb_sums() { find "$WORK/bstate" "$WORK/cfg" -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort; }
sb17_ok=1
for st in intent borrowed returning; do
  bput "$st" '"five_hour"' "$E" '' "$st/steady"
  before=$(sb_sums)
  for args in "$LANE sess-none" "$DONOR sess-none" "$LANE sess-sb14"; do
    set -- $args
    slb "$1" "$2" >/dev/null || sb17_ok=0
  done
  SLB_SL="$WORK/partial/statusline.sh" slb "$LANE" sess-none >/dev/null || sb17_ok=0
  [ "$(sb_sums)" = "$before" ] || sb17_ok=0
done
check "SB17 렌더는 상태 루트와 설정 디렉터리에 아무것도 쓰지 않고 모두 rc 0" "$sb17_ok" "1"
bclear

printf '\n통과 %s · 실패 %s · 건너뜀 %s\n' "$passed" "$failed" "$skipped"
[ "$failed" -eq 0 ]
