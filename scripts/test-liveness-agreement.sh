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

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
LIVENESS="$repo_root/plugins/cc-cmds/orchestrator/liveness.sh"
GATE="$repo_root/plugins/cc-cmds/orchestrator/gate.sh"
WATCH="$repo_root/plugins/cc-cmds/orchestrator/watch.sh"
SL="$repo_root/plugins/cc-cmds/orchestrator/statusline.sh"
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
  sed -n 's/.*스테이지 \([0-9][0-9]*\)개.*/\1/p' "$1/watch.heartbeat" 2>/dev/null | head -1
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
  local sid="$1" out rest
  out=$(fx_statusline_stdin "$sid" | bash "$SL")
  case "$out" in
    *"스테이지 0"*) printf '0' ;;
    "⟳"*)
      rest=${out#⟳ }        # the glyph
      rest=${rest#* }       # the run id
      printf '%s' "${rest%% *}"
      ;;
    *)             printf 'other:%s' "$out" ;;
  esac
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
# first in the ledger. The pair below is not invented: both are two spaces and
# 2-2-2 syllables, and they are the real vocabulary this field uses.
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
  printf -- '- `blocked` | 스코프=run | 원인=불명 | 사유=중단 기록 존재 | prev=x\n'
  printf -- '- `blocked` | 스코프=run | 원인=해소 | 사유=중단 기록 존재 | prev=x\n'
  printf -- '- `blocked` | 스코프=run | 원인=불명 | 사유=강제 표면 이동 | prev=x\n'
} > "$FX_BLK"
n=$(LC_ALL=en_US.UTF-8 bash -c '. "$1"; cc_unresolved_blocked "$2" | grep -c .' \
      _ "$LIVENESS" "$FX_BLK" || true)
check "해소된 블록이 미해소 블록을 가리지 않는다 (en_US 콜레이션)" "$n" "1"
got=$(LC_ALL=en_US.UTF-8 bash -c '. "$1"; cc_unresolved_blocked "$2"' \
        _ "$LIVENESS" "$FX_BLK" | sed -n 's/.*\t//p')
check "남는 것이 강제 표면 이동이다" "$got" "강제 표면 이동"

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
nonascii=$(printf '%s' "$w" | LC_ALL=C grep -c '[^ -~]' || true)
check "한글 날짜 로케일에서 캡처해도 지문이 ASCII 다 (쓰는 쪽 픽스처)" "$nonascii" "0"

# The second covers what no fixture can reach: the product's own two captures
# live inside a stage spawn and a driver spawn, neither of which this suite can
# drive. So they are asserted on the source. A structural check is weaker than a
# behavioural one and is used here only because the alternative was the hollow
# assertion above — and unlike that one, this fails the moment either capture
# goes back to a variable that `LC_ALL` outranks.
for f in "$GATE" "$repo_root/plugins/cc-cmds/orchestrator/run.sh" "$LIVENESS" \
         "$repo_root/scripts/run-fixture.sh"; do
  n=$(grep -c 'LC_ALL=C ps -o lstart=' "$f" || true)
  bad_n=$(grep -c 'LC_TIME=C ps -o lstart=' "$f" || true)
  check "$(basename "$f") 의 지문 캡처가 LC_ALL 로 고정돼 있다" "$n" "1"
  check "$(basename "$f") 에 LC_TIME 만 건 캡처가 남아 있지 않다" "$bad_n" "0"
done

printf '\n통과 %s · 실패 %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
