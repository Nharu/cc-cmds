#!/usr/bin/env bash
# Test scripts/reader-model-compare.sh against tests/fixtures/reader-model-compare/.
#
# Every input is synthetic: the pair cases are built from the small specs under
# pairs/ into the exchange format the paired re-audit runner writes
# (docs.tsv and reports/<n>-<branch>.md), and the cohort cases are a reports
# directory built here under `mktemp -d`.
#
# The verdict rule is pinned by golden files: a constant changed after the
# experiment breaks constants.golden instead of passing in silence, and two
# whole reports are pinned besides. Regenerate the goldens only for an intended
# rule change: READER_CMP_UPDATE_GOLDEN=1.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/reader-model-compare"
compare="$script_dir/reader-model-compare.sh"

failures=0
passed=0

pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }

for v in $(compgen -e | grep '^CC_PIPELINE_' || true); do unset "$v"; done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-reader-model-compare.XXXXXX")
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

FB='<!-- cc-design-audit-disclosure v1 begin -->'
FE='<!-- /cc-design-audit-disclosure v1 end -->'
SB='<!-- cc-design-audit-skeletal v1 begin -->'
SE='<!-- /cc-design-audit-skeletal v1 end -->'

# mk_report <file> <owner-doc> <frozen at> <reader-model line|-> <unique> <rejected> <bytes|-> <skeletal|-> <synth skeletal|-> [double]
# `-` for the reader-model line leaves it out, `-` for bytes leaves that slot
# out, `-` for the skeletal pair leaves the skeletal fence out, and `double`
# writes the disclosure fence twice.
mk_report() {
  local f="$1" owner="$2" at="$3" rm="$4" u="$5" r="$6" b="$7" k="$8" ks="$9" dbl="${10:-}"
  local block
  block="${FB}
**동결 문서 sha256**: 0000000000000000000000000000000000000000000000000000000000000000
$( [[ "$b" == "-" ]] || printf '**동결 문서 바이트**: %s' "$b" )
**동결 시각**: ${at}
**리뷰어 수**: 3
**고유 결함 수**: ${u}
**미보강 잔여 수**: 1
**라우팅 — 조정 패스 적용**: $((u - r))
**라우팅 — 기각**: ${r}
${FE}"
  {
    echo "# 설계 감사 — ${owner}"
    echo "<!-- cc-design-audit v1; writer=design-audit; reader=design-audit; owner-doc=${owner}; NOT a design doc; mechanism-local, never staged by a skill -->"
    echo
    echo "## 감사 개시"
    echo "- 대상: ${owner}"
    [[ "$rm" == "-" ]] || echo "$rm"
    echo "**고유 결함 수**: 99"
    echo
    echo "## 고유 결함"
    echo "- reader-model: 본문의 이 줄은 개시 절 밖이라 읽지 않는다"
    echo
    echo "$block"
    [[ "$dbl" != "double" ]] || echo "$block"
    if [[ "$k" != "-" ]]; then
      echo "$SB"
      echo "**골격급 수**: ${k}"
      echo "**합성 요구 후보 수**: ${ks}"
      echo "**합성 요구 골격급 수**: ${ks}"
      echo "$SE"
    fi
  } > "$f"
}

# ---- pairs: build an experiment directory from a spec -------------------------
#
# Spec lines: `doc <n> <a> <ka> <s> <ks> <b> <kb>` — the adopted count and K of
# opus-1, sonnet and opus-2 — or `invalid <n> <reason>`. Every report carries
# one 기각 and splits K into 골격급 K−1 plus 합성 요구 골격급 1 when K ≥ 1, so the
# rule is seen to subtract the one and add the other.

