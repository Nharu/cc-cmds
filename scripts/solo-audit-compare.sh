#!/usr/bin/env bash
# Measure, compare and judge the solo-design audit experiment.
#
# Deterministic: no model, no network. It reads the pair records and the
# classification results an experiment directory holds and writes the verdict
# report. Keeping the verdict apart from the billed stages is what lets the
# rule be pinned by synthetic fixtures alone — a threshold changed after the
# experiment breaks a golden file instead of passing in silence.
#
# Input (an experiment directory written by scripts/solo-audit-experiment.sh):
#
#   pairs/<n>/pair.tsv      key<TAB>value lines, n = 1..PAIRS_REQUIRED:
#                           status (유효|무효), invalid_reason, team_label,
#                           solo_label, and for each side (team_|solo_):
#                           unique, bytes, unremedied, reviewers, plugin
#   classify/<label>.json   {"defects":[{id,routing,class,reason}]} for one
#                           report; the label hides the pair and the side
#   classify/review.tsv     the ambiguous defects, with a `사람 판정` column a
#                           person fills with 골격급 or 비골격
#
# Rule (fixed before the experiment ran):
#
#   skeletal(report) = defects classed 골격급 + ambiguous defects a person
#                      judged 골격급
#   veto             = Σ solo skeletal − Σ team skeletal ≥ VETO_SUM_DIFF
#                      AND pairs with solo > team ≥ VETO_PAIR_MAJORITY
#                      → `≠` at once
#   otherwise        = median over pairs of S/T (unique defects per KB) and of
#                      (S+1)/(T+1) (unremedied residuals); both ≤ RATIO_MAX → `≈`,
#                      either above → `≠`
#   `판정 불가`       = valid pairs ≠ PAIRS_REQUIRED, or a person's judgment is
#                      still blank or outside the two values
#
# Output: report.md in the experiment directory (or stdout with `--out -`).
# Its last line is the machine-read `# verdict: <판정>`.
#
# Usage:
#   scripts/solo-audit-compare.sh --exp <experiment dir> [--out <file>|-]
#
# Exit codes:
#   0 — report written (the verdict may be `판정 불가`)
#   1 — input defect (a valid pair with a non-numeric value or no
#       classification result)
#   2 — usage error / experiment directory not found
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.
# Non-ASCII literals follow a `${var}` brace, never a bare `$var`.

set -euo pipefail

PAIRS_REQUIRED=5
VETO_SUM_DIFF=3
VETO_PAIR_MAJORITY=3
RATIO_MAX=1.5

exp_dir=""
out=""

while (( $# > 0 )); do
  case "$1" in
    --exp) exp_dir="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    -h|--help)
      grep -E '^# ' "$0" | cut -c3-
      exit 0
      ;;
    *)
      echo "solo-audit-compare: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$exp_dir" || ! -d "$exp_dir" ]]; then
  echo "solo-audit-compare: experiment directory not found: ${exp_dir:-<empty>}" >&2
  exit 2
fi
exp_dir=$(cd "$exp_dir" && pwd)
[[ -n "$out" ]] || out="$exp_dir/report.md"

REVIEW="$exp_dir/classify/review.tsv"

# kv <file> <key> — the value of one key<TAB>value line, empty when absent.
kv() {
  awk -F'\t' -v k="$2" '$1 == k { print substr($0, length(k) + 2); exit }' "$1"
}

# skeletal <label> — 골격급 defects of one report, the person's 골격급 verdicts on
# its ambiguous defects included. Prints nothing when the result is missing.
skeletal() {
  local f="$exp_dir/classify/$1.json" c h=0
  [[ -f "$f" ]] || return 1
  c=$(jq -r '[.defects[]? | select(.class == "골격급")] | length' "$f" 2>/dev/null) || return 1
  if [[ -f "$REVIEW" ]]; then
    h=$(awk -F'\t' -v l="$1" 'NR > 1 && $1 == l && $5 == "골격급" { n++ } END { print n + 0 }' "$REVIEW")
  fi
  echo $((c + h))
}

is_count() { [[ "$1" =~ ^[0-9]+$ ]]; }

