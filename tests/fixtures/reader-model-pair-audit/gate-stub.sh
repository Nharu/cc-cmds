#!/usr/bin/env bash
# Stub gate for scripts/test-reader-model-pair-audit.sh — stands in for the
# branch clones' plugins/cc-cmds/orchestrator/gate.sh behind READER_EXP_GATE.
#
#   snapshot  prints {"H":"stub-h"}
#   act       appends its argv to $STUB_GATE_LOG, then acts by $STUB_GATE_MODE:
#     ok    the first call of a run does nothing (the seat must call again);
#           the second writes the run's first audit report into the clone's
#           docs/design-audit/ — both fences, 리뷰어 수 3, the `reader-model`
#           line of the branch the manifest's 의도 names, the sha256 of the
#           document bytes in the clone — the run's plugin-pin with that
#           branch's commit from $READER_EXP_STATE_ROOT/<exp id>/branches.state,
#           a result line costing $STUB_RUN_COST (default 2), and `done`
#     handoff  appends a handoff row with 사유=$STUB_HANDOFF to the run's
#           ledger in the clone and exits 0 without done; with STUB_HALT set
#           it also leaves halt/A1#1.md under the run directory:
#             rec     options `a`·`b` and a **추천** line
#             norec   options `a`·`b`, no 추천, no 스킬 or 스텝 line
#             policy  a design-audit-unattended `Step 6 합성 질문(CFI-3b)`
#                     record with no 추천
#           Once a halt-answer was taken, the next router-shift acts as `ok`
#           does on its second call
#     wait  exits 5 (an approval for a person)
#     fail  exits 7
#     ended  writes `done` with no report and exits 3, as the gate refuses
#           `대기` on a run that ended while the host slept
#   STUB_ONLY_DOC=<owner-doc> applies $STUB_GATE_MODE to that document's runs
#   only; every other run acts as `ok`.
#
#   act --kind halt-answer  exits $STUB_HALT_ANSWER_RC (default 0); on 0 it
#           appends a 중단 답 row naming the record, the option and the
#           answering party it was given to the clone's ledger

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

hdr() { head -n 8 "$m" | grep -oE "$1=[^;]*" | head -n 1 | sed "s/^$1=//"; }
rid=$(hdr run-id); doc=$(hdr owner-doc)

mode="${STUB_GATE_MODE:-ok}"
if [[ -n "${STUB_ONLY_DOC:-}" && "$doc" != "$STUB_ONLY_DOC" ]]; then mode=ok; fi

case "$mode" in
  wait) exit 5 ;;
  fail) exit 7 ;;
esac

clone=$(grep -m 1 -E '^- `target` ' "$m" | tr '|' '\n' | sed -n 's/^ *메인 워크트리=//p' | sed 's/[[:space:]]*$//')
rd="${XDG_STATE_HOME:?}/cc-cmds/run/$rid"
led="$clone/docs/pipeline-run/$rid.md"
mkdir -p "$rd/log" "$clone/docs/pipeline-run"
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
  printf -- '- `중단 답` | 중단 기록=%s | 선택지=%s | 답한 주체=%s | prev=0\n' "$rec" "$opt" "$by" >> "$led"
  touch "$rd/stub-answered"
  exit 0
fi
if [[ "$mode" == "ended" ]]; then
  echo "2026-10-17T05:00:00Z 종단 — 경계 B4 · 근거 비용이 선언 천장에 닿았습니다" > "$rd/done"
  exit 3