build_pairs() {
  local spec="$1" d="$2" kind n rest a ka s ks b kb br ad kk
  rm -rf "$d"; mkdir -p "$d/reports"
  printf 'n\towner-doc\t입력 sha256\topus-1\tsonnet\topus-2\t사유\n' > "$d/docs.tsv"
  while read -r kind n rest; do
    case "$kind" in
      doc)
        read -r a ka s ks b kb <<<"$rest"
        printf '%s\tdocs/d%s.md\t%064d\t유효\t유효\t유효\t-\n' "$n" "$n" 0 >> "$d/docs.tsv"
        for br in opus-1 sonnet opus-2; do
          case "$br" in opus-1) ad=$a; kk=$ka ;; sonnet) ad=$s; kk=$ks ;; opus-2) ad=$b; kk=$kb ;; esac
          if (( kk >= 1 )); then
            mk_report "$d/reports/${n}-${br}.md" "docs/d${n}.md" 2026-10-20T00:00:00Z "reader-model: ${br%-*}" $((ad + 1)) 1 2048 $((kk - 1)) 1
          else
            mk_report "$d/reports/${n}-${br}.md" "docs/d${n}.md" 2026-10-20T00:00:00Z "reader-model: ${br%-*}" $((ad + 1)) 1 2048 0 0
          fi
        done ;;
      invalid)
        printf '%s\tdocs/d%s.md\t%064d\t유효\t무효\t유효\t%s\n' "$n" "$n" 0 "$rest" >> "$d/docs.tsv" ;;
    esac
  done < <(grep -vE '^(#|$)' "$spec")
}

verdict_of() { tail -n 1 "$1"; }

# ---- pairs: constants golden ----------------------------------------------------

grep -E '^(DOCS_REQUIRED|VETO_DOC_MIN|VETO_SUM_MIN|DROP_FLOOR|NOISE_FACTOR|NOISE_MAX)=' "$compare" > "$tmp/constants"
if [[ "${READER_CMP_UPDATE_GOLDEN:-0}" == "1" ]]; then cp "$tmp/constants" "$fixtures/constants.golden"; fi
if diff -u "$fixtures/constants.golden" "$tmp/constants" > "$tmp/diff"; then
  pass "pairs: the six rule constants match the golden"
else
  fail "pairs: a rule constant moved"; cat "$tmp/diff" >&2
fi

# ---- pairs: verdict cases ------------------------------------------------------

# want <spec name> <what decides it> <expected verdict>
want() {
  local c="$1" what="$2" v="$3" d="$tmp/pairs/$1" rc=0
  build_pairs "$fixtures/pairs/$c.spec" "$d"
  bash "$compare" pairs --exp "$d" > "$tmp/out" 2> "$tmp/err" || rc=$?
  if [[ "$rc" != "0" ]]; then fail "pairs $c: exit $rc"; cat "$tmp/err" >&2; return; fi
  if [[ "$(verdict_of "$d/report.md")" == "# verdict: $v" ]]; then
    pass "pairs $c: $what → $v"
  else
    fail "pairs $c: expected $v, got '$(verdict_of "$d/report.md")'"; cat "$d/report.md" >&2
  fi
}

want keep "같은 채택 수" "유지"
want veto "두 문서에서 ks 가 min(ka, kb) 보다 1씩 작다" "되돌림"
grep -qF -- '- 발동: 예' "$tmp/pairs/veto/report.md" && pass "pairs veto: the veto decided it" || fail "pairs veto: the veto did not fire"
want veto-short "한 문서에서만 ks 가 3 작다 — 거부권 미달" "유지"
grep -qF -- '- 발동: 아니오' "$tmp/pairs/veto-short/report.md" && grep -qF 'Σ max(0, min(ka, kb) − ks): 3' "$tmp/pairs/veto-short/report.md" \
  && pass "pairs veto-short: one document of sum 3 does not fire the veto" || fail "pairs veto-short: veto line wrong"
want noise "W 가 0.25 를 넘는다" "판정 불가"
grep -qF '변동 폭 과다' "$tmp/pairs/noise/report.md" && pass "pairs noise: the reason names the noise" || fail "pairs noise: reason missing"
want drop-over "D 가 0.20 을 막 넘는다" "되돌림"
want drop-equal "D 가 0.20 과 같다 — 같음은 넘지 않는다" "유지"
want drop-2w-over "D 가 2W 를 넘는다" "되돌림"
want drop-2w-equal "D 가 2W 와 같다" "유지"
want four-valid "유효 문서 4건" "판정 불가"
grep -qF '유효 문서가 4건이다' "$tmp/pairs/four-valid/report.md" && grep -qF '무효 — 대상 클론 준비 실패' "$tmp/pairs/four-valid/report.md" \
  && pass "pairs four-valid: the report names the count and the invalid document's reason" || fail "pairs four-valid: reasons missing"
