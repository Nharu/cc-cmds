#!/usr/bin/env bash
# Pin every numeric threshold the pacing sensor declares against every place
# that restates it.
#
# `fleet.sh` is the single source of the pacing thresholds: the sensor period,
# the tick budget, the staleness horizon, the burn window and cache TTL, the
# idle horizon, the lane targets, the scan caps. Each is one `readonly
# <NAME>=<digits>` line, and that form is the contract this lint reads — a
# threshold declared any other way is a threshold this lint cannot see, and a
# threshold this lint cannot see is one nothing holds.
#
# The numbers are restated elsewhere on purpose: the gate reads the same
# staleness horizon (`GATE_PACE_STALE_SECONDS`) so that "the sensor is stale"
# means the same thing on both sides of `state.json`, the driver reads it again
# (`RUN_PACE_STALE_SECONDS`) for the headroom question, and the sidecar contract
# and the autopilot skill spell values in prose. Each restatement is a place a
# default can move away from, and `lint-watch-threshold-pins.sh` is the
# measured precedent: a repaired launch line and a stale paragraph beside it,
# both green.
#
# Rules:
#   1  fleet.sh declares each `FLEET_*` numeric threshold exactly once   [exit 2]
#   2  gate.sh's GATE_PACE_STALE_SECONDS and run.sh's RUN_PACE_STALE_SECONDS
#      each exist exactly once and equal FLEET_STATE_STALE_SECONDS        [fail]
#   2b run.sh's RUN_PACE_SESSION_WINDOW_PCT_MAX exists exactly once and
#      equals FLEET_SESSION_WINDOW_PCT_MAX                                 [fail]
#      (fleet.sh not declaring FLEET_SESSION_WINDOW_PCT_MAX is exit 2)
#   3  every consumer mention `<NAME>=<n>` or `<NAME> (<n>s)` agrees      [fail]
#   4  every consumer file exists                                          [fail]
#   5  the two thresholds rule 1 does not collect — gate.sh's
#      GATE_MASTER_STALE_SECONDS and repair.sh's REPAIR_DEADLINE_SECONDS —
#      are each one `readonly <NAME>=<digits>` line                       [fail]
#   6  the master reading's timing holds together:
#      GATE_MASTER_STALE_SECONDS >= 3 x (FLEET_MASTER_INTERVAL_SECONDS +
#      FLEET_MASTER_BUDGET_SECONDS), so three missed rounds still read
#      fresh, and FLEET_MASTER_SKIP_SECONDS x 2 <= FLEET_MASTER_INTERVAL_SECONDS,
#      so a pair is never skipped for a whole period                       [fail]
#      (fleet.sh not declaring one of the three FLEET_MASTER_* is exit 2)
#
# Rule 4 is a FAIL and not a skip, unlike the watcher lint. The watcher lint
# skips an absent consumer because its consumers arrived one at a time; here
# the consumers are the files this change lands together, and a consumer that
# is missing is a consumer that was deleted or moved without moving this list —
# which is drift, not rollout. Files under `docs/` are never consumers: they
# are design records and may legitimately carry a number the code has moved on
# from.
#
# Usage:
#   bash scripts/lint-pace-threshold-pins.sh
#
# Env overrides (fixture runner):
#   ORCH_ROOT=<dir>     # directory holding fleet.sh, gate.sh, run.sh, repair.sh
#   SKILLS_ROOT=<dir>   # skills root holding autopilot/SKILL.md and _common/pipeline-sidecar.md
#
# Exit codes:
#   0 — pass
#   1 — at least one violation
#   2 — the source of truth is unusable (fleet.sh absent, or a threshold declared 0 or 2+ times)
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
orch_root="${ORCH_ROOT:-$repo_root/plugins/cc-cmds/orchestrator}"
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"
FLEET="$orch_root/fleet.sh"
GATE="$orch_root/gate.sh"
RUN="$orch_root/run.sh"
REPAIR="$orch_root/repair.sh"
CONSUMERS=(
  "$skills_root/autopilot/SKILL.md"
  "$skills_root/_common/pipeline-sidecar.md"
  "$orch_root/gate.sh"
)

if [[ ! -f "$FLEET" ]]; then
  echo "FAIL: fleet.sh not found under $orch_root — 페이싱 임계 SOT 부재" >&2
  exit 2
fi

fail=0

# --- Rule 1: the declarations, one line each -------------------------------
# `readonly NAME=digits` at line start, a trailing comment allowed. Names are
# collected first and counted second so a duplicate is reported by name.
decl_lines=$(LC_ALL=C sed -n 's/^readonly \(FLEET_[A-Z0-9_]*\)=\([0-9][0-9]*\)\([[:space:]].*\)\{0,1\}$/\1=\2/p' "$FLEET" || true)
if [[ -z "$decl_lines" ]]; then
  echo "FAIL: fleet.sh — readonly FLEET_<NAME>=<digits> 선언을 하나도 찾지 못했다 (임계 SOT 부재)" >&2
  exit 2
