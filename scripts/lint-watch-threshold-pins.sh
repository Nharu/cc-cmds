#!/usr/bin/env bash
# Pin the watcher's four thresholds against the watcher script's own defaults.
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
#   1  watch.sh declares exactly one default for each of the four     [fail]
#   2  the launch line carries each of the four flags exactly once    [fail]
#   3  each pinned value equals the declared default                  [fail]
#
# Rule 3 derives the expected value from the script instead of pinning a literal
# here, so this check cannot drift away from the value it protects. Rule 1 is not
# bookkeeping either: a second assignment of the same variable is drift with no
# detector, because whichever runs last wins while the document pins the other.
#
# Usage:
#   bash scripts/lint-watch-threshold-pins.sh
#
# Env overrides (fixture runner):
#   ORCH_ROOT=<dir>     # directory holding watch.sh (the defaults' SOT)
#   SKILLS_ROOT=<dir>   # skills root holding autopilot/SKILL.md
#
# Posture: if either side is absent the whole check is a silent skip, so the
# script stays green during an incremental rollout.
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
CONSUMER="$skills_root/autopilot/SKILL.md"

if [[ ! -f "$WATCHER" ]]; then
  echo "SKIP: watch.sh not found under $orch_root — 임계 기본값 SOT 부재"
  exit 0
fi
if [[ ! -f "$CONSUMER" ]]; then
  echo "SKIP: autopilot/SKILL.md not found under $skills_root — 기동 줄 소비자 부재"
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
)

fail=0
checked=0

# The launch line, located by the two things that identify it — the script name
# and the argument every invocation is required to carry.
#
# CAPTURED AND COUNTED, not `grep -q`. An early-exiting reader on the right of a
# pipe kills the writer with SIGPIPE, and under `pipefail` the pipeline then
# reports failure even though the match was found.
launch=$(LC_ALL=C grep -E 'watch\.sh .*--run-dir' "$CONSUMER" || true)
nlaunch=0
if [[ -n "$launch" ]]; then
  nlaunch=$(printf '%s\n' "$launch" | grep -c '' || true)
fi
if [[ "$nlaunch" != "1" ]]; then
  echo "FAIL: autopilot/SKILL.md — 워처 기동 줄이 정확히 1개여야 하는데 ${nlaunch}개다" >&2
  echo "       이 대조는 기동 줄 하나를 그 런의 설정으로 읽는다 — 둘이면 어느 쪽인지 정할 수 없다" >&2
  exit 1
fi

for pin in "${PINS[@]}"; do
  flag="${pin%%|*}"
  var="${pin##*|}"
  checked=$((checked + 1))

  # --- Rule 1: exactly one declared default -------------------------------
  # The assignments sit together on one line separated by `; `, so the leading
  # boundary is a semicolon or whitespace rather than start-of-line. The
  # argument parser's own `VAR="$2"` arms carry no digits and do not match.
  decls=$(LC_ALL=C grep -oE "(^|[;[:space:]])$var=[0-9]+" "$WATCHER" || true)
  ndecl=0
  if [[ -n "$decls" ]]; then
    ndecl=$(printf '%s\n' "$decls" | grep -c '' || true)
  fi
  if [[ "$ndecl" != "1" ]]; then
    echo "FAIL: watch.sh — $var 의 기본값 선언이 정확히 1개여야 하는데 ${ndecl}개다" >&2
    fail=1
    continue
  fi
  want=$(printf '%s' "$decls" | sed -E "s/.*$var=//")

  # --- Rule 2: exactly one use of the flag on the launch line -------------
  uses=$(printf '%s' "$launch" | LC_ALL=C grep -oE -- "$flag [0-9]+" || true)
  nuse=0
  if [[ -n "$uses" ]]; then
    nuse=$(printf '%s\n' "$uses" | grep -c '' || true)
  fi
  if [[ "$nuse" != "1" ]]; then
    echo "FAIL: autopilot/SKILL.md — 기동 줄의 $flag 가 정확히 1개여야 하는데 ${nuse}개다" >&2
    echo "       기동 줄: $launch" >&2
    fail=1
    continue
  fi
  got=$(printf '%s' "$uses" | sed -E "s/^$flag //")

  # --- Rule 3: the two agree ----------------------------------------------
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: $flag — 기동 줄은 $got 을 못 박는데 watch.sh 의 $var 기본값은 $want 이다" >&2
    echo "       둘이 갈라지면 '네 임계 전부가 스크립트 기본값' 이라는 진술이 거짓이 된다" >&2
    fail=1
  fi
done

if [[ "$fail" != "0" ]]; then
  echo "lint-watch-threshold-pins: violations found" >&2
  exit 1
fi

echo "OK:   watch threshold pins — 임계 ${checked}개가 watch.sh 기본값과 축자로 일치"
exit 0