want noise-veto "W 가 0.25 를 넘으면서 거부권이 발동한다 — 거부권이 앞선다" "되돌림"
grep -qF '골격급 거부권이 발동했다' "$tmp/pairs/noise-veto/report.md" && pass "pairs noise-veto: the veto, not the noise, decided it" || fail "pairs noise-veto: wrong reason"

# The adopted count subtracts 기각: every report carries one 기각 over adopted + 1 unique.
grep -qE '^\| 1 \| docs/d1\.md \| opus-1 \| 유효 \| 11 \| 1 \| 10 \| 2048 \| 5\.000 \| 2 \| 1 \|$' "$tmp/pairs/keep/report.md" \
  && pass "pairs: adopted = 고유 − 기각, adopted/KB = adopted × 1024 ÷ bytes, K = 골격급 + 합성 요구 골격급" \
  || { fail "pairs: the document row is not as computed"; grep '^| 1 |' "$tmp/pairs/keep/report.md" >&2 || true; }

# ---- pairs: whole-report goldens -------------------------------------------------

for c in keep veto; do
  if [[ "${READER_CMP_UPDATE_GOLDEN:-0}" == "1" ]]; then
    bash "$compare" pairs --exp "$tmp/pairs/$c" --out "$fixtures/pairs/$c.expected.md"
  fi
  if diff -u "$fixtures/pairs/$c.expected.md" "$tmp/pairs/$c/report.md" > "$tmp/diff"; then
    pass "pairs golden: $c"
  else
    fail "pairs golden diff: $c"; cat "$tmp/diff" >&2
  fi
done

# ---- pairs: input and usage errors -----------------------------------------------

d="$tmp/pairs/bad"
build_pairs "$fixtures/pairs/keep.spec" "$d"
awk '{ if (index($0, "**고유 결함 수**: ") == 1 && !done && seen) { print "**고유 결함 수**: 많음"; done = 1; next } } index($0, "<!-- cc-design-audit-disclosure v1 begin -->") == 1 { seen = 1 } { print }' \
  "$d/reports/2-sonnet.md" > "$d/x" && mv "$d/x" "$d/reports/2-sonnet.md"
rc=0; bash "$compare" pairs --exp "$d" --out - > /dev/null 2>&1 || rc=$?
[[ "$rc" == "1" ]] && pass "pairs: a slot that is not a count → exit 1" || fail "pairs: a non-count slot gave exit $rc"
build_pairs "$fixtures/pairs/keep.spec" "$d"
rm -f "$d/reports/3-opus-2.md"
rc=0; bash "$compare" pairs --exp "$d" --out - > /dev/null 2>&1 || rc=$?
[[ "$rc" == "1" ]] && pass "pairs: a valid document without its report → exit 1" || fail "pairs: a missing report gave exit $rc"
rc=0; bash "$compare" pairs --exp "$tmp/nowhere" > /dev/null 2>&1 || rc=$?
[[ "$rc" == "1" ]] && pass "pairs: no experiment directory → exit 1" || fail "pairs: a missing directory gave exit $rc"
rc=0; bash "$compare" pairs --exp "$tmp/pairs/keep" --bogus > /dev/null 2>&1 || rc=$?
[[ "$rc" == "2" ]] && pass "pairs: an unknown argument → exit 2" || fail "pairs: an unknown argument gave exit $rc"
rc=0; bash "$compare" > /dev/null 2>&1 || rc=$?
[[ "$rc" == "2" ]] && pass "no subcommand → exit 2" || fail "no subcommand gave exit $rc"

rm -f "$tmp/pairs/keep/report.md"
rc=0; bash "$compare" pairs --exp "$tmp/pairs/keep" --out - > "$tmp/stdout.md" 2>/dev/null || rc=$?
if [[ "$rc" == "0" && "$(verdict_of "$tmp/stdout.md")" == "# verdict: 유지" && ! -e "$tmp/pairs/keep/report.md" ]]; then
  pass "pairs: --out - writes to stdout, ends with '# verdict:', and leaves no report.md"
