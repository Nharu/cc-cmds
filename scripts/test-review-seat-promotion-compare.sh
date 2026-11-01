#!/usr/bin/env bash
# Test scripts/review-seat-promotion-compare.sh against
# tests/fixtures/review-seat-promotion-compare/.
#
# The observe cases read the small reports under observe/, which spell the
# seat attribution every way a report spells it (the formal `**좌석**` line, a
# `·` tail with an agreement clause, a comma tail, a `-reviewer` suffix) and
# every way a report is left out. The pairs cases are built here under
# `mktemp -d` into the exchange format the paired re-review runner writes
# (samples.tsv and reports/<n>-<branch>.md), one case per edge of the rule.
#
# The verdict rule is pinned by constants.golden: a constant changed after the
# experiment breaks it instead of passing in silence. Regenerate it only for
# an intended rule change: SEAT_PROMO_CMP_UPDATE_GOLDEN=1.
#
# The last group reads the review skill files this experiment depends on: the
# template's `**좌석**` skeleton, the fill paragraph of both review skills, and
# review-unattended's branch for a repository with no remote.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/review-seat-promotion-compare"
compare="$script_dir/review-seat-promotion-compare.sh"
template="$repo_root/plugins/cc-cmds/skills/review/references/02-review-report-template.md"
review_skill="$repo_root/plugins/cc-cmds/skills/review/SKILL.md"
unattended_skill="$repo_root/plugins/cc-cmds/skills/review-unattended/SKILL.md"

failures=0
passed=0

pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }

for v in $(compgen -e | grep '^CC_PIPELINE_' || true); do unset "$v"; done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-review-seat-promotion-compare.XXXXXX")
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

# expect_line <label> <file> <exact line>
expect_line() {
  if grep -Fxq -- "$3" "$2"; then pass "$1"; else fail "$1 — no line: $3"; fi
}

# ---------- constants golden -------------------------------------------------

grep -E '^(SAMPLES_REQUIRED|VETO_SAMPLE_MIN|VETO_SUM_MIN|SIGNAL_MIN|DROP_FLOOR|NOISE_FACTOR|NOISE_MAX)=' "$compare" > "$tmp/constants"
if [[ "${SEAT_PROMO_CMP_UPDATE_GOLDEN:-}" == "1" ]]; then
  cp "$tmp/constants" "$fixtures/constants.golden"
  echo "updated: constants.golden"
fi
if cmp -s "$tmp/constants" "$fixtures/constants.golden"; then
  pass "the rule constants match constants.golden"
else
  fail "the rule constants drifted from constants.golden"
  diff "$fixtures/constants.golden" "$tmp/constants" >&2 || true
fi

# ---------- observe ----------------------------------------------------------

obs="$fixtures/observe"
rc=0; bash "$compare" observe --reports "$obs" --out "$tmp/obs.md" 2> "$tmp/obs.err" || rc=$?
if (( rc == 0 )); then pass "observe exits 0 on the fixture reports"; else fail "observe exit $rc: $(cat "$tmp/obs.err")"; fi
expect_line "observe totals: three reports read, every class counted" "$tmp/obs.md" \
  "# observe: 보고서=3 항목=13 승격만=3 표도냄=3 표동의=1 승격동의=2 표만=1 미상=3 상속제외=1"
expect_line "formal field: one item of each class, the misspelt slug counted" "$tmp/obs.md" \
  "| $obs/a-formal.md | 2026-10-20 | logic-shell=opus=authz,shared-contract | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 6 | 0 |"
expect_line "tail forms: · tail, agreement clause, comma tail, -reviewer suffix, unknown seat, inherited, no tail" "$tmp/obs.md" \
  "| $obs/b-tail.md | 2026-10-21 | logic-shell=opus=authz, basis-finding, conformance=opus=basis-finding | 1 | 2 | 0 | 1 | 0 | 2 | 0 | 0 | 1 |"
expect_line "a report with no 모델 티어 block is left out by name" "$tmp/obs.md" "- $obs/c-notier.md — 모델 티어 없음"
expect_line "a report with a heading-form item is left out by name" "$tmp/obs.md" "- $obs/d-headform.md — 머리형 항목"
if grep -Fq "f-x.lead-fix.md" "$tmp/obs.md"; then
  fail "the lead-fix record was read as a report"
