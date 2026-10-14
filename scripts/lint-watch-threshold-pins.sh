#!/usr/bin/env bash
# Pin the watcher's launch thresholds against the watcher script's own defaults.
#
# The autopilot skill's watcher launch line spells all four thresholds out, and
# the paragraph under it gives the reason: the status line has to judge whether a
# heartbeat is fresh, and a threshold it cannot read from a contract is a
# threshold it invents. That line was repaired once for exactly this — two arms
# had been added and their thresholds went unwritten, so the only configuration
# the run actually used was readable nowhere.
#
# The repair was to write the numbers down again, which fixes the instance and
# leaves the mechanism. Nothing holds the agreement: when a default moves, the
# sentence saying all four are the script's own defaults becomes false and the
# tree stays green, and the next person finds out during a night run.
#
# Rules:
#   1  watch.sh declares exactly one default for each pinned flag     [fail]
#   2  the launch line carries each pinned flag exactly once          [fail]
#   3  each pinned value equals the declared default                  [fail]
#   4  every other mention of a flag in the document agrees too       [fail]
#   5  liveness.sh declares the idle self-exit threshold once, as
#      86400, and neither watcher declares one of its own              [fail]
#
# Rule 3 derives the expected value from the script instead of pinning a literal
# here, so this check cannot drift away from the value it protects. Rule 1 is not
# bookkeeping either: a second assignment of the same variable is drift with no
# detector, because whichever runs last wins while the document pins the other.
#
# Rule 4 exists because the launch line is not the only place the document writes
# these numbers. The paragraph under it restates all four independently, and that
# paragraph is where the sentence quoted at the top of this header lives — the
# one asserting they are the script's own defaults. It names no script, so a scan
# anchored on `watch.sh` never reaches it. Measured: moving a default and
# repairing only the launch line printed OK while that sentence went on pinning
# the old number and claiming it was the default, and repairing only that
# sentence produced a failure naming the launch line, which was not the stale
# text. Rules 2 and 3 stay anchored on the launch line because that line is the
# configuration a run actually consumes and has to be identifiable as exactly
# one; rule 4 is the wider sweep no single line can stand in for.
#
# TWO CONSUMERS, COUNTED PER FILE. The autopilot skill's kickoff line was the
# only launcher until the fleet dispatcher (`fleet.sh dispatch`) started
# launching the watcher for a run it admits — with the same four flags, because
# the run it launches is the same kind of run. Each consumer is held to the
# launch-line rules on its own: one launch line per file, each flag once on that
# line, and every other mention in that file agreeing. A consumer that is absent
# is skipped by itself rather than skipping the whole check, so an incremental
# rollout of one file does not switch off the pin on the other.
#
# RULE 5 PINS A LITERAL, unlike rule 3. The idle self-exit threshold is not a
# launch flag: no document passes it, so there is no second place to derive it
# from, and both watchers read the one declaration in liveness.sh through the
# shared predicate. What can drift is a watcher growing a threshold of its own —
# then the two watchers stop on different days for the same run, and a run that
# one of them still watches is one the other has already left. The value itself
# is the design's 24 hours; moving it is a decision, and this rule makes that
# decision show up as an edit here.
#
# Usage:
#   bash scripts/lint-watch-threshold-pins.sh
#
# Env overrides (fixture runner):
#   ORCH_ROOT=<dir>     # directory holding watch.sh (the defaults' SOT) and fleet.sh
#   SKILLS_ROOT=<dir>   # skills root holding autopilot/references/act2-seat.md
#
# Posture: if the watcher is absent the whole check is a silent skip; an absent
# consumer skips that consumer only.
#
# Exit codes:
#   0 — pass (or skipped)
#   1 — at least one violation
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
orch_root="${ORCH_ROOT:-$repo_root/plugins/cc-cmds/orchestrator}"
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"
WATCHER="$orch_root/watch.sh"
# The autopilot launch line and the paragraph restating its thresholds sit in
# the Act 2 seat reference, which Step 7 reads before it launches the watcher.
CONSUMERS=(
  "$skills_root/autopilot/references/act2-seat.md"
  "$orch_root/fleet.sh"
)

if [[ ! -f "$WATCHER" ]]; then
  echo "SKIP: watch.sh not found under $orch_root — 임계 기본값 SOT 부재"
  exit 0
fi

