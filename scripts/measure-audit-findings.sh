#!/usr/bin/env bash
# Extract the audit-finding baseline the team-size rollback observation needs.
#
# This is NOT a gate. Nothing here passes or fails; the output is the input to
# a human comparison — the count of unique defects an audit found per design
# document, before and after the design team's default size changed. `make
# test` runs this script against synthetic fixtures only, never against the
# real report corpus, which lives under `docs/` and is not tracked.
#
# Two outputs, and the second exists because of what the first cannot see:
#
#   fenced          one row per report that carries the versioned disclosure
#                   fence. The unique-defect count is read ONLY from inside
#                   the fence — `<!-- cc-design-audit-disclosure v1 begin -->`
#                   to `<!-- /cc-design-audit-disclosure v1 end -->`. There
#                   is NO prose fallback, deliberately: a report without the
#                   fence states its numbers in reconciliation prose, and a
#                   fallback that read that prose returned 101 for one report
#                   — a ledger census line, not a defect count. A wrong number
#                   that looks like a measurement is worse than a gap.
#   missing-fence   the producer-side check. A report that carries the audit
#                   header and a `## 조정 패스` heading reached the step that
#                   is obliged to write the fence, and did not. Without this
#                   list the extractor is exactly the defect class it is meant
#                   to measure — a field that is recorded and never compared —
#                   because half the corpus would be silently absent from n.
#
# `동결 문서 바이트` is read from the same fence when present. A smaller team
# writes a shorter document, and fewer findings can mean "a better design" or
# "less surface to find"; the per-kilobyte column is what separates the two,
# and it is `-` for reports written before that slot existed.
#
# Population: every `*.md` directly under the reports directory whose basename
# does not contain `reader-` (per-reader witness files are inputs to a report,
# not reports). The selector is printed in the header so the number can be
# re-derived, and the median is the median of the fenced values only — the
# hand-counted baseline that mixed fenced and prose values is a different
# population and is not reproduced here.
#
# Usage:
#   scripts/measure-audit-findings.sh [--reports <dir>]
#     --reports defaults to <repo>/docs/design-audit
#
# Exit codes:
#   0 — outputs emitted (possibly with n=0; headers are always printed)
#   2 — usage error / reports directory not found
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.
# Non-ASCII literals follow a `${var}` brace, never a bare `$var`.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
reports_dir="$repo_root/docs/design-audit"

while (( $# > 0 )); do
  case "$1" in
    --reports) reports_dir="${2:-}"; shift 2 ;;
    -h|--help)
      grep -E '^# ' "$0" | cut -c3-
      exit 0
      ;;
    *)
      echo "measure-audit-findings: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$reports_dir" || ! -d "$reports_dir" ]]; then
  echo "measure-audit-findings: reports directory not found: ${reports_dir:-<empty>}" >&2
  exit 2
fi

FENCE_BEGIN='<!-- cc-design-audit-disclosure v1 begin -->'
FENCE_END='<!-- /cc-design-audit-disclosure v1 end -->'
HEADER_TOKEN='<!-- cc-design-audit v1'
PASS_HEADING='## 조정 패스'

# ---------- population ---------------------------------------------------------

REPORTS=()
while IFS= read -r f; do
  case "$(basename "$f")" in
    *reader-*) continue ;;
  esac
  REPORTS+=("$f")
done < <(find "$reports_dir" -maxdepth 1 -name '*.md' | sort)

# ---------- per-report extraction ---------------------------------------------

# fence_values <file> — prints "<unique>\t<bytes>" read from inside the fence,
# each `-` when absent. Only lines strictly between the fences are consulted;
# a count line outside them is prose and is never read.
fence_values() {
  LC_ALL=C awk -v b="$FENCE_BEGIN" -v e="$FENCE_END" '
    index($0, b) == 1 { inf = 1; next }
    index($0, e) == 1 { inf = 0; next }
    inf && u == "" && index($0, "**고유 결함 수**: ") == 1 {
      v = substr($0, length("**고유 결함 수**: ") + 1)
      if (v ~ /^[0-9]+$/) u = v
    }
    inf && by == "" && index($0, "**동결 문서 바이트**: ") == 1 {
      v = substr($0, length("**동결 문서 바이트**: ") + 1)
      if (v ~ /^[0-9]+$/) by = v
    }
    END { printf "%s\t%s\n", (u == "" ? "-" : u), (by == "" ? "-" : by) }
  ' "$1"
}

# has_fence <file>
has_fence() {
  local n
  n=$(grep -Fc -- "$FENCE_BEGIN" "$1" || true)
  [[ "${n:-0}" != "0" ]]
}

# has_audit_header <file> — the machine header within the first 5 lines.
has_audit_header() {
  local n
  n=$(head -n 5 "$1" | grep -Fc -- "$HEADER_TOKEN" || true)
  [[ "${n:-0}" != "0" ]]
}

# has_pass_heading <file> — a heading line starting with `## 조정 패스`.
has_pass_heading() {
  local n
  n=$(grep -c -- "^${PASS_HEADING}" "$1" || true)
  [[ "${n:-0}" != "0" ]]
}

fenced_rows=""
fenced_values=""
fenced_n=0
missing=""
missing_n=0

for f in ${REPORTS[@]+"${REPORTS[@]}"}; do
  name=$(basename "$f")
  if has_fence "$f"; then
    vals=$(fence_values "$f")
    u=${vals%%	*}
    by=${vals##*	}
    if [[ "$u" == "-" ]]; then
      echo "measure-audit-findings: $name — fence present but no unique-defect line inside it; skipped" >&2
      continue
    fi
    if [[ "$by" == "-" ]]; then
      per_kb="-"
    else
      per_kb=$(awk -v u="$u" -v b="$by" 'BEGIN { printf "%.2f", u * 1000 / b }')
    fi
    fenced_rows="${fenced_rows}${name}	${u}	${by}	${per_kb}
"
    fenced_values="${fenced_values}${u}
"
    fenced_n=$((fenced_n + 1))
  elif has_audit_header "$f" && has_pass_heading "$f"; then
    missing="${missing}${name}
"
    missing_n=$((missing_n + 1))
  fi
done

# ---------- statistics over the fenced values ---------------------------------

median="-"
range="-"
if (( fenced_n > 0 )); then
  sorted=$(printf '%s' "$fenced_values" | sort -n)
  median=$(printf '%s\n' "$sorted" | awk '
    { v[NR] = $1 }
    END {
      if (NR % 2 == 1) m = v[(NR + 1) / 2]
      else m = (v[NR / 2] + v[NR / 2 + 1]) / 2
      printf "%.1f", m
    }')
  lo=$(printf '%s\n' "$sorted" | head -n 1)
  hi=$(printf '%s\n' "$sorted" | tail -n 1)
  range="${lo}~${hi}"
fi

# ---------- output --------------------------------------------------------------

echo "# population: *.md directly under the reports directory, basename without 'reader-'; values read only between the v1 disclosure fences (no prose fallback); defects_per_kb = unique_defects / (frozen_bytes / 1000)"
echo "# fenced  n=${fenced_n}  median=${median}  range=${range}"
printf 'doc\tunique_defects\tfrozen_bytes\tdefects_per_kb\n'
printf '%s' "$fenced_rows"
echo "# missing-fence  n=${missing_n}"
printf '%s' "$missing"

exit 0
