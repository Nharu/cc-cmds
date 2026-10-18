#!/usr/bin/env bash
# lint-bash-portability: self-skip
# One fixture, four consumers, one answer.
#
# WHY THIS SUITE EXISTS SEPARATELY. Each consumer's own suite isolates it, and
# four isolated suites can all be green while the four answers disagree — that
# is not hypothetical, it is what was measured before the shared predicate
# existed: 21 pid files, 5 live processes, and a render reporting a live stage
# for a run whose recorded pid was dead. Agreement is a property OF THE SET, so
# it needs an assertion that holds the set.
#
# THE CONSUMERS ARE FOUR, NOT THREE. `snapshot --render`, termination condition
# 7, the status line, and the watcher's `live_stages()`. The fourth is the one
# the shared predicate was modelled on, so leaving it out would exempt the very
# implementation that set the standard.
#
# Usage: bash scripts/test-liveness-agreement.sh

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
# The dashboard server is off for the same reason: the gate's run-open branch
# starts one, and nothing in this suite stops it.
CC_CMDS_DASHBOARD=off
export CC_CMDS_DASHBOARD


script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
LIVENESS="$repo_root/plugins/cc-cmds/orchestrator/liveness.sh"
GATE="$repo_root/plugins/cc-cmds/orchestrator/gate.sh"
WATCH="$repo_root/plugins/cc-cmds/orchestrator/watch.sh"
SL="$repo_root/plugins/cc-cmds/orchestrator/statusline.sh"
PANE="$repo_root/plugins/cc-cmds/orchestrator/run-pane.sh"
COLLECT="$repo_root/plugins/cc-cmds/orchestrator/collect-run-metrics.sh"
CHECKS="$repo_root/plugins/cc-cmds/orchestrator/checks.sh"
. "$repo_root/scripts/run-fixture.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-liveness-agree.XXXXXX")
XDG_STATE_HOME="$WORK/state"
export XDG_STATE_HOME
mkdir -p "$XDG_STATE_HOME"
trap 'fx_reap; rm -rf "$WORK"' EXIT

# The watcher's banners must not reach a person from a test run.
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
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

# --- the four readings ------------------------------------------------------

read_shared() {
  # The predicate itself — the number the other three are supposed to equal.
  CC_RD="$1" bash -c '. "$0"; cc_live_stages "$CC_RD"' "$LIVENESS"
}

read_condition7() {
  # Termination condition 7, run as the gate's own source text. Extracting the
  # function is what lets this be a RUNTIME reading rather than a claim about
  # the file: driving the real verb would need a manifest and an origin
  # worktree, and neither is what this suite is asking about.
  local fn
  fn=$(sed -n '/^gate_live_stages() {/,/^}/p' "$GATE")
  [ -n "$fn" ] || { printf 'EXTRACT-FAILED'; return 0; }
  RUN_DIR="$1" CC_LIV="$LIVENESS" CC_FN="$fn" \
    bash -c '. "$CC_LIV"; eval "$CC_FN"; gate_live_stages'
}

read_watcher() {
  # The watcher publishes its count in the heartbeat, every pass, even on the
  # passes where an arm fires.
  bash "$WATCH" --run-dir "$1" --ledger "$2" --once >/dev/null 2>&1
  sed -n 's/.*스테이지 \([0-9][0-9]*\)개.*/\1/p' "$1/watch.heartbeat" 2>/dev/null | sed -n '1p'
}

read_statusline() {
  # The status line does not print a count — it prints ONE NAME, the segment it
  # sets beside the glyph, so the observable to read back is that name and the
  # question to ask of it is whether it belongs to a stage the predicate counts.
  #
  # Folding the output to `0` / `1+` and comparing against a literal was worse
  # than weak, it was green on the wrong answer: a row naming a segment whose
  # process had died still started with the glyph, so it folded to `1+` and
  # passed. Reading the name is what makes this consumer's reading say the same
  # thing as the other three instead of merely not contradicting them.
  #
  # THE SETTLING LINE SHARES THE GLYPH. `⟳ <rid> 정산 중` puts a word where the
  # segment name sits, so reading the token after the run id would report a
  # segment called 「정산」. That line is read back as the state token it stands
  # for, and so is the finished line, so the settlement fixtures below can be
  # compared against the readers that answer with a token.
  local sid="$1" out rest
  out=$(fx_statusline_stdin "$sid" | bash "$SL")
  case "$out" in
    *"스테이지 0"*) printf '0' ;;
    "⟳"*)
      rest=${out#⟳ }        # the glyph
      rest=${rest#* }       # the run id
      case "$rest" in
        "정산 중"*) printf '정산중' ;;
        *)          printf '%s' "${rest%% *}" ;;
      esac
      ;;
    "✓ "*" 종료"*) printf '종단' ;;
    *)             printf 'other:%s' "$out" ;;
  esac
}

read_pane() {
  # The status pane's helper takes its run from the status line's fields row,
  # so the two can only disagree if that borrowing breaks. Its head row carries
  # the run id in the fourth field.
  bash "$PANE" "$1" | sed -n '1p' | cut -f4
}

read_statusline_rid() {
  # The status line's second token, read the way the pane's contract names it.
  fx_statusline_stdin "$1" | bash "$SL" | cut -d' ' -f2
}

# ---------------------------------------------------------------------------
# Fixture A — one live stage among a dead one and a reused pid.
#
# All three shapes in ONE directory on purpose: a consumer that tests only
# `kill -0` counts 2 here, one that counts pid files counts 3, and the correct
# answer is 1. Split across three fixtures, each wrong consumer would still be
# right about one of them.
# ---------------------------------------------------------------------------
fx_mkrun agree-a; fx_ledger_path; fx_session_index sess-a agree-a
fx_segment S1 실행중
fx_stage_live S1
fx_stage_dead S2
fx_stage_reused S3
# THE LIVE STAGE IS DELIBERATELY THE OLDEST. The status line picks the newest
# pid file among the stages the predicate counts, and the three files above are
# written inside one epoch second — `date -r` has no finer resolution, so all
# three tie and the strict `>` leaves the FIRST glob entry standing. That entry
# is `S1`, which is the right answer arrived at by glob order rather than by the
# filter, and the assertion below therefore passes just as well with the filter
# deleted. Ageing the live one puts the dead stage and the reused pid strictly
# ahead of it, so an unfiltered pick names one of THEM and the assertion fails.
fx_age_file "$FX_RUN_DIR/S1.pid" 5
fx_heartbeat 0 5
RD_A="$FX_RUN_DIR"; LG_A="$FX_LEDGER"

n=$(read_shared "$RD_A")
check "A 공용 술어 — 셋 중 하나만 살아 있다" "$n" "1"
check "A 종료 조건 7 이 같은 수를 본다" "$(read_condition7 "$RD_A")" "$n"
check "A 워처가 같은 수를 본다" "$(read_watcher "$RD_A" "$LG_A")" "$n"
# The other three answer with a number; this one answers with the name it is
# about to show a person. Naming S2 or S3 here would be the same disagreement
# the numbers are checked for, wearing a different type.
check "A 상태줄이 도는 중으로 싣는 이름이 그 살아 있는 하나다" "$(read_statusline sess-a)" "S1"

# ---------------------------------------------------------------------------
# Fixture B — the same directory minus the live stage. Every consumer must flip
# together; a reading that is right about A and wrong about B is a reading that
# happened to agree once.
# ---------------------------------------------------------------------------
fx_mkrun agree-b; fx_ledger_path; fx_session_index sess-b agree-b
fx_segment S1 실행중
fx_stage_dead S2
fx_stage_reused S3
fx_heartbeat 0 5
RD_B="$FX_RUN_DIR"; LG_B="$FX_LEDGER"

n=$(read_shared "$RD_B")
check "B 공용 술어 — 죽은 pid 와 재사용 pid 는 0 이다" "$n" "0"
check "B 종료 조건 7 이 같은 수를 본다" "$(read_condition7 "$RD_B")" "$n"
check "B 워처가 같은 수를 본다" "$(read_watcher "$RD_B" "$LG_B")" "$n"
check "B 상태줄이 같은 수를 본다" "$(read_statusline sess-b)" "0"