else
  fail "pairs: --out - did not behave (rc=$rc)"
fi

# ---- cohort -----------------------------------------------------------------------

# build_cohort <dir> <sonnet first audits> <sonnet unique>
# opus: 22 first audits a day apart, adopted/KB 4.000; the two oldest alone carry
# a skeletal fence, so a window of the latest 20 shows zero of them.
# sonnet: the four spellings first, a lead report whose slug carries `reader-`,
# one without bytes, the rest plain; each with one 기각 and K = 1 + 1.
# Around them: reader copies, a re-audit, a doubled fence, a report with no
# reader-model line and one whose value is empty.
build_cohort() {
  local d="$1" ns="$2" su="$3" i at
  rm -rf "$d"; mkdir -p "$d"
  for i in $(seq 1 22); do
    at=$(printf '2026-09-%02dT00:00:00Z' "$i")
    if (( i <= 2 )); then
      mk_report "$d/docs-o$(printf '%02d' "$i").md" "docs/o$(printf '%02d' "$i").md" "$at" "reader-model: opus" 5 1 1024 3 3
    else
      mk_report "$d/docs-o$(printf '%02d' "$i").md" "docs/o$(printf '%02d' "$i").md" "$at" "reader-model: opus" 5 1 1024 - -
    fi
  done
  local spell
  for i in $(seq 1 "$ns"); do
    at=$(printf '2026-10-%02dT00:00:00+09:00' "$i")
    case "$i" in
      1) spell="reader-model: sonnet" ;;
      2) spell="- reader-model: sonnet" ;;
      3) spell="**reader-model**: sonnet" ;;
      4) spell="- **reader-model**: sonnet" ;;
      *) spell="reader-model: sonnet" ;;
    esac
    if (( i == 5 )); then
      mk_report "$d/docs-reader-x.md" docs/reader-x.md "$at" "$spell" "$su" 1 1024 1 1
    elif (( i == 6 )); then
      mk_report "$d/docs-s${i}.md" "docs/s${i}.md" "$at" "$spell" "$su" 1 - 1 1
    else
      mk_report "$d/docs-s${i}.md" "docs/s${i}.md" "$at" "$spell" "$su" 1 1024 1 1
    fi
  done
  mk_report "$d/docs-s1.reader-1.md" docs/s1.md 2026-10-01T00:00:00+09:00 "reader-model: sonnet" 40 0 1024 - -
  mk_report "$d/docs-s1.reader-2.fanout.md" docs/s1.md 2026-10-01T00:00:00+09:00 "reader-model: sonnet" 40 0 1024 - -
  mk_report "$d/docs-s1.A1-3.md" docs/s1.md 2026-10-21T00:00:00Z "reader-model: sonnet" 40 0 1024 1 1
  mk_report "$d/docs-dbl.md" docs/dbl.md 2026-10-02T00:00:00Z "reader-model: sonnet" 40 0 1024 - - double
  mk_report "$d/docs-none.md" docs/none.md 2026-10-02T00:00:00Z - 40 0 1024 - -
  mk_report "$d/docs-blank.md" docs/blank.md 2026-10-02T00:00:00Z "reader-model:" 40 0 1024 - -
}

cohort() { bash "$compare" cohort --reports "$1" > "$2" 2> "$tmp/err"; }

d="$tmp/cohort/wait"
build_cohort "$d" 9 3
rc=0; cohort "$d" "$tmp/c.md" || rc=$?
if [[ "$rc" != "0" ]]; then fail "cohort: exit $rc"; cat "$tmp/err" >&2; fi
c="$tmp/c.md"
[[ "$(tail -n 1 "$c")" == "표본 대기 (9/10)" ]] && pass "cohort: sonnet n = 9 → 표본 대기 (9/10)" || fail "cohort: n = 9 ends with '$(tail -n 1 "$c")'"
grep -qE '^\| sonnet \| 9 \| 2\.000 \| 3\.000 \|' "$c" \
  && pass "cohort: all four spellings and the reader- slug lead report land in sonnet, adopted subtracts 기각" \
  || { fail "cohort: the sonnet row is not n = 9 with adopted/KB 2.000"; grep '^| sonnet' "$c" >&2 || true; }
