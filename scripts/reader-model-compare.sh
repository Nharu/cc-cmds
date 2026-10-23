#!/usr/bin/env bash
# Judge the audit-reader model change from the audits' own counts.
#
# Two subcommands read the same slots through the same reader function:
#
#   pairs   the paired re-audit's verdict. Reads only <exp>/docs.tsv and
#           <exp>/reports/<n>-<opus-1|sonnet|opus-2>.md — the exchange format
#           scripts/reader-model-pair-audit.sh writes, never its state root —
#           and writes the verdict report (default <exp>/report.md).
#   cohort  the comparison after the switch over the audit reports
#           (default: docs/design-audit of this script's checkout): first
#           audits grouped by `reader-model`, the same metrics side by side.
#           The documents differ between the groups, so it never judges; its
#           last line is at most a call to run the paired re-audit again.
#
# Deterministic: no model, no network. Nothing is modified but the --out file.
#
# Metrics, read between the fences only and never from prose:
#   adopted     = 고유 결함 수 − 라우팅 — 기각
#   adopted/KB  = adopted × 1024 ÷ 동결 문서 바이트
#   K           = 골격급 수 + 합성 요구 골격급 수 (unknown without the skeletal fence)
#   secondary, no threshold: unique/KB, 기각 ÷ 고유, 미보강 잔여 ÷ 고유
# A report whose disclosure or skeletal fence is present but not exactly one
# pair, or whose `## 감사 개시` does not carry exactly one `reader-model` line,
# reads unknown in every slot.
#
# Rule of `pairs`, fixed before the switch (the constants below and the golden
# test hold it). a, b and s are the adopted counts of opus-1, opus-2 and sonnet
# on the same bytes, o = (a + b) ÷ 2; the first line that applies decides:
#   1 valid documents ≠ DOCS_REQUIRED                                → 판정 불가
#   2 documents with ks < min(ka, kb) ≥ VETO_DOC_MIN and
#     Σ max(0, min(ka, kb) − ks) ≥ VETO_SUM_MIN                       → 되돌림
#   3 W = median of |a − b| ÷ (o + 1) > NOISE_MAX                     → 판정 불가
#   4 D = median of (o − s) ÷ (o + 1) > max(DROP_FLOOR, NOISE_FACTOR × W) → 되돌림
#   5 otherwise                                                        → 유지
# Equal to a threshold is not above it. Every act after the verdict is a
# person's: a separate change to the `audit-reader` row and the lint pin, or a
# separate change to the constants before a new experiment.
#
# Usage:
#   scripts/reader-model-compare.sh pairs --exp <dir> [--out <file>|-]
#   scripts/reader-model-compare.sh cohort [--reports <dir>] [--out <file>|-]
#
# Exit codes (both subcommands):
#   0 — report written (`판정 불가` included)
#   1 — a slot error (a valid document whose slot is not a count) or no input
#   2 — usage error
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.
# Non-ASCII literals follow a `${var}` brace, never a bare `$var`.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)

DOCS_REQUIRED=5
VETO_DOC_MIN=2
VETO_SUM_MIN=2
DROP_FLOOR=0.20
NOISE_FACTOR=2
NOISE_MAX=0.25

COHORT_OPUS_WINDOW=20
COHORT_SONNET_MIN=10
COHORT_ALARM_RATIO=0.8

BRANCHES="opus-1 sonnet opus-2"

DISC_BEGIN='<!-- cc-design-audit-disclosure v1 begin -->'
DISC_END='<!-- /cc-design-audit-disclosure v1 end -->'
SKEL_BEGIN='<!-- cc-design-audit-skeletal v1 begin -->'
SKEL_END='<!-- /cc-design-audit-skeletal v1 end -->'

usage() { echo "reader-model-compare: $1" >&2; exit 2; }
die() { echo "reader-model-compare: $1" >&2; exit 1; }

# ---------- arguments --------------------------------------------------------

cmd="${1:-}"
case "$cmd" in
  pairs|cohort) shift ;;
  -h|--help) grep -E '^# ' "$0" | cut -c3-; exit 0 ;;
  "") usage "a subcommand is required: pairs or cohort" ;;
  *) usage "unknown subcommand: $cmd" ;;
esac