# ---------------------------------------------------------------------------
# The status pane names the same run as the status line, on every fixture here
# that a session index points at. Each is pinned to its run id as well, so a
# pair that both fell back to "no run" cannot agree its way to green.
# ---------------------------------------------------------------------------
for _pr in sess-a:agree-a sess-b:agree-b; do
  _ps=${_pr%%:*}; _pw=${_pr#*:}
  check "패널이 상태 표시줄과 같은 런을 고른다 ($_ps)" "$(read_pane "$_ps")" "$(read_statusline_rid "$_ps")"
  check "그 런이 픽스처의 런이다 ($_ps)" "$(read_pane "$_ps")" "$_pw"
done

# And the same KIND for the running stage: the status line's kind slot and the
# pane's running detail both read `cc_stage_kind`. One fixture has a `.kind`
# that differs from the last stage-result, the other has none, so each source
# of the kind is the answer once. Each is pinned to its expected kind as well.
read_sl_kind() {
  # The token after the segment on the `⟳ <rid> <seg> <kind> <elapsed>` line.
  fx_statusline_stdin "$1" | bash "$SL" | cut -d' ' -f4
}
read_pane_kind() {
  # The first word of the running segment's detail row.
  bash "$PANE" "$1" | awk -F'\t' '$1 == "seg-detail" { s = $4; sub(/^ +/, "", s); split(s, w, " "); print w[1]; exit }'
}
fx_mkrun agree-kind1; fx_ledger_path; fx_session_index sess-k1 agree-kind1
fx_segment S1 실행중
fx_row 'stage-result' "세그먼트=S1" "스테이지=S1" "종류=review" "종료 코드=0" "실행 버전=1"
fx_stage_live S1; fx_stage_meta S1 implement 2
fx_heartbeat 0 5
fx_mkrun agree-kind2; fx_ledger_path; fx_session_index sess-k2 agree-kind2
fx_segment S1 실행중
fx_row 'stage-result' "세그먼트=S1" "스테이지=S1" "종류=review" "종료 코드=0" "실행 버전=1"
fx_stage_live S1
fx_heartbeat 0 5
for _pk in sess-k1:implement sess-k2:review; do
  _ps=${_pk%%:*}; _pw=${_pk#*:}
  check "패널의 종류가 상태 표시줄의 종류와 같다 ($_ps)" "$(read_pane_kind "$_ps")" "$(read_sl_kind "$_ps")"
  check "그 종류가 기대한 출처의 것이다 ($_ps)" "$(read_pane_kind "$_ps")" "$_pw"
done

# ---------------------------------------------------------------------------
# The pane's row functions number what the run verdict counts.
#
# Each fixture holds the case where a reader that took a shortcut would come
# apart from the count, and the shortcut's answer is asserted to differ — so the
# equality cannot hold merely because the fixture was too plain to separate
# anything.
# ---------------------------------------------------------------------------
fx_mkrun agree-rows
fx_segment S1 실행중
# A merge that still owes its apply: terminal by its 상태 field, in flight by
# the count. Read off the second field, this is the case a reader gets wrong.
fx_row 'segment' "id=S2" "상태=머지됨" "적용=대기" "워크트리=$FX_RUN_DIR"
fx_segment S3 완료
fx_segment S4 park
# `A1` resolved and `A10` still waiting: a substring match on the id makes the
# resolution of one the last row of the other.
fx_approval A1 대기
fx_approval A10 대기
fx_approval A1 승인
fx_approval A2 대기
LG_R="$FX_LEDGER"
. "$LIVENESS"
n_open=$( { cc_segment_states "$LG_R" || true; } | awk -F'\t' '$3 == "open"' | grep -c . || true)
check "cc_segment_states 의 open 줄 수가 cc_nonterminal_segments 와 같다" "$n_open" "$(cc_nonterminal_segments "$LG_R")"
check "그 수가 머지됨+적용=대기 를 센다 (둘)" "$n_open" "2"
# A function rather than an inline loop: bash 3.2 cannot parse a `case` arm's
# `)` inside a command substitution.
count_by_state_field() {
  local _i _s _v
  while IFS="$(printf '\t')" read -r _i _s _v; do
    case " $TERMINAL_SEGMENT_STATES " in
      *" $_s "*) ;;
      *) printf '%s\n' "$_i" ;;
    esac
  done
}
n_by_state=$( { cc_segment_states "$LG_R" || true; } | count_by_state_field | grep -c . || true)
if [ "$n_by_state" != "$n_open" ]; then
  ok "대조 — 상태 칸으로 세면 이 픽스처에서 수가 갈라진다 (${n_by_state} ≠ ${n_open})"
else
  bad "대조 픽스처" "상태 칸으로 센 수가 같다 — 픽스처가 셋째 칸의 판정을 시험하지 못한다"
fi
n_rows=$( { cc_open_approval_rows "$LG_R" || true; } | grep -c . || true)
check "cc_open_approval_rows 의 줄 수가 cc_open_approvals 와 같다" "$n_rows" "$(cc_open_approvals "$LG_R")"
check "그 줄이 A10 과 A2 다" "$( { cc_open_approval_rows "$LG_R" || true; } | cut -f1 | LC_ALL=C sort | paste -sd, -)" "A10,A2"
n_naive=$(grep -E '^- `승인`' "$LG_R" | grep -c '상태=대기' || true)
if [ "$n_naive" != "$n_rows" ]; then
  ok "대조 — 대기 행을 그대로 세면 수가 갈라진다 (${n_naive} ≠ ${n_rows})"
else
  bad "대조 픽스처" "대기 행 수가 같다 — 픽스처가 id 별 마지막 행 규칙을 시험하지 못한다"
fi

# ---------------------------------------------------------------------------
# The render's reading, which cannot be driven without a manifest.
#
# Asserted on the call site rather than on a run, and the difference is stated
# plainly: this shows the render DELEGATES, not that it agrees at runtime. The
# two other gate readings above are runtime, and the delegation is a single
# line, so what is left uncovered is that one line.
# ---------------------------------------------------------------------------
if grep -qF 'n_live=$(cc_live_stages "$RUN_DIR")' "$GATE"; then
  ok "snapshot --render 가 공용 술어에 위임한다"
else
  bad "render 위임" "호출부가 바뀌었다 — 사본이 생겼는지 확인할 것"
fi

# ---------------------------------------------------------------------------
# No consumer keeps a predicate of its own. This is what makes the agreement
# above durable rather than a coincidence of today's code: a second `kill -0`
# in any of these files is a fourth answer waiting to happen.
# ---------------------------------------------------------------------------
# Comments are stripped first, and that is not a convenience: all three files
# EXPLAIN why `kill -0` on its own is not enough, so a naive count finds the
# prose that documents the absence and reports it as the thing it documents.
# Cutting at the first `#` keeps every executable occurrence — a real call with
# a trailing comment still survives the cut — so the strictness is unchanged.
for f in "$GATE" "$WATCH" "$SL"; do
  n=$(sed 's/#.*//' "$f" | grep -c 'kill -0' || true)
  check "$(basename "$f") 는 자기 라이브니스 판정을 갖지 않는다" "$n" "0"
done

# ---------------------------------------------------------------------------
# The run-scope block census is a SET operation, so it carries the same
# collation hazard as the fingerprint — and it is worse when it folds.
#
# `사유` is Korean free text by contract. Under `en_US.UTF-8` every Hangul
# syllable weighs the same, so two reasons with the same non-Hangul shape and
# the same syllable counts compare equal and `sort -u` keeps only whichever came
# first in the ledger.
#
# BOTH VALUES BELOW ARE ONES THIS FIELD IS ACTUALLY WRITTEN WITH — the gate's
# surface check writes `사유=강제 표면 이동` and the driver's adoption floor
# writes `자동 채택 미달` — and they collide because each is two spaces and
# 2-2-2 syllables. An invented pair would demonstrate the collation and not the
# hazard; the hazard is that the vocabulary this field already carries holds a
# colliding pair, so the fold is reachable without anybody adding a word.
#
# What makes it a merge blocker rather than a display bug is WHICH one survives.
# The resolved block is written first, so it is the one kept, and the strongest
# block this system has — the one raised when a file the boundary rests on was
# edited — is counted as zero. The run becomes eligible to propose an ending
# with that block still open, and nothing reports anything.
#
# Asserted under `en_US.UTF-8` explicitly rather than under whatever this runner
# has, because a suite that happens to run under C would pass with the pin gone.
FX_BLK="$WORK/blocked-census.md"
{
  printf -- '- `blocked` | 스코프=run | 원인=불명 | 사유=자동 채택 미달 | prev=x\n'
  printf -- '- `blocked` | 스코프=run | 원인=해소 | 사유=자동 채택 미달 | prev=x\n'
  printf -- '- `blocked` | 스코프=run | 원인=불명 | 사유=강제 표면 이동 | prev=x\n'
} > "$FX_BLK"
n=$(LC_ALL=en_US.UTF-8 bash -c '. "$1"; cc_unresolved_blocked "$2" | grep -c .' \
      _ "$LIVENESS" "$FX_BLK" || true)
check "해소된 블록이 미해소 블록을 가리지 않는다 (en_US 콜레이션)" "$n" "1"
got=$(LC_ALL=en_US.UTF-8 bash -c '. "$1"; cc_unresolved_blocked "$2"' \
        _ "$LIVENESS" "$FX_BLK" | sed -n 's/.*\t//p')
check "남는 것이 강제 표면 이동이다" "$got" "강제 표면 이동"

# AND THE PAIR IS REQUIRED TO BE REAL VOCABULARY OF THIS FIELD, not said to be.
# The paragraph above is the whole difference between this fixture reporting a
# hazard and it demonstrating a collation rule, and a paragraph is exactly the
# part that stays behind when the vocabulary moves: the pair this one replaced
# named a string that turns up only as a park's 관측, and every assertion here
# stayed green while the sentence underneath them was false.
#
# A BARE SUBSTRING SEARCH DOES NOT SEPARATE THOSE TWO, so it was still the wrong
# question one layer down. Measured: put the discarded value back into the
# fixture and into the search and this suite stays green — it does occur, just
# as a park's fifth argument rather than its fourth. The search is therefore
# anchored on the FIELD, in the two spellings the product writes it in: `사유=`
# where a row is appended by name, and the fourth positional of a `park` where
# the driver calls one. A value that only ever occupies some other argument
# matches neither. Comments are cut first because one of these files carries the
# paragraph that names both values.
for _sy in '자동 채택 미달' '강제 표면 이동'; do
  _sy_n=$(sed 's/#.*//' \
        "$repo_root/plugins/cc-cmds/orchestrator/gate.sh" \
        "$repo_root/plugins/cc-cmds/orchestrator/run.sh" \
      | grep -cE "(사유=|park([[:space:]]+[^[:space:]]+){3}[[:space:]]+\")$_sy" || true)
  if [ "${_sy_n:-0}" -gt 0 ]; then
    ok "'$_sy' 는 제품이 이 필드에 실제로 쓰는 값이다 (${_sy_n}곳)"
  else
    bad "충돌쌍 어휘" "'$_sy' 를 사유 자리에 쓰는 곳이 코드에 없다 — 이 쌍은 콜레이션만 보이고 위험은 보이지 않는다"
  fi
done

