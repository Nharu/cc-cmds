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

for f in "$GATE" "$repo_root/plugins/cc-cmds/orchestrator/run.sh" "$LIVENESS" \
         "$repo_root/scripts/run-fixture.sh"; do
  n=$(lc_census "$f" 'LC_ALL=C ps -o lstart=')
  bad_n=$(lc_census "$f" 'LC_TIME=C ps -o lstart=')
  check "$(basename "$f") 의 지문 캡처가 LC_ALL 로 고정돼 있다" "$n" "1"
  check "$(basename "$f") 에 LC_TIME 만 건 캡처가 남아 있지 않다" "$bad_n" "0"
done

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
_selected_want="test-gate.sh test-liveness-agreement.sh test-run.sh test-snapshot.sh"
_selected_got=$(printf '%s\n' $_selected_names | sort | tr '\n' ' ' \
                  | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')
check "누출 술어가 고르는 스위트 집합이 그대로다" "$_selected_got" "$_selected_want"

printf '\n통과 %s · 실패 %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