fi
names=$(printf '%s\n' "$decl_lines" | sed 's/=.*//' | LC_ALL=C sort)
dups=$(printf '%s\n' "$names" | uniq -d || true)
if [[ -n "$dups" ]]; then
  printf '%s\n' "$dups" | while IFS= read -r n; do
    echo "FAIL: fleet.sh — $n 의 선언이 2개 이상이다; 마지막 것이 이기고 문서는 다른 쪽을 못 박는다" >&2
  done
  exit 2
fi
ndecl=$(printf '%s\n' "$decl_lines" | grep -c '' || true)

value_of() {
  printf '%s\n' "$decl_lines" | sed -n "s/^$1=//p"
}

# --- Rule 4 first: every consumer exists ------------------------------------
for c in "${CONSUMERS[@]}" "$RUN" "$REPAIR"; do
  if [[ ! -f "$c" ]]; then
    echo "FAIL: 소비 파일 부재 — $c (부재는 SKIP 이 아니라 FAIL 이다: 이 목록과 함께 옮기지 않은 이동·삭제)" >&2
    fail=1
  fi
done
if [[ "$fail" != "0" ]]; then
  echo "lint-pace-threshold-pins: violations found" >&2
  exit 1
fi

# --- Rule 2: the two readers of the staleness horizon ----------------------
stale_want=$(value_of FLEET_STATE_STALE_SECONDS)
if [[ -z "$stale_want" ]]; then
  echo "FAIL: fleet.sh — FLEET_STATE_STALE_SECONDS 선언이 없다; 게이트와 드라이버가 같은 낡음 지평을 읽을 수 없다" >&2
  exit 2
fi
check_mirror() {
  # check_mirror <file> <label> <var>
  local f="$1" label="$2" var="$3" decls n got
  decls=$(LC_ALL=C sed -n "s/^readonly $var=\([0-9][0-9]*\)\([[:space:]].*\)\{0,1\}$/\1/p" "$f" || true)
  n=0
  if [[ -n "$decls" ]]; then n=$(printf '%s\n' "$decls" | grep -c '' || true); fi
  if [[ "$n" != "1" ]]; then
    echo "FAIL: $label — readonly $var=<n> 선언이 정확히 1개여야 하는데 ${n}개다" >&2
    fail=1
    return 0
  fi
  got=$(printf '%s' "$decls")
  if [[ "$got" != "$stale_want" ]]; then
    echo "FAIL: $label — $var=$got 인데 fleet.sh 의 FLEET_STATE_STALE_SECONDS 는 $stale_want 이다" >&2
    echo "       센서의 낡음 지평과 소비자의 낡음 지평이 갈라지면 한쪽은 부재를 판정으로, 다른 쪽은 판정을 부재로 읽는다" >&2
    fail=1
  fi
}
check_mirror "$GATE" "gate.sh" GATE_PACE_STALE_SECONDS
check_mirror "$RUN" "run.sh" RUN_PACE_STALE_SECONDS

# --- Rule 2b: the two readers of the 5h session ceiling ----------------------
# The fleet's window cap and the driver's headroom read the same `usage.json`
# figure, so their two 80s are one threshold. `check_mirror` above is bound to
# the staleness value, which is why this pair has its own function rather than
# a parameter on that one.
pct_want=$(value_of FLEET_SESSION_WINDOW_PCT_MAX)
if [[ -z "$pct_want" ]]; then
  echo "FAIL: fleet.sh — FLEET_SESSION_WINDOW_PCT_MAX 선언이 없다; fleet 상한과 드라이버 여유가 같은 5시간 창 상한을 읽을 수 없다" >&2
  exit 2
fi
check_session_mirror() {
  # check_session_mirror <file> <label> <var>
  local f="$1" label="$2" var="$3" decls n got
  decls=$(LC_ALL=C sed -n "s/^readonly $var=\([0-9][0-9]*\)\([[:space:]].*\)\{0,1\}$/\1/p" "$f" || true)
  n=0
  if [[ -n "$decls" ]]; then n=$(printf '%s\n' "$decls" | grep -c '' || true); fi
  if [[ "$n" != "1" ]]; then
    echo "FAIL: $label — readonly $var=<n> 선언이 정확히 1개여야 하는데 ${n}개다" >&2
    fail=1
    return 0
  fi
  got=$(printf '%s' "$decls")
  if [[ "$got" != "$pct_want" ]]; then
    echo "FAIL: $label — $var=$got 인데 fleet.sh 의 FLEET_SESSION_WINDOW_PCT_MAX 는 $pct_want 이다" >&2
    echo "       두 상한이 갈라지면 fleet 은 막고 드라이버는 여유로 읽거나, 그 반대가 된다" >&2
    fail=1
  fi
}
check_session_mirror "$RUN" "run.sh" RUN_PACE_SESSION_WINDOW_PCT_MAX