# ---------------------------------------------------------------------------
# Agreement across LOCALES, not just across consumers.
#
# The four consumers share one predicate, so they cannot disagree about code —
# but they are four processes with four environments, and the fingerprint they
# compare is a date that `ps` localises. Measured: a stage recorded from a shell
# exporting `LC_ALL=ko_KR.UTF-8` wrote `2026년 9월 4일 금요일 00시 35분 25초`,
# and a reader that had cleared `LC_ALL` computed `Fri Sep 4 00:35:25 2026` for
# the same process, so the compare failed and a running stage read as dead. The
# driver clears `LC_ALL` at startup and the watcher does not, which is exactly a
# writer and a reader that disagree.
#
# Nothing errors when this breaks — it UNDER-counts, and an under-count lets a
# run declare itself finished while a stage is still running. The consumer-level
# assertions above cannot see it: they run in one process, so both sides of the
# compare fold the same way and agree on a wrong answer.
#
# Written across a real process boundary with a real locale on each side, since
# reading the pin out of the source would only re-assert the line that was
# already there and wrong.
fx_mkrun agree-loc
fx_stage_live S1
RD_L="$FX_RUN_DIR"
for lc in ko_KR.UTF-8 en_US.UTF-8 C; do
  got=$(LC_ALL="$lc" bash -c '. "$1"; cc_live_stages "$2"' _ "$LIVENESS" "$RD_L")
  check "지문이 로케일에 불변이다 (읽는 쪽 LC_ALL=$lc)" "$got" "1"
done
# The loop above varies the READER. The WRITER needs its own assertion, and the
# first version of it was hollow in two ways at once — it is kept described here
# because the shape is easy to write again.
#
# It read the fixture's own recorded byte and asked whether they were ASCII. But
# (1) the bytes it measured came from the FIXTURE's capture, not from either of
# the product's two, so reverting both product captures left it green; and (2)
# it never varied the writer's locale, so an unpinned capture also produces
# ASCII whenever the suite happens to run somewhere the date is spelled in
# ASCII. Under mutation it passed. That is the tell, and it was visible in the
# mutation output at the time: an assertion that survives the removal of the
# thing it exists to check is not weak, it is absent.
#
# Replaced by two assertions that can fail. The first runs the fixture capture
# in a subprocess under a locale that spells dates in Hangul, so an unpinned
# capture produces non-ASCII there and is caught wherever this suite runs.
w=$(LC_ALL=ko_KR.UTF-8 bash -c '
  . "$1"; FX_RUN_DIR=$2; export FX_RUN_DIR
  fx_stage_live W >/dev/null 2>&1
  cat "$FX_RUN_DIR/W.start"
  kill "$(cat "$FX_RUN_DIR/W.pid")" 2>/dev/null
' _ "$repo_root/scripts/run-fixture.sh" "$RD_L")
# WHAT IS BEING MEASURED HAS TO BE SHOWN TO EXIST FIRST. `grep -c` over an
# empty input answers 0, so a capture that produced nothing passes the ASCII
# assertion by having nothing that could be non-ASCII — and everything that
# would make it produce nothing is an ordinary edit: the fixture function
# renamed, the spawner no longer writing `.start`, the sourcing failing. That
# is the same hollow shape the paragraph above says this assertion replaced.
# A fingerprint is a `ps -o lstart=` line and carries digits in every locale,
# so asking for one digit separates "ASCII" from "absent" without re-pinning
# the spelling this assertion is about.
case "$w" in
  *[0-9]*) ok "쓰는 쪽 픽스처가 실제로 지문을 남겼다 (빈 캡처가 ASCII 로 통과하지 않는다)" ;;
  *) bad "쓰는 쪽 픽스처 캡처" "W.start 에서 시각 지문을 읽지 못했다 — 이 자리가 비면 아래 단언이 잴 것이 없어진다" ;;
esac
nonascii=$(printf '%s' "$w" | LC_ALL=C grep -c '[^ -~]' || true)
check "한글 날짜 로케일에서 캡처해도 지문이 ASCII 다 (쓰는 쪽 픽스처)" "$nonascii" "0"

# The second covers what no fixture can reach: the product's own two captures
# live inside a stage spawn and a driver spawn, neither of which this suite can
# drive. So they are asserted on the source. A structural check is weaker than a
# behavioural one and is used here only because the alternative was the hollow
# assertion above — and unlike that one, this fails the moment either capture
# goes back to a variable that `LC_ALL` outranks.
lc_census() {
  # lc_census <파일> <패턴> — count the CODE lines that match. Comments are cut
  # first, the same treatment the `kill -0` census above applies and for the same
  # reason: all four files this is pointed at EXPLAIN why `LC_TIME` was not
  # enough, and quoting the rejected spelling inside that prose is the ordinary
  # way to write it. Counted naively the sentence documenting the absence is
  # reported as the thing it documents, and the error runs the other way too —
  # a capture demoted into a comment would still be counted as present.
  sed 's/#.*//' "$1" | grep -c "$2" || true
}

# THE CUT IS DRIVEN ON A FILE BUILT TO CARRY BOTH HAZARDS, because none of the
# four carries either one today: the cut can be deleted with all eight counts
# below unchanged and this suite green. That is the same shape as the hollow
# assertion this section replaced, one layer down — a guard whose only evidence
# is inputs that never exercise it.
_lc_fx="$WORK/lc-census-fixture.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' '# 이 파일의 핀은 `LC_ALL=C ps -o lstart=` 이며 `LC_TIME=C ps -o lstart=` 이 아니다.'
  printf '%s\n' 'LC_ALL=C ps -o lstart= -p "$1"'
  printf '%s\n' '# LC_ALL=C ps -o lstart= -p "$2"   — 주석으로 내려간 캡처'
} > "$_lc_fx"
check "부재를 설명하는 주석이 부재의 반대로 보고되지 않는다" \
  "$(lc_census "$_lc_fx" 'LC_TIME=C ps -o lstart=')" "0"
check "주석으로 내려간 캡처는 살아 있는 캡처로 세어지지 않는다" \
  "$(lc_census "$_lc_fx" 'LC_ALL=C ps -o lstart=')" "1"

# THE EXPECTED COUNT IS NOW ZERO FOR THE GATE AND THE DRIVER, and that is the
# assertion rather than a relaxation. Both re-spelled the capture inline beside
# `cc_proc_fingerprint`, so one rule had three spellings that matched by luck;
# `.start` is written through the function in both files now, so the capture
# exists in exactly ONE place. `run-fixture.sh` keeps its own — it is a fixture
# writing what the product would have written, deliberately independent so a
# broken product spelling cannot make the fixture agree with it.
lc_expected() {
  case "$(basename "$1")" in
    gate.sh|run.sh) printf '0' ;;
    *)              printf '1' ;;
  esac
}
for f in "$GATE" "$repo_root/plugins/cc-cmds/orchestrator/run.sh" "$LIVENESS" \
         "$repo_root/scripts/run-fixture.sh"; do
  n=$(lc_census "$f" 'LC_ALL=C ps -o lstart=')
  bad_n=$(lc_census "$f" 'LC_TIME=C ps -o lstart=')
  check "$(basename "$f") 의 지문 캡처 수가 기대와 같다 (게이트·드라이버는 liveness.sh 한 곳으로 접혔다)" "$n" "$(lc_expected "$f")"
  check "$(basename "$f") 에 LC_TIME 만 건 캡처가 남아 있지 않다" "$bad_n" "0"
done
# AND THE TWO THAT DROPPED TO ZERO CALL THE FUNCTION INSTEAD. A count of zero
# is also what deleting the write would produce, so the positive half has to be
# asserted beside it.
for f in "$GATE" "$repo_root/plugins/cc-cmds/orchestrator/run.sh"; do
  check "$(basename "$f") 가 지문을 cc_proc_fingerprint 로 쓴다" \
    "$( [ "$(lc_census "$f" 'cc_proc_fingerprint "\$[a-z]*" > "\$RUN_DIR')" -ge 1 ] && printf 'yes' || printf 'no' )" "yes"
done

# ---------------------------------------------------------------------------
# The fifth reader — the snapshot's `live_stages[]`.
#
# The census answers HOW MANY and could not answer WHICH, so a successor shift
# had no way to learn the segment it should `wait` on. `cc_live_stage_records`
# is the census returning names, and this is the assertion that the two cannot
# come apart: the list's length is the census.
# ---------------------------------------------------------------------------
# Its own run directory, carrying the same three shapes Fixture A carries, so a
# reader that counted pid files or trusted `kill -0` alone would disagree here.
. "$LIVENESS"
fx_mkrun agree-records
fx_stage_live   LR1
fx_stage_dead   LR2
fx_stage_reused LR3
check "live_stages 레코드 수가 census 와 같다" \
  "$( { cc_live_stage_records "$FX_RUN_DIR" || true; } | grep -c . || true)" "$(cc_live_stages "$FX_RUN_DIR")"
check "그 census 가 실제로 하나를 센다 (위 단언이 0=0 으로 공허하지 않다)" "$(cc_live_stages "$FX_RUN_DIR")" "1"
check "레코드가 이름 대는 세그먼트가 살아 있는 그 스테이지다" \
  "$( { cc_live_stage_records "$FX_RUN_DIR" || true; } | cut -f1 | paste -sd, -)" "LR1"

# AND A LIVE SHIFT IS NOT A STAGE. `shift.live` sits outside the `*.pid` glob,
# so the guarantee is structural rather than a sibling-file check — but a
# structural guarantee that nothing measures is one an innocent rename breaks.
sl_before=$(cc_live_stages "$FX_RUN_DIR")
printf '%s\n%s\n' "$$" "$(cc_proc_fingerprint "$$")" > "$FX_RUN_DIR/shift.live"
check "shift.live 를 심어도 스테이지 census 가 움직이지 않는다" "$(cc_live_stages "$FX_RUN_DIR")" "$sl_before"
check "그 shift.live 는 살아 있는 교대로 읽힌다 (검사가 공허하지 않다)" \
  "$( cc_shift_is_live "$FX_RUN_DIR" && printf 'live' || printf 'dead' )" "live"
