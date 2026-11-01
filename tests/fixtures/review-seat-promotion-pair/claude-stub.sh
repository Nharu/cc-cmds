#!/usr/bin/env bash
# Model CLI stub for scripts/test-review-seat-promotion-pair.sh.
#
# Every call leaves calls/<seq>.argv (one argument per line), calls/<seq>.env
# (the exported names and the values the closed list fixes) and calls/<seq>.key
# under $STUB_DIR. The call's key is the run directory of its --report-path —
# `<n>-<branch>` or `pilot-opus-1` — followed by `#<k>` for its k-th call.
#
# $STUB_DIR/plan holds `<key>#<k><TAB><action>` lines; a call with no line is
# `ok`. Actions:
#   ok           a valid report, every promoted row on the branch's model
#   noreport     no report
#   badformat    a summary whose P1 count is not the number of P1 items
#   halt         a halt record in the run's halt/ and no report
#   nocost       a valid report, a JSON without total_cost_usd
#   twoseats     a valid report whose code-quality seat is promoted too
# The JSON's total_cost_usd is $STUB_COST (default 1.25).
set -euo pipefail

d="${STUB_DIR:?}"
mkdir -p "$d/calls"
seq=$(( $(find "$d/calls" -name '*.argv' | wc -l) + 1 ))
printf '%s\n' "$@" > "$d/calls/$seq.argv"
{
  compgen -e | LC_ALL=C sort | sed 's/^/name /'
  for v in CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS CC_CMDS_STATUSLINE_AUTOINSTALL XDG_STATE_HOME \
           CLAUDE_CODE_DISABLE_CLAUDE_MDS CLAUDE_CODE_ENABLE_APPEND_SUBAGENT_PROMPT CLAUDE_CONFIG_DIR; do
    printf 'value %s=%s\n' "$v" "${!v:-}"
  done
  printf 'cwd %s\n' "$(pwd -P)"
} > "$d/calls/$seq.env"

prompt="" pd=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    --plugin-dir) pd="$2"; shift 2 ;;
    *) shift ;;
  esac
done
rp=$(printf '%s' "$prompt" | grep -oE -- '--report-path [^ ]+' | cut -d' ' -f2)
rd=$(dirname "$rp")
case "$rd" in
  */pilot/*) base="pilot-$(basename "$rd")" ;;
  *) base=$(basename "$rd") ;;
esac
k=$(( $(grep -c "^$base#" "$d/keys" 2>/dev/null || true) + 1 ))
key="$base#$k"
printf '%s\n' "$key" >> "$d/keys"
printf '%s\n' "$key" > "$d/calls/$seq.key"
action=$(awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' "$d/plan" 2>/dev/null || true)
[ -n "$action" ] || action=ok

model=opus
case "$pd" in */promo-sonnet/*) model=sonnet ;; esac
head=$(git rev-parse HEAD)
cq_src="표"; cq_model="sonnet"
[ "$action" != "twoseats" ] || { cq_src="승격"; cq_model="$model"; }
p1=1
[ "$action" != "badformat" ] || p1=2

if [ "$action" = "halt" ]; then
  mkdir -p "$rd/halt"
  printf -- '- **분류**: gate-unanswerable\n- **질문 문면**: 사전 점검이 멈췄다\n  둘째 줄\n' > "$rd/halt/review.md"
fi
if [ "$action" != "noreport" ] && [ "$action" != "halt" ]; then
  cat > "$rp" <<EOF
# 코드 리뷰 보고서 — 스텁

## 개요

- **리뷰 날짜**: 2026-11-01
- **리뷰 대상**: 브랜치 \`work\`, 로컬 diff
- **리뷰 모드**: 전체
- **리뷰 HEAD**: \`$head\`
- **모델 티어**:
    - logic-shell | 부류=logic | 모델=$model | 출처=승격 | 지표=authz | 재기동=-
    - code-quality | 부류=quality | 모델=$cq_model | 출처=$cq_src | 지표=- | 재기동=-
- **발견 요약**: 🔴 P0 1건 | 🟠 P1 ${p1}건 | 🟡 P2 0건 | 🟢 P3 0건

## 🔴 P0 — 즉시 수정

- **[logic]** \`f.sh:1\` 승격 좌석이 낸 항목 — logic-shell
    - **좌석**: 낸=logic-shell | 동의=-

## 🟠 P1 — 머지 전 수정

- **[차단]** **[code-quality]** \`f.sh:2\` 표 좌석이 낸 항목 — code-quality
    - **좌석**: 낸=code-quality | 동의=-
EOF
fi

if [ "$action" = "nocost" ]; then
  printf '{"type":"result","subtype":"success","is_error":false}\n'
else
  printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":%s}\n' "${STUB_COST:-1.25}"
fi