reasons=""
add_reason() { reasons="${reasons}- $1
"; }

rows=""        # n status tU tB tUn tSk sU sB sUn sSk  (valid pairs only feed the math)
table=""
confound=""
valid=0

for n in $(seq 1 "$PAIRS_REQUIRED"); do
  pf="$exp_dir/pairs/$n/pair.tsv"
  if [[ ! -f "$pf" ]]; then
    add_reason "짝 ${n}: 짝 기록이 없다"
    table="${table}| ${n} | 없음 | - | - | - | - | - | - | - | - | - | - | - | - |
"
    continue
  fi
  st=$(kv "$pf" status)
  tp=$(kv "$pf" team_plugin); sp=$(kv "$pf" solo_plugin)
  tr_=$(kv "$pf" team_reviewers); sr=$(kv "$pf" solo_reviewers)
  tb=$(kv "$pf" team_bytes); sb=$(kv "$pf" solo_bytes)
  confound="${confound}| ${n} | ${tp:--} | ${sp:--} | ${tr_:--} | ${sr:--} | ${tb:--} | ${sb:--} |
"
  if [[ "$st" != "유효" ]]; then
    why=$(kv "$pf" invalid_reason)
    add_reason "짝 ${n}: 무효 — ${why:-사유 없음}"
    table="${table}| ${n} | ${st:-미상} | - | - | - | - | - | - | - | - | - | - | - | - |
"
    continue
  fi
  tu=$(kv "$pf" team_unique); tun=$(kv "$pf" team_unremedied)
  su=$(kv "$pf" solo_unique); sun=$(kv "$pf" solo_unremedied)
  for v in "$tu" "$tb" "$tun" "$su" "$sb" "$sun"; do
    if ! is_count "$v"; then
      echo "solo-audit-compare: pair ${n} carries a non-numeric value: '${v}'" >&2
      exit 1
    fi
  done
  if (( tb == 0 || sb == 0 )); then
    echo "solo-audit-compare: pair ${n} carries a zero frozen byte count" >&2
    exit 1
  fi
  tl=$(kv "$pf" team_label); sl=$(kv "$pf" solo_label)
  if ! tsk=$(skeletal "$tl") || ! ssk=$(skeletal "$sl"); then
    echo "solo-audit-compare: pair ${n} has no classification result (labels '${tl}', '${sl}')" >&2
    exit 1
  fi
  valid=$((valid + 1))
  rows="${rows}${n}	${tu}	${tb}	${tun}	${tsk}	${su}	${sb}	${sun}	${ssk}
"
  table="${table}$(awk -F'\t' -v OFS=' | ' '{
    td = $2 * 1000 / $3; sd = $6 * 1000 / $7
    if (td == 0) dr = (sd == 0 ? "1.000" : "inf"); else dr = sprintf("%.3f", sd / td)
    rr = sprintf("%.3f", ($8 + 1) / ($4 + 1))
    printf "| %s | 유효 | %s | %s | %.3f | %s | %s | %s | %s | %.3f | %s | %s | %s | %s |\n", \
      $1, $2, $3, td, $5, $4, $6, $7, sd, $9, $8, dr, rr
  }' <<<"${n}	${tu}	${tb}	${tun}	${tsk}	${su}	${sb}	${sun}	${ssk}")
"
done

if [[ -f "$REVIEW" ]]; then
  blank=$(awk -F'\t' 'NR > 1 && $5 == "" { n++ } END { print n + 0 }' "$REVIEW")
  odd=$(awk -F'\t' 'NR > 1 && $5 != "" && $5 != "골격급" && $5 != "비골격" { n++ } END { print n + 0 }' "$REVIEW")
  (( blank == 0 )) || add_reason "경계 사례 ${blank}건의 사람 판정이 비어 있다 (classify/review.tsv)"
  (( odd == 0 )) || add_reason "경계 사례 ${odd}건의 사람 판정이 골격급·비골격 밖의 값이다 (classify/review.tsv)"
fi
if (( valid != PAIRS_REQUIRED )); then
  add_reason "유효한 짝이 ${valid}쌍이다 — 판정은 정확히 ${PAIRS_REQUIRED}쌍일 때만 낸다"
fi

veto_section=""
median_section=""
verdict=""
why=""

if [[ -n "$reasons" ]]; then
  verdict="판정 불가"
  veto_section="계산하지 않음 — 판정 불가 사유가 있다."
  median_section="계산하지 않음 — 판정 불가 사유가 있다."
  why="$reasons"
