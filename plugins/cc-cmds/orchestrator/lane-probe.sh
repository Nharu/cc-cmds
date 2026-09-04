#!/usr/bin/env bash
#
# lane-probe.sh — which lane is the pipeline spending, and is anything running?
#
# One line per run directory:
#
#   <run-id> <상태> <살아있는 스테이지 수> <config dir>
#
# WHY THIS IS A SEPARATE PROGRAM. Its consumer is outside this repository — a
# swap scheduler has to know whether an unattended run is live before it moves a
# lane's credentials, and it cannot link a driver. What it can do is run a
# read-only probe and read four fields. Nothing here writes.
#
# THE STATUS IS THREE-VALUED AND THE THIRD VALUE IS LOAD-BEARING.
#
#   도는중    — a recorded pid is alive AND its start-time fingerprint matches.
#   아님      — no such stage.
#   판정 불가 — the records exist but this probe does not recognize their shape.
#
# The third one is not a tidy-up. Run directories are never cleaned, they
# outlive reboots, and their record format has already drifted once on disk;
# what kept that drift harmless was degrading to "cannot judge" instead of
# answering "idle". A two-valued probe answers 아님 for a record it cannot read,
# and 아님 is the answer that authorizes a swap.
#
# ENUMERATION FAILURE IS NOT "NO RUNS", AND THE OUTPUT CANNOT SAY SO. Both cases
# print nothing — there are no lines to print either way — so the only thing
# separating them is the exit code, and a caller that ignores it reads an
# unreadable run root as an idle machine. A missing run root IS zero runs: the
# orchestrator not being installed is a fact, not an unknown.
#
# Exit codes:
#   0 — enumeration succeeded (including zero runs)
#   3 — enumeration failed; nothing was printed and nothing may be concluded
#   2 — usage error
#
# Usage:
#   bash lane-probe.sh              # one line per run
#   bash lane-probe.sh --resolve    # the resolver's answer with no run in hand
#
# Compatibility: bash 3.2 — no associative arrays, no mapfile.

set -uo pipefail

PROBE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# The predicates are SOURCED, never re-implemented. `cc_stage_is_live` is the
# one place that knows a live stage is a live pid AND a matching start-time
# fingerprint, and a second copy of that here would be a second thing to keep
# true. The same goes for `resolve_account`: this probe's whole job is to report
# the lane the driver would pick, so it has to ask the driver.
#
# `CC_ORCH_SOURCE_ONLY=1` is the driver's own seam for loading definitions
# without running a pipeline. Sourcing imports `set -e`, which this program must
# not inherit — every branch below runs a command expected to fail.
# shellcheck disable=SC1091
. "$PROBE_DIR/liveness.sh"
CC_ORCH_SOURCE_ONLY=1 . "$PROBE_DIR/run.sh"
set +e

RUN_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run"

probe_shape_ok() {
  # probe_shape_ok <run-dir> — false when this directory holds a record whose
  # shape this probe does not recognize, so the caller reports 판정 불가 rather
  # than counting.
  #
  # The readability tests come first and they are the reason this function
  # exists at all: `cc_live_stages` walks a glob, and a directory it cannot
  # enter yields no matches and therefore the count 0 — indistinguishable from
  # an idle run. An empty or non-numeric pid file is the same failure one level
  # down; it is reachable because a spawner's redirection creates the file
  # before it writes into it.
  local d="$1" f pid
  [ -d "$d" ] && [ -r "$d" ] && [ -x "$d" ] || return 1
  for f in "$d"/*.pid; do
    [ -e "$f" ] || continue
    [ -r "$f" ] || return 1
    pid=$( { cat "$f" 2>/dev/null || true; } | tr -d '[:space:]')
    case "$pid" in
      ''|*[!0-9]*) return 1 ;;
    esac
  done
  return 0
}

probe_config_dir() {
  # probe_config_dir <run-dir> — the lane recorded at run open, or the literal
  # `(미기록)`. Absence is ordinary rather than an error: every run directory
  # laid down before the driver started recording the lane has no such file, and
  # reporting those as undecidable would make the whole history unreadable.
  local d="$1" v
  [ -r "$d/config-dir" ] || { printf '(미기록)'; return 0; }
  v=$(sed -n '1p' "$d/config-dir" 2>/dev/null)
  [ -n "$v" ] || { printf '(미기록)'; return 0; }
  printf '%s' "$v"
}

probe_runs() {
  local d rid live
  # A missing root is zero runs, not a failure — see the header. An existing but
  # unenterable root IS the failure, and it is the branch the exit code exists
  # for.
  [ -d "$RUN_ROOT" ] || return 0
  { [ -r "$RUN_ROOT" ] && [ -x "$RUN_ROOT" ]; } || return 3
  for d in "$RUN_ROOT"/*; do
    [ -d "$d" ] || continue
    rid=${d##*/}
    if probe_shape_ok "$d"; then
      live=$(cc_live_stages "$d")
      if [ "${live:-0}" -gt 0 ] 2>/dev/null; then
        printf '%s 도는중 %s %s\n' "$rid" "$live" "$(probe_config_dir "$d")"
      else
        printf '%s 아님 %s %s\n' "$rid" "${live:-0}" "$(probe_config_dir "$d")"
      fi
    else
      # The count is `?` and not `0`. A number here would be read as a
      # measurement, and there was no measurement.
      printf '%s 판정 불가 ? %s\n' "$rid" "$(probe_config_dir "$d")"
    fi
  done
  return 0
}

main() {
  case "${1:-}" in
    '')
      # Buffered, so that a failure discovered part way through prints nothing
      # at all. Streaming would emit the lines it managed before the refusal,
      # and a partial census is the one output shape a swap gate must not see.
      local out rc
      out=$(probe_runs); rc=$?
      [ "$rc" = "0" ] || return 3
      [ -z "$out" ] || printf '%s\n' "$out"
      return 0
      ;;
    --resolve)
      # The resolver with NO run in hand, which is what a caller outside a run
      # is asking about. `RUN_DIR` is empty after the source-only load, so tier
      # 2 is skipped by construction and the answer comes from the environment,
      # the machine setting, or the default.
      local cfg
      cfg=$(resolve_account) || return 3
      printf '%s\n' "$cfg"
      return 0
      ;;
    *)
      printf 'lane-probe.sh: 알 수 없는 인자: %s (없음 | --resolve)\n' "$1" >&2
      return 2
      ;;
  esac
}

main "$@"