# --- Rule 5: the named thresholds outside fleet.sh ---------------------------
# Rule 1 collects `FLEET_*` from fleet.sh alone, so the gate's freshness horizon
# for the master reading and the repair run's deadline are held here by name.
# The value they must hold is rule 6's for the first, and the design's for the
# second; this rule makes each one line a reader can find.
named_value() {
  # named_value <file> <label> <var> — the one declared value, or nothing
  # after a FAIL line. It runs in a command substitution, so the caller sets
  # `fail` on an empty result.
  local f="$1" label="$2" var="$3" decls n
  decls=$(LC_ALL=C sed -n "s/^readonly $var=\([0-9][0-9]*\)\([[:space:]].*\)\{0,1\}$/\1/p" "$f" || true)
  n=0
  if [[ -n "$decls" ]]; then n=$(printf '%s\n' "$decls" | grep -c '' || true); fi
  if [[ "$n" != "1" ]]; then
    echo "FAIL: $label — readonly $var=<n> 선언이 정확히 1개여야 하는데 ${n}개다" >&2
    return 0
  fi
  printf '%s' "$decls"
}
master_stale=$(named_value "$GATE" "gate.sh" GATE_MASTER_STALE_SECONDS)
[[ -n "$master_stale" ]] || fail=1
repair_deadline=$(named_value "$REPAIR" "repair.sh" REPAIR_DEADLINE_SECONDS)
[[ -n "$repair_deadline" ]] || fail=1

# --- Rule 6: the master reading's timing -------------------------------------
m_interval=$(value_of FLEET_MASTER_INTERVAL_SECONDS)
m_budget=$(value_of FLEET_MASTER_BUDGET_SECONDS)
m_skip=$(value_of FLEET_MASTER_SKIP_SECONDS)
if [[ -z "$m_interval" || -z "$m_budget" || -z "$m_skip" ]]; then
  echo "FAIL: fleet.sh — FLEET_MASTER_INTERVAL_SECONDS·FLEET_MASTER_BUDGET_SECONDS·FLEET_MASTER_SKIP_SECONDS 중 선언이 없는 것이 있다; master 판독의 주기 관계를 잴 수 없다" >&2
  exit 2
fi
if [[ -n "$master_stale" ]] && (( master_stale < 3 * (m_interval + m_budget) )); then
  echo "FAIL: gate.sh — GATE_MASTER_STALE_SECONDS=$master_stale 이 3 x (FLEET_MASTER_INTERVAL_SECONDS $m_interval + FLEET_MASTER_BUDGET_SECONDS $m_budget) = $(( 3 * (m_interval + m_budget) )) 보다 작다" >&2
  echo "       회차 셋을 놓치기 전에 판독이 낡아, 살아 있는 관측을 게이트가 부재로 읽는다" >&2
  fail=1
fi
if (( m_skip * 2 > m_interval )); then
  echo "FAIL: fleet.sh — FLEET_MASTER_SKIP_SECONDS=$m_skip 의 두 배가 FLEET_MASTER_INTERVAL_SECONDS=$m_interval 보다 크다" >&2
  echo "       한 회차 늦게 시작한 판독이 다음 회차에도 건너뛰어져, 쌍 하나가 주기 하나를 통째로 빠진다" >&2
  fail=1
fi

# --- Rule 3: every mention in every consumer agrees --------------------------
# Two spellings are bound to a name: `NAME=<n>` and `NAME` followed on the same
# line by `(<n>s)` / `(<n>)`. A bare number in prose (`3 x (55 + 5) = 180s`) is
# bound to nothing and is not judged here — the sentence that binds it to a name
# is the one this lint reads.
mentions_total=0
for c in "${CONSUMERS[@]}"; do
  cname="${c#"$skills_root/"}"
  cname="${cname#"$orch_root/"}"
  while IFS= read -r decl; do
    name="${decl%%=*}"
    want="${decl#*=}"
    lines=$(LC_ALL=C grep -n -- "$name" "$c" || true)
    [[ -n "$lines" ]] || continue
    while IFS= read -r ln; do
      [[ -n "$ln" ]] || continue
      lineno="${ln%%:*}"
      text="${ln#*:}"
      # The two spellings are joined by `t`: once the first substitution has
      # fired the second is skipped, so at most one value comes out and no
      # early-exit reader sits on the right of the pipe. The three steps are
      # separate `-e` arguments because BSD sed reads everything after `t` on
      # the same line — semicolon included — as its label.
      got=$(printf '%s' "$text" | LC_ALL=C sed -n -E \
        -e "s/.*$name\`?=([0-9]+).*/\1/p" -e t \
        -e "s/.*$name\`?[[:space:]]*\(([0-9]+)s?\).*/\1/p")
      [[ -n "$got" ]] || continue
      mentions_total=$((mentions_total + 1))
      if [[ "$got" != "$want" ]]; then
        echo "FAIL: $cname:$lineno — $name 을 $got 으로 적는데 fleet.sh 의 선언은 $want 이다" >&2
        fail=1
      fi
    done <<EOF
$lines
EOF
  done <<EOF
$decl_lines
EOF
done

if [[ "$fail" != "0" ]]; then
  echo "lint-pace-threshold-pins: violations found" >&2
  exit 1
fi

echo "OK:   pace threshold pins — 선언 ${ndecl}개, 거울 3개, 소비 문서 기재 ${mentions_total}건이 fleet.sh 선언과 축자로 일치, 이름 핀 2개와 master 주기 관계 2개 통과"
exit 0