else
  pass "the lead-fix record is not read as a report"
fi
expect_line "the header counts the lead-fix record apart" "$tmp/obs.md" \
  "- 디렉터리: $obs — 보고서 5건 (리드 수정 기록 1건은 보고서가 아니어서 읽지 않음)"
if grep -Fq ".hidden.md" "$tmp/obs.md"; then fail "a dot file was read"; else pass "a dot file is not read"; fi
if grep -Fq "b.sh:8" "$tmp/obs.md" || ! grep -Fq "상속제외=1" "$tmp/obs.md"; then
  fail "an item outside the P0 and P1 sections was counted"
else
  pass "the 재확인 and P2 items are not counted"
fi
expect_line "승격만 per trigger: authz counted from two reports" "$tmp/obs.md" "| authz | 2 |"
expect_line "승격만 per trigger: the union of two promoted seats counts basis-finding once" "$tmp/obs.md" "| basis-finding | 1 |"
expect_line "승격만 per trigger: concurrency from the oldest report" "$tmp/obs.md" "| concurrency | 1 |"
expect_line "승격만 per trigger: shared-contract" "$tmp/obs.md" "| shared-contract | 1 |"

bash "$compare" observe --reports "$obs" --since 2026-10-01 --out "$tmp/since.md"
expect_line "--since leaves the older report out" "$tmp/since.md" "- $obs/e-old.md — 날짜 범위 밖"
expect_line "--since totals" "$tmp/since.md" \
  "# observe: 보고서=2 항목=12 승격만=2 표도냄=3 표동의=1 승격동의=2 표만=1 미상=3 상속제외=1"
bash "$compare" observe --reports "$obs" --since 2026-10-20 --out "$tmp/since-eq.md"
if grep -Fq "a-formal.md — 날짜 범위 밖" "$tmp/since-eq.md"; then
  fail "a report dated on the --since day was left out"
else
  pass "a report dated on the --since day is read"
fi

mkdir -p "$tmp/nodate"
grep -v '리뷰 날짜' "$obs/a-formal.md" > "$tmp/nodate/x.md"
rc=0; bash "$compare" observe --reports "$tmp/nodate" --out "$tmp/nodate.md" 2> "$tmp/nodate.err" || rc=$?
if (( rc == 1 )) && grep -Fq "날짜 없음" "$tmp/nodate.err"; then
  pass "a report with no 리뷰 날짜 is left out, and no report left exits 1"
else
  fail "no-date report: exit $rc, $(cat "$tmp/nodate.err")"
fi

rc=0; bash "$compare" observe --reports "$tmp/absent" --out "$tmp/absent.md" 2> "$tmp/absent.err" || rc=$?
if (( rc == 1 )) && grep -Fq "$tmp/absent: 디렉터리 없음" "$tmp/absent.err"; then
  pass "a directory that does not exist is named with 디렉터리 없음"
else
  fail "absent directory: exit $rc, $(cat "$tmp/absent.err")"
fi

rc=0; bash "$compare" observe --exp "$tmp" 2> /dev/null || rc=$?
if (( rc == 2 )); then pass "observe refuses a pairs argument with exit 2"; else fail "observe --exp exit $rc"; fi
rc=0; bash "$compare" 2> /dev/null || rc=$?
if (( rc == 2 )); then pass "no subcommand exits 2"; else fail "no subcommand exit $rc"; fi

# ---------- scan -------------------------------------------------------------

bash "$compare" scan "$obs/a-formal.md" > "$tmp/scan.tsv"
expect_line "scan: the header line carries the summary counts, HEAD and promoted seats" "$tmp/scan.tsv" \
  "$(printf 'H\t-\t2026-10-20\t정규\t1\t5\t2222222222222222222222222222222222222222\tlogic-shell=opus=authz,shared-contract\t2\t0\t-')"
