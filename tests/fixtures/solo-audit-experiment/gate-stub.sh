#!/usr/bin/env bash
# Stub gate for scripts/test-solo-audit-experiment.sh — stands in for
# plugins/cc-cmds/orchestrator/gate.sh behind SOLO_EXP_GATE.
#
#   snapshot  prints {"H":"stub-h"}
#   act       appends its argv to $STUB_GATE_LOG and, with STUB_ENV_LOG set,
#             the names of its environment variables to that file, then acts
#             by $STUB_GATE_MODE:
#     ok    the first call of a run does nothing (the seat must call again);
#           the second writes what the stage would have written and `done`:
#           a design run writes the frozen document (no 상태 line when
#           STUB_NO_FREEZE=1) and log/D1#1.json, carrying $STUB_CONTAM when
#           set; an audit run copies $STUB_SOLO_REPORTS/<report name> and
#           every $STUB_SOLO_REPORTS/<report name without .md>.*.md into the
#           clone's docs/design-audit/
#     handoff  appends a handoff row with 사유=$STUB_HANDOFF to the run's
#           ledger in the clone and exits 0 without done; with STUB_HALT set
#           it also leaves halt/<stage>#1.md under the run directory:
#             rec     options `a`·`b` and a **추천** line
#             norec   options `a`·`b`, no 추천, no 스킬 or 스텝 line
#             policy  an audit run's design-audit-unattended
#                     `Step 6 합성 질문(CFI-3b)` record with no 추천; a design
#                     run acts as `ok`
#             ladder  a design run's design-solo-unattended
#                     `Step 7U / ladder-unsettled` record with no 추천; an
#                     audit run acts as `ok`
#           with STUB_DEADLINE_PARK=1 and no STUB_HALT it appends a `blocked`
#           row whose 근거 carries `마감 초과 — ready_at`. Once a halt-answer
#           was taken, the next router-shift acts as `ok` does on its second
#           call
#     deadline  as `ok`, but the run's done names the wall-clock deadline
#     wait  exits 5 (an approval for a person)
#     fail  exits 7
#     ended  writes a done that names the wall-clock deadline and exits 3, as
#           the gate refuses `대기` on a run that ended while the host slept
#     failopen  opens the run, writes a result line costing $STUB_RUN_COST,
#           and exits 7
#   STUB_ONLY_DOC=<owner-doc> applies $STUB_GATE_MODE to that document's runs
#   only; every other run acts as `ok`.
#
#   act --kind halt-answer  exits $STUB_HALT_ANSWER_RC (default 0); on 0 it
#           appends a 중단 답 row naming the record, the option and the
#           answering party it was given to the clone's ledger
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
# The names (never the values) of the variables a stage process would
# inherit, so the test can see that no SOLO_EXP_* variable reaches one.
[[ -z "${STUB_ENV_LOG:-}" ]] || compgen -e >> "$STUB_ENV_LOG"

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

hdr() { head -n 8 "$m" | grep -oE "$1=[^;]*" | head -n 1 | sed "s/^$1=//"; }
rid=$(hdr run-id); kind=$(hdr anchor-kind); doc=$(hdr owner-doc)

mode="${STUB_GATE_MODE:-ok}"
if [[ -n "${STUB_ONLY_DOC:-}" && "$doc" != "$STUB_ONLY_DOC" ]]; then mode=ok; fi
if [[ "$mode" == "handoff" ]]; then
  case "${STUB_HALT:-}:$kind" in
    policy:intent|ladder:doc) mode=ok ;;
  esac
fi

case "$mode" in
  wait) exit 5 ;;
  fail) exit 7 ;;
esac