exp_dir=""
reports=""
out=""
while (( $# > 0 )); do
  case "$1" in
    --exp) [[ "$cmd" == "pairs" ]] || usage "--exp belongs to pairs"; exp_dir="${2:-}"; shift 2 || usage "--exp needs a value" ;;
    --reports) [[ "$cmd" == "cohort" ]] || usage "--reports belongs to cohort"; reports="${2:-}"; shift 2 || usage "--reports needs a value" ;;
    --out) out="${2:-}"; shift 2 || usage "--out needs a value" ;;
    -h|--help) grep -E '^# ' "$0" | cut -c3-; exit 0 ;;
    *) usage "unknown argument: $1" ;;
  esac
done

# ---------- the shared reader ------------------------------------------------

is_count() { [[ "$1" =~ ^[0-9]+$ ]]; }

# report_fields <report> — one tab-separated line, `-` for an absent slot:
#   state why model unique rejected unremedied bytes reviewers sha256 skeletal synth freeze
# state is `ok`, `미상` (why names the failed pair check) or `울타리 없음`.
# Every slot but freeze is `-` unless state is `ok`; the skeletal slots are `-`
# when the report has no skeletal fence. freeze is the disclosure block's
# 동결 시각, else the opening's `frozen-at` line in any of its four spellings.
report_fields() {
  LC_ALL=C awk -v db="$DISC_BEGIN" -v de="$DISC_END" -v sb="$SKEL_BEGIN" -v se="$SKEL_END" '
    function grab(key, slot,   k, s) {
      k = "**" key "**: "
      if (index($0, k) == 1 && !(slot in v)) { s = substr($0, length(k) + 1); sub(/[[:space:]]+$/, "", s); v[slot] = s }
    }
    function f(slot) { return ((slot in v) && v[slot] != "") ? v[slot] : "-" }
    index($0, db) == 1 { ndb++; ind = 1; next }
    index($0, de) == 1 { nde++; ind = 0; next }
    index($0, sb) == 1 { nsb++; ins = 1; next }
    index($0, se) == 1 { nse++; ins = 0; next }
    /^## / { open = ($0 == "## 감사 개시") }
    open && match($0, /^(- )?(reader-model|\*\*reader-model\*\*): */) {
      nrm++; rm = substr($0, RLENGTH + 1); sub(/[[:space:]]+$/, "", rm)
    }
    fa == "" && match($0, /^(- )?(\*\*)?frozen-at(\*\*)?: */) { fa = substr($0, RLENGTH + 1); sub(/[[:space:]]+$/, "", fa) }
    ind { grab("고유 결함 수", "u"); grab("라우팅 — 기각", "r"); grab("미보강 잔여 수", "un"); grab("동결 문서 바이트", "b")
          grab("리뷰어 수", "rev"); grab("동결 문서 sha256", "sha"); grab("동결 시각", "at") }
    ins { grab("골격급 수", "k"); grab("합성 요구 골격급 수", "ks") }
    END {
      at = ("at" in v && v["at"] != "") ? v["at"] : fa
      if (at == "") at = "-"
      state = "ok"; why = "-"
      if (ndb + nde == 0) { state = "울타리 없음" }
      else if (ndb != 1 || nde != 1) { state = "미상"; why = "공시 울타리가 한 쌍이 아니다" }
      else if (nsb + nse > 0 && (nsb != 1 || nse != 1)) { state = "미상"; why = "골격급 울타리가 한 쌍이 아니다" }
      else if (nrm != 1) { state = "미상"; why = "reader-model 줄이 " (nrm + 0) "개다" }
      if (state != "ok") { printf "%s\t%s\t-\t-\t-\t-\t-\t-\t-\t-\t-\t%s\n", state, why, at; exit }
      sk = (nsb == 1) ? f("k") : "-"; sy = (nsb == 1) ? f("ks") : "-"
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", state, why, (rm == "" ? "-" : rm), \
        f("u"), f("r"), f("un"), f("b"), f("rev"), f("sha"), sk, sy, at
    }' "$1"
}

# iso_epoch <ISO 8601 with Z or ±HH:MM> — epoch seconds, empty when unparsable.
iso_epoch() {
  jq -rn --arg s "$1" '
    $s
    | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$") then
        ((.[0:19] + "Z") | fromdateiso8601) as $t
        | if .[19:] == "Z" then $t
          else ((.[20:22] | tonumber) * 3600 + (.[23:25] | tonumber) * 60) as $o
            | if .[19:20] == "+" then $t - $o else $t + $o end
          end
      else empty end' 2>/dev/null || true
}

