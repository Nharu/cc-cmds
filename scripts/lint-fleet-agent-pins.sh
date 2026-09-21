#!/usr/bin/env bash
# Pin the LaunchAgent template against the script that renders it.
#
# `fleet-agent.plist.in` is rendered by `fleet.sh agent install` with a fixed
# set of `@PLACEHOLDER@` substitutions, and the numbers a launchd job runs on —
# the two StartIntervals — live in `fleet.sh` as `readonly` thresholds and reach
# the plist only through `@START_INTERVAL@`. Two ways that agreement rots, and
# each has a rule:
#
#   1  every placeholder the template carries is one fleet.sh substitutes,
#      and every placeholder fleet.sh substitutes (or deletes) is one the
#      template carries                                                    [fail]
#      A placeholder the script does not know survives rendering as a
#      literal `@NAME@` inside a plist launchd then loads; a substitution
#      for a placeholder the template lost is a value that goes nowhere.
#   2  `StartInterval` is followed by the placeholder, never by a literal   [fail]
#      A literal here is a second declaration of a threshold `fleet.sh`
#      already declares once, and `lint-pace-threshold-pins.sh` cannot see
#      it because it is not in fleet.sh.
#   3  `KeepAlive`, `AbandonProcessGroup` and `ProcessType` are absent      [fail]
#      Each absence is a decision the template's own header explains; a key
#      added back silently reverses it.
#   4  the substituted StartInterval values are the two fleet.sh thresholds [fail]
#      `fleet_render_plist` is called with `$FLEET_START_INTERVAL` for the
#      sensor and `$FLEET_DISPATCH_START_INTERVAL` for a dispatch label, by
#      name — a literal at either call site is rule 2 one file over.
#
# Usage:
#   bash scripts/lint-fleet-agent-pins.sh
#
# Env overrides (fixture runner):
#   ORCH_ROOT=<dir>     # directory holding fleet.sh and fleet-agent.plist.in
#
# Exit codes:
#   0 — pass (or skipped: fleet.sh absent)
#   1 — at least one violation
#   2 — fleet.sh present but the template is missing
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
orch_root="${ORCH_ROOT:-$repo_root/plugins/cc-cmds/orchestrator}"
FLEET="$orch_root/fleet.sh"
TPL="$orch_root/fleet-agent.plist.in"

if [[ ! -f "$FLEET" ]]; then
  echo "SKIP: fleet.sh not found under $orch_root — 렌더러 부재"
  exit 0
fi
if [[ ! -f "$TPL" ]]; then
  echo "FAIL: fleet-agent.plist.in not found under $orch_root — fleet.sh 는 있는데 템플릿이 없다" >&2
  exit 2
fi

fail=0

# --- Rule 1: placeholder sets agree, both directions -------------------------
# The template's set is every `@NAME@` outside the leading XML comment; the
# comment documents the placeholders and would otherwise count each twice. The
# script's set is every `@NAME@` named in a sed `s|@NAME@|…|` or `/@NAME@/d`
# expression inside `fleet_render_plist`.
tpl_body=$(LC_ALL=C sed -n '/^-->$/,$p' "$TPL")
tpl_set=$(printf '%s\n' "$tpl_body" | LC_ALL=C grep -oE '@[A-Z_]+@' | LC_ALL=C sort -u || true)
render_fn=$(LC_ALL=C sed -n '/^fleet_render_plist() {/,/^}/p' "$FLEET")
if [[ -z "$render_fn" ]]; then
  echo "FAIL: fleet.sh — fleet_render_plist() 를 찾지 못했다" >&2
  exit 1
fi
sh_set=$(printf '%s\n' "$render_fn" | LC_ALL=C grep -oE '(s\|@[A-Z_]+@\||/@[A-Z_]+@/d)' | LC_ALL=C grep -oE '@[A-Z_]+@' | LC_ALL=C sort -u || true)

only_tpl=$(LC_ALL=C comm -23 <(printf '%s\n' "$tpl_set") <(printf '%s\n' "$sh_set") || true)
only_sh=$(LC_ALL=C comm -13 <(printf '%s\n' "$tpl_set") <(printf '%s\n' "$sh_set") || true)
if [[ -n "$only_tpl" ]]; then
  printf '%s\n' "$only_tpl" | while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    echo "FAIL: fleet-agent.plist.in 이 $p 를 싣는데 fleet.sh 의 fleet_render_plist 는 그것을 치환하지 않는다 — 렌더된 plist 에 축자로 남는다" >&2
  done
  fail=1