grep -qE '^\| sonnet \| 9 \| [^|]+\| [^|]+\| [^|]+\| [^|]+\| 9 \| 2\.000 \|$' "$c" \
  && pass "cohort: K = 골격급 + 합성 요구 골격급 over the reports with the skeletal fence" || fail "cohort: the sonnet K columns are wrong"
grep -qE '^\| opus \| 20 \| 4\.000 \| 5\.000 \| [^|]+\| [^|]+\| 0 \| - \|$' "$c" \
  && pass "cohort: the opus cohort is the latest 20 first audits" \
  || { fail "cohort: the opus window is wrong"; grep '^| opus' "$c" >&2 || true; }
grep -qF -- '- opus 창 밖 (동결 시각이 가장 늦은 20건 밖): 2' "$c" && pass "cohort: the two oldest opus audits are counted out of the window" || fail "cohort: opus out-of-window count missing"
grep -qF -- '- 판독자 사본: 2' "$c" && pass "cohort: both reader copies are excluded" || fail "cohort: reader copy count wrong"
grep -qF -- '- 재감사 (같은 owner-doc 의 첫 감사가 따로 있다): 1' "$c" && pass "cohort: the re-audit is excluded" || fail "cohort: re-audit count wrong"
grep -qF -- '- 공시 울타리가 한 쌍이 아니다: 1' "$c" && pass "cohort: a doubled fence reads unknown and its count is printed" || fail "cohort: doubled-fence count wrong"
grep -qF -- '- reader-model 줄이 0개다: 1' "$c" && pass "cohort: a report with no reader-model line is excluded with its reason" || fail "cohort: no-line count wrong"
grep -qE '^\| 미상 \(비교 제외\) \| 1 \|' "$c" && pass "cohort: an empty reader-model value forms the 미상 group" || fail "cohort: 미상 group missing"
grep -qE '^\| sonnet \| 1 \| 1 \| 0 \| 0 \|$' "$c" \
  && pass "cohort: missing bytes leave the per-KB medians only, the ratios keep the report" || { fail "cohort: the drop counts are wrong"; grep '^| sonnet' "$c" >&2 || true; }

d="$tmp/cohort/alarm"
build_cohort "$d" 10 3
cohort "$d" "$tmp/c.md" || true
[[ "$(tail -n 1 "$tmp/c.md")" == "코호트 경보 — 문서 차이가 섞인 비교라 판정이 아닙니다. 새 표본으로 쌍 재감사를 다시 돌려 판정하세요" ]] \
  && pass "cohort: n = 10 and 2.000 < 0.8 × 4.000 → 경보" || fail "cohort: no alarm at n = 10 below 0.8 ×: '$(tail -n 1 "$tmp/c.md")'"

d="$tmp/cohort/quiet"
build_cohort "$d" 10 5
cohort "$d" "$tmp/c.md" || true
[[ "$(tail -n 1 "$tmp/c.md")" == "코호트 경보 없음" ]] && pass "cohort: n = 10 at the same median → 경보 없음" || fail "cohort: quiet case ends with '$(tail -n 1 "$tmp/c.md")'"

rc=0; bash "$compare" cohort --reports "$tmp/cohort/nowhere" > /dev/null 2>&1 || rc=$?
[[ "$rc" == "1" ]] && pass "cohort: no reports directory → exit 1" || fail "cohort: a missing directory gave exit $rc"
mkdir -p "$tmp/cohort/empty"
rc=0; bash "$compare" cohort --reports "$tmp/cohort/empty" > /dev/null 2>&1 || rc=$?
[[ "$rc" == "1" ]] && pass "cohort: an empty reports directory → exit 1" || fail "cohort: an empty directory gave exit $rc"
rc=0; bash "$compare" cohort --exp "$tmp" > /dev/null 2>&1 || rc=$?
[[ "$rc" == "2" ]] && pass "cohort: --exp is a usage error → exit 2" || fail "cohort: --exp gave exit $rc"

echo "test-reader-model-compare: ${passed} passed, ${failures} failed"
(( failures == 0 ))
