#!/usr/bin/env bash
# Measure what two gate read paths COST, in processes.
#
# THE PRIMARY METRIC IS A PROCESS COUNT, NOT A DURATION. Wall-clock on this path
# is dominated by interpreter startup and varies with load, so two runs of the
# same code disagree and a change of a few percent is unreadable. The process
# count does not: it is an exact function of the input, with zero variance
# across runs, so a slice's effect can be stated as an integer instead of a
# percentage with an error bar.
#
# TWO AXES, TWO GUARDS, ONE APPARATUS.
#
#   chain    — `gate_chain_verify` over a ledger of N rows. Reports
#              `processes_total`, expected to be 1 at EVERY size: the walk is a
#              single `perl` pass, and that number is the certificate that it
#              stayed one. It says nothing about any other path.
#   progress — `gate_progress_vector` over a ledger holding K DISTINCT SEGMENT
#              IDS. Reports `progress_processes_total`, and what matters about
#              it is its SLOPE: each additional distinct id costs a fixed number
#              of child processes (measured: 14 — four `grep`, four `sed`, four
#              `tail`, two `tr`), because the vector reads two fields per id and
#              each read is a pipeline. This axis guards the ENTITY term of the
#              act path, the one that scales with what the run has recorded. It
#              guards that ONE carrier and proves nothing about other paths.
#
# THE SLOPE AXIS IS ONLY READABLE WITH BOTH OF ITS INPUTS, and this script
# makes them. The vector reads the manifest (`goal`, target rows) and the
# ledger's `segment` rows; a run of this script with no manifest, or with a
# ledger carrying no segment rows, reports one flat point whatever the input —
# a guard that is green by construction. So a missing manifest is a refusal
# (exit 2) rather than a zero, and `--segments K` puts K distinct ids into the
# synthetic ledger so the independent variable actually moves.
#
# HOW. A directory of counting stubs is prepended to PATH. Each stub appends its
# own name to a counter file and then execs the real binary it shadows, so the
# measurement changes the process count by zero and the verdict not at all. The
# real paths are resolved BEFORE the stub directory goes on PATH — otherwise the
# stubs would exec themselves. `perl` is in the list: the chain walk is one
# `perl` process and a list without it read that walk as zero, which is also
# what a dead counter reads.
#
# IT DOES NOT WRITE TO ANY LEDGER, and that is a designed property rather than
# an accident. Measuring this cost the obvious way — calling `gate.sh snapshot`
# in a loop — appends a row to the ledger on every call, because `snapshot` is
# not a read verb: on a run whose settings directory is absent it opens the run
# and records it. A measurement that grows its own input is not a measurement,
# and the ledgers it grows are also the morning report. So this script never
# invokes a gate VERB. It sources gate.sh under the existing source-only seam and
# calls the two functions directly, which only read. The check at the end
# fingerprints the ledger and the manifest before and after and fails loudly if
# that ever stops being true.
#
# Usage:
#   bash scripts/measure-gate-cost.sh [--rows N] [--segments K] [--ledger PATH] [--manifest PATH]
#
#   --rows N       build a synthetic ledger of N `act` rows (default 34)
#   --segments K   append K `segment` rows with distinct ids to it (default 0)
#   --ledger P     measure against an existing ledger instead (no rows or
#                  segments are generated)
#   --manifest P   read this manifest for the progress axis instead of the
#                  generated fixture; a path that does not exist is exit 2
#
# Output is one `key=value` line per tool and per axis plus totals, so a caller
# can diff two runs without parsing prose. Keys of the progress axis are
# prefixed `progress_` so a reader that takes the first match of a bare key
# still finds the chain axis where it always was.
#
# Exit codes:
#   0 — measured
#   2 — could not measure (missing tool, unusable ledger or manifest, or an
#       input moved under us, which would mean this script is no longer
#       read-only)

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
GATE="${GATE_SH:-$repo_root/plugins/cc-cmds/orchestrator/gate.sh}"

ROWS=34
SEGMENTS=0
LEDGER_IN=""
MANIFEST_IN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rows)     ROWS="${2:?--rows needs a value}"; shift 2 ;;
    --segments) SEGMENTS="${2:?--segments needs a value}"; shift 2 ;;
    --ledger)   LEDGER_IN="${2:?--ledger needs a value}"; shift 2 ;;
    --manifest) MANIFEST_IN="${2:?--manifest needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,66p' "$0"; exit 0 ;;
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
  #
  # The segment rows come AFTER the act rows and chain on the same `prev`, so
  # one file serves both axes and the chain axis still sees an intact chain.
  # `id=<id> ` with the trailing space is the shape the vector's field reader
  # keys on; K distinct ids are K distinct entities.
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
    i=1
    while [ "$i" -le "$SEGMENTS" ]; do
      row='- `segment` | id=S'"$i"' | 상태=실행중 | 커밋=- | prev='"$prev"
      printf '%s\n' "$row"
      prev=$(printf '%s' "$row" | shasum -a 256 | cut -d' ' -f1)
      i=$((i + 1))
    done
  } > "$LEDGER_PATH"
