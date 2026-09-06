#!/usr/bin/env bash
# Measure what a chain verification COSTS, in processes.
#
# THE PRIMARY METRIC IS A PROCESS COUNT, NOT A DURATION. Wall-clock on this path
# is dominated by interpreter startup and varies with load, so two runs of the
# same code disagree and a change of a few percent is unreadable. The process
# count does not: for the row-at-a-time loop it is exactly 3n+2 for n rows, with
# zero variance across runs, so a slice's effect can be stated as an integer
# instead of a percentage with an error bar.
#
# HOW. A directory of counting stubs is prepended to PATH. Each stub appends its
# own name to a counter file and then execs the real binary it shadows, so the
# measurement changes the process count by zero and the verdict not at all. The
# real paths are resolved BEFORE the stub directory goes on PATH — otherwise the
# stubs would exec themselves.
#
# IT DOES NOT WRITE TO ANY LEDGER, and that is a designed property rather than
# an accident. Measuring this cost the obvious way — calling `gate.sh snapshot`
# in a loop — appends a row to the ledger on every call, because `snapshot` is
# not a read verb: on a run whose settings directory is absent it opens the run
# and records it. A measurement that grows its own input is not a measurement,
# and the ledgers it grows are also the morning report. So this script never
# invokes a gate VERB. It sources gate.sh under the existing source-only seam and
# calls `gate_chain_verify` directly, which only reads. The check at the end
# fingerprints the ledger before and after and fails loudly if that ever stops
# being true.
#
# Usage:
#   bash scripts/measure-gate-cost.sh [--rows N] [--ledger PATH]
#
#   --rows N     build a synthetic ledger of N rows (default 34)
#   --ledger P   measure against an existing ledger instead
#
# Output is one `key=value` line per tool plus a total, so a caller can diff two
# runs without parsing prose.
#
# Exit codes:
#   0 — measured
#   2 — could not measure (missing tool, unusable ledger, or the ledger moved
#       under us, which would mean this script is no longer read-only)

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
GATE="${GATE_SH:-$repo_root/plugins/cc-cmds/orchestrator/gate.sh}"

ROWS=34
LEDGER_IN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rows)   ROWS="${2:?--rows needs a value}"; shift 2 ;;
    --ledger) LEDGER_IN="${2:?--ledger needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) printf 'measure-gate-cost: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

die2() { printf 'measure-gate-cost: %s\n' "$1" >&2; exit 2; }

[ -f "$GATE" ] || die2 "gate.sh not found: $GATE"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-measure-gate.XXXXXX") || die2 "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# ---------- the ledger under measurement ------------------------------------
MEASURE_RUN_ID=MEASURE
if [ -n "$LEDGER_IN" ]; then
  [ -f "$LEDGER_IN" ] || die2 "ledger not found: $LEDGER_IN"
  LEDGER_PATH="$LEDGER_IN"
else
  # Built with shasum deliberately: this ledger is an INPUT SIZE, not an
  # expectation, so it has to chain the way the verifier expects or the walk
  # stops at row 1 and measures nothing.
  LEDGER_PATH="$WORK/ledger.md"
  hdr="## 실행 $MEASURE_RUN_ID"
  prev=$(printf '%s' "$hdr" | shasum -a 256 | cut -d' ' -f1)
  {
    printf '%s\n' "$hdr"
    i=1
    while [ "$i" -le "$ROWS" ]; do
      row='- `act` | 순번='"$i"' | prev='"$prev"
      printf '%s\n' "$row"
      prev=$(printf '%s' "$row" | shasum -a 256 | cut -d' ' -f1)
      i=$((i + 1))
    done
  } > "$LEDGER_PATH"
fi

before=$(shasum -a 256 < "$LEDGER_PATH" | cut -d' ' -f1)
rows_seen=$(grep -c '^- `' "$LEDGER_PATH")

# ---------- counting stubs --------------------------------------------------
STUBDIR="$WORK/stubs"
COUNTF="$WORK/counts"
mkdir -p "$STUBDIR"
: > "$COUNTF"

for t in shasum sed cut grep; do
  real=$(command -v "$t" 2>/dev/null) || real=""
  [ -n "$real" ] || die2 "cannot resolve the real path of '$t' — the stub would exec itself"
  cat > "$STUBDIR/$t" <<STUB
#!/bin/sh
printf '%s\n' "$t" >> "$COUNTF"
exec "$real" "\$@"
STUB
  chmod +x "$STUBDIR/$t"
done

# ---------- measure ---------------------------------------------------------
export CC_GATE_SOURCE_ONLY=1
# shellcheck disable=SC1090
. "$GATE" || die2 "could not source $GATE"
set +e

command -v gate_chain_verify >/dev/null 2>&1 \
  || die2 "gate_chain_verify not defined after sourcing $GATE"

LEDGER="$LEDGER_PATH"
RUN_ID="$MEASURE_RUN_ID"

PATH="$STUBDIR:$PATH" gate_chain_verify >/dev/null 2>&1
verdict=$?

after=$(shasum -a 256 < "$LEDGER_PATH" | cut -d' ' -f1)
[ "$before" = "$after" ] \
  || die2 "the ledger changed during measurement — this script is supposed to be read-only, and something in the path it exercises is writing"

total=0
for t in shasum sed cut grep; do
  n=$(grep -c "^$t\$" "$COUNTF")
  printf '%s=%s\n' "$t" "$n"
  total=$((total + n))
done
printf 'rows=%s\n' "$rows_seen"
printf 'processes_total=%s\n' "$total"
printf 'verdict_rc=%s\n' "$verdict"
exit 0
