#!/usr/bin/env bash
#
# lint-ledger-row-length.sh — the run ledger's row-length cap has one value.
#
# Concurrent appends to one file splice field values once a line passes a
# threshold, and the failure is invisible to every check anyone would think to
# write: the line count stays correct and only the values inside the row are
# wrong. Two independent measurements put the last clean size at exactly 1024
# bytes, with corruption beginning at 1025. Every gate invocation is its own
# shell, so "one writer" is true of the component and false of the processes —
# which is why the cap is enforced rather than documented.
#
# A cap that lives in two places drifts, and the copy that drifts is the one
# nobody reads. So this lint does not pin a literal: it EXTRACTS the value from
# the gate (the single source of truth, the thing that actually refuses a row)
# and asserts that every consumer document states the same number. That is the
# same shape `lint-cutpoint-vocabulary.sh` uses against the driver's ladder, and
# for the same reason.
#
# Rules:
#   1. [fail] `gate.sh` declares `readonly GATE_ROW_MAX=<n>` exactly once.
#   2. [fail] Every consumer document states that same `<n>` in its row-length
#      section. A document absent from disk is skipped, not failed — the same
#      incremental-rollout posture the sibling lints take.
#   3. [fail] No row in any run ledger under the ledger root exceeds `<n>`
#      bytes including its newline. A ledger that does not exist is not a
#      failure; a ledger with an over-cap row is.
#
# Usage: bash scripts/lint-ledger-row-length.sh
#
# Env override:
#   ORCH_ROOT    orchestrator directory (default plugins/cc-cmds/orchestrator)
#   SKILLS_ROOT  skills directory (default plugins/cc-cmds/skills)
#   LEDGER_ROOT  directory scanned for run ledgers (default docs/pipeline-run)
#
# Exit codes:
#   0  pass, or a silent skip because the mechanism is not present
#   1  at least one violation
#   2  invalid invocation — the gate is present but declares no cap
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
orch_root="${ORCH_ROOT:-$repo_root/plugins/cc-cmds/orchestrator}"
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"
ledger_root="${LEDGER_ROOT:-$repo_root/docs/pipeline-run}"

GATE="$orch_root/gate.sh"

if [[ ! -f "$GATE" ]]; then
  echo "SKIP: gate.sh not found under $orch_root — row-length mechanism not present"
  exit 0
fi

fail=0

# --- Rule 1: extract the SOT ------------------------------------------------
cap=$(sed -n 's/^readonly GATE_ROW_MAX=\([0-9][0-9]*\)$/\1/p' "$GATE")
count=$(printf '%s\n' "$cap" | grep -c . || true)

if [[ -z "$cap" ]]; then
  echo "FAIL: gate.sh — readonly GATE_ROW_MAX=<n> 를 찾지 못했다 (상한 SOT 부재)" >&2
  exit 2
fi
if [[ "$count" != "1" ]]; then
  echo "FAIL: gate.sh — GATE_ROW_MAX 선언이 ${count}개다 ; 정확히 하나여야 SOT 가 성립한다" >&2
  exit 2
fi
echo "OK:   gate.sh — 원장 행 상한 SOT = ${cap} 바이트"

# --- Rule 2: consumers state the same number --------------------------------
CONSUMERS="_common/pipeline-sidecar.md"

for rel in $CONSUMERS; do
  doc="$skills_root/$rel"
  if [[ ! -f "$doc" ]]; then
    echo "SKIP: $rel — not present"
    continue
  fi
  if grep -qE "(^|[^0-9])${cap}( |바이트)" "$doc"; then
    echo "OK:   $rel — 상한 ${cap} 을 진술한다"
  else
    echo "FAIL: $doc — 게이트가 강제하는 상한 ${cap} 이 이 문서에 없다 ; 계약과 기제가 갈라졌다" >&2
    fail=1
  fi
done

# --- Rule 3: no ledger row exceeds the cap ----------------------------------
if [[ ! -d "$ledger_root" ]]; then
  echo "SKIP: $ledger_root — 원장 없음"
else
  found=0
  while IFS= read -r ledger; do
    [[ -n "$ledger" ]] || continue
    found=1
    line_no=0
    while IFS= read -r row; do
      line_no=$((line_no + 1))
      case "$row" in
        '- `'*) ;;
        *) continue ;;
      esac
      # +1 for the newline the row occupies on disk.
      n=$(( $(printf '%s' "$row" | wc -c | tr -d ' ') + 1 ))
      if [[ "$n" -gt "$cap" ]]; then
        echo "FAIL: $ledger:$line_no — 행이 ${n} 바이트로 상한 ${cap} 을 넘는다 ; 긴 값은 사이드카로 빼야 한다" >&2
        fail=1
      fi
    done < "$ledger"
  done < <(find "$ledger_root" -maxdepth 1 -name "*.md" | sort)
  [[ "$found" = "1" ]] || echo "SKIP: $ledger_root — 스캔할 원장 파일이 없음"
fi

if [[ "$fail" != "0" ]]; then
  echo "lint-ledger-row-length: violations found" >&2
  exit 1
fi
exit 0