# `<launch flag>|<shell variable the watcher assigns>`. Both halves are needed
# and neither file states the correspondence: the document writes the flag, the
# script defaults the variable, and the spelling differs on both sides of the
# pair (`--after-stage` against `AFTER_STAGE`).
PINS=(
  "--stall|STALL"
  "--interval|INTERVAL"
  "--after-stage|AFTER_STAGE"
  "--run-open|RUN_OPEN"
  # The general and settle-stall arms' own threshold. Pinned like the others:
  # the arms fire at `min(STALL, SILENCE)`, so a launch line that omitted it
  # would run a value no contract states.
  "--silence|SILENCE"
)

fail=0
checked=0
mentions_total=0
consumers_seen=0

# --- Rule 1, once per pin: exactly one declared default ---------------------
# The assignments sit together on one line separated by `; `, so the leading
# boundary is a semicolon or whitespace rather than start-of-line. The argument
# parser's own `VAR="$2"` arms carry no digits and do not match. Rule 1 is a
# property of the watcher alone, so it is decided before any consumer is read
# and a pin that fails it is dropped from the per-consumer rules below — an
# expected value that does not exist cannot be compared against.
WANTS=""
for pin in "${PINS[@]}"; do
  var="${pin##*|}"
  decls=$(LC_ALL=C grep -oE "(^|[;[:space:]])$var=[0-9]+" "$WATCHER" || true)
  ndecl=0
  if [[ -n "$decls" ]]; then
    ndecl=$(printf '%s\n' "$decls" | grep -c '' || true)
  fi
  if [[ "$ndecl" != "1" ]]; then
    echo "FAIL: watch.sh — $var 의 기본값 선언이 정확히 1개여야 하는데 ${ndecl}개다" >&2
    fail=1
    WANTS="$WANTS$var=
"
    continue
  fi
  want=$(printf '%s' "$decls" | sed -E "s/.*$var=//")
  WANTS="$WANTS$var=$want
"
  checked=$((checked + 1))
done

want_of() {
  printf '%s' "$WANTS" | sed -n "s/^$1=//p"
}

for CONSUMER in "${CONSUMERS[@]}"; do
  cname="${CONSUMER#"$skills_root/"}"
  cname="${cname#"$orch_root/"}"
  if [[ ! -f "$CONSUMER" ]]; then
    echo "SKIP: $cname not found — 기동 줄 소비자 부재 (이 소비자만 건너뛴다)"
    continue
  fi
  consumers_seen=$((consumers_seen + 1))

  # The launch line, located by the two things that identify it — the script
  # name and the argument every invocation is required to carry.
  #
  # CAPTURED AND COUNTED, not `grep -q`. An early-exiting reader on the right of
  # a pipe kills the writer with SIGPIPE, and under `pipefail` the pipeline then
  # reports failure even though the match was found.
  launch=$(LC_ALL=C grep -E 'watch\.sh"? .*--run-dir' "$CONSUMER" || true)
  nlaunch=0
  if [[ -n "$launch" ]]; then
    nlaunch=$(printf '%s\n' "$launch" | grep -c '' || true)
  fi
  if [[ "$nlaunch" != "1" ]]; then
    echo "FAIL: $cname — 워처 기동 줄이 정확히 1개여야 하는데 ${nlaunch}개다" >&2
    echo "       이 대조는 기동 줄 하나를 그 런의 설정으로 읽는다 — 둘이면 어느 쪽인지 정할 수 없다" >&2
    echo "       다른 스크립트(예: checks.sh)의 기동 줄이나 산문도, 감시자 스크립트 이름과 그 뒤의 --run-dir 를 한 줄에 함께 담으면 기동 줄로 세어진다 — 그런 줄은 자기 스크립트 이름만 적어야 한다" >&2
    fail=1
    continue
  fi

  for pin in "${PINS[@]}"; do
    flag="${pin%%|*}"
    var="${pin##*|}"
    want=$(want_of "$var")
    [[ -n "$want" ]] || continue

    # --- Rule 2: exactly one use of the flag on the launch line -----------
    uses=$(printf '%s' "$launch" | LC_ALL=C grep -oE -- "$flag [0-9]+" || true)
    nuse=0
    if [[ -n "$uses" ]]; then
      nuse=$(printf '%s\n' "$uses" | grep -c '' || true)
    fi
    if [[ "$nuse" != "1" ]]; then
      echo "FAIL: $cname — 기동 줄의 $flag 가 정확히 1개여야 하는데 ${nuse}개다" >&2
      echo "       기동 줄: $launch" >&2
      fail=1
      continue
    fi
    got=$(printf '%s' "$uses" | sed -E "s/^$flag //")

    # --- Rule 3: the two agree --------------------------------------------
    if [[ "$got" != "$want" ]]; then
      echo "FAIL: $cname $flag — 기동 줄은 $got 을 못 박는데 watch.sh 의 $var 기본값은 $want 이다" >&2
      echo "       둘이 갈라지면 '임계 전부가 스크립트 기본값' 이라는 진술이 거짓이 된다" >&2
      fail=1
    fi

    # --- Rule 4: every mention in the document, not only the launch line ---
    # The whole file rather than `$launch`, because the second place these
    # numbers are written carries no script name and is therefore invisible to
    # the scan that locates the launch line. Counted rather than short-circuited
    # for the same SIGPIPE reason as above.
    mentions=$(LC_ALL=C grep -oE -- "$flag [0-9]+" "$CONSUMER" || true)
    nment=0
    nstale=0
    if [[ -n "$mentions" ]]; then
      nment=$(printf '%s\n' "$mentions" | grep -c '' || true)
      stale=$(printf '%s\n' "$mentions" | sed -E "s/^$flag //" \
              | LC_ALL=C grep -vxF -- "$want" || true)
      if [[ -n "$stale" ]]; then
        nstale=$(printf '%s\n' "$stale" | grep -c '' || true)
      fi
    fi
    mentions_total=$((mentions_total + nment))
    if [[ "$nstale" != "0" ]]; then
      echo "FAIL: $cname $flag — 문서 안 기재 ${nment}건 중 ${nstale}건이 watch.sh 의 $var 기본값 $want 과 다르다" >&2
      echo "       기동 줄 밖의 기재도 같은 값을 못 박아야 한다 — '임계 전부가 스크립트 기본값' 이라고 단언하는 문장이 그 기재다" >&2
      fail=1
    fi
  done
