#!/usr/bin/env bash
# lint-sidecar-field-table: self-skip
# Lint the ledger contract's per-series field table against what the gate
# actually writes.
#
# The contract's field table is the only place a ledger reader can learn which
# fields a series carries, and until now nothing compared it against the
# writer: a field added at a `gate_append` call site was invisible to the table
# and a field listed there could be written by nothing. Both directions are
# the same defect — a value recorded and compared against nothing — and this
# lint is what makes either one a failing build.
#
# Rule, per series named at a `gate_append '<계열>' …` call site in gate.sh:
#   the union of literal `<키>=` names across all its call sites must be a
#   SUBSET of the table row's field list                                [fail]
#   and, when every call site of that series is fully literal (no `"$@"`
#   pass-through), the table row must be a subset of the union too, so the
#   two are EQUAL                                                       [fail]
#
# `교대` and `prev` are excluded: `gate_append` adds them to every row itself,
# and the table documents them once in prose rather than per row. THE NUMBER
# OF SERIES IS NOT COMPARED — the table's count is a heading the contract owns,
# and a series without a call site (`generation`) is documented as deliberately
# unwritten.
#
# A call site is read across its continuation lines (a trailing backslash joins
# the next line), and a series passed through a variable rather than a literal
# is not attributed to anything.
#
# Usage:
#   bash scripts/lint-sidecar-field-table.sh
#
# Env overrides (fixture runner):
#   ORCH_ROOT=<dir>    # directory holding gate.sh
#   SKILLS_ROOT=<dir>  # directory holding _common/pipeline-sidecar.md
#
# Posture: if gate.sh or the contract is absent the check is a silent skip.
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
GATE_SH="$orch_root/gate.sh"
CONTRACT="$skills_root/_common/pipeline-sidecar.md"

if [[ ! -f "$GATE_SH" ]]; then
  echo "SKIP: gate.sh not found under $orch_root — 호출부 부재"
  exit 0
fi
if [[ ! -f "$CONTRACT" ]]; then
  echo "SKIP: _common/pipeline-sidecar.md not found under $skills_root — 필드표 부재"
  exit 0
fi

fail=0

# --- the call sites, one logical line each ---------------------------------
# Continuation lines are joined so a multi-line `gate_append` reads as one.
joined=$(awk '
  { line = $0
    if (cont) { buf = buf " " line } else { buf = line }
    if (line ~ /\\$/) { sub(/\\$/, "", buf); cont = 1; next }
    cont = 0; print buf; buf = "" }
  END { if (cont) print buf }' "$GATE_SH")

# series_of <logical line> — the literal series a call names, or nothing.
series_of() {
  # `printf '%s\n'`, not `'%s'`: BSD sed prints a last line without a newline
  # exactly as it read it, and the series names then ran together.
  printf '%s\n' "$1" | sed -n "s/.*gate_append '\([^']*\)'.*/\1/p"
}

# keys_of <logical line> — the literal keys of every `"<키>=…"` argument.
# The line is split on quotes so each quoted argument stands alone; a piece is
# a field when it carries `=` and the part before it is a plain name — no
# expansion, no shell syntax, no leading dash. The series literal itself is
# removed first so `gate_append '승인'` does not read as a key.
keys_of() {
  printf '%s\n' "$1" | sed "s/gate_append '[^']*'//" \
    | tr '"' '\n' | tr "'" '\n' \
    | awk -F'=' 'NF >= 2 {
        k = $1
        sub(/^[[:space:]]+/, "", k); sub(/[[:space:]]+$/, "", k)
        if (k == "") next
        if (k ~ /[$(){}\[\];<>!*\/\\%#|&]/) next
        if (k ~ /^-/) next
        if (length(k) > 40) next
        print k }'
}

series_list=$(printf '%s\n' "$joined" | grep -F "gate_append '" | while IFS= read -r l; do series_of "$l"; done | LC_ALL=C sort -u)

if [[ -z "$series_list" ]]; then
  echo "FAIL: gate.sh 에서 gate_append '<계열>' 호출부를 하나도 찾지 못했다" >&2
  exit 1
fi

# doc_cells_of <series> — the cells of the table row for that series, one per
# line: split on the table's ` · ` separator.
doc_cells_of() {
  local row
  # `sed -n '1p'` and not `head -1`: an early-exiting reader on the right of a
  # pipe kills the writer under `pipefail`.
  row=$(grep -F "| \`$1\` |" "$CONTRACT" | sed -n '1p' || true)
  [[ -n "$row" ]] || return 1
  row=${row#*"| \`$1\` |"}
  row=${row%|*}
  printf '%s\n' "$row" | sed 's/ · /\
/g'
}

# doc_fields_of <series> — the field names: each cell's FIRST backtick token,
# whatever note follows it.
# `교대` and `prev` are dropped on this side too: `gate_append` puts them on
# every row itself, and a row (`handoff`) that documents its own `교대` is
# documenting the seat field, not a field its call site must spell.
doc_fields_of() {
  doc_cells_of "$1" | awk -F'`' 'NF >= 3 { print $2 }' | grep -vxF '교대' | grep -vxF 'prev' || true
}

# doc_pending_of <series> — the fields whose note says `writer pending`: the
# contract lists them ahead of the call site that will write them, and says so
# in the cell, so the reverse direction does not report them. The marker is
# in the table where a reader sees it, never in this script.
doc_pending_of() {
  doc_cells_of "$1" | grep -F 'writer pending' | awk -F'`' 'NF >= 3 { print $2 }' || true
}

nser=0; nkeys=0
while IFS= read -r s; do
  [[ -n "$s" ]] || continue
  nser=$((nser + 1))
  passthrough=0
  call_keys=""
  while IFS= read -r l; do
    case "$l" in *"gate_append '$s'"*) ;; *) continue ;; esac
    case "$l" in *'"$@"'*) passthrough=1 ;; esac
    call_keys=$(printf '%s\n%s\n' "$call_keys" "$(keys_of "$l")")
  done <<EOF