# hdr_field <file> <key> — `key=value;` from the machine header in the first lines.
hdr_field() {
  head -n 8 "$1" | grep -oE "$2=[^;]*" | head -n 1 | sed "s/^$2=//" || true
}

# is_reader_copy <file name> — a reader's witness copy, not a lead report. The
# tail decides, so a lead report whose slug carries `reader-` stays.
is_reader_copy() { [[ "$1" =~ [.-]reader-[0-9]+(\.fanout)?\.md$ ]]; }

# report_name <document key> — the name the audit skill gives a document's report.
report_name() { local k="${1%.md}"; printf '%s.md' "$(printf '%s' "$k" | tr '/' '-')"; }

# first_audit <index> <owner-doc> — the name of the document's first audit:
# the report frozen earliest, with or without its block, ties broken by name.
# The name decides only when the report under report_name has no readable
# freeze time, because then the times cannot be compared.
first_audit() {
  awk -F'\t' -v o="$2" -v nm="$(report_name "$2")" '
    $2 != o { next }
    $1 == nm && $3 == "" { fallback = 1 }
    $3 != "" && (bn == "" || $3 + 0 < best || ($3 + 0 == best && $1 < bn)) { best = $3 + 0; bn = $1 }
    END { print (fallback ? nm : bn) }' "$1"
}