expect_line "scan: the misspelt item is unknown and flagged" "$tmp/scan.tsv" "$(printf 'I\tP1\t미상\t1\t1\t0\t-')"
expect_line "scan: the 승격만 item carries its triggers" "$tmp/scan.tsv" "$(printf 'I\tP0\t승격만\t1\t0\t1\tauthz,shared-contract')"
bash "$compare" scan "$obs/b-tail.md" > "$tmp/scan-b.tsv"
if awk -F'\t' '$1 == "H" && $10 == 6 { ok = 1 } END { exit !ok }' "$tmp/scan-b.tsv"; then
  pass "scan: non-inherited items without a 좌석 line are counted"
else
  fail "scan: the missing-line count of b-tail is off"
fi
if awk -F'\t' '$1 == "H" && $11 ~ /앵커 없음|태그 밖/ { bad = 1 } END { exit bad }' "$tmp/scan-b.tsv"; then
  pass "scan: a well-formed report has no format problem"
else
  fail "scan: b-tail reported a format problem"
fi
bash "$compare" scan "$fixtures/tail-clauses/comma-agree.md" > "$tmp/scan-comma.tsv"
got=$(awk -F'\t' '$1 == "I" { printf "%s%s", (n++ ? " " : ""), $3 }' "$tmp/scan-comma.tsv")
if [[ "$got" == "미상 승격동의 승격동의 미상" ]]; then
  pass "scan: a comma-listed agreement clause leaves the item 미상, a severity clause is dropped, a ·-listed agreement is read"
else
  fail "scan: the parenthesised clauses were read as [$got]"
fi
bash "$compare" scan "$obs/d-headform.md" > "$tmp/scan-d.tsv"
if awk -F'\t' '$1 == "H" && $2 == "머리형 항목" && $11 ~ /비불릿:1/ { ok = 1 } END { exit !ok }' "$tmp/scan-d.tsv"; then
  pass "scan: a heading-form item is a format problem"
else
  fail "scan: the heading-form report was not flagged"
fi
rc=0; bash "$compare" scan "$tmp/nope.md" 2> /dev/null || rc=$?
if (( rc == 1 )); then pass "scan of a missing file exits 1"; else fail "scan missing file exit $rc"; fi

# ---------- pairs ------------------------------------------------------------

# mk_branch_report <file> <P0> <P1>
mk_branch_report() {
  local f="$1" p0="$2" p1="$3" i
  {
    echo "# 코드 리뷰 보고서"
    echo
    echo "- **리뷰 날짜**: 2026-10-30"
    echo "- **리뷰 HEAD**: \`aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\`"
    echo "- **모델 티어**:"
    echo "    - logic | 부류=logic | 모델=opus | 출처=승격 | 지표=authz | 재기동=-"
    echo "    - quality | 부류=quality | 모델=sonnet | 출처=표 | 지표=- | 재기동=-"
    echo "- **발견 요약**: 🔴 P0 ${p0}건 | 🟠 P1 ${p1}건 | 🟡 P2 0건 | 🟢 P3 0건"
    echo
    echo "## 🔴 P0 — 즉시 수정"
    echo
    for ((i = 1; i <= p0; i++)); do echo "- **[logic]** \`x.sh:${i}\` 항목 — logic"; done
    echo
    echo "## 🟠 P1 — 머지 전 수정"
    echo
    for ((i = 1; i <= p1; i++)); do echo "- **[차단]** **[code-quality]** \`y.sh:${i}\` 항목 — quality"; done
  } > "$f"
}

# mk_exp <dir> <spec>… — each spec is `a,a0,s,s0,b,b0` for one valid sample
# (P0+P1 and P0 of opus-1, sonnet and opus-2), or `invalid` for an invalid one.
mk_exp() {
  local d="$1" n=0 spec a a0 s s0 b b0
  shift
  mkdir -p "$d/reports"
  printf 'n\t보고서\tbase\thead\t상태\t사유\t승격 좌석\n' > "$d/samples.tsv"
  for spec in "$@"; do
    n=$((n + 1))
    if [[ "$spec" == "invalid" ]]; then
      printf '%d\tr%d.md\tb\th\t무효\t한 갈래 보고서 없음\t-\n' "$n" "$n" >> "$d/samples.tsv"
      continue
    fi
    IFS=, read -r a a0 s s0 b b0 <<<"$spec"
    mk_branch_report "$d/reports/${n}-opus-1.md" "$a0" $((a - a0))
    mk_branch_report "$d/reports/${n}-sonnet.md" "$s0" $((s - s0))
    mk_branch_report "$d/reports/${n}-opus-2.md" "$b0" $((b - b0))
    printf '%d\tr%d.md\tb\th\t유효\t-\topus-1=logic;sonnet=logic;opus-2=logic\n' "$n" "$n" >> "$d/samples.tsv"
  done
}

