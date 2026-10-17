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
#           ledger in the clone and exits 0 without done; with STUB_HALT set
#           it also leaves halt/<stage>#1.md under the run directory, carrying
#           a **추천** line when STUB_HALT=rec. Once a halt-answer was taken,
#           the next router-shift acts as `ok` does on its second call
#     deadline  as `ok`, but the run's done names the wall-clock deadline
#
#   act --kind halt-answer  exits $STUB_HALT_ANSWER_RC (default 0); on 0 it
#           appends a 중단 답 row naming the record to the clone's ledger
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

m=""; akind=""
while (( $# > 0 )); do
  case "$1" in
    --manifest) m="$2"; shift 2 ;;
    --kind) akind="$2"; shift 2 ;;
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
if [[ "$akind" == "halt-answer" ]]; then
  rc="${STUB_HALT_ANSWER_RC:-0}"
  (( rc == 0 )) || exit "$rc"
  rec=""
  for a in "$@"; do case "$a" in 중단\ 기록=*) rec="${a#*=}" ;; esac; done
  printf -- '- `중단 답` | 중단 기록=%s | 답한 주체=좌석 | prev=0\n' "$rec" >> "$clone/docs/pipeline-run/$rid.md"
  touch "$rd/stub-answered"
  exit 0
fi
if [[ "${STUB_GATE_MODE:-ok}" == "handoff" ]]; then
  if [[ -e "$rd/stub-answered" ]]; then
    echo 1 > "$rd/stub-calls"
  else
    mkdir -p "$clone/docs/pipeline-run"
    printf -- '- `handoff` | 교대=1 | 사유=%s | prev=0\n' "${STUB_HANDOFF:?}" >> "$clone/docs/pipeline-run/$rid.md"
    if [[ -n "${STUB_HALT:-}" ]]; then
      st=A1; [[ "$kind" == "intent" ]] && st=D1
      mkdir -p "$rd/halt"
      {
        printf '<!-- cc-pipeline-halt v1; writer=stub; reader=orchestrator; stage=%s#1; run=%s -->\n' "$st" "$rid"
        printf '**분류**: gate-unanswerable\n**선택지**:\n- `a` — 첫째\n- `b` — 둘째\n'
        if [[ "$STUB_HALT" == "rec" ]]; then
          printf '**추천**: `a` — 기록이 정한다\n**추천 근거**: 인터뷰 기록:첫째로 한다 / 상시 지침:되돌릴 수 있는 쪽\n'
        fi
        printf '**하네스 오류**: (없음)\n<!-- /cc-pipeline-halt v1 -->\n'
      } > "$rd/halt/$st#1.md"
    fi
    exit 0
  fi
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
if [[ "${STUB_GATE_MODE:-ok}" == "deadline" ]]; then
  echo "2026-10-17T05:00:00Z 종단 — 경계 마감 · 근거 마감 지남" > "$rd/done"
else
  touch "$rd/done"
fi
exit 0
