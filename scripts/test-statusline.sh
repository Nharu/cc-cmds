#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test the status line and the apply path that installs it.
#
# TWO GUARANTEES THAT DO NOT COVER EACH OTHER. The apply proves the settings
# file ends up correct and no worse than it started; this suite proves the
# script is TOTAL — that every degraded input still yields one valid line and
# exit 0. The apply's own verify run exercises whichever branch the installed
# path happens to reach on that machine, so it can never stand in for the cases
# below, and a green apply is not evidence that the script works.
#
# WHAT THE ISOLATION HIDES. Every case here sets `XDG_STATE_HOME`, so the real
# environment's branch — the variable unset, falling back to `$HOME/.local/state`
# — is never executed. That shape is pinned by a separate textual assertion
# rather than left to the fixture, which by construction cannot reach it.
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


script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
SL="$repo_root/plugins/cc-cmds/orchestrator/statusline.sh"
APPLY="$repo_root/plugins/cc-cmds/orchestrator/apply-statusline.sh"
LIVENESS="$repo_root/plugins/cc-cmds/orchestrator/liveness.sh"
. "$repo_root/scripts/run-fixture.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-statusline-test.XXXXXX")
XDG_STATE_HOME="$WORK/state"
export XDG_STATE_HOME
mkdir -p "$XDG_STATE_HOME"
trap 'fx_reap; chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# THE APPLY CASES INSTALL FROM A COPY, NOT FROM THIS CHECKOUT. `--plugin-dir`
# now parks on a linked git worktree, and this suite is run from one about as
# often as from a clone — pointing the apply at its own tree would make every
# case below pass or park depending on where somebody happened to check the
# repository out. The copy is made here rather than carried in the repository so
# it cannot drift from the files it is a copy of.
APLUG="$WORK/plugin"
mkdir -p "$APLUG/orchestrator"
cp "$SL" "$LIVENESS" "$APLUG/orchestrator/"
chmod +x "$APLUG/orchestrator/statusline.sh"