printf '%s\n%s\n' "$$" "Mon Jan  1 00:00:00 2001" > "$FX_RUN_DIR/shift.live"
check "지문이 어긋난 shift.live 는 살아 있는 교대가 아니다" \
  "$( cc_shift_is_live "$FX_RUN_DIR" && printf 'live' || printf 'dead' )" "dead"
# LINES 3–4 ARE THE LAUNCHER, and the shift's own answer reads lines 1–2 only:
# a four-line file answers exactly as the two-line file with the same head, both
# ways round — a dead launcher does not kill a live shift, and a live launcher
# does not revive a dead one.
printf '%s\n%s\n%s\n%s\n' "$$" "$(cc_proc_fingerprint "$$")" "999999" "Mon Jan  1 00:00:00 2001" \
  > "$FX_RUN_DIR/shift.live"
check "실행기 줄이 붙은 shift.live 도 앞 두 줄로 살아 있는 교대다" \
  "$( cc_shift_is_live "$FX_RUN_DIR" && printf 'live' || printf 'dead' )" "live"
printf '%s\n%s\n%s\n%s\n' "$$" "Mon Jan  1 00:00:00 2001" "$$" "$(cc_proc_fingerprint "$$")" \
  > "$FX_RUN_DIR/shift.live"
check "산 실행기 줄이 지문이 어긋난 교대를 살리지 않는다" \
  "$( cc_shift_is_live "$FX_RUN_DIR" && printf 'live' || printf 'dead' )" "dead"
rm -f "$FX_RUN_DIR/shift.live"
RD_R="$FX_RUN_DIR"

# ---------------------------------------------------------------------------
# The sixth reader — the dashboard's port of these predicates.
#
# The dashboard cannot call this file: one run takes about a tenth of a second
# through `cc_run_state`, and a host carries hundreds of run directories. So
# `dashboard_read.py` carries a port, and a port is a second implementation —
# exactly the shape this suite exists to hold to one answer. It joins the
# census readings above as a sixth participant, on the same three fixtures.
#
# Called with `PYTHONDONTWRITEBYTECODE=1`, because only `dashboard.py` turns the
# bytecode cache off for itself; importing the module any other way leaves a
# `__pycache__` inside the plugin tree.
# ---------------------------------------------------------------------------
PORT_PY="$repo_root/plugins/cc-cmds/orchestrator/dashboard_read.py"
port() { PYTHONDONTWRITEBYTECODE=1 python3 "$PORT_PY" "$@"; }
shell_state() { bash -c '. "$1"; cc_run_state "$2" "$3"' _ "$LIVENESS" "$1" "$2"; }
shell_grade() { bash -c '. "$1"; cc_run_grade "$2"' _ "$LIVENESS" "$1"; }

if ! command -v python3 >/dev/null 2>&1; then
  bad "포트 참가자" "python3 를 찾지 못했다 — 여섯째 읽기와 상태·등급 대조가 한 줄도 돌지 않는다"
else
  check "A 포트가 같은 수를 본다" "$(port live-stages "$RD_A")" "$(read_shared "$RD_A")"
  check "A 포트가 이름 대는 스테이지가 살아 있는 그 하나다" "$(port live-names "$RD_A")" "S1"
  check "B 포트가 같은 수를 본다" "$(port live-stages "$RD_B")" "$(read_shared "$RD_B")"
  check "레코드 픽스처에서 포트의 이름이 레코드의 이름과 같다" \
    "$(port live-names "$RD_R")" \
    "$( { cc_live_stage_records "$RD_R" || true; } | cut -f1 | paste -sd, -)"
  for lc in ko_KR.UTF-8 C; do
    check "포트의 지문 비교가 로케일에 불변이다 (LC_ALL=$lc)" \
      "$(LC_ALL="$lc" port live-stages "$RD_L")" "1"
  done

  # STATE AND GRADE HAVE NO EXISTING PARTICIPANT TO JOIN. Nothing above derives
  # a state token, and the grade has one consumer, the status line. So these
  # are two-participant comparisons — the port against the shell function — on
  # a fixture built for each branch. Each case also asserts the token it was
  # built for: a comparison that agrees on the wrong branch would be green while
  # the branch it names went untested.
  st_case() {
    # st_case <설명> <기대 토큰> — compare the current fixture through both.
    #
    # THE PORT IS READ TWICE. `port state` is the command line's path, a ledger
    # read whole and the clock re-derived; the server never takes it. It takes
    # discovery, `Ledger` and `Model.evaluate`, which keep their own growth
    # clock and override a clockless run on their own, so `port model-state`
    # is that path over the same directory. Discovery needs `ledger-path`, which
    # every real run directory carries.
    local want="$2" sh py pm
    [ -f "$FX_RUN_DIR/ledger-path" ] || fx_ledger_path
    sh=$(shell_state "$FX_RUN_DIR" "$FX_LEDGER")
    py=$(port state "$FX_RUN_DIR" "$FX_LEDGER")
    pm=$(port model-state "$FX_RUN_DIR")
    check "상태 갈래 $1 — 셸이 의도한 토큰을 낸다" "$sh" "$want"
    check "상태 갈래 $1 — 포트가 셸과 같은 토큰을 낸다" "$py" "$sh"
    check "상태 갈래 $1 — 서버 경로(Model.evaluate)가 셸과 같은 토큰을 낸다" "$pm" "$sh"
  }

  fx_mkrun st-live; fx_segment S1 실행중; fx_stage_live S1; fx_heartbeat 0 5
  st_case "살아 있는 스테이지" "도는중"
  fx_mkrun st-pend; fx_segment S1 실행중; fx_approval A1 대기; fx_heartbeat 0 5
  st_case "열린 승인" "승인대기"
  fx_mkrun st-pend-closed; fx_segment S1 실행중; fx_approval A1 대기; fx_approval A1 승인
  fx_heartbeat 0 5
  st_case "닫힌 승인은 대기로 세지 않는다" "진행중"
  fx_mkrun st-done; fx_segment S1 실행중; fx_done
  st_case "done 파일" "종단"
  fx_mkrun st-segs; fx_segment S1 실행중; fx_segment S1 머지됨; fx_segment S2 완료
  fx_segment S3 park
  st_case "모든 세그먼트가 종단" "종단"
  fx_mkrun st-blocked; fx_segment S1 머지됨; fx_done
  fx_blocked '강제 표면 이동' 불명; fx_heartbeat 0 5
  st_case "미해소 런 막힘이 done 을 이긴다" "진행중"
  fx_mkrun st-unblocked; fx_segment S1 머지됨
  fx_blocked '자동 채택 미달' 불명; fx_blocked '자동 채택 미달' 해소
  st_case "해소된 막힘은 종단을 막지 않는다" "종단"
  fx_mkrun st-going; fx_segment S1 실행중; fx_heartbeat 0 5
  st_case "하트비트 성장 안" "진행중"
  fx_mkrun st-stall; fx_segment S1 실행중; fx_heartbeat 0 600
  st_case "정지 임계 너머" "정지경고"
  fx_mkrun st-abandon; fx_segment S1 실행중; fx_heartbeat 0 7200
  st_case "포기 임계 너머" "버려짐"
  fx_mkrun st-mtime; fx_segment S1 실행중; fx_age_file "$FX_LEDGER" 600
  st_case "하트비트 없이 원장 mtime" "정지경고"
  fx_mkrun st-noclock; rm -f "$FX_LEDGER"
  st_case "시계가 하나도 없다" "버려짐"
  # A merge that still owes its apply is in flight, so the run is not over;
  # the same row with the apply done is the control.
  fx_mkrun st-apply-wait
  fx_row 'segment' "id=S1" "상태=머지됨" "적용=대기" "워크트리=$FX_RUN_DIR"
  fx_heartbeat 0 5
  st_case "머지됨이지만 적용=대기" "진행중"
  fx_mkrun st-apply-done
  fx_row 'segment' "id=S1" "상태=머지됨" "적용=완료" "워크트리=$FX_RUN_DIR"
  fx_heartbeat 0 5
  st_case "머지됨이고 적용=완료" "종단"

  # A STAGE WAITING FOR AN ACCOUNT HAS NO PID FILE, only `<key>.waiting`, and
  # `cc_run_state` folds a fresh one into its live count. Each case below sits
  # on a ledger whose growth clock is past the stall threshold, so a port that
  # skips the waiter answers 정지경고 where the shell answers 도는중. The wake
  # reading is taken off the host seam: on a machine that woke a minute ago the
  # stale marker would be fresh by its wake time, and the case would stop
  # testing what its name says.
  ag_waiter() {
    # ag_waiter <key> <갱신 age> <시도> <계보> — a marker held by a live process.
    local pid fp
    sleep 120 &
    pid=$!
    FX_PIDS="${FX_PIDS:-}$pid "
    fp=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null | sed 's/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//')
    printf '보유자=%s\n지문=%s\n기록자=게이트\n계보=%s\n그룹=-\n까지=-\n갱신=%s\n종류=implement\n시도=%s\n' \
      "$pid" "$fp" "$4" "$(( $(date -u +%s) - $2 ))" "$3" > "$FX_RUN_DIR/$1.waiting"
  }
  ag_host_saved=${ORCH_HOST_OS-}
  ORCH_HOST_OS=Linux; export ORCH_HOST_OS
  fx_mkrun st-wait-fresh; fx_segment W1 실행중; fx_heartbeat 0 600
  ag_waiter W1 5 1 'B:W1#1'
  st_case "신선한 대기자" "도는중"
  fx_mkrun st-wait-stale; fx_segment W1 실행중; fx_heartbeat 0 600
  ag_waiter W1 100000 1 'B:W1#1'
  st_case "갱신이 멈춘 대기자는 신선하지 않다" "정지경고"
  fx_mkrun st-wait-result; fx_segment W1 실행중; fx_heartbeat 0 600
  fx_row 'stage-result' "세그먼트=W1" "스테이지=W1" "종류=implement" "종료 코드=0" "실행 버전=1"
  ag_waiter W1 5 1 'B:W1#1'
  st_case "그 시도의 stage-result 가 있으면 대기자가 아니다" "정지경고"
  fx_mkrun st-wait-blocked; fx_segment W1 실행중; fx_heartbeat 0 600
  fx_row 'blocked' "대상=-" "스코프=act" "원인=불명" "사유=픽스처" "계보=B:W1#1"
  ag_waiter W1 5 1 'B:W1#1'
  st_case "같은 계보의 blocked 행이 있으면 대기자가 아니다" "정지경고"
  fx_mkrun st-wait-lin-prefix; fx_segment W1 실행중; fx_heartbeat 0 600
  fx_row 'blocked' "대상=-" "스코프=act" "원인=불명" "사유=픽스처" "계보=B:W1#10"
  ag_waiter W1 5 1 'B:W1#1'
  st_case "B:W1#10 은 B:W1#1 을 이름 대지 않는다" "도는중"
  if [ -n "$ag_host_saved" ]; then ORCH_HOST_OS=$ag_host_saved; else unset ORCH_HOST_OS; fi

  # THE BLOCKED FOLD'S INPUT SHAPES. A design step has no segment row, so a cone
  # row anchored on one holds the whole run; a later attempt of the same key is
  # what releases it, and an equal attempt is not. A `스코프=run` quoted inside
  # another field is not the scope, and `사유=막힘` is not `사유=막힘 추가`.
  fx_mkrun st-cone-step; fx_segment S1 머지됨
  fx_row 'blocked' "대상=cc-cmds" "스코프=cone" "원인=불명" "사유=마감 정지" \
    "근거=계보=B:STEP1#1 마감" "앵커 세그먼트=STEP1"
  fx_heartbeat 0 5
  st_case "스텝 앵커 cone 막힘이 종단을 막는다" "진행중"
  fx_mkrun st-cone-released; fx_segment S1 머지됨
  fx_row 'blocked' "대상=cc-cmds" "스코프=cone" "원인=불명" "사유=마감 정지" \
    "근거=계보=B:STEP1#1 마감" "앵커 세그먼트=STEP1"
  fx_row 'stage-wait' "교대=1" "계보=B:STEP1#2" "그룹=-" "근거=fifo-yield"
  fx_heartbeat 0 5
  st_case "같은 키의 더 큰 시도가 스텝 cone 을 푼다" "종단"
  fx_mkrun st-cone-same; fx_segment S1 머지됨
  fx_row 'blocked' "대상=cc-cmds" "스코프=cone" "원인=불명" "사유=마감 정지" \
    "근거=계보=B:STEP1#1 마감" "앵커 세그먼트=STEP1"
  fx_row 'stage-wait' "교대=1" "계보=B:STEP1#1" "그룹=-" "근거=fifo-yield"
  fx_heartbeat 0 5
  st_case "같은 시도는 스텝 cone 을 풀지 않는다" "진행중"
  fx_mkrun st-scope-quoted; fx_segment S1 머지됨
  fx_row 'blocked' "대상=-" "스코프=act" "원인=불명" "사유=인용" "근거='스코프=run'"
  st_case "다른 필드 안의 스코프=run 은 범위가 아니다" "종단"
  fx_mkrun st-reason-prefix; fx_segment S1 머지됨
  fx_blocked '막힘' 불명; fx_blocked '막힘 추가' 해소
  fx_heartbeat 0 5
  st_case "사유 막힘 추가의 해소가 막힘을 풀지 않는다" "진행중"

  # THE GRADE TOKENS ARE READ OFF `cc_run_grade`, not listed here. A list
  # written by hand is complete on the day it is written: it missed 정산중,
  # where the shell answers 3 and a port without the arm answers 9, and
  # nothing failed. The unknown token is added because no arm names it.
  gr_toks=$(sed -n '/^cc_run_grade() {/,/^}/p' "$LIVENESS" \
              | sed -n -E 's/^ *([^ ()*#]+)\).*/\1/p' | tr '\n' ' ')
  case " $gr_toks " in
    *"("*) bad "등급 토큰 유도" "함수 머리줄이 토큰으로 섞였다: '$gr_toks'" ;;
    *" 정산중 "*) ok "등급 토큰 목록을 cc_run_grade 에서 유도했다 ($gr_toks)" ;;
    *) bad "등급 토큰 유도" "cc_run_grade 에서 뽑은 목록이 비었거나 정산중을 담지 않는다: '$gr_toks'" ;;
  esac
  for tok in $gr_toks 미지의토큰; do
    check "등급 갈래 $tok — 포트가 셸과 같은 등급을 낸다" "$(port grade "$tok")" "$(shell_grade "$tok")"
  done