$joined
EOF
  call_keys=$(printf '%s\n' "$call_keys" | grep -v '^$' | grep -vxF '교대' | grep -vxF 'prev' | LC_ALL=C sort -u || true)
  doc_keys=$(doc_fields_of "$s" || true)
  if [[ -z "$doc_keys" ]]; then
    echo "FAIL: pipeline-sidecar.md 의 필드표에 계열 '$s' 의 행이 없다 — 게이트는 그 계열을 쓴다" >&2
    fail=1
    continue
  fi
  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    nkeys=$((nkeys + 1))
    hit=$(printf '%s\n' "$doc_keys" | grep -xF -- "$k" || true)
    if [[ -z "$hit" ]]; then
      echo "FAIL: 계열 '$s' 의 호출부가 필드 '$k' 를 쓰는데 pipeline-sidecar.md 의 필드표 행에는 없다" >&2
      fail=1
    fi
  done <<EOF
$call_keys
EOF
  if [[ "$passthrough" = "0" ]]; then
    pending_keys=$(doc_pending_of "$s" || true)
    while IFS= read -r k; do
      [[ -n "$k" ]] || continue
      hit=$(printf '%s\n' "$call_keys" | grep -xF -- "$k" || true)
      if [[ -z "$hit" ]]; then
        pend=$(printf '%s\n' "$pending_keys" | grep -xF -- "$k" || true)
        if [[ -n "$pend" ]]; then
          echo "NOTE: 계열 '$s' 의 필드 '$k' 는 필드표에 writer pending 으로 적혀 있고 아직 호출부가 없다"
          continue
        fi
        echo "FAIL: pipeline-sidecar.md 의 계열 '$s' 행이 필드 '$k' 를 싣는데 어느 호출부도 쓰지 않는다 (이 계열의 호출부는 전부 리터럴이다)" >&2
        fail=1
      fi
    done <<EOF
$doc_keys
EOF
  fi
done <<EOF
$series_list
EOF

if [[ "$fail" != "0" ]]; then
  echo "lint-sidecar-field-table: violations found" >&2
  exit 1
fi

echo "OK:   sidecar field table — 계열 ${nser}개, 호출부 필드 ${nkeys}개를 필드표와 대조"
exit 0