else
  calc=$(printf '%s' "$rows" | awk -F'\t' \
    -v vd="$VETO_SUM_DIFF" -v vm="$VETO_PAIR_MAJORITY" -v rmax="$RATIO_MAX" '
    {
      n++; ts += $5; ss += $9; if ($9 > $5) more++
      td = $2 * 1000 / $3; sd = $6 * 1000 / $7
      if (td == 0) d[n] = (sd == 0 ? 1 : 1e18); else d[n] = sd / td
      r[n] = ($8 + 1) / ($4 + 1)
    }
    function med(a,   i, j, t) {
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }
      return (n % 2 == 1) ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2
    }
    END {
      veto = ((ss - ts) >= vd && more + 0 >= vm) ? 1 : 0
      md = med(d); mr = med(r)
      if (veto) v = "≠"; else if (md <= rmax && mr <= rmax) v = "≈"; else v = "≠"
      printf "%d\t%d\t%d\t%d\t%s\t%s\t%s\n", ss, ts, more + 0, veto, \
        (md >= 1e18 ? "inf" : sprintf("%.3f", md)), sprintf("%.3f", mr), v
      printf "%d\t%d\n", (md <= rmax ? 1 : 0), (mr <= rmax ? 1 : 0)
    }')
  IFS='	' read -r ss ts more veto md mr verdict <<<"$(sed -n 1p <<<"$calc")"
  IFS='	' read -r d_ok r_ok <<<"$(sed -n 2p <<<"$calc")"
  diff=$((ss - ts))
  veto_word="아니오"; (( veto == 1 )) && veto_word="예"
  veto_section="- 골격급 합: 단독 ${ss} · 팀 ${ts} · 차 ${diff} (문턱 ${VETO_SUM_DIFF} 이상)
- 단독 골격급이 팀보다 많은 짝: ${more} (문턱 ${VETO_PAIR_MAJORITY} 이상)
- 발동: ${veto_word}"
  d_word="이하"; (( d_ok == 1 )) || d_word="초과"
  r_word="이하"; (( r_ok == 1 )) || r_word="초과"
  if (( veto == 1 )); then
    median_section="- 결함/KB 비 S/T 중앙값: ${md} (참고 — 거부권이 판정을 정했다)
- 잔여 비 (S+1)/(T+1) 중앙값: ${mr} (참고 — 거부권이 판정을 정했다)"
    why="- 골격급 거부권이 발동했다"
  else
    median_section="- 결함/KB 비 S/T 중앙값: ${md} — 문턱 ${RATIO_MAX} ${d_word}
- 잔여 비 (S+1)/(T+1) 중앙값: ${mr} — 문턱 ${RATIO_MAX} ${r_word}"
    if [[ "$verdict" == "≈" ]]; then
      why="- 거부권이 발동하지 않았고 두 중앙값이 모두 문턱 ${RATIO_MAX} 이하다"
    else
      why="- 거부권은 발동하지 않았으나 중앙값 하나 이상이 문턱 ${RATIO_MAX} 를 넘는다"
    fi
  fi
  why="${why}
"
fi

render() {
  cat <<EOF
# 단독 설계 감사 실험 판정 보고서

- 실험: $(basename "$exp_dir")
- 필요 짝 수: ${PAIRS_REQUIRED} · 거부권 문턱: 합 차 ${VETO_SUM_DIFF} 이상이고 ${VETO_PAIR_MAJORITY}쌍 이상 · 비율 문턱: ${RATIO_MAX}
- 결함/KB = 고유 결함 수 × 1000 ÷ 동결 문서 바이트

## 짝별 지표

| 짝 | 상태 | 팀 고유 결함 | 팀 동결 바이트 | 팀 결함/KB | 팀 골격급 | 팀 미보강 | 단독 고유 결함 | 단독 동결 바이트 | 단독 결함/KB | 단독 골격급 | 단독 미보강 | 결함/KB 비 S/T | 잔여 비 (S+1)/(T+1) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
${table}
## 거부권

${veto_section}

## 비율 중앙값

${median_section}

## 판정

**판정**: ${verdict}

${why}
## 교란 변수

| 짝 | 팀 감사 플러그인 판 | 단독 감사 플러그인 판 | 팀 리뷰어 수 | 단독 리뷰어 수 | 팀 동결 바이트 | 단독 동결 바이트 |
| --- | --- | --- | --- | --- | --- | --- |
${confound}
# verdict: ${verdict}
EOF
}

if [[ "$out" == "-" ]]; then
  render
else
  tmp="${out}.tmp.$$"
  render > "$tmp"
  mv "$tmp" "$out"
fi
exit 0
