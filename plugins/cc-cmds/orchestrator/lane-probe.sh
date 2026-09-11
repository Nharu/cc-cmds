#!/usr/bin/env bash
#
# lane-probe.sh — which lane is the pipeline spending, and is anything running?
#
# One line per run directory, TAB-separated:
#
#   <run-id>\t<상태>\t<살아있는 스테이지 수>\t<config dir>
#
# THE SEPARATOR IS A TAB AND THAT IS PART OF THE CONTRACT. The last field is a
# filesystem path and the status token contains a space, so neither is bounded
# by whitespace; a consumer splitting on spaces reads `판정` as the status and a
# truncated path as the lane. Split on TAB — `cut -f4`, `awk -F'\t'`, or
# `IFS=$'\t' read`.
#
# NO FIELD MAY CONTAIN A TAB OR A NEWLINE, AND THIS PROGRAM IS WHAT MAKES THAT
# TRUE — it is not a property inherited from elsewhere. An earlier version of
# this paragraph claimed it twice over and was wrong both times: it said the run
# id is a directory name this program creates the shape of (it is not — the
# names are ENUMERATED from a shared root nothing here creates or cleans), and
# it said a lane path holding a tab is refused upstream (it was not, anywhere).
# A tab split a record into five fields; a NEWLINE was worse, because it does
# not split a field, it MANUFACTURES A WHOLE RECORD — one planted directory
# produced a syntactically perfect line for a run id that does not exist, with
# all three swap-deciding fields under the planter's control, delivered at
# exit 0. A consumer cannot defend against that by parsing more carefully.
#
# So both ends are closed here. A run id carrying a control character is never
# interpolated: the line is published with the fixed literal `(비정규 이름)` and
# the status `판정 불가`, so the directory stays visible without its bytes
# reaching the record. A lane path carrying one is refused by the resolver's
# file tiers and, for the environment tier those do not cover, by the field
# printer below. The status is one of three literals and the count is digits or
# `?`, and neither comes from disk.
#
# THE DECLARED RUN-ID SHAPE IS NOT USED AS THE FILTER, and that is a measured
# decision rather than an omission. The contract document names the shape
# `<UTC date>-<8 hex>`, but the run root is never cleaned and holds names from
# before that shape existed: 82 of the 202 real directories on this machine do
# not match it (`2026-09-04-23fa6c24`, `btopen-20260904-985a8a02`, `R1`).
# Filtering on the shape would publish 판정 불가 for 40% of the history
# permanently — and a probe that can never say 아님 for those directories stops
# being a gate for them, which is the same argument the `watch.pid` exemption
# below makes. The control-character refusal closes the forgery completely
# without that cost; the shape is a naming convention, not a security boundary.
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
# `cd` 가 실패하면 빈 문자열이 되고, 그러면 아래 두 소싱이 루트에서 엉뚱한 파일을
# 찾거나 조용히 실패한다. 열거 실패는 열거 실패로 나가야 한다.
[ -n "$PROBE_DIR" ] || exit 3

# The predicates are SOURCED, never re-implemented. `cc_stage_is_live` is the
# one place that knows a live stage is a live pid AND a matching start-time
# fingerprint, and a second copy of that here would be a second thing to keep
# true. The same goes for `resolve_account`: this probe's whole job is to report
# the lane the driver would pick, so it has to ask the driver.
#
# `CC_ORCH_SOURCE_ONLY=1` is the driver's own seam for loading definitions
# without running a pipeline. Sourcing imports `set -e`, which this program must
# not inherit — every branch below runs a command expected to fail.
# 소싱 실패를 확인하지 않으면 `cc_live_stages` 가 미정의인 채로 센서스에 도달해
# 빈 문자열을 내고, 그 값이 `아님 0` 으로 인쇄되며 종료 코드는 0 으로 나간다 —
# 이 파일 헤더가 종료 코드만이 열거 실패와 런 없음을 가른다고 선언한 그 계약이
# 그 자리에서 깨진다. `set -e` 는 위 사유로 걸 수 없으므로 각각을 직접 확인한다.
# `|| exit 3` 이 붙은 소싱은 복합 명령이라, 소싱이 들여오는 `set -e` 아래에서도
# 스크립트를 중단시키지 않는다.
# shellcheck disable=SC1091
[ -r "$PROBE_DIR/liveness.sh" ] || exit 3
. "$PROBE_DIR/liveness.sh" || exit 3
[ -r "$PROBE_DIR/run.sh" ] || exit 3
CC_ORCH_SOURCE_ONLY=1 . "$PROBE_DIR/run.sh" || exit 3
set +e
# 소싱이 rc=0 으로 성공하고도 정의가 없는 경우(잘린 파일, 이름 변경)까지 덮는다.
# 이 프로그램이 기대는 술어 둘을 이름으로 못박아 두는 것이 이 줄의 요점이다.
command -v cc_live_stages >/dev/null && command -v resolve_account >/dev/null || exit 3

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
  #
  # THIS CHECK MUST ADMIT EXACTLY THE SET THE CENSUS COUNTS. `cc_stage_is_live`
  # requires a sibling handle — `<name>.start` or `<name>.pgid` — beside a pid
  # before it will call that pid a stage, and a pid it rejects there is simply
  # not counted. So a pid file this shape check waves through without the same
  # requirement lands in the census as 0, and 0 prints as `아님` — the answer
  # this file's own header calls the one that authorizes a swap. The window is
  # real rather than theoretical: the two spawners write the pid and the
  # fingerprint in OPPOSITE orders, so a stage exists whose pid file is on disk
  # before its handle is, and a probe run inside that window must say it cannot
  # judge rather than say the machine is idle.
  #
  # AND "THE SAME REQUIREMENT" MEANS CONTENT, NOT EXISTENCE. This test used to
  # ask `[ -f ]` while the census asks for a NON-EMPTY handle, so the invariant
  # above was false in exactly the direction that hurts: an empty `.start` was
  # admitted here, fell through the census's `.pgid` fallback — the gate writes
  # no `.pgid` at all — and published as `아님 0` for a stage that was alive.
  #
  # The empty state is not a narrow race. The gate spawner's `.start` is the
  # output redirection target of a `ps | sed` pipeline, so the shell creates and
  # truncates the file before `ps` emits a byte: measured 300/300 in a window
  # about 3.9 ms wide. And `ps` runs with stderr discarded and its output
  # unchecked, so if it prints nothing the file stays empty for the stage's
  # ENTIRE lifetime — a persistent state, not a window.
  #
  # The test is the UNION of the two handles being non-empty, not `.start`
  # alone. `cc_stage_is_live` answers "alive" for an empty `.start` sitting
  # beside a valid `.pgid` (measured: 도는중 1), so `[ -s .start ]` on its own
  # would flip every driver-spawned directory to 판정 불가 — the same
  # over-admission failure pointed the other way.
  #
  # The structurally better form is to lift this predicate into `liveness.sh`
  # and have the census and this check call one named thing, which would make
  # the invariant above true by construction instead of by comment. It is not
  # done here because `liveness.sh` is outside this change's declared file set —
  # recorded so the next reader can tell a deliberate omission from a missing one.
  local d="$1" f pid seg
  [ -d "$d" ] && [ -r "$d" ] && [ -x "$d" ] || return 1
  for f in "$d"/*.pid; do
    [ -e "$f" ] || continue
    seg=${f##*/}; seg=${seg%.pid}
    # The watcher is exempt BY NAME, not by shape. It never leaves a sibling
    # handle, which is exactly how the census already declines to count it; if
    # this check demanded one anyway, every watcher-only run directory on disk —
    # and there are roughly ninety of them — would report 판정 불가 forever, and
    # a probe that can never say 아님 stops being a gate at all.
    [ "$seg" = "watch" ] && continue
    [ -r "$f" ] || return 1
    pid=$( { cat "$f" 2>/dev/null || true; } | tr -d '[:space:]')
    case "$pid" in
      ''|*[!0-9]*) return 1 ;;
    esac
    [ -s "$d/$seg.start" ] || [ -s "$d/$seg.pgid" ] || return 1
  done
  return 0
}