fi

# ---------------------------------------------------------------------------
# The run's STATE, read by every consumer that acts on it.
#
# The readings above compare a count of live stages. A run that ends on `done`
# adds a state between "segments all terminal" and "ended" — 정산중 — and four
# more consumers act on the state token rather than on a count: the reaper,
# the metrics collector's population, the CI poller's exit test and the status
# line. Each answers in its own form, so each is read in that form and the
# expected values are written per reader rather than forced into one token:
# the collector says open or closed, the poller says ended or not.
#
# THE POLLER IS ALLOWED TO DISAGREE ON THE DONE-TAIL, and that is asserted
# rather than tolerated. It tests `done` before it reads any state, so a run
# whose shift is still alive after writing `done` has ended for the poller
# while every other reader still says 정산중. Pinning that answer keeps a later
# edit from quietly changing the poller's order in either direction.
# ---------------------------------------------------------------------------
read_reaper() {
  # The reaper's call shape, thresholds and all.
  CC_RD="$1" CC_LG="$2" bash -c '. "$0"; cc_run_state "$CC_RD" "$CC_LG" 180 3600' "$LIVENESS"
}

read_metrics() {
  # The collector's population function, run as its own source text against a
  # ledger directory holding only this run. The script runs its main on load,
  # so the function is extracted rather than sourced — the same treatment
  # `read_condition7` gives the gate.
  local rd="$1" lg="$2" rid fn ldir state
  rid=$(basename "$rd")
  fn=$(sed -n '/^cm_population() {/,/^}/p' "$COLLECT")
  [ -n "$fn" ] || { printf 'EXTRACT-FAILED'; return 0; }
  ldir="$WORK/metrics-ledgers/$rid"
  mkdir -p "$ldir"
  cp -p "$lg" "$ldir/$rid.md"
  state=$(CM_LEDGER_DIR="$ldir" CM_STATE_ROOT="$(dirname "$(dirname "$rd")")" \
          CC_LIV="$LIVENESS" CC_FN="$fn" \
          bash -c '. "$CC_LIV"; eval "$CC_FN"; cm_population' | cut -f2)
  # The collector's closed set, asserted against its source below so this copy
  # cannot drift from it unseen.
  case "$state" in
    '')          printf 'NOT-IN-POPULATION' ;;
    종단|버려짐) printf '닫힌 런' ;;
    *)           printf '열린 런' ;;
  esac
}

read_poller() {
  # The CI poller's exit test, run as its own source text: `done` first, then
  # the shared state.
  local fn
  fn=$(sed -n '/^run_is_over() {/,/^}/p' "$CHECKS")
  [ -n "$fn" ] || { printf 'EXTRACT-FAILED'; return 0; }
  RUN_DIR="$1" LEDGER="$2" CC_LIV="$LIVENESS" CC_FN="$fn" \
    bash -c '. "$CC_LIV"; eval "$CC_FN"; if run_is_over; then printf "끝남"; else printf "끝나지 않음"; fi'
}

if grep -qE '^[[:space:]]*종단\|버려짐\) ;;$' "$COLLECT"; then
  ok "지표 수집기의 닫힌 집합이 독자의 사본과 같다 (종단|버려짐)"
else
  bad "지표 독자" "수집기의 모집단 필터가 바뀌었다 — read_metrics 의 닫힌 집합을 다시 맞출 것"
fi

ag_shift_live() {
  # ag_shift_live <run-dir> [pid] — a live shift record. The pid is spawned
  # unless one is passed, so a table of fixtures can share one process. The
  # fingerprint is captured here rather than through the product's function,
  # for the reason `run-fixture.sh` keeps its own capture.
  local rd="$1" pid="${2:-}"
  if [ -z "$pid" ]; then
    sleep 300 & pid=$!
    FX_PIDS="${FX_PIDS:-}$pid "; export FX_PIDS
  fi
  { printf '%s\n' "$pid"
    LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null | sed 's/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//'
  } > "$rd/shift.live"
  AG_SHIFT_PID="$pid"
}

# Fixture C — the settlement window: marker, one merged segment, no `done`, a
# ledger that grew a moment ago.
fx_mkrun 20261010-0000000c; fx_ledger_path; fx_session_index sess-c 20261010-0000000c
fx_segment S1 머지됨
printf '1\n' > "$FX_RUN_DIR/ends-on-done"
fx_heartbeat 0 5
RD_C="$FX_RUN_DIR"; LG_C="$FX_LEDGER"
check "C 상태 독자 — 정산 창은 정산중이다" "$(read_statusline sess-c)" "정산중"
check "C 리퍼 독자 — 정산중이다" "$(read_reaper "$RD_C" "$LG_C")" "정산중"
check "C 지표 독자 — 열린 런이다" "$(read_metrics "$RD_C" "$LG_C")" "열린 런"
check "C 폴러 독자 — 끝나지 않았다" "$(read_poller "$RD_C" "$LG_C")" "끝나지 않음"
# The dashboard reads the same window through its port, on the command line's
# path and on the server's. Its absence was not visible to any reader above.
if command -v python3 >/dev/null 2>&1; then
  check "C 포트 독자 — 정산중이다" "$(port state "$RD_C" "$LG_C")" "정산중"
  check "C 모델 독자 — 정산중이다" "$(port model-state "$RD_C")" "정산중"
