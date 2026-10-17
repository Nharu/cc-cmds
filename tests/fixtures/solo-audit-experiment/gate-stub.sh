#!/usr/bin/env bash
# Stub gate for scripts/test-solo-audit-experiment.sh — stands in for
# plugins/cc-cmds/orchestrator/gate.sh behind SOLO_EXP_GATE.
#
#   snapshot  prints {"H":"stub-h"}
#   act       appends its argv to $STUB_GATE_LOG, then acts by $STUB_GATE_MODE:
#     ok    the first call of a run does nothing (the seat must call again);
#           the second writes what the stage would have written and `done`:
#           a design run writes the frozen document (no 상태 line when
#           STUB_NO_FREEZE=1) and log/D1#1.json, carrying $STUB_CONTAM when
#           set; an audit run copies $STUB_SOLO_REPORTS/<report name> and
#           every $STUB_SOLO_REPORTS/<report name without .md>.*.md into the
#           clone's docs/design-audit/
#     handoff  appends a handoff row with 사유=$STUB_HANDOFF to the run's
#           ledger in the clone and exits 0 without done
#     wait  exits 5 (an approval for a person)
#     fail  exits 7
#     failopen  opens the run, writes a result line costing $STUB_RUN_COST,
#           and exits 7
#
# Every run writes plugin-pin and a result line costing $STUB_RUN_COST
# (default 2) under ${XDG_STATE_HOME}/cc-cmds/run/<run id>/.

set -euo pipefail

verb="$1"; shift
case "$verb" in
  snapshot) echo '{"H":"stub-h"}'; exit 0 ;;
  act) ;;
  *) echo "gate-stub: unknown verb $verb" >&2; exit 2 ;;
esac

printf '%s\n' "act $*" >> "${STUB_GATE_LOG:?}"

m=""
while (( $# > 0 )); do
  case "$1" in
    --manifest) m="$2"; shift 2 ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
[[ -f "$m" ]] || { echo "gate-stub: no manifest $m" >&2; exit 2; }

case "${STUB_GATE_MODE:-ok}" in
  wait) exit 5 ;;
  fail) exit 7 ;;
esac

hdr() { head -n 8 "$m" | grep -oE "$1=[^;]*" | head -n 1 | sed "s/^$1=//"; }
rid=$(hdr run-id); kind=$(hdr anchor-kind); doc=$(hdr owner-doc)
clone=$(grep -m 1 -E '^- `target` ' "$m" | tr '|' '\n' | sed -n 's/^ *메인 워크트리=//p' | sed 's/[[:space:]]*$//')
rd="${XDG_STATE_HOME:?}/cc-cmds/run/$rid"
mkdir -p "$rd/log"
if [[ "${STUB_GATE_MODE:-ok}" == "handoff" ]]; then
  mkdir -p "$clone/docs/pipeline-run"
  printf -- '- `handoff` | 교대=1 | 사유=%s | prev=0\n' "${STUB_HANDOFF:?}" >> "$clone/docs/pipeline-run/$rid.md"
  exit 0
fi
if [[ "${STUB_GATE_MODE:-ok}" == "failopen" ]]; then
  printf '{"type":"result","subtype":"success","total_cost_usd":%s}\n' "${STUB_RUN_COST:-2}" > "$rd/log/open.json"
  exit 7
fi
n=$(( $(cat "$rd/stub-calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$rd/stub-calls"
(( n >= 2 )) || exit 0

printf 'version\t9.9.9\ncommit\t0123456789abcdef0123\n' > "$rd/plugin-pin"
if [[ "$kind" == "intent" ]]; then
  mkdir -p "$(dirname "$clone/$doc")"
  {
    echo "# 단독 설계 — $doc"
    [[ "${STUB_NO_FREEZE:-0}" == "1" ]] || echo "**상태**: 동결됨"
    echo "본문"
  } > "$clone/$doc"
  {
    printf '{"type":"assistant","message":"%s"}\n' "${STUB_CONTAM:-클론만 읽었다}"
    printf '{"type":"result","subtype":"success","total_cost_usd":%s}\n' "${STUB_RUN_COST:-2}"
  } > "$rd/log/D1#1.json"
else
  name="$(printf '%s' "${doc%.md}" | tr '/' '-').md"
  mkdir -p "$clone/docs/design-audit"
  for f in "${STUB_SOLO_REPORTS:?}/$name" "$STUB_SOLO_REPORTS/${name%.md}".*.md; do
    if [[ -f "$f" ]]; then cp "$f" "$clone/docs/design-audit/$(basename "$f")"; fi
  done
  printf '{"type":"result","subtype":"success","total_cost_usd":%s}\n' "${STUB_RUN_COST:-2}" > "$rd/log/A1#1.json"
fi
touch "$rd/done"
exit 0