done

# --- Rule 5: the idle self-exit threshold lives in liveness.sh alone ----------
IDLE_VAR=CC_RUN_IDLE_EXIT_SECONDS
IDLE_WANT=86400
LIVENESS="$orch_root/liveness.sh"
idle_note="유휴 임계 생략(liveness.sh 부재)"
if [[ -f "$LIVENESS" ]]; then
  decls=$(LC_ALL=C grep -oE "(^|[;[:space:]])$IDLE_VAR=[^[:space:];]*" "$LIVENESS" || true)
  ndecl=0
  if [[ -n "$decls" ]]; then
    ndecl=$(printf '%s\n' "$decls" | grep -c '' || true)
  fi
  if [[ "$ndecl" != "1" ]]; then
    echo "FAIL: liveness.sh — $IDLE_VAR 의 선언이 정확히 1개여야 하는데 ${ndecl}개다" >&2
    fail=1
  else
    got=$(printf '%s' "$decls" | sed -E "s/.*$IDLE_VAR=//")
    if [[ "$got" != "$IDLE_WANT" ]]; then
      echo "FAIL: liveness.sh — $IDLE_VAR 는 $IDLE_WANT(24시간)이어야 하는데 $got 이다" >&2
      echo "       값을 옮기는 것은 결정이다 — 옮긴다면 이 린트의 고정값도 함께 고친다" >&2
      fail=1
    fi
  fi
  for w in "$WATCHER" "$orch_root/checks.sh"; do
    [[ -f "$w" ]] || continue
    # An assignment, not any occurrence of the number: watch.sh converts `ps`
    # elapsed days to seconds with the same 86400, and that is not a threshold.
    own=$(LC_ALL=C grep -nE "(^|[;[:space:]])($IDLE_VAR|[A-Za-z_][A-Za-z0-9_]*)=[\"']?$IDLE_WANT([^0-9]|$)|(^|[;[:space:]])$IDLE_VAR=" "$w" || true)
    if [[ -n "$own" ]]; then
      echo "FAIL: ${w##*/} — 유휴 자기 종료 임계를 제 안에 따로 둔다 (liveness.sh 의 $IDLE_VAR 만 읽어야 한다)" >&2
      echo "       $own" >&2
      fail=1
    fi
  done
  idle_note="유휴 임계 $IDLE_VAR=$IDLE_WANT 가 liveness.sh 한 곳에만 선언"
fi

if [[ "$fail" != "0" ]]; then
  echo "lint-watch-threshold-pins: violations found" >&2
  exit 1
fi

echo "OK:   watch threshold pins — 임계 ${checked}개, 소비자 ${consumers_seen}개, 문서 안 기재 ${mentions_total}건이 watch.sh 기본값과 축자로 일치, ${idle_note}"
exit 0