emit() {
  if [[ "$out" == "-" ]]; then
    cat "$1"
  else
    local t="${out}.tmp.$$"
    cat "$1" > "$t"
    mv "$t" "$out"
  fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/reader-model-compare.XXXXXX")
trap 'rm -rf "$work"' EXIT

# ---------- pairs ------------------------------------------------------------

run_pairs() {
  [[ -n "$exp_dir" ]] || usage "pairs needs --exp <dir>"
  [[ -d "$exp_dir" ]] || die "experiment directory not found: $exp_dir"
  exp_dir=$(cd "$exp_dir" && pwd)
  [[ -n "$out" ]] || out="$exp_dir/report.md"
  local docs="$exp_dir/docs.tsv"
  [[ -f "$docs" ]] || die "no docs.tsv in $exp_dir"

  local table="" reasons="" rows="" valid=0 aux="$work/aux.tsv"
  : > "$aux"
  local n owner isha c1 c2 c3 why br f st fwhy model u r un b rev sha k ks at ad kk kb_ rp
  while IFS='	' read -r n owner isha c1 c2 c3 why; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    if [[ "$c1" != "유효" || "$c2" != "유효" || "$c3" != "유효" ]]; then
      reasons="${reasons}- 문서 ${n} (${owner}): 무효 — ${why:-사유 없음}
"
      table="${table}| ${n} | ${owner} | - | 무효 | - | - | - | - | - | - | - |
"
      continue
    fi
    local line="${n}"
    for br in $BRANCHES; do
      f="$exp_dir/reports/${n}-${br}.md"
      [[ -f "$f" ]] || die "document ${n} is valid but has no report: $f"
      IFS='	' read -r st fwhy model u r un b rev sha k ks at <<<"$(report_fields "$f")"
      [[ "$st" == "ok" ]] || die "document ${n} ${br}: the report reads unknown (${fwhy})"
      for rp in "$u" "$r" "$un" "$b" "$k" "$ks"; do
        is_count "$rp" || die "document ${n} ${br}: a slot is not a count: '${rp}'"
      done
      (( r <= u )) || die "document ${n} ${br}: 라우팅 — 기각 ${r} exceeds 고유 결함 수 ${u}"
      ad=$((u - r)); kk=$((k + ks))
      if (( b > 0 )); then kb_=$(awk -v a="$ad" -v b="$b" 'BEGIN { printf "%.3f", a * 1024 / b }'); else kb_="-"; fi
      table="${table}| ${n} | ${owner} | ${br} | 유효 | ${u} | ${r} | ${ad} | ${b} | ${kb_} | ${kk} | ${un} |
"
      printf '%s\t%s\t%s\t%s\t%s\n' "$br" "$u" "$r" "$un" "$b" >> "$aux"
      line="${line}	${ad}	${kk}"
    done
    valid=$((valid + 1))
    rows="${rows}${line}
"
  done < "$docs"

  # rows: n a ka s ks b kb (branch order opus-1 sonnet opus-2)
  local veto_section noise_section verdict why_text calc
  if (( valid != DOCS_REQUIRED )); then
    reasons="${reasons}- 유효 문서가 ${valid}건이다 — 판정은 정확히 ${DOCS_REQUIRED}건일 때만 낸다
"
    verdict="판정 불가"
    veto_section="계산하지 않음 — 판정 불가 사유가 있다."
    noise_section="계산하지 않음 — 판정 불가 사유가 있다."
    why_text="$reasons"
  else
    calc=$(printf '%s' "$rows" | awk -F'\t' -v vdm="$VETO_DOC_MIN" -v vsm="$VETO_SUM_MIN" \
      -v df="$DROP_FLOOR" -v nf="$NOISE_FACTOR" -v nm="$NOISE_MAX" '
      function med(x, c,   i, j, t, a) {
        for (i = 1; i <= c; i++) a[i] = x[i]
        for (i = 1; i <= c; i++) for (j = i + 1; j <= c; j++) if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }
        return (c % 2 == 1) ? a[(c + 1) / 2] : (a[c / 2] + a[c / 2 + 1]) / 2
      }
      NF >= 7 {
        c++
        a = $2; ka = $3; s = $4; ks = $5; b = $6; kb = $7
        o = (a + b) / 2
        var[c] = (a > b ? a - b : b - a) / (o + 1)
        drop[c] = (o - s) / (o + 1)
        km = (ka < kb ? ka : kb)
        if (ks < km) { vd++; vs += km - ks }
        printf "D\t%s\t%d\t%d\t%d\t%.1f\t%.3f\t%.3f\t%d\t%d\n", $1, a, b, s, o, var[c], drop[c], km, ks
      }
      END {
        W = med(var, c); D = med(drop, c)
        T = nf * W; if (T < df) T = df
        veto = (vd + 0 >= vdm && vs + 0 >= vsm) ? 1 : 0
        # A threshold met exactly is not crossed; the margin absorbs float noise.
        if (veto) v = "되돌림:veto"
        else if (W > nm + 1e-9) v = "판정 불가:noise"
        else if (D > T + 1e-9) v = "되돌림:drop"
        else v = "유지:keep"
        printf "S\t%d\t%d\t%d\t%.3f\t%.3f\t%.3f\t%s\n", vd + 0, vs + 0, veto, W, D, T, v
      }')
    local vd vs veto W D T vv tag dtab=""
    IFS='	' read -r _ vd vs veto W D T vv <<<"$(printf '%s\n' "$calc" | grep '^S	')"
    while IFS='	' read -r _ dn da db ds do_ dvar ddrop dkm dks; do
      dtab="${dtab}| ${dn} | ${da} | ${db} | ${ds} | ${do_} | ${dvar} | ${ddrop} | ${dkm} | ${dks} |
"
    done < <(printf '%s\n' "$calc" | grep '^D	')
    verdict="${vv%%:*}"; tag="${vv##*:}"
    local vword="아니오"; (( veto == 1 )) && vword="예"
    veto_section="- ks < min(ka, kb) 인 문서: ${vd} (문턱 ${VETO_DOC_MIN} 이상)
- Σ max(0, min(ka, kb) − ks): ${vs} (문턱 ${VETO_SUM_MIN} 이상)
- 발동: ${vword}"
    noise_section="| 문서 | a (opus-1) | b (opus-2) | s (sonnet) | o | 변동 | 하락 | min(ka, kb) | ks |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
${dtab}
- W = 변동 중앙값: ${W} (문턱 ${NOISE_MAX})
- D = 하락 중앙값: ${D} (문턱 max(${DROP_FLOOR}, ${NOISE_FACTOR} × W) = ${T})"
    case "$tag" in
      veto) why_text="- 골격급 거부권이 발동했다 — 판정 순서상 변동 폭 검사보다 앞선다" ;;
      noise) why_text="- 변동 폭 과다 — W = ${W} 가 문턱 ${NOISE_MAX} 를 넘는다" ;;
      drop) why_text="- 하락 D = ${D} 가 문턱 ${T} 를 넘는다" ;;
      *) why_text="- 거부권이 발동하지 않았고 W = ${W} 는 ${NOISE_MAX} 이하, D = ${D} 는 ${T} 이하다" ;;
    esac
    why_text="${why_text}
