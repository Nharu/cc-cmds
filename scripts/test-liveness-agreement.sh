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

printf '\n통과 %s · 실패 %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