fi
if [[ "$mode" == "handoff" ]]; then
  if [[ -e "$rd/stub-answered" ]]; then
    echo 1 > "$rd/stub-calls"
  else
    printf -- '- `handoff` | 교대=1 | 사유=%s | prev=0\n' "${STUB_HANDOFF:?}" >> "$led"
    if [[ -n "${STUB_HALT:-}" ]]; then
      mkdir -p "$rd/halt"
      {
        printf '<!-- cc-pipeline-halt v1; writer=stub; reader=orchestrator; stage=A1#1; run=%s -->\n' "$rid"
        if [[ "$STUB_HALT" == "policy" ]]; then
          printf '**스킬**: design-audit-unattended\n**스텝**: Step 6 합성 질문(CFI-3b)\n**분류**: gate-unanswerable\n**선택지**:\n'
          printf -- '- `adopt as a requirement` — 합성 요구로 채택하고 재수렴한다\n'
          printf -- '- `record in the unresolved-issues section` — 미해결 이슈 절에 적는다\n'
          printf -- '- `reject` — 기각한다\n'
          printf '**추천**: (없음) — 기록이 정하지 않는다\n'
        else
          printf '**분류**: gate-unanswerable\n**선택지**:\n- `a` — 첫째\n- `b` — 둘째\n'
          if [[ "$STUB_HALT" == "rec" ]]; then
            printf '**추천**: `a` — 기록이 정한다\n**추천 근거**: 인터뷰 기록:첫째로 한다 / 상시 지침:되돌릴 수 있는 쪽\n'
          fi
        fi
        printf '**하네스 오류**: (없음)\n<!-- /cc-pipeline-halt v1 -->\n'
      } > "$rd/halt/A1#1.md"
    fi
    exit 0
  fi
fi
n=$(( $(cat "$rd/stub-calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$rd/stub-calls"
(( n >= 2 )) || exit 0

# The 의도 line: `… (reader-model-pair-audit <exp id> 문서 <n> <branch>)`.
words=$(sed -n 's/.*(reader-model-pair-audit \([^ ]*\) 문서 [0-9]* \([^ )]*\)).*/\1 \2/p' "$m" | head -n 1)
exp="${words%% *}"; br="${words##* }"
model="${br%-*}"
commit=$(awk -F'\t' -v k="${model}_commit" '$1 == k { print $2; exit }' "${READER_EXP_STATE_ROOT:?}/$exp/branches.state")
sha=$(shasum -a 256 "$clone/$doc" | cut -d' ' -f1)
bytes=$(wc -c < "$clone/$doc" | tr -d ' ')
at="2026-10-22T00:00:00Z"
name="$(printf '%s' "${doc%.md}" | tr '/' '-').md"
mkdir -p "$clone/docs/design-audit"
{
  echo "# 설계 감사 — ${doc}"
  echo "<!-- cc-design-audit v1; writer=design-audit; reader=design-audit; owner-doc=${doc}; origin-worktree=${clone}; NOT a design doc; mechanism-local, never staged by a skill -->"
  echo
  echo "## 감사 개시"
  echo "- frozen-at: ${at}"
  echo "- reader-model: ${model}"
  echo
  echo '<!-- cc-design-audit-disclosure v1 begin -->'
  echo "**동결 문서 sha256**: ${sha}"
  echo "**동결 문서 바이트**: ${bytes}"
  echo "**동결 시각**: ${at}"
  echo "**리뷰어 수**: 3"
  echo "**고유 결함 수**: ${STUB_UNIQUE:-4}"
  echo "**미보강 잔여 수**: 0"
  echo "**라우팅 — 기각**: 0"
  echo '<!-- /cc-design-audit-disclosure v1 end -->'
  echo '<!-- cc-design-audit-skeletal v1 begin -->'
  echo "**골격급 수**: 0"
  echo "**합성 요구 골격급 수**: 0"
  echo '<!-- /cc-design-audit-skeletal v1 end -->'
} > "$clone/docs/design-audit/$name"
printf 'version\t9.9.9\ncommit\t%s\n' "$commit" > "$rd/plugin-pin"
printf '{"type":"result","subtype":"success","total_cost_usd":%s}\n' "${STUB_RUN_COST:-2}" > "$rd/log/A1#1.json"
touch "$rd/done"
exit 0