"
  fi

  local auxtab
  auxtab=$(awk -F'\t' -v order="$BRANCHES" '
    function med(x, c,   i, j, t, a) {
      if (c == 0) return "-"
      for (i = 1; i <= c; i++) a[i] = x[i]
      for (i = 1; i <= c; i++) for (j = i + 1; j <= c; j++) if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }
      return sprintf("%.3f", (c % 2 == 1) ? a[(c + 1) / 2] : (a[c / 2] + a[c / 2 + 1]) / 2)
    }
    { br = $1
      if ($5 > 0) { nu[br]++; uk[br, nu[br]] = $2 * 1024 / $5 }
      if ($2 > 0) { nr[br]++; rr[br, nr[br]] = $3 / $2; rn[br, nr[br]] = $4 / $2 } }
    END {
      m = split(order, o, " ")
      for (i = 1; i <= m; i++) {
        br = o[i]
        delete x; for (j = 1; j <= nu[br]; j++) x[j] = uk[br, j]; a1 = med(x, nu[br] + 0)
        delete x; for (j = 1; j <= nr[br]; j++) x[j] = rr[br, j]; a2 = med(x, nr[br] + 0)
        delete x; for (j = 1; j <= nr[br]; j++) x[j] = rn[br, j]; a3 = med(x, nr[br] + 0)
        printf "| %s | %s | %s | %s |\n", br, a1, a2, a3
      }
    }' "$aux")

  cat > "$work/report.md" <<EOF
# 판독자 모델 쌍 재감사 판정 보고서

- 실험: $(basename "$exp_dir")
- 상수: DOCS_REQUIRED=${DOCS_REQUIRED} · VETO_DOC_MIN=${VETO_DOC_MIN} · VETO_SUM_MIN=${VETO_SUM_MIN} · DROP_FLOOR=${DROP_FLOOR} · NOISE_FACTOR=${NOISE_FACTOR} · NOISE_MAX=${NOISE_MAX}
- 채택 결함 = 고유 결함 수 − 라우팅 — 기각 · 채택/KB = 채택 결함 × 1024 ÷ 동결 문서 바이트 · K = 골격급 수 + 합성 요구 골격급 수
- 판정 통계량은 같은 바이트 위의 채택 결함 수로 계산한다. 채택/KB 는 인쇄하는 지표다

## 문서별 지표

| 문서 | owner-doc | 갈래 | 상태 | 고유 | 기각 | 채택 | 바이트 | 채택/KB | K | 미보강 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
${table}
## 골격급 거부권

${veto_section}

## 변동 폭과 하락

${noise_section}

## 보조 지표 (문턱 없음)

| 갈래 | 고유/KB 중앙값 | 기각 비율 중앙값 | 미보강 비율 중앙값 |
| --- | --- | --- | --- |
${auxtab}

## 판정

**판정**: ${verdict}

${why_text}
# verdict: ${verdict}
EOF
  emit "$work/report.md"
}

# ---------- cohort -----------------------------------------------------------