fi

# Fixture D — the done-tail: marker, `done`, and the shift that wrote it still
# alive.
fx_mkrun 20261010-0000000d; fx_ledger_path; fx_session_index sess-d 20261010-0000000d
fx_segment S1 머지됨
printf '1\n' > "$FX_RUN_DIR/ends-on-done"
fx_done
ag_shift_live "$FX_RUN_DIR"
fx_heartbeat 0 5
RD_D="$FX_RUN_DIR"; LG_D="$FX_LEDGER"
check "D 상태 독자 — done 꼬리는 정산중이다" "$(read_statusline sess-d)" "정산중"
check "D 리퍼 독자 — 정산중이다" "$(read_reaper "$RD_D" "$LG_D")" "정산중"
check "D 지표 독자 — 열린 런이다" "$(read_metrics "$RD_D" "$LG_D")" "열린 런"
check "D 폴러 독자 — done 을 먼저 보므로 끝났다" "$(read_poller "$RD_D" "$LG_D")" "끝남"
if command -v python3 >/dev/null 2>&1; then
  check "D 포트 독자 — 정산중이다" "$(port state "$RD_D" "$LG_D")" "정산중"
  check "D 모델 독자 — 정산중이다" "$(port model-state "$RD_D")" "정산중"
fi

# And every reader flips together when the shift goes, so the agreement above
# is not one fixture's coincidence.
kill "$AG_SHIFT_PID" 2>/dev/null; wait "$AG_SHIFT_PID" 2>/dev/null
check "D′ 상태 독자 — 교대가 끝나면 종단이다" "$(read_statusline sess-d)" "종단"
check "D′ 리퍼 독자 — 종단이다" "$(read_reaper "$RD_D" "$LG_D")" "종단"
check "D′ 지표 독자 — 닫힌 런이다" "$(read_metrics "$RD_D" "$LG_D")" "닫힌 런"
check "D′ 폴러 독자 — 끝났다" "$(read_poller "$RD_D" "$LG_D")" "끝남"
if command -v python3 >/dev/null 2>&1; then
  check "D′ 포트 독자 — 종단이다" "$(port state "$RD_D" "$LG_D")" "종단"
  check "D′ 모델 독자 — 종단이다" "$(port model-state "$RD_D")" "종단"
fi

# ---------------------------------------------------------------------------
# The state table: marker × done × shift × nonterminal segment × ledger age ×
# run-scope block, read in the reaper's shape (180 3600) and the watcher's
# (`--stall 1200`, default abandon).
#
# THE EXPECTED VALUE IS WRITTEN FROM THE RULE, not from the function. Without
# the marker every shape reads as it did before the marker existed: the derived
# conjunction or `done` ends the run, and otherwise the age ladder. With the
# marker, `done` ends it only once no shift is alive, the derived conjunction
# opens 정산중 on the same age ladder, and anything still open walks the ladder
# as before. A run-scope block puts every shape on the ladder.
# ---------------------------------------------------------------------------
st_expect() {
  # st_expect <marker y|n> <done y|n> <shift y|n> <nonterm 0|1> <age> <blocked y|n> <stall>
  local ladder fresh=진행중
  if [ "$5" -ge 3600 ]; then ladder=버려짐
  elif [ "$5" -ge "$7" ]; then ladder=정지경고
  else ladder=fresh; fi
  if [ "$6" = n ]; then
    if [ "$1" = n ]; then
      if [ "$2" = y ] || [ "$4" = 0 ]; then printf '종단'; return 0; fi
    else
      if [ "$2" = y ]; then
        if [ "$3" = y ]; then printf '정산중'; else printf '종단'; fi
        return 0
      fi
      [ "$4" = 0 ] && fresh=정산중
    fi
  fi
  if [ "$ladder" = fresh ]; then printf '%s' "$fresh"; else printf '%s' "$ladder"; fi
}

sleep 300 & ST_PID=$!
FX_PIDS="${FX_PIDS:-}$ST_PID "; export FX_PIDS
# The dashboard's port reads every case in both call shapes as well. The table
# holds the marker, `done` and a live shift in every combination, which is the
# set of branches the port once lacked while every fixture above agreed.
st_port=no
command -v python3 >/dev/null 2>&1 && st_port=yes
st_i=0; st_bad=0; st_pbad=0; st_pn=0
for st_m in n y; do for st_d in n y; do for st_s in n y; do for st_n in 0 1; do
for st_a in 0 200 4000; do for st_b in n y; do
  st_i=$((st_i + 1))
  fx_mkrun "st-$st_i"
  fx_segment S1 머지됨
  [ "$st_n" = 1 ] && fx_segment S2 실행중
  [ "$st_b" = y ] && fx_blocked '자동 채택 미달' 불명
  [ "$st_m" = y ] && printf '1\n' > "$FX_RUN_DIR/ends-on-done"
  [ "$st_d" = y ] && fx_done
  [ "$st_s" = y ] && ag_shift_live "$FX_RUN_DIR" "$ST_PID"
  fx_heartbeat 0 "$st_a"
  st_case="표지=$st_m done=$st_d 교대=$st_s 비종단=$st_n 나이=$st_a 막힘=$st_b"
  st_got=$(cc_run_state "$FX_RUN_DIR" "$FX_LEDGER" 180 3600)
  st_want=$(st_expect "$st_m" "$st_d" "$st_s" "$st_n" "$st_a" "$st_b" 180)
  [ "$st_got" = "$st_want" ] || { st_bad=$((st_bad + 1)); bad "상태표 (180 3600) $st_case" "got '$st_got', want '$st_want'"; }
  if [ "$st_port" = yes ]; then
    st_pn=$((st_pn + 1))
    st_py=$(port state "$FX_RUN_DIR" "$FX_LEDGER" 180 3600)
    [ "$st_py" = "$st_got" ] || { st_pbad=$((st_pbad + 1)); bad "상태표 포트 (180 3600) $st_case" "port '$st_py', shell '$st_got'"; }
  fi
  st_got=$(cc_run_state "$FX_RUN_DIR" "$FX_LEDGER" 1200)
  st_want=$(st_expect "$st_m" "$st_d" "$st_s" "$st_n" "$st_a" "$st_b" 1200)
  [ "$st_got" = "$st_want" ] || { st_bad=$((st_bad + 1)); bad "상태표 (1200) $st_case" "got '$st_got', want '$st_want'"; }
  if [ "$st_port" = yes ]; then
    st_pn=$((st_pn + 1))
    st_py=$(port state "$FX_RUN_DIR" "$FX_LEDGER" 1200 3600)
    [ "$st_py" = "$st_got" ] || { st_pbad=$((st_pbad + 1)); bad "상태표 포트 (1200) $st_case" "port '$st_py', shell '$st_got'"; }
  fi
done; done; done; done; done; done
check "상태표 96 사례가 두 호출 꼴 모두에서 규칙과 같다" "$st_bad" "0"
check "상태표가 실제로 96 사례를 돌았다" "$st_i" "96"
if [ "$st_port" = yes ]; then
  check "상태표 192 판독에서 포트가 셸과 어긋난 수" "$st_pbad" "0"
  check "포트가 상태표의 판독 192 개를 실제로 돌았다" "$st_pn" "192"
fi

# ---------------------------------------------------------------------------
# The watchers' idle self-exit, `cc_run_idle_exit`, and the poller reading it.
#
# EVERY FIXTURE HERE IS 버려짐 TO THE STATE TABLE, and that is the point. The
# ledger last grew 25 hours ago and a segment is still open, so `cc_run_state`
# says 버려짐 for all of them; the idle predicate has to tell apart the run that
# waits on a person — an unanswered halt record, an open approval — from the run
# that waits on nobody. A predicate that reused 버려짐 would pass the first
# fixture and take the progress channel away from a person's open question.
# ---------------------------------------------------------------------------
idle_of() {
  # idle_of <run-dir> <ledger> [T] — the predicate's answer as a word, with the
  # ledger's mtime moved back to the fixture's growth age first. The predicate
  # takes the later of the heartbeat field and the mtime, and a fixture row
  # appended a moment ago would otherwise be the growth every case reads.
  fx_age_file "$2" "$ID_AGE"
  if cc_run_idle_exit "$1" "${3:-}" "$2"; then printf '유휴'; else printf '유휴 아님'; fi
}
id_mkrun() {
  # id_mkrun <run-id> <growth-age> — an open run whose ledger last grew that long ago.
  fx_mkrun "$1"
  fx_segment S1 실행중
  fx_heartbeat 0 "$2"
  ID_AGE="$2"
}

id_mkrun 20261012-0000000a 90000
mkdir -p "$FX_RUN_DIR/halt"
printf '# 중단 기록\n' > "$FX_RUN_DIR/halt/S1.md"
check "유휴 A — 상태표는 이 런을 버려짐 으로 읽는다 (아래 단언이 공허하지 않다)" \
  "$(cc_run_state "$FX_RUN_DIR" "$FX_LEDGER" 1200)" "버려짐"
check "유휴 A — 답 없는 중단 기록이 있으면 25시간 조용해도 유휴가 아니다" \
  "$(idle_of "$FX_RUN_DIR" "$FX_LEDGER")" "유휴 아님"