fi
if [[ -n "$only_sh" ]]; then
  printf '%s\n' "$only_sh" | while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    echo "FAIL: fleet.sh 가 $p 를 치환하는데 fleet-agent.plist.in 에는 그 자리가 없다 — 값이 어디에도 닿지 않는다" >&2
  done
  fail=1
fi

# --- Rule 2: StartInterval carries the placeholder ---------------------------
si_lines=$(printf '%s\n' "$tpl_body" | LC_ALL=C grep -n -A1 '<key>StartInterval</key>' || true)
nsi=$(printf '%s\n' "$tpl_body" | LC_ALL=C grep -c '<key>StartInterval</key>' || true)
if [[ "${nsi:-0}" != "1" ]]; then
  echo "FAIL: fleet-agent.plist.in — StartInterval 키가 정확히 1개여야 하는데 ${nsi:-0}개다" >&2
  fail=1
else
  si_val=$(printf '%s\n' "$si_lines" | LC_ALL=C grep -oE '<integer>[^<]*</integer>' | sed -E 's|</?integer>||g' || true)
  if [[ "$si_val" != "@START_INTERVAL@" ]]; then
    echo "FAIL: fleet-agent.plist.in — StartInterval 값이 '@START_INTERVAL@' 자리표시자여야 하는데 '${si_val}' 이다" >&2
    echo "       숫자는 fleet.sh 의 readonly 선언에만 산다; 여기 리터럴은 lint-pace-threshold-pins.sh 가 볼 수 없는 두 번째 선언이다" >&2
    fail=1
  fi
fi

# --- Rule 3: the three deliberately absent keys stay absent -----------------
for k in KeepAlive AbandonProcessGroup ProcessType; do
  n=$(printf '%s\n' "$tpl_body" | LC_ALL=C grep -c "<key>$k</key>" || true)
  if [[ "${n:-0}" != "0" ]]; then
    echo "FAIL: fleet-agent.plist.in — <key>$k</key> 가 있다; 그 키의 부재는 템플릿 머리말이 설명하는 결정이다" >&2
    fail=1
  fi
done

# --- Rule 4: the render call sites pass the thresholds by name ---------------
for pair in "sensor|FLEET_START_INTERVAL" "dispatch|FLEET_DISPATCH_START_INTERVAL"; do
  sub="${pair%%|*}"; var="${pair##*|}"
  calls=$(LC_ALL=C grep -E "fleet_render_plist \"\\\$label\" $sub " "$FLEET" || true)
  ncall=0
  if [[ -n "$calls" ]]; then ncall=$(printf '%s\n' "$calls" | grep -c '' || true); fi
  if [[ "$ncall" != "1" ]]; then
    echo "FAIL: fleet.sh — fleet_render_plist … $sub … 호출이 정확히 1개여야 하는데 ${ncall}개다" >&2
    fail=1
    continue
  fi
  case "$calls" in
    *"\"\$$var\""*) ;;
    *) echo "FAIL: fleet.sh — $sub 레이블의 렌더 호출이 \"\$$var\" 를 이름으로 넘기지 않는다: $calls" >&2
       fail=1 ;;
  esac
  ndecl=$(LC_ALL=C grep -cE "^readonly $var=[0-9]+" "$FLEET" || true)
  if [[ "${ndecl:-0}" != "1" ]]; then
    echo "FAIL: fleet.sh — readonly $var=<n> 선언이 정확히 1개여야 하는데 ${ndecl:-0}개다" >&2
    fail=1
  fi
done

if [[ "$fail" != "0" ]]; then
  echo "lint-fleet-agent-pins: violations found" >&2
  exit 1
fi

ntpl=$(printf '%s\n' "$tpl_set" | grep -c '' || true)
echo "OK:   fleet agent pins — 자리표시자 ${ntpl}개가 양방향 일치, StartInterval 은 자리표시자, 부재 키 3개 부재, 렌더 호출 2개가 선언을 이름으로 넘긴다"
exit 0