# expect_verdict <label> <expected verdict> <spec>…
case_n=0
expect_verdict() {
  local label="$1" want="$2" d rc
  shift 2
  case_n=$((case_n + 1)); d="$tmp/exp$case_n"
  mk_exp "$d" "$@"
  rc=0; bash "$compare" pairs --exp "$d" 2> "$d/err" || rc=$?
  if (( rc == 0 )) && [[ "$(tail -1 "$d/report.md")" == "# verdict: ${want}" ]]; then
    pass "pairs: $label → $want"
  else
    fail "pairs: $label — exit $rc, last line '$(tail -1 "$d/report.md" 2> /dev/null)', $(cat "$d/err")"
  fi
}

expect_verdict "four valid samples" "판정 불가(표본 수)" 2,0,2,0,2,0 2,0,2,0,2,0 2,0,2,0,2,0 2,0,2,0,2,0 invalid
expect_verdict "six valid samples" "판정 불가(표본 수)" 2,0,2,0,2,0 2,0,2,0,2,0 2,0,2,0,2,0 2,0,2,0,2,0 2,0,2,0,2,0 2,0,2,0,2,0
expect_verdict "the P0 veto at both minimums" "유지" 2,1,1,0,2,1 2,1,1,0,2,1 2,0,2,0,2,0 2,0,2,0,2,0 2,0,2,0,2,0
expect_verdict "a P0 drop in one sample only is no veto" "축소 권고" 3,2,3,0,3,2 2,0,2,0,2,0 2,0,2,0,2,0 2,0,2,0,2,0 2,0,2,0,2,0
expect_verdict "the veto comes before the signal floor" "유지" 1,1,0,0,1,1 1,1,0,0,1,1 0,0,0,0,0,0 0,0,0,0,0,0 0,0,0,0,0,0
expect_verdict "Σo below the signal floor" "판정 불가(신호 부족)" 1,0,1,0,1,0 1,0,1,0,1,0 1,0,1,0,1,0 1,0,1,0,1,0 0,0,0,0,0,0
expect_verdict "Σo exactly at the signal floor" "축소 권고" 1,0,1,0,1,0 1,0,1,0,1,0 1,0,1,0,1,0 1,0,1,0,1,0 1,0,1,0,1,0
expect_verdict "W above the noise ceiling" "판정 불가(변동 폭 과다)" 3,0,2,0,1,0 3,0,2,0,1,0 3,0,2,0,1,0 2,0,2,0,2,0 2,0,2,0,2,0
expect_verdict "W exactly at the noise ceiling" "축소 권고" 8,0,7,0,6,0 8,0,7,0,6,0 8,0,7,0,6,0 7,0,7,0,7,0 7,0,7,0,7,0
expect_verdict "D above the floor" "유지" 4,0,2,0,4,0 4,0,2,0,4,0 4,0,2,0,4,0 4,0,4,0,4,0 4,0,4,0,4,0
expect_verdict "D exactly at the floor" "축소 권고" 4,0,3,0,4,0 4,0,3,0,4,0 4,0,3,0,4,0 4,0,4,0,4,0 4,0,4,0,4,0
expect_verdict "D above the floor but not above 2W" "축소 권고" 10,0,5,0,8,0 10,0,5,0,8,0 10,0,5,0,8,0 9,0,9,0,9,0 9,0,9,0,9,0
expect_verdict "D above 2W" "유지" 10,0,4,0,8,0 10,0,4,0,8,0 10,0,4,0,8,0 9,0,9,0,9,0 9,0,9,0,9,0

# The report beside the verdict: per-sample metrics and the aux metrics.
d="$tmp/exp3"
expect_line "pairs report: a sample row carries a, b, s, a0, b0, s0, 변동 and 하락" "$d/report.md" \
  "| 1 | 2 | 2 | 1 | 1 | 1 | 0 | 2.0 | 0.000 | 0.333 |"