run_cohort() {
  [[ -n "$reports" ]] || reports="$script_dir/../docs/design-audit"
  [[ -d "$reports" ]] || die "reports directory not found: $reports"
  reports=$(cd "$reports" && pwd)
  [[ -n "$out" ]] || out="-"

  local idx="$work/index.tsv" fl="$work/fields.tsv" r name owner fields at ep readers=0
  : > "$idx"; : > "$fl"
  while IFS= read -r r; do
    name=$(basename "$r")
    if is_reader_copy "$name"; then readers=$((readers + 1)); continue; fi
    owner=$(hdr_field "$r" owner-doc)
    fields=$(report_fields "$r")
    at=${fields##*	}
    ep=""; [[ "$at" == "-" ]] || ep=$(iso_epoch "$at")
    printf '%s\t%s\t%s\n' "$name" "$owner" "$ep" >> "$idx"
    printf '%s\t%s\t%s\t%s\n' "$name" "${owner:--}" "${ep:--}" "$fields" >> "$fl"
  done < <(find "$reports" -maxdepth 1 -name '*.md' | LC_ALL=C sort)
  [[ -s "$idx" ]] || die "no audit report in $reports"

  # Disposition of every lead report: first audit or not, then its fields.
  local disp="$work/disp.tsv" first st why model
  : > "$disp"
  while IFS='	' read -r name owner ep st why model rest; do
    if [[ "$owner" == "-" ]]; then printf '제외\towner-doc 없음\n' >> "$disp"; continue; fi
    first=$(first_audit "$idx" "$owner")
    if [[ "$name" != "$first" ]]; then printf '제외\t재감사 (같은 owner-doc 의 첫 감사가 따로 있다)\n' >> "$disp"; continue; fi
    case "$st" in
      "울타리 없음") printf '제외\t공시 울타리 없음\n' >> "$disp" ;;
      "미상") printf '제외\t%s\n' "$why" >> "$disp" ;;
      ok) printf '포함\t%s\t%s\t%s\t%s\n' "$name" "$ep" "$model" "$rest" >> "$disp" ;;
    esac
  done < "$fl"

  local body
  body=$(awk -F'\t' -v readers="$readers" -v win="$COHORT_OPUS_WINDOW" -v smin="$COHORT_SONNET_MIN" -v ratio="$COHORT_ALARM_RATIO" '
    function cnt(x) { return x ~ /^[0-9]+$/ }
    function med(x, c,   i, j, t, a) {
      for (i = 1; i <= c; i++) a[i] = x[i]
      for (i = 1; i <= c; i++) for (j = i + 1; j <= c; j++) if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }
      return (c % 2 == 1) ? a[(c + 1) / 2] : (a[c / 2] + a[c / 2 + 1]) / 2
    }
    function fmt(c, v) { return c == 0 ? "-" : sprintf("%.3f", v) }
    $1 == "제외" { if (!($2 in ex)) eo[++ne] = $2; ex[$2]++; next }
    $1 == "포함" {
      # 포함 name epoch model u r un b rev sha k ks at
      m = $4; if (m == "-") m = "미상"
      if (!(m in gn)) go[++ng] = m
      gn[m]++; i = gn[m]
      nm[m, i] = $2; ep[m, i] = ($3 == "-" ? -1 : $3 + 0)
      u[m, i] = $5; r[m, i] = $6; un[m, i] = $7; b[m, i] = $8; k[m, i] = $11; ks[m, i] = $12
    }
    END {
      # The opus cohort is its latest first audits by freeze time.
      if ("opus" in gn && gn["opus"] > win) {
        c = gn["opus"]
        for (i = 1; i <= c; i++) ord[i] = i
        for (i = 1; i <= c; i++) for (j = i + 1; j <= c; j++) {
          p = ord[i]; q = ord[j]
          if (ep["opus", q] > ep["opus", p] || (ep["opus", q] == ep["opus", p] && nm["opus", q] < nm["opus", p])) { ord[i] = q; ord[j] = p }
        }
        for (i = 1; i <= c; i++) keep[ord[i]] = (i <= win)
        outwin = c - win
      } else outwin = 0
      print "## 빠진 보고서"
      print ""
      printf "- 판독자 사본: %d\n", readers
      for (e = 1; e <= ne; e++) printf "- %s: %d\n", eo[e], ex[eo[e]]
      printf "- opus 창 밖 (동결 시각이 가장 늦은 %d건 밖): %d\n", win, outwin
      print ""
      print "## 묶음"
      print ""
      print "| reader-model | n | 채택/KB 중앙값 | 고유/KB 중앙값 | 기각 비율 중앙값 | 미보강 비율 중앙값 | 골격급 울타리 있는 보고서 | K 중앙값 |"
      print "| --- | --- | --- | --- | --- | --- | --- | --- |"
      # opus and sonnet first, then the rest by name, 미상 last.
      no = 0
      if ("opus" in gn) ol[++no] = "opus"
      if ("sonnet" in gn) ol[++no] = "sonnet"
      for (g = 1; g <= ng; g++) if (go[g] != "opus" && go[g] != "sonnet" && go[g] != "미상") rest[++nr_] = go[g]
      for (i = 1; i <= nr_; i++) for (j = i + 1; j <= nr_; j++) if (rest[j] < rest[i]) { t = rest[i]; rest[i] = rest[j]; rest[j] = t }
      for (i = 1; i <= nr_; i++) ol[++no] = rest[i]
      if ("미상" in gn) ol[++no] = "미상"
      for (g = 1; g <= no; g++) {
        m = ol[g]; n = 0; c1 = c2 = c3 = c4 = c5 = 0; d1 = d2 = d3 = d4 = 0
        delete x1; delete x2; delete x3; delete x4; delete x5
        for (i = 1; i <= gn[m]; i++) {
          if (m == "opus" && gn["opus"] > win && !keep[i]) continue
          n++
          if (cnt(u[m, i]) && cnt(r[m, i]) && cnt(b[m, i]) && b[m, i] > 0) x1[++c1] = (u[m, i] - r[m, i]) * 1024 / b[m, i]; else d1++
          if (cnt(u[m, i]) && cnt(b[m, i]) && b[m, i] > 0) x2[++c2] = u[m, i] * 1024 / b[m, i]; else d2++
          if (cnt(u[m, i]) && u[m, i] > 0 && cnt(r[m, i])) x3[++c3] = r[m, i] / u[m, i]; else d3++
          if (cnt(u[m, i]) && u[m, i] > 0 && cnt(un[m, i])) x4[++c4] = un[m, i] / u[m, i]; else d4++
          if (cnt(k[m, i]) && cnt(ks[m, i])) x5[++c5] = k[m, i] + ks[m, i]
        }
        g1 = c1 ? med(x1, c1) : 0
        label = (m == "opus" || m == "sonnet") ? m : m " (비교 제외)"
        printf "| %s | %d | %s | %s | %s | %s | %d | %s |\n", label, n, fmt(c1, g1), fmt(c2, c2 ? med(x2, c2) : 0), \
          fmt(c3, c3 ? med(x3, c3) : 0), fmt(c4, c4 ? med(x4, c4) : 0), c5, fmt(c5, c5 ? med(x5, c5) : 0)
        gnn[m] = n; gm1[m] = g1; gc1[m] = c1
        drop_line[g] = sprintf("| %s | %d | %d | %d | %d |", label, d1, d2, d3, d4)
      }
      print ""
      print "## 중앙값에서 뺀 보고서 (칸 없음·수가 아님·바이트 0)"
      print ""
      print "| reader-model | 채택/KB | 고유/KB | 기각 비율 | 미보강 비율 |"
      print "| --- | --- | --- | --- | --- |"
      for (g = 1; g <= no; g++) print drop_line[g]
      print ""
      sn = gnn["sonnet"] + 0
      if (sn < smin) printf "표본 대기 (%d/%d)\n", sn, smin
      else if (gc1["sonnet"] > 0 && gc1["opus"] > 0 && gm1["sonnet"] < ratio * gm1["opus"]) print "코호트 경보 — 문서 차이가 섞인 비교라 판정이 아닙니다. 새 표본으로 쌍 재감사를 다시 돌려 판정하세요"
      else print "코호트 경보 없음"
    }' "$disp")

  {
    printf '# 판독자 모델 코호트 비교\n\n'
    printf -- '- 보고서 디렉터리: %s\n' "$reports"
    printf -- '- owner-doc 마다 첫 감사만, 공시 v1 울타리가 있는 보고서만 읽는다. opus 는 동결 시각이 가장 늦은 %s건, sonnet 은 전부다\n' "$COHORT_OPUS_WINDOW"
    printf -- '- 채택 결함 = 고유 결함 수 − 라우팅 — 기각 · 채택/KB = 채택 결함 × 1024 ÷ 동결 문서 바이트 · K = 골격급 수 + 합성 요구 골격급 수\n'
    printf -- '- 묶음 사이에 문서가 달라 이 비교는 판정을 내지 않는다. 경보 문턱: sonnet n ≥ %s 이고 채택/KB 중앙값 < %s × opus 중앙값\n\n' "$COHORT_SONNET_MIN" "$COHORT_ALARM_RATIO"
    printf '%s\n' "$body"
  } > "$work/cohort.md"
  emit "$work/cohort.md"
}

case "$cmd" in
  pairs) run_pairs ;;
  cohort) run_cohort ;;
esac
exit 0