passed=0; failed=0; skipped=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
skip() { skipped=$((skipped + 1)); printf 'SKIP: %s — %s\n' "$1" "${2:-}"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
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

# The "no run" line. Byte-identical to every degraded path's output, which is
# the property cases 10-13 exist to hold in place.
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
if [ -n "$ref_cmd" ]; then
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
hasnt "8a 종단이 정지 경고보다 앞선다" "$(sl sess-8a)" "⚠"

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
# A1-A10. The five-rank grade, and the render for the bottom rank
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

fx_mkrun run-a10-term; fx_ledger_path; fx_segment S1 머지됨; fx_heartbeat 0 5
fx_session_index sess-a10 run-a10 run-a10-term
out=$(sl sess-a10)
has "A10 그 런은 종단 런 아래 단이다" "$out" "run-a10-term"
hasnt "A10 경계의 런이 종단을 이기지 않는다" "$out" "⚠"

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
# bit makes that guard permanently false: every render takes the fallback, the
# apply's verify run takes the fallback too and passes all five conditions, and
# the pipeline records a dead status line as a success. Losing the bit is
# silent everywhere except here.
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

# ---------------------------------------------------------------------------
# The apply path.
#
# A fixture settings file throughout — the real one is never touched.
# ---------------------------------------------------------------------------
mk_settings() {
  # mk_settings <path> [command] — a settings file shaped like the real one:
  # several unrelated keys around the one this design owns.
  local p="$1" c="${2:-printf 'PRE-APPLY-LITERAL'}"
  jq -n --arg c "$c" \
    '{theme: "dark", model: "opus", statusLine: {type: "command", command: $c}, cleanupPeriodDays: 30}' \
    > "$p"
}

digest_of() { jq -S -c '.statusLine' "$1" | shasum -a 256 | cut -d' ' -f1; }

S1F="$WORK/settings-normal.json"; mk_settings "$S1F"
EXPECT1=$(digest_of "$S1F")

bash "$APPLY" --probe --settings "$S1F" --plugin-dir "$APLUG" --expect "$EXPECT1" >/dev/null 2>&1
check "적용 사전 프로브 — 옛 값이면 2(진행)" "$?" "2"

out=$(bash "$APPLY" --apply --settings "$S1F" --plugin-dir "$APLUG" --expect "$EXPECT1" 2>&1)
check "적용 — 종료 코드 0" "$?" "0"
has "적용 — 백업 포인터를 표준출력으로 낸다" "$out" "백업:"
has "적용 — 변경 탐지용 전체 다이제스트를 함께 낸다" "$out" "적용 후 전체 sha256:"
check "적용 — 무관한 키가 보존된다" "$(jq -r '.theme + "/" + .model' "$S1F")" "dark/opus"
check "적용 — 키 수가 늘지 않는다" "$(jq -r '[keys[]] | length' "$S1F")" "4"
has "적용 — 설치된 명령이 방어적 가드다" \
  "$(jq -r '.statusLine.command' "$S1F")" "[ -x \"$APLUG/orchestrator/statusline.sh\" ]"
has "적용 — 사용자의 기존 명령이 폴백으로 남는다" \
  "$(jq -r '.statusLine.command' "$S1F")" "|| printf 'PRE-APPLY-LITERAL'"
has "적용 — exec bash 이지 exec <경로> 가 아니다" \
  "$(jq -r '.statusLine.command' "$S1F")" "exec bash \"$APLUG/orchestrator/statusline.sh\""
n=$(ls "$WORK"/settings-normal.json.pre-statusline-* 2>/dev/null | grep -c . || true)
check "적용 — 대상 파일 옆에 기존 명명 관례로 백업이 남는다" "$n" "1"

bash "$APPLY" --probe --settings "$S1F" --plugin-dir "$APLUG" --expect "$EXPECT1" >/dev/null 2>&1
check "적용 사후 프로브 — 같은 인자로 0(수렴)" "$?" "0"

# The subobject digest is what makes this survive a neighbour's edit; a
# whole-file hash would have parked here.
jq '.newUnrelatedKey = "drifted"' "$S1F" > "$S1F.tmp" && mv "$S1F.tmp" "$S1F"
bash "$APPLY" --probe --settings "$S1F" --plugin-dir "$APLUG" --expect "$EXPECT1" >/dev/null 2>&1
check "프로브 — 무관한 키 표류에 걸리지 않는다" "$?" "0"

# Applying twice must not nest the wrapper inside its own fallback.
bash "$APPLY" --apply --settings "$S1F" --plugin-dir "$APLUG" --expect "$EXPECT1" >/dev/null 2>&1
n=$(jq -r '.statusLine.command' "$S1F" | grep -c 'exec bash' || true)
check "적용은 멱등이다 — 두 번 적용해도 래퍼가 겹치지 않는다" "$n" "1"

S3F="$WORK/settings-third.json"; mk_settings "$S3F" "printf 'SOMEBODY-ELSE'"
bash "$APPLY" --probe --settings "$S3F" --plugin-dir "$APLUG" --expect "$EXPECT1" >/dev/null 2>&1
check "프로브 — 제삼자가 손댄 값이면 1(park)" "$?" "1"

# ---------------------------------------------------------------------------
# The applies that must not write
# ---------------------------------------------------------------------------
S4F="$WORK/settings-guard.json"; mk_settings "$S4F"
E4=$(digest_of "$S4F"); B4=$(shasum -a 256 "$S4F" | cut -d' ' -f1)

bash "$APPLY" --apply --settings "$S4F" --plugin-dir "" --expect "$E4" >/dev/null 2>&1
check "--plugin-dir 이 비면 쓰기 전에 park 한다" "$?" "1"
bash "$APPLY" --apply --settings "$S4F" --plugin-dir "relative/path" --expect "$E4" >/dev/null 2>&1
check "--plugin-dir 이 절대경로가 아니면 쓰기 전에 park 한다" "$?" "1"
bash "$APPLY" --apply --settings "$S4F" --plugin-dir "$APLUG" >/dev/null 2>&1
check "--expect 는 생략할 수 없다" "$?" "1"
check "park 한 세 경우 모두 파일을 건드리지 않았다" "$(shasum -a 256 "$S4F" | cut -d' ' -f1)" "$B4"

# ---------------------------------------------------------------------------
# The absolute paths that are still wrong.
#
# Every case here was measured landing as `apply rc=0` AND `post-probe rc=0` —
# the driver's only success condition — while the installed command rendered the
# fallback forever. None of them can be caught after the write: the verify run
# feeds a session id with no index, so the script's own "no run" output and the
# fallback are the same bytes and the five conditions pass on either branch.
# ---------------------------------------------------------------------------
S7F="$WORK/settings-path.json"; mk_settings "$S7F"
E7=$(digest_of "$S7F"); B7=$(shasum -a 256 "$S7F" | cut -d' ' -f1)

bash "$APPLY" --apply --settings "$S7F" --plugin-dir "$WORK/does-not-exist" --expect "$E7" >/dev/null 2>&1
check "절대경로이나 존재하지 않는 트리 — 쓰기 전에 park 한다" "$?" "1"

mkdir -p "$WORK/partial-plugin/orchestrator"
bash "$APPLY" --apply --settings "$S7F" --plugin-dir "$WORK/partial-plugin" --expect "$E7" >/dev/null 2>&1
check "statusline.sh 만 없는 부분 체크아웃 — 쓰기 전에 park 한다" "$?" "1"

mkdir -p "$WORK/nobit/orchestrator"
cp "$SL" "$WORK/nobit/orchestrator/statusline.sh"
chmod -x "$WORK/nobit/orchestrator/statusline.sh"
bash "$APPLY" --apply --settings "$S7F" --plugin-dir "$WORK/nobit" --expect "$E7" >/dev/null 2>&1
check "파일은 있으나 실행 비트가 없음 — 쓰기 전에 park 한다" "$?" "1"

check "경로 성질로 park 한 세 경우 모두 파일을 건드리지 않았다" \
  "$(shasum -a 256 "$S7F" | cut -d' ' -f1)" "$B7"

# The throwaway worktree — the one shape that passes all three checks above and
# is gone seconds later. Its sibling assertion matters as much: an ordinary
# checkout must NOT park, and the two differ only in how git answers about them.
if command -v git >/dev/null 2>&1; then
  # EVERY PATH BELOW REACHES THE CHECKOUT THROUGH A SYMLINK, and the plugin
  # directory is a SUBDIRECTORY of it. Together those two are the shape
  # `--plugin-dir` actually has, and the only shape in which the two git answers
  # differ as strings while naming one directory: git answers `--git-dir`
  # physically absolute and `--git-common-dir` relative, so resolving the second
  # one logically keeps the symlink the caller walked in through.
  #
  # Built at the checkout ROOT instead, this fixture proves nothing — there git
  # answers both relative to the same place, and the assertion passes whether
  # the compare normalises physically, logically, or not at all. That is how it
  # stayed green over a compare that parked every ordinary checkout reached
  # through `/tmp` or `/var`, which on this platform is all of them.
  mkdir -p "$WORK/wt-real"
  ln -s "$WORK/wt-real" "$WORK/wt-via"
  WT_MAIN="$WORK/wt-via/main"
  WT_MAIN_PLUG="$WT_MAIN/plugins/cc-cmds"
  mkdir -p "$WT_MAIN_PLUG/orchestrator"
  cp "$SL" "$LIVENESS" "$WT_MAIN_PLUG/orchestrator/"
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
    S8F="$WORK/settings-wt.json"; mk_settings "$S8F"; E8=$(digest_of "$S8F")
    B8=$(shasum -a 256 "$S8F" | cut -d' ' -f1)
    bash "$APPLY" --apply --settings "$S8F" --plugin-dir "$WT_LINKED_PLUG" --expect "$E8" >/dev/null 2>&1
    check "임시 워크트리를 가리키는 --plugin-dir — 쓰기 전에 park 한다" "$?" "1"
    check "워크트리로 park — 파일을 건드리지 않았다" \
      "$(shasum -a 256 "$S8F" | cut -d' ' -f1)" "$B8"
    bash "$APPLY" --apply --settings "$S8F" --plugin-dir "$WT_MAIN_PLUG" --expect "$E8" >/dev/null 2>&1
    check "심링크를 경유한 본 체크아웃의 하위 디렉터리는 park 하지 않는다" "$?" "0"
  else
    skip "임시 워크트리 park" "git worktree 를 만들 수 없다"
  fi
else
  skip "임시 워크트리 park" "git 이 없다"
fi

# The space that made the installed `[` fail with too many arguments. Comparing
# against the live render rather than against "not the fallback literal" is what
# makes this prove the guard was TRUE — the two branches are otherwise only
# distinguishable by which script produced the bytes.
SPACED="$WORK/plugin with space"
mkdir -p "$SPACED/orchestrator"
cp "$SL" "$LIVENESS" "$SPACED/orchestrator/"
chmod +x "$SPACED/orchestrator/statusline.sh"
S9F="$WORK/settings-spaced.json"; mk_settings "$S9F"; E9=$(digest_of "$S9F")
bash "$APPLY" --apply --settings "$S9F" --plugin-dir "$SPACED" --expect "$E9" >/dev/null 2>&1
check "공백이 든 절대경로 — 적용이 성공한다" "$?" "0"
check "공백이 든 절대경로 — 설치된 명령이 폴백이 아니라 그 스크립트를 부른다" \
  "$(fx_statusline_stdin sess-live | sh -c "$(jq -r '.statusLine.command' "$S9F")" | strip_clock)" \
  "$(sl sess-live | strip_clock)"

# ---------------------------------------------------------------------------
# The absolute paths the installed guard cannot survive being re-evaluated over.
#
# What lands in the settings file is a STRING, and the harness hands that string
# to `sh -c` on every render — so the double quotes around the path stop a space
# and nothing else. A `$`, a backtick or a `"` inside it is expanded at that
# second evaluation, the guard is false forever, and the apply still lands rc=0
# because the verify run cannot tell the guard's two branches apart: the session
# id it feeds has no index, so the script's own "no run" output and the fallback
# are the same bytes.
#
# BOTH DIRECTIONS OR NEITHER. A check written as "reject these characters"
# instead of as "the guard about to be installed is true" parks ordinary applies
# too, and that failure is not hypothetical — it is what parked every legitimate
# checkout the last time this pair was one-sided. A backslash and a newline come
# through the second evaluation untouched, so they must still install, and what
# they install must still call the script; the two blocks below are one case.
# ---------------------------------------------------------------------------
SREF="$WORK/settings-reeval.json"; mk_settings "$SREF"
EREF=$(digest_of "$SREF"); BREF=$(shasum -a 256 "$SREF" | cut -d' ' -f1)

# THE FOURTH NAME PINS THE STRATEGY, NOT A CHARACTER. The three before it are
# the characters a reader would enumerate, so a pre-evaluation rewritten as
# "reject `$`, `"` and a backtick" keeps all three of them red — and installs a
# dead status line for the fourth. Two backslashes pass such an enumeration
# untouched and still collapse to one at the render's second evaluation, so the
# installed guard then tests a path that does not exist, is false forever, and
# the apply lands rc=0 anyway. Measured: with the pre-evaluation replaced by
# that enumeration this suite is green except for this one case.
#
# Its sibling below is the ACCEPT case for a SINGLE backslash, which the second
# evaluation does leave alone. The pair is what keeps this from being read as
# "backslashes are dangerous" — the question is whether the guard about to be
# installed is true, not which characters somebody has thought of.
mkdir -p "$WORK/reeval"
for bad_name in 'plug$dollar' 'plug"quote' 'plug`tick`' 'plug\\double'; do
  bad_plug="$WORK/reeval/$bad_name"
  mkdir -p "$bad_plug/orchestrator"
  cp "$SL" "$LIVENESS" "$bad_plug/orchestrator/"
  chmod +x "$bad_plug/orchestrator/statusline.sh"
  bash "$APPLY" --apply --settings "$SREF" --plugin-dir "$bad_plug" --expect "$EREF" >/dev/null 2>&1
  check "재평가에서 해석되는 문자가 든 절대경로 ($bad_name) — 쓰기 전에 park 한다" "$?" "1"
done
check "재평가로 park 한 네 경우 모두 파일을 건드리지 않았다" \
  "$(shasum -a 256 "$SREF" | cut -d' ' -f1)" "$BREF"

reeval_ok_case() {
  # reeval_ok_case <tag> <label> <plugin-dir> — a path whose characters survive
  # the render's second evaluation. Two assertions, because the apply landing
  # rc=0 is not evidence that the guard was true: the fallback branch also exits
  # 0 and passes all five verify conditions. Comparing the installed command's
  # render against the live one is what separates the branches.
  local tag="$1" label="$2" dir="$3" sf ef
  mkdir -p "$dir/orchestrator"
  cp "$SL" "$LIVENESS" "$dir/orchestrator/"
  chmod +x "$dir/orchestrator/statusline.sh"
  sf="$WORK/settings-reeval-$tag.json"; mk_settings "$sf"; ef=$(digest_of "$sf")
  bash "$APPLY" --apply --settings "$sf" --plugin-dir "$dir" --expect "$ef" >/dev/null 2>&1
  check "$label — 적용이 성공한다" "$?" "0"
  check "$label — 설치된 명령이 폴백이 아니라 그 스크립트를 부른다" \
    "$(fx_statusline_stdin sess-live | sh -c "$(jq -r '.statusLine.command' "$sf")" | strip_clock)" \
    "$(sl sess-live | strip_clock)"
}

# `$(printf ...)` is how the newline gets into the name at all — a literal one
# cannot be written into the word list above without ending it.
reeval_ok_case bs "백슬래시가 든 절대경로" "$WORK/reeval/plug\\back"
reeval_ok_case nl "개행이 든 절대경로" "$(printf '%s/reeval/plug\nnewline' "$WORK")"

# The interpreter is named absolutely: a PATH with nothing on it cannot resolve
# `bash` either, and a 127 from the lookup would look like the script's own
# verdict while proving nothing about it.
mkdir -p "$WORK/nojq"
PATH="$WORK/nojq" /bin/bash "$APPLY" --apply --settings "$S4F" --plugin-dir "$APLUG" --expect "$E4" >/dev/null 2>&1
check "jq 부재 — 실패하고 아무것도 쓰지 않는다" "$?" "1"
check "jq 부재 — 파일이 그대로다" "$(shasum -a 256 "$S4F" | cut -d' ' -f1)" "$B4"

S5F="$WORK/settings-broken.json"; printf '{ this is not json' > "$S5F"
B5=$(shasum -a 256 "$S5F" | cut -d' ' -f1)
bash "$APPLY" --apply --settings "$S5F" --plugin-dir "$APLUG" --expect "$E4" >/dev/null 2>&1
check "깨진 JSON — 쓰기 전에 중단한다" "$?" "1"
check "깨진 JSON — 파일이 그대로다" "$(shasum -a 256 "$S5F" | cut -d' ' -f1)" "$B5"
n=$(ls "$WORK"/settings-broken.json.pre-statusline-* 2>/dev/null | grep -c . || true)
check "깨진 JSON — 백업도 만들지 않는다" "$n" "0"

# ---------------------------------------------------------------------------
# Verification and rollback. Three plugin dirs, one per output shape — this is
# the "exactly one line" rule under the three feeds that decide it.
# ---------------------------------------------------------------------------
mk_fake_plugin() {
  # mk_fake_plugin <dir> <printf-format> — a plugin tree whose status line emits
  # exactly the given bytes.
  local d="$1" fmt="$2"
  mkdir -p "$d/orchestrator"
  printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf %s\n' "'$fmt'" \
    > "$d/orchestrator/statusline.sh"
  chmod +x "$d/orchestrator/statusline.sh"
}

mk_fake_plugin "$WORK/p-nonl"  'ONE LINE NO NEWLINE'
mk_fake_plugin "$WORK/p-1nl"   'ONE LINE ONE NEWLINE\n'
mk_fake_plugin "$WORK/p-2nl"   'LINE ONE\nLINE TWO\n'
mk_fake_plugin "$WORK/p-empty" ''

for case_name in nonl:0 1nl:0 2nl:1 empty:1; do
  tag=${case_name%%:*}; want=${case_name##*:}
  SF="$WORK/settings-$tag.json"; mk_settings "$SF"
  EF=$(digest_of "$SF"); BF=$(shasum -a 256 "$SF" | cut -d' ' -f1)
  bash "$APPLY" --apply --settings "$SF" --plugin-dir "$WORK/p-$tag" --expect "$EF" >/dev/null 2>&1
  check "검증 ($tag) — 종료 코드" "$?" "$want"
  if [ "$want" = "1" ]; then
    check "검증 실패 ($tag) — 백업으로 롤백해 바이트 동일" \
      "$(shasum -a 256 "$SF" | cut -d' ' -f1)" "$BF"
  fi
done

# ---------------------------------------------------------------------------
# The settings file that does not exist yet
# ---------------------------------------------------------------------------
S6F="$WORK/nested/settings-new.json"
bash "$APPLY" --probe --settings "$S6F" --plugin-dir "$APLUG" --expect "$EXPECT1" >/dev/null 2>&1
check "대상 파일 부재 — 사전 프로브는 2(진행)" "$?" "2"
bash "$APPLY" --apply --settings "$S6F" --plugin-dir "$APLUG" --expect "$EXPECT1" >/dev/null 2>&1
check "대상 파일 부재 — 최소 파일을 만든다" "$?" "0"
check "새로 만든 파일은 키 하나뿐이다" "$(jq -r '[keys[]] | join(",")' "$S6F")" "statusLine"
bash "$APPLY" --probe --settings "$S6F" --plugin-dir "$APLUG" --expect "$EXPECT1" >/dev/null 2>&1
check "새로 만든 뒤 사후 프로브 — 0(수렴)" "$?" "0"

printf '\n통과 %s · 실패 %s · 건너뜀 %s\n' "$passed" "$failed" "$skipped"
[ "$failed" -eq 0 ]