probe_config_dir() {
  # probe_config_dir <run-dir> — the lane recorded at run open, or the literal
  # `(미기록)`. Absence is ordinary rather than an error: every run directory
  # laid down before the driver started recording the lane has no such file, and
  # reporting those as undecidable would make the whole history unreadable.
  #
  # A CONTROL CHARACTER IN THE RECORDED VALUE IS NEVER INTERPOLATED. The
  # resolver's file tiers refuse such a value upstream, but tier 1 is the
  # environment and this printer is reached through a path that tier does not
  # cover — and the field is last on the line, so a tab here adds a fifth field
  # and a newline manufactures a record. `(비정규 레인)` is distinct from
  # `(미기록)` on purpose: absence is ordinary, a value that cannot be published
  # is not, and folding them would hide the second inside the first.
  local d="$1" v
  [ -r "$d/config-dir" ] || { printf '(미기록)'; return 0; }
  v=$(sed -n '1p' "$d/config-dir" 2>/dev/null)
  [ -n "$v" ] || { printf '(미기록)'; return 0; }
  case "$v" in
    *[[:cntrl:]]*) printf '(비정규 레인)'; return 0 ;;
  esac
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
    # THE NAME IS ENUMERATED, NOT AUTHORED, so it is not trusted to be a field.
    # A directory name may hold anything but `/` and NUL, and the two characters
    # that matter here are the two that carry structure: a tab adds a field, a
    # newline adds a RECORD. Planting one directory was enough to deliver a
    # syntactically perfect line — correct field count, a status literal, a
    # count — for a run id that does not exist. The line stays, because a
    # directory that cannot be published is itself worth seeing, but the name
    # does not: a fixed literal takes its place and the status is 판정 불가,
    # since nothing was measured about a directory this program refused to name.
    case "$rid" in
      *[[:cntrl:]]*)
        printf '(비정규 이름)\t판정 불가\t?\t(미기록)\n'
        continue ;;
    esac
    if probe_shape_ok "$d"; then
      live=$(cc_live_stages "$d")
      case "${live:-}" in
        ''|*[!0-9]*)
          # 센서스가 수치를 내지 않았다. 0 으로 메우면 그 값이 `아님` 으로
          # 발행되고, 이 파일 헤더가 스왑을 인가하는 답이라고 부른 것이 바로 그
          # 값이다. 측정이 없었으므로 개수는 `?` 다.
          printf '%s\t판정 불가\t?\t%s\n' "$rid" "$(probe_config_dir "$d")" ;;
        *)
          if [ "$live" -gt 0 ]; then
            printf '%s\t도는중\t%s\t%s\n' "$rid" "$live" "$(probe_config_dir "$d")"
          else
            printf '%s\t아님\t%s\t%s\n' "$rid" "$live" "$(probe_config_dir "$d")"
          fi ;;
      esac
    else
      # The count is `?` and not `0`. A number here would be read as a
      # measurement, and there was no measurement.
      printf '%s\t판정 불가\t?\t%s\n' "$rid" "$(probe_config_dir "$d")"
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