clone=$(grep -m 1 -E '^- `target` ' "$m" | tr '|' '\n' | sed -n 's/^ *메인 워크트리=//p' | sed 's/[[:space:]]*$//')
rd="${XDG_STATE_HOME:?}/cc-cmds/run/$rid"
mkdir -p "$rd/log"
if [[ "$akind" == "halt-answer" ]]; then
  rc="${STUB_HALT_ANSWER_RC:-0}"
  (( rc == 0 )) || exit "$rc"
  rec=""; by=""; opt="-"
  for a in "$@"; do
    case "$a" in
      중단\ 기록=*) rec="${a#*=}" ;;
      답한\ 주체=*) by="${a#*=}" ;;
      선택지=*) opt="${a#*=}" ;;
    esac
  done
  printf -- '- `중단 답` | 중단 기록=%s | 선택지=%s | 답한 주체=%s | prev=0\n' "$rec" "$opt" "$by" >> "$clone/docs/pipeline-run/$rid.md"
  touch "$rd/stub-answered"
  exit 0
fi
if [[ "$mode" == "handoff" ]]; then
  if [[ -e "$rd/stub-answered" ]]; then
    echo 1 > "$rd/stub-calls"
  else
    mkdir -p "$clone/docs/pipeline-run"
    printf -- '- `handoff` | 교대=1 | 사유=%s | prev=0\n' "${STUB_HANDOFF:?}" >> "$clone/docs/pipeline-run/$rid.md"
    st=A1; [[ "$kind" == "intent" ]] && st=D1
    if [[ -n "${STUB_HALT:-}" ]]; then
      mkdir -p "$rd/halt"
      {
        printf '<!-- cc-pipeline-halt v1; writer=stub; reader=orchestrator; stage=%s#1; run=%s -->\n' "$st" "$rid"
        case "$STUB_HALT" in
          policy)
            printf '**스킬**: design-audit-unattended\n**스텝**: Step 6 합성 질문(CFI-3b)\n**분류**: gate-unanswerable\n**선택지**:\n'
            printf -- '- `adopt as a requirement` — 합성 요구로 채택하고 재수렴한다\n'
            printf -- '- `record in the unresolved-issues section` — 미해결 이슈 절에 적는다\n'
            printf -- '- `reject` — 기각한다\n'
            printf '**추천**: (없음) — 기록이 정하지 않는다\n'
            ;;
          ladder)
            printf '**스킬**: design-solo-unattended\n**스텝**: Step 7U / ladder-unsettled\n**분류**: gate-unanswerable\n**선택지**:\n'
            printf -- '- `잔여로 두고 동결` — 잔여 항목으로 두고 문서를 동결한다\n'
            printf -- '- `골격 재검토` — 동결 뒤 재수렴한다\n'
            printf '**추천**: (없음) — 기록이 정하지 않는다\n'
            ;;
          *)
            printf '**분류**: gate-unanswerable\n**선택지**:\n- `a` — 첫째\n- `b` — 둘째\n'
            if [[ "$STUB_HALT" == "rec" ]]; then
              printf '**추천**: `a` — 기록이 정한다\n**추천 근거**: 인터뷰 기록:첫째로 한다 / 상시 지침:되돌릴 수 있는 쪽\n'
            fi
            ;;
        esac
        printf '**하네스 오류**: (없음)\n<!-- /cc-pipeline-halt v1 -->\n'
      } > "$rd/halt/$st#1.md"
    elif [[ "${STUB_DEADLINE_PARK:-0}" == "1" ]]; then
      printf -- '- `blocked` | 교대=1 | 대상=exp | 근거=계보=B:%s#2 마감 초과 — ready_at 2026-10-19T09:00:00Z (stub) | prev=0\n' "$st" >> "$clone/docs/pipeline-run/$rid.md"
    fi
    exit 0
  fi
fi
if [[ "$mode" == "ended" ]]; then
  echo "2026-10-17T05:00:00Z 종단 — 경계 마감 · 근거 마감 지남" > "$rd/done"
  exit 3
fi
if [[ "$mode" == "failopen" ]]; then
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
if [[ "$mode" == "deadline" ]]; then
  echo "2026-10-17T05:00:00Z 종단 — 경계 마감 · 근거 마감 지남" > "$rd/done"
else
  touch "$rd/done"
fi
exit 0