check "유휴 A 폴러 — 끝나지 않았다" "$(read_poller "$FX_RUN_DIR" "$FX_LEDGER")" "끝나지 않음"
printf '답\n' > "$FX_RUN_DIR/halt/S1.answer.md"
check "유휴 A — 답 첨부 파일은 원장의 답 행이 아니다" \
  "$(idle_of "$FX_RUN_DIR" "$FX_LEDGER")" "유휴 아님"
fx_row '중단 답' "중단 기록=$FX_RUN_DIR/halt/S1.md" "답=좌석 실행"
check "유휴 A′ — 그 기록을 원장의 중단 답 행이 가리키면 유휴다" \
  "$(idle_of "$FX_RUN_DIR" "$FX_LEDGER")" "유휴"
check "유휴 A′ 폴러 — 끝났다" "$(read_poller "$FX_RUN_DIR" "$FX_LEDGER")" "끝남"

id_mkrun 20261012-0000000b 90000
mkdir -p "$FX_RUN_DIR/halt"
printf '# 중단 기록\n' > "$FX_RUN_DIR/halt/S1.md"
fx_row '중단 답' "중단 기록=/elsewhere/20261012-0000000a/halt/S1.md" "답=좌석 실행"
check "유휴 B — 다른 런의 같은 이름 기록을 가리키는 답은 이 기록의 답이 아니다" \
  "$(idle_of "$FX_RUN_DIR" "$FX_LEDGER")" "유휴 아님"

# A SHIFT'S STOP IS A QUESTION TOO. Its record sits one level down, under
# `halt/shift/`, and a run whose only open question is one of those still waits
# on a person.
id_mkrun 20261012-00000010 90000
mkdir -p "$FX_RUN_DIR/halt/shift"
printf '# 중단 기록\n' > "$FX_RUN_DIR/halt/shift/S1#1.md"
check "유휴 G — 교대 정지 기록만 있어도 답이 없으면 유휴가 아니다" \
  "$(idle_of "$FX_RUN_DIR" "$FX_LEDGER")" "유휴 아님"
fx_row '중단 답' "중단 기록=/elsewhere/20261012-00000010/halt/S1#1.md" "답=재시도"
check "유휴 G — halt/ 의 같은 이름을 가리키는 답은 교대 기록의 답이 아니다" \
  "$(idle_of "$FX_RUN_DIR" "$FX_LEDGER")" "유휴 아님"
fx_row '중단 답' "중단 기록=$FX_RUN_DIR/halt/shift/S1#1.md" "답=재시도"
check "유휴 G′ — 그 교대 기록을 원장의 중단 답 행이 가리키면 유휴다" \
  "$(idle_of "$FX_RUN_DIR" "$FX_LEDGER")" "유휴"

id_mkrun 20261012-0000000c 90000
fx_approval A1 대기
check "유휴 C — 대기 중인 승인이 있으면 유휴가 아니다" "$(idle_of "$FX_RUN_DIR" "$FX_LEDGER")" "유휴 아님"
fx_approval A1 승인됨
check "유휴 C′ — 그 승인이 풀리면 유휴다" "$(idle_of "$FX_RUN_DIR" "$FX_LEDGER")" "유휴"

id_mkrun 20261012-0000000d 90000
check "유휴 D — 아무도 기다리지 않는 런은 유휴다" "$(idle_of "$FX_RUN_DIR" "$FX_LEDGER")" "유휴"
check "유휴 D 폴러 — done 없이도 끝났다" "$(read_poller "$FX_RUN_DIR" "$FX_LEDGER")" "끝남"
check "유휴 D — 술어는 done 을 쓰지 않는다" "$( [ -e "$FX_RUN_DIR/done" ] && printf 있음 || printf 없음 )" "없음"
ag_shift_live "$FX_RUN_DIR" "$ST_PID"
check "유휴 D′ — 살아 있는 교대가 있으면 유휴가 아니다" "$(idle_of "$FX_RUN_DIR" "$FX_LEDGER")" "유휴 아님"
rm -f "$FX_RUN_DIR/shift.live"
fx_stage_live S9
check "유휴 D″ — 살아 있는 스테이지가 있으면 유휴가 아니다" "$(idle_of "$FX_RUN_DIR" "$FX_LEDGER")" "유휴 아님"

id_mkrun 20261012-0000000e 4000
check "유휴 E — 기본 임계(24시간) 안에서는 유휴가 아니다" "$(idle_of "$FX_RUN_DIR" "$FX_LEDGER")" "유휴 아님"
check "유휴 E — 임계를 인자로 줄이면 같은 런이 유휴다" "$(idle_of "$FX_RUN_DIR" "$FX_LEDGER" 3600)" "유휴"
check "유휴 E — 숫자 아닌 임계는 유휴가 아니다" "$(idle_of "$FX_RUN_DIR" "$FX_LEDGER" 1h)" "유휴 아님"
check "기본 임계는 24시간이다" "$CC_RUN_IDLE_EXIT_SECONDS" "86400"

# A watcher started again on a run its predecessor left as idle. The heartbeat's
# `마지막성장` stays a day old once that watcher is gone, so the clock has to come
# from somewhere it does not reach. F′ is F with the ledger aged back, so the
# appended row is what F's answer rests on; F″ is F′ with a caller that started
# watching just now, so the start epoch is what F″'s answer rests on.
id_mkrun 20261012-0000000f 90000
fx_row 'handoff' "사유=중단"
check "유휴 F — 묵은 하트비트가 있어도 원장에 방금 행이 붙었으면 유휴가 아니다" \
  "$(cc_run_idle_exit "$FX_RUN_DIR" "" "$FX_LEDGER" && printf '유휴' || printf '유휴 아님')" "유휴 아님"
fx_age_file "$FX_LEDGER" 90000
check "유휴 F′ — 원장도 하루 넘게 조용하면 유휴다" \
  "$(cc_run_idle_exit "$FX_RUN_DIR" "" "$FX_LEDGER" && printf '유휴' || printf '유휴 아님')" "유휴"
check "유휴 F″ — 같은 런이라도 방금 지켜보기 시작한 호출자에게는 유휴가 아니다" \
  "$(cc_run_idle_exit "$FX_RUN_DIR" "" "$FX_LEDGER" "$(date -u +%s)" && printf '유휴' || printf '유휴 아님')" "유휴 아님"
check "유휴 F‴ — 임계보다 오래 지켜본 호출자에게는 유휴다" \
  "$(cc_run_idle_exit "$FX_RUN_DIR" "" "$FX_LEDGER" "$(( $(date -u +%s) - 90000 ))" && printf '유휴' || printf '유휴 아님')" "유휴"

# ---------------------------------------------------------------------------
# The notifier channel stays off for every suite that does not assert on it.
#
# This is a property OF THE SET, like the agreement above: any one suite can be
# guarded and the tree still reaches a person, because `make test` runs all of
# them and the gate's fire path defeats a PATH stub by prepending Homebrew's
# directories itself. Measured before the guard: two banners arrived at a user
# from an ordinary test run, one of them with sound.
#
# Asserted on the source rather than by firing, and the reason is the same one
# that makes the defect worth a test: to observe it behaviourally this suite
# would have to let a banner escape to the real notifier, which is the thing
# being prevented. So the check is that each suite carries the export, and the
# skip list names the ones that legitimately do not — for those the banner IS
# the subject, so a process-level kill would remove what they assert. The list
# is deliberately not counted here: it was, and the count outlived a change to
# the list itself, which is the same defect this file keeps finding one layer
# up — a statement that was true when written and became false with nothing
# about the statement changing.
# HOW MANY SUITES THIS SELECTS IS ITSELF AN OBSERVABLE. The predicate below has
# chosen nothing three times — a BRE `sed` whose alternation did not apply, a
# `grep -q` that lost a `pipefail` race on the largest file, and an ERE anchor
# written unescaped — and every time the suite ended with zero failures and a
# smaller total, which is what a clean tree looks like too. The count leaves the
# loop so that outcome can be asserted rather than left to a reader who happens
# to remember the previous total.
leak_pat() {
  # leak_pat <주석 걷어낸 소스> — build the ERE that recognises an invocation of
  # the gate, the driver or the watcher inside that source.
  #
  # A FUNCTION RATHER THAN A BLOCK INSIDE THE LOOP, because the tree the loop
  # reads does not exercise every branch of what it builds. Measured: the base
  # branch — a literal path after `bash` — selects ZERO suites here today, and
  # all four that are selected come from a handle branch. So that branch could be
  # deleted, or narrowed, without a single verdict moving. Lifted out, it can be
  # handed a corpus written for it; the recognition table below is that corpus.
  #
  # A `bash` THAT BEGINS INSIDE A STRING LITERAL IS DATA, NOT AN INVOCATION.
  # Some suites here carry command lines as fixtures — the pretool-hook suite
  # feeds `"bash $GATE snapshot …"` to the hook it is testing — and reading one
  # of those selects a suite that never runs the gate, then reports it as a
  # leak. So the character in front of `bash` may not be a double quote; nor may
  # it be part of a longer word, which is what keeps `bash_json` from counting.
  # Everything a real call site puts there — a line start, a space, a `(`, a
  # `/` — still counts.
  #
  # THE DERIVATION READS WORDS, NOT LINES, because a line-anchored extraction is
  # a closed list of assignment spellings wearing a regex — the same defect as
  # the hardcoded handle list it replaced, moved one layer down. Measured, it
  # missed `local`/`export`/`readonly` prefixes, a second assignment on the same
  # line, `H=$d/gate.sh` with no quotes, and `H="$d"/gate.sh` with the quotes
  # around the other half. Splitting on the shell's own separators first makes a
  # prefix its own word and every assignment its own word, so what is left to
  # recognise is `<name>=…<script>` — the one shape all of them share. A
  # trailing `;` needs no removal; the pattern's tail absorbs it.
  #
  # `sed -E`, and the flag is load-bearing. BSD sed's default BRE has no `|`
  # alternation, so the bracketed group matches nothing and the extraction
  # yields an empty handle list — which does not error, it selects no suites,
  # and every assertion in that loop disappears while the suite reports a
  # smaller green total. Measured: 30 assertions became 26 and nothing said so.
  local _src="$1" _h _ref _pat
  _pat='(^|[^"A-Za-z_0-9])bash +[^ ]*(gate|run|watch)\.sh'
  for _h in $(printf '%s\n' "$_src" | tr ' \t' '\n\n' \
      | sed -n -E 's/^([A-Za-z_][A-Za-z_0-9]*)=.*(gate|run|watch)\.sh.*$/\1/p' \
      | sort -u); do
    # `\\$` and not `$`: this string becomes an ERE, where a bare `$` is the
    # end-of-line anchor. Written unescaped the alternative reads as `bash "`
    # then end-of-line, matches nothing, and the caller selects no suites at
    # all — silently, with the suite reporting a smaller green total.
    #
    # The braces and the quotes are OPTIONAL in the reference, because
    # `bash "$H"`, `bash "${H}"` and `bash $H` are one act spelled three ways.
    # And running the handle DIRECTLY is a fourth — no `bash` in front of it at
    # all — so that one anchors on the start of the line instead. Requiring a
    # literal `bash "$H"` was a closed list of invocation spellings, which is
    # the same defect as the closed list of assignment spellings above.
    _ref="\\\$\\{?$_h\\}?"
    _pat="$_pat|(^|[^\"A-Za-z_0-9])bash +\"?$_ref\"?"
    _pat="$_pat|^[[:space:]]*\"?$_ref\"?([[:space:]]|\$)"
  done
  printf '%s' "$_pat"
}