fi

# ---------- the manifest the progress axis reads ------------------------------
if [ -n "$MANIFEST_IN" ]; then
  [ -f "$MANIFEST_IN" ] || die2 "manifest not found: $MANIFEST_IN — the progress axis cannot be measured without one, and a missing input is a refusal rather than a flat reading"
  MANIFEST_PATH="$MANIFEST_IN"
else
  # The smallest manifest the vector reads: one target row and the `## 인가`
  # section carrying the goal. Nothing here is validated by `check_manifest`;
  # this script never calls it.
  MANIFEST_PATH="$WORK/manifest.md"
  cat > "$MANIFEST_PATH" <<'MANIFEST'
# 파이프라인 런 매니페스트 — MEASURE
<!-- cc-run-manifest v1; writer=measure-gate-cost; reader=orchestrator; run-id=MEASURE;
     anchor-kind=doc; anchor-key=docs/measure.md; owner-doc=docs/measure.md;
     origin-worktree=/nonexistent; NOT a design doc; synthetic fixture -->

## 대상
- `target` | 별칭=measure | 메인 워크트리=/nonexistent | 공통 git 디렉터리=/nonexistent/.git | 베이스 브랜치=master | 홈=예 | 원격 슬러그=measure/measure | 절단점=PR | 말단 행위 상한=없음

## 인가
**종료 지점**: 계측 픽스처 — 도달하지 않는다
MANIFEST
fi

ledger_before=$(shasum -a 256 < "$LEDGER_PATH" | cut -d' ' -f1)
manifest_before=$(shasum -a 256 < "$MANIFEST_PATH" | cut -d' ' -f1)
rows_seen=$(grep -c '^- `' "$LEDGER_PATH")
segments_seen=$(grep -c '^- `segment` ' "$LEDGER_PATH" || true)

# ---------- counting stubs --------------------------------------------------
STUBDIR="$WORK/stubs"
COUNTF="$WORK/counts"
PROGRESS_COUNTF="$WORK/progress-counts"
mkdir -p "$STUBDIR"
: > "$COUNTF"
: > "$PROGRESS_COUNTF"

# The stub writes to whichever counter file `CC_MEASURE_COUNTF` names, so the
# two axes use one stub directory and separate counters.
TOOLS="shasum sed cut grep perl tail tr sort awk"
for t in $TOOLS; do
  real=$(command -v "$t" 2>/dev/null) || real=""
  [ -n "$real" ] || die2 "cannot resolve the real path of '$t' — the stub would exec itself"
  cat > "$STUBDIR/$t" <<STUB
#!/bin/sh
printf '%s\n' "$t" >> "\$CC_MEASURE_COUNTF"
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
command -v gate_progress_vector >/dev/null 2>&1 \
  || die2 "gate_progress_vector not defined after sourcing $GATE"

LEDGER="$LEDGER_PATH"
RUN_ID="$MEASURE_RUN_ID"
MANIFEST="$MANIFEST_PATH"
# The gate takes its manifest memo once per call before any verb; the vector
# runs under it in production, so it runs under it here too when the memo
# exists. It changes the fixed part of the progress count, not the slope.
manifest_memo=0
if command -v manifest_snapshot_take >/dev/null 2>&1; then manifest_snapshot_take; manifest_memo=1; fi

CC_MEASURE_COUNTF="$COUNTF" PATH="$STUBDIR:$PATH" gate_chain_verify >/dev/null 2>&1
verdict=$?

CC_MEASURE_COUNTF="$PROGRESS_COUNTF" PATH="$STUBDIR:$PATH" gate_progress_vector > "$WORK/vector.txt" 2>/dev/null
progress_rc=$?

ledger_after=$(shasum -a 256 < "$LEDGER_PATH" | cut -d' ' -f1)
manifest_after=$(shasum -a 256 < "$MANIFEST_PATH" | cut -d' ' -f1)
[ "$ledger_before" = "$ledger_after" ] \
  || die2 "the ledger changed during measurement — this script is supposed to be read-only, and something in the path it exercises is writing"
[ "$manifest_before" = "$manifest_after" ] \
  || die2 "the manifest changed during measurement — this script is supposed to be read-only, and something in the path it exercises is writing"

total=0
for t in $TOOLS; do
  n=$(grep -c "^$t\$" "$COUNTF")
  printf '%s=%s\n' "$t" "$n"
  total=$((total + n))
done
printf 'rows=%s\n' "$rows_seen"
printf 'processes_total=%s\n' "$total"
printf 'verdict_rc=%s\n' "$verdict"

ptotal=0
for t in $TOOLS; do
  n=$(grep -c "^$t\$" "$PROGRESS_COUNTF")
  printf 'progress_%s=%s\n' "$t" "$n"
  ptotal=$((ptotal + n))
done
printf 'segments=%s\n' "$segments_seen"
printf 'manifest_memo=%s\n' "$manifest_memo"
printf 'progress_processes_total=%s\n' "$ptotal"
printf 'progress_rc=%s\n' "$progress_rc"
exit 0