expect_line "pairs report: the veto is shown fired" "$d/report.md" "- 발동: 예"
expect_line "pairs report: items a promoted seat raised are summed" "$d/report.md" "- 승격 좌석이 낸 항목 수(유효 표본 갈래 합): 4"
expect_line "pairs report: a sample with one promoted-seat set is not counted as differing" "$d/report.md" \
  "- 갈래끼리 승격 좌석 집합이 다른 유효 표본: 0"
d="$tmp/exp1"
expect_line "pairs report: an invalid sample is listed with its reason" "$d/report.md" "- 표본 5 (r5.md): 무효 — 한 갈래 보고서 없음"

d="$tmp/exp-diff"
mk_exp "$d" 2,0,2,0,2,0 2,0,2,0,2,0 2,0,2,0,2,0 2,0,2,0,2,0 2,0,2,0,2,0
awk -F'\t' 'BEGIN { OFS = "\t" } NR == 2 { $7 = "opus-1=logic;sonnet=logic,quality;opus-2=logic" } { print }' "$d/samples.tsv" > "$d/s.tmp"
mv "$d/s.tmp" "$d/samples.tsv"
bash "$compare" pairs --exp "$d" --out "$d/r.md"
expect_line "pairs report: a sample whose branches promoted different seats is counted" "$d/r.md" \
  "- 갈래끼리 승격 좌석 집합이 다른 유효 표본: 1"

d="$tmp/exp-missing"
mk_exp "$d" 2,0,2,0,2,0 2,0,2,0,2,0 2,0,2,0,2,0 2,0,2,0,2,0 2,0,2,0,2,0
rm "$d/reports/3-sonnet.md"
rc=0; bash "$compare" pairs --exp "$d" 2> "$d/err" || rc=$?
if (( rc == 1 )) && grep -Fq "3-sonnet.md" "$d/err"; then
  pass "pairs: a valid sample without its report exits 1 and names the slot"
else
  fail "pairs: missing slot — exit $rc, $(cat "$d/err")"
fi
rc=0; bash "$compare" pairs 2> /dev/null || rc=$?
if (( rc == 2 )); then pass "pairs without --exp exits 2"; else fail "pairs without --exp exit $rc"; fi

# ---------- the review skill files -------------------------------------------

skel_n=$(grep -c '^    - \*\*좌석\*\*: 낸=<role-slug>\[,<role-slug>\] | 동의=<role-slug>\[,<role-slug>\]|-$' "$template" || true)
if [[ "$skel_n" == "3" ]]; then
  pass "template: the P0 skeleton and both P1 skeletons carry the 좌석 line"
else
  fail "template: $skel_n skeletons carry the 좌석 line, want 3"
fi
if grep -Fq '`**좌석**` line is the' "$template" || grep -Fq '`**좌석**` 줄' "$template"; then
  pass "template: the 좌석 line's rule is written down"
else
  fail "template: the 좌석 line's rule is missing"
fi
for f in "$review_skill" "$unattended_skill"; do
  if grep -Fq "**Fill every P0 and P1 item's \`**좌석**\` line.**" "$f"; then
    pass "$(basename "$(dirname "$f")"): the 좌석 fill paragraph is present"
  else
    fail "$(basename "$(dirname "$f")"): the 좌석 fill paragraph is missing"
  fi
done
if grep -Fq '**A branch target in a repository with no remote skips the three checks.**' "$unattended_skill"; then
  pass "review-unattended: the no-remote branch is present"
else
  fail "review-unattended: the no-remote branch is missing"
fi
if grep -Fq '원격 없는 저장소의 브랜치 대상은 예외다' "$unattended_skill"; then
  pass "review-unattended: the --base-sha parse note names the no-remote exception"
else
  fail "review-unattended: the --base-sha parse note lacks the no-remote exception"
fi
if grep -Fq 'A branch target in a repository with no remote is the exception' "$unattended_skill"; then
  pass "review-unattended: the --base-sha fallback names the no-remote exception"
else
  fail "review-unattended: the --base-sha fallback lacks the no-remote exception"
fi

echo
echo "test-review-seat-promotion-compare: ${passed} passed, ${failures} failed"
(( failures == 0 ))