# THE BRANCHES THE TREE DOES NOT REACH ARE CHECKED AGAINST A CORPUS WRITTEN FOR
# THEM. One row per branch and one per exclusion, spelled the way a real call
# site and a real non-call-site are spelled, so each row is failed by breaking
# the one thing it names — and the base branch, which today's tree cannot fail,
# is failed here.
_lp=$(leak_pat 'GATE=/x/plugins/cc-cmds/orchestrator/gate.sh')
while IFS='|' read -r _want _line; do
  [ -n "$_want" ] || continue
  _got=$(printf '%s\n' "$_line" | grep -cE "$_lp" || true)
  case "$_want:${_got:-0}" in
    y:0) bad "누출 술어 인식" "호출로 인식해야 하는 줄을 놓쳤다: $_line" ;;
    n:0) ok "누출 술어가 호출 아닌 줄을 세지 않는다: $_line" ;;
    y:*) ok "누출 술어가 호출 표기를 인식한다: $_line" ;;
    *)   bad "누출 술어 인식" "호출이 아닌 줄을 호출로 셌다: $_line" ;;
  esac
done <<'LEAKROWS'
y|bash /x/plugins/cc-cmds/orchestrator/gate.sh snapshot --manifest m
y|  bash "$GATE" act --kind segment
y|bash ${GATE} act --kind segment
y|  "$GATE" act --kind segment
n|  "bash $GATE snapshot --manifest m"
n|bash_json "$GATE" act
n|  echo "$GATEWAY" act
LEAKROWS

_selected=0
_selected_names=""
for f in "$repo_root"/scripts/test-*.sh "$repo_root"/plugins/cc-cmds/orchestrator/test-run.sh; do
  [ -f "$f" ] || continue
  b=$(basename "$f")
  case "$b" in
    # `test-gate.sh` is NOT skipped, and it was — which put the one file that
    # actually leaked, and the one holding a hundred-plus direct gate calls,
    # outside the only check that would catch a regression. It carries the
    # export like the others; what differs is only that it turns the channel
    # back ON inside two helpers, and that is a local override rather than an
    # absence. The two below are the real exceptions: for them the banner IS
    # the subject, so a process-level kill would remove what they assert.
    test-active-notify-*|test-watch.sh) continue ;;
  esac
  # Only suites that can reach a firing path need it — the gate, the driver and
  # the watcher are the three that fire, and what matters is EXECUTING one of
  # them rather than naming it.
  #
  # This predicate has been wrong twice in the same direction, so it is built
  # rather than written. The first version matched any mention, and reported
  # four lint suites that merely read `run.sh` for its vocabulary. The second
  # required `bash ` in front — and still matched `# Usage: bash …/test-run.sh`,
  # while missing that file's real invocations, which go through a handle
  # (`/usr/bin/env bash "$DRIVER"`) that a hardcoded list of variable names did
  # not contain. A closed list of handles is the same defect wearing a narrower
  # spelling: it is complete on the day it is written.
  #
  # So comments are cut first — the same treatment the `kill -0` census above
  # applies, and for the same reason — and the handles are DERIVED from the
  # file: whatever variable it assigns one of the three scripts to is what its
  # invocations will name.
  #
  # Comments are cut first, and the pattern is built from what is left — the
  # construction, and why it has the shape it has, live in `leak_pat` above.
  _src=$(sed 's/#.*//' "$f")
  _pat=$(leak_pat "$_src")
  # `grep -c`, never `grep -q`, and the reason is this file's own section 0a:
  # under `pipefail` an early-exiting reader on the right of a pipe kills the
  # writer with SIGPIPE and the pipeline reports that failure. `grep -q` leaves
  # as soon as it matches, so the bigger the file the likelier the writer is
  # still going — which selected against exactly the file that matters. Measured:
  # `test-gate.sh` matched 124 lines and was dropped, while three smaller suites
  # whose writers finished first were kept. `grep -c` reads to the end.
  #
  # AN ERROR IS NOT A "NO". `grep` answers 1 for "nothing matched" and 2 or more
  # for "the search could not be done" — a malformed ERE, an unreadable input —
  # and `|| true` folded those together, so a pattern broken by an edit dropped
  # every suite and looked exactly like a tree with nothing to check. The count
  # is captured rather than discarded because BSD `grep` short-circuits when its
  # output goes to /dev/null, which brings back the SIGPIPE this uses `-c` to
  # avoid.
  _n=$(printf '%s\n' "$_src" | grep -cE "$_pat")
  _rc=$?
  if [ "$_rc" -gt 1 ]; then
    bad "누출 술어" "$b 에 대해 선택 검사가 오류로 끝났다 (grep rc=$_rc) — 오류를 매치 없음과 같이 처리하면 모든 스위트가 조용히 빠진다"
    continue
  fi
  [ "${_n:-0}" != "0" ] || continue
  _selected=$((_selected + 1))
  _selected_names="$_selected_names $b"
  if grep -q '^export CC_CMDS_AUTOPILOT_NOTIFY$' "$f"; then
    ok "$b 가 알림 채널을 프로세스 수준에서 끈다"
  else
    bad "알림 누출" "$b 가 게이트 계열을 부르면서 CC_CMDS_AUTOPILOT_NOTIFY 를 내보내지 않는다 — 이 스위트가 도는 동안 사용자 화면에 실제 배너가 도달한다"
  fi
  # The same set runs the gate's run-open branch, which starts the dashboard
  # server. Left on, every fixture run that opens there leaves a real server
  # listening on this host after the suite ends.
  if grep -q '^export CC_CMDS_DASHBOARD$' "$f"; then
    ok "$b 가 대시보드 자동 기동을 프로세스 수준에서 끈다"
  else
    bad "대시보드 누출" "$b 가 게이트 계열을 부르면서 CC_CMDS_DASHBOARD 를 내보내지 않는다 — 픽스처 런 개시마다 실제 서버가 남는다"
  fi
done

# ZERO SELECTED IS A BROKEN PREDICATE, NOT A CLEAN TREE. Nothing inside the loop
# can report this, because the assertions that would have spoken are exactly the
# ones that disappear.
if [ "$_selected" -gt 0 ]; then
  ok "누출 술어가 게이트 계열을 부르는 스위트를 실제로 골랐다 (${_selected}개)"
else
  bad "누출 술어" "게이트 계열을 부르는 스위트를 하나도 고르지 못했다 — 술어가 깨졌다는 뜻이지 트리가 깨끗하다는 뜻이 아니다"
fi
# And a NAMED one, because a count above zero can still be the wrong set. This
# is the file that actually leaked and the one holding the most direct gate
# calls, so a derivation that stops recognising a spelling drops it first.
case " $_selected_names " in
  *" test-gate.sh "*) ok "그 선택에 test-gate.sh 가 들어 있다 (가장 많이 부르는 스위트가 빠지지 않았다)" ;;
  *) bad "누출 술어" "test-gate.sh 를 고르지 못했다 — 핸들 유도나 호출 표기 인식이 좁아졌다" ;;
esac
# AND THE WHOLE SET, because "above zero" and "contains one name" both survive a
# predicate that narrowed. A narrowing drops suites one at a time, and the suite
# then ends with zero failures and a smaller total — which is what a clean tree
# looks like too. Measured: a derivation broken so that a whole branch matched
# nothing left this count at four and this name present, and nothing said so.
#
# Spelling the set out means a suite added to this tree that calls the gate
# family has to be added here as well. That edit is the point rather than a cost:
# it is the one moment somebody looks at whether the new suite kills the channel.
_selected_want="test-gate-oracle.sh test-gate.sh test-liveness-agreement.sh test-lost-dispatch.sh test-rekick.sh test-run-issue-filing.sh test-run.sh test-snapshot.sh test-solo-audit-experiment.sh test-stage-supervisor.sh test-suite-isolation.sh"
_selected_got=$(printf '%s\n' $_selected_names | sort | tr '\n' ' ' \
                  | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')
check "누출 술어가 고르는 스위트 집합이 그대로다" "$_selected_got" "$_selected_want"

printf '\n통과 %s · 실패 %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
