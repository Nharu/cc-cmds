#!/usr/bin/env bash
# Test scripts/review-seat-promotion-pair.sh against a fixture repository built
# here under `mktemp -d`, the model CLI stub
# tests/fixtures/review-seat-promotion-pair/claude-stub.sh and the GitHub CLI
# stub tests/fixtures/review-seat-promotion-pair/gh-stub.sh, which answers
# pull request 11 only.
#
# The fixture repository carries the plugin pieces the runner reads at commit
# C (tests/fixtures/review-seat-promotion-pair/plugin/: the tier file with the
# three sentences the sonnet branch changes, and stand-ins of the driver, the
# gate, the stage wrapper, the stage policy and the personal-rules extractor),
# the compare script, a linear history with one head and one fix commit per
# review, and untracked docs/: the past review reports, two run manifests and
# their ledgers.
#
# The stub records each call's arguments and environment and writes the report
# its plan names, so every validity reason, the reserve, the cost rows, the
# budget guard and the pilot are driven without a model.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/review-seat-promotion-pair"
pair="$script_dir/review-seat-promotion-pair.sh"

failures=0
passed=0

pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }

for v in $(compgen -e | grep '^CC_PIPELINE_' || true); do unset "$v"; done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-review-seat-promotion-pair.XXXXXX")
tmp=$(cd "$tmp" && pwd -P)
# SEAT_PROMO_PAIR_KEEP=1 keeps the scratch tree for a failing run.
if [[ "${SEAT_PROMO_PAIR_KEEP:-}" == "1" ]]; then echo "scratch: $tmp"; else trap 'rm -rf "$tmp"' EXIT; fi

# The runner reads the account's CLAUDE.md, settings.json and the host source
# map through HOME and CLAUDE_CONFIG_DIR: both point inside the fixture.
export HOME="$tmp/home"
export CLAUDE_CONFIG_DIR="$tmp/cfg"
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR"
printf '# account rules\n\n- fixture personal rule\n' > "$CLAUDE_CONFIG_DIR/CLAUDE.md"
printf '{"enabledPlugins":{"cc-cmds@cc-cmds":true,"other@market":true}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
# The lane directory's paths and file contents before any runner call; the
# runner never writes there.
lane_list() { (cd "$CLAUDE_CONFIG_DIR" && find . | LC_ALL=C sort && find . -type f | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done); }
lane_list > "$tmp/lane.before"
export GIT_AUTHOR_NAME=fx GIT_AUTHOR_EMAIL=fx@localhost GIT_COMMITTER_NAME=fx GIT_COMMITTER_EMAIL=fx@localhost
export GIT_AUTHOR_DATE=2026-01-02T00:00:00Z GIT_COMMITTER_DATE=2026-01-02T00:00:00Z
export PROMO_EXP_STATE_ROOT="$tmp/state"
cp "$fixtures/claude-stub.sh" "$tmp/claude-stub"
chmod 755 "$tmp/claude-stub"
export PROMO_EXP_CLAUDE_BIN="$tmp/claude-stub"
export STUB_DIR="$tmp/stub-none"
cp "$fixtures/gh-stub.sh" "$tmp/gh-stub"
chmod 755 "$tmp/gh-stub"
export PROMO_EXP_GH_BIN="$tmp/gh-stub"
export GH_STUB_DIR="$tmp/gh-prs"
mkdir -p "$GH_STUB_DIR"
# Pull request 11 has a title, a body of several lines with a double quote,
# and two labels; no other pull request exists.
pr_body=$(printf '첫 줄 "인용"\n\n둘째 단락')
jq -n --arg b "$pr_body" '{title: "feat(x): 픽스처 PR", body: $b, labels: [{name: "bug"}, {name: "autopilot"}]}' > "$GH_STUB_DIR/11.json"

# expect_eq <label> <want> <got>
expect_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 — want [$2], got [$3]"; fi
}

# expect_rc <label> <want> <got> <stderr file>
expect_rc() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 — exit $3, want $2: $(tail -n 3 "$4" 2>/dev/null | tr '\n' ' ')"; fi
}

expect_line() {
  if grep -Fxq -- "$3" "$2"; then pass "$1"; else fail "$1 — no line: $3"; fi
}

# runner <out file> <args…> — the runner with two pipeline variables to leak.
runner() {
  local out="$1"; shift
  local rc=0
  CC_PIPELINE_RUN_ID=leak CC_PIPELINE_STAGE_ID=leak bash "$pair" "$@" > "$out" 2> "$out.err" || rc=$?
  return "$rc"
}

# ---------- the fixture repository -------------------------------------------

R="$tmp/repo"
mkdir -p "$R"
cd "$R"
git init -q -b master
# select resolves the pull request field's repository from this origin.
git remote add origin https://github.com/fx/repo.git
mkdir -p plugins/cc-cmds scripts
cp -R "$fixtures/plugin/." plugins/cc-cmds/
cp "$repo_root/scripts/review-seat-promotion-compare.sh" scripts/
printf '# fixture repo rules\n' > CLAUDE.md
git add -A
git commit -q -m "c0"
c0=$(git rev-parse HEAD)
for s in A B C D E F G H I J K L M; do
  printf '%s\n' "$s" > "f-$s.sh"
  git add -A
  git commit -q -m "head $s"
  eval "h_$s=\$(git rev-parse HEAD)"
  eval "p_$s=\$(git rev-parse HEAD~1)"
  printf 'fix\n' >> "f-$s.sh"
  git commit -q -am "fix $s"
  eval "x_$s=\$(git rev-parse HEAD)"
done
C=$(git rev-parse HEAD)
git checkout -q -b gone
printf 'u\n' > u.sh
git add -A
git commit -q -m "unreachable"
h_U=$(git rev-parse HEAD)
git checkout -q master
git branch -q -D gone
cd "$tmp"

rid1=20261001-0000000a
rid2=20261002-0000000c
rid3=20261009-0000000b
mkdir -p "$R/docs/reviews" "$R/docs/pipeline-run"
printf '# 설계 x\n\n본문\n' > "$R/docs/design-x.md"

# mk_report <name> <range or -> <review head> <p0> <p1> <promoted 1|0> <slice line> [mode] [PR line]
mk_report() {
  local f="$R/docs/reviews/$1" i
  {
    printf '# 코드 리뷰 보고서\n\n## 개요\n\n'
    printf -- '- **리뷰 날짜**: 2026-10-20\n'
    if [[ "$2" == "-" ]]; then printf -- '- **리뷰 대상**: 브랜치 `seg/x`\n'
    else printf -- '- **리뷰 대상**: 브랜치 `seg/x`, 커밋 범위 `%s`\n' "$2"; fi
    [[ -z "${9:-}" ]] || printf -- '- **PR**: %s\n' "$9"
    printf -- '- **리뷰 모드**: %s\n' "${8:-전체}"
    printf -- '- **슬라이스 범위**: %s\n' "$7"
    printf -- '- **리뷰 HEAD**: `%s`\n' "$3"
    printf -- '- **모델 티어**:\n'
    [[ "$6" != 1 ]] || printf '    - logic-shell | 부류=logic | 모델=opus | 출처=승격 | 지표=authz | 재기동=-\n'
    printf '    - code-quality | 부류=quality | 모델=sonnet | 출처=표 | 지표=- | 재기동=-\n'
    printf -- '- **발견 요약**: 🔴 P0 %s건 | 🟠 P1 %s건 | 🟡 P2 0건 | 🟢 P3 0건\n\n' "$4" "$5"
    printf '## 🔴 P0 — 즉시 수정\n\n'
    i=0; while (( i < $4 )); do printf -- '- **[logic]** `f.sh:%s` 항목 — logic-shell\n    - **좌석**: 낸=logic-shell | 동의=-\n' "$i"; i=$((i + 1)); done
    printf '\n## 🟠 P1 — 머지 전 수정\n\n'
    i=0; while (( i < $5 )); do printf -- '- **[차단]** **[code-quality]** `f.sh:1%s` 항목 — code-quality\n    - **좌석**: 낸=code-quality | 동의=-\n' "$i"; i=$((i + 1)); done
  } > "$f"
}

none='적용 안 됨 — 인자 없음'
mk_report "seg-$rid1-A-cycle1.md" "$p_A..$h_A" "$h_A" 1 0 1 "$none" '전체 (델타 아님)' '#11 — feat(x): 픽스처 PR'
mk_report "seg-$rid1-A-cycle2.md" "$p_A..$h_A" "$h_A" 1 2 1 "$none"
mk_report "$rid1-B-c1.md" "${c0:0:7}...${h_B:0:7}" "$h_B" 1 1 1 '슬라이스 B (구현 슬라이싱의 B)'
mk_report "seg-$rid1-C-cycle1.md" "$p_C..$h_C" "$h_C" 1 2 1 '적용 안 됨 — 설계 문서 없음'
mk_report "seg-$rid1-D-cycle1.md" "$p_D..$h_D" "$h_D" 2 2 1 "$none" "" '없음 — 로컬 모드(브랜치 직접 리뷰)'
mk_report "seg-$rid1-E-cycle1.md" "$p_E..$h_E" "$h_E" 2 3 1 "$none" "" '해당 없음 — 브랜치 대상 리뷰 (로컬 diff 모드)'
mk_report "seg-$rid1-O-cycle1.md" "$p_K..$h_K" "$h_K" 1 1 1 "$none" "" '#99 — 지워진 PR'
mk_report "seg-$rid1-P-cycle1.md" "$p_K..$h_K" "$h_K" 1 1 1 "$none" "" '나중에 정한다'
mk_report "seg-$rid2-F-cycle1.md" "$p_F..$h_F" "$h_F" 3 3 1 "$none"
mk_report "seg-$rid1-G-cycle1.md" "$p_G..$h_G" "$h_A" 1 1 1 "$none"
mk_report "seg-$rid1-H-cycle1.md" "$p_H..$h_U" "$h_U" 1 1 1 "$none"
mk_report "seg-$rid1-I-cycle1.md" "$p_I..$h_I" "$h_I" 0 0 1 "$none"
mk_report "seg-$rid3-J-cycle1.md" "$p_J..$h_J" "$h_J" 1 1 1 "$none"
mk_report "seg-$rid1-K-cycle1.md" "$p_K..$h_K" "$h_K" 1 1 0 "$none"
mk_report "seg-$rid1-L-cycle1.md" "-" "$h_L" 1 1 1 "$none"
mk_report "seg-$rid1-M-cycle1.md" "$p_M..$h_M" "$h_M" 1 1 1 "$none" '전체 (상한 사이클 2 재확인, `--recheck`)'
mk_report "seg-$rid1-N-cycle1.md" "$p_M..$h_M" "$h_M" 1 1 1 "$none" '델타 (기준 사이클 1)'
mk_report ".hidden.md" "$p_A..$h_A" "$h_A" 1 1 1 "$none"
mk_report "seg-$rid1-A-cycle1.lead-fix.md" "$p_A..$h_A" "$h_A" 1 1 1 "$none"

{
  printf '# 런 매니페스트\n\n**런 id**: %s\n**앵커 종류**: doc\n**앵커 키**: design-x\n' "$rid1"
  printf '```text\n대상 맵\n```\n\n**설계 문서**: docs/design-x.md\n\n```json\n{\n  "review_expand": ["perf"]\n}\n```\n'
} > "$R/docs/pipeline-run/$rid1.plan.md"
{
  printf '# 런 매니페스트\n\n**런 id**: %s\n**앵커 종류**: intent\n**앵커 키**: fx-intent\n' "$rid2"
  printf '**설계 문서**: (없음)\n\n```json\n{\n  "review_expand": []\n}\n```\n'
} > "$R/docs/pipeline-run/$rid2.plan.md"
printf '`f-E.sh`, `docs/long.md`\n' > "$tmp/declared.E"
{
  printf '# 원장\n\n'
  for s in A B C D G H I K L M O P; do
    printf -- '- `segment` | id=%s | 상태=시작 | 선언 파일 집합=`f-%s.sh`, `README.md` | 베이스 sha=x\n' "$s" "$s"
  done
  printf -- '- `segment` | id=E | 상태=시작 | 선언 파일 집합=`f-E.…(잘림) (전체: %s) | 베이스 sha=x\n' "$tmp/declared.E"
} > "$R/docs/pipeline-run/$rid1.md"
printf '# 원장\n\n- `segment` | id=F | 상태=시작 | 선언 파일 집합=- | 베이스 sha=x\n' > "$R/docs/pipeline-run/$rid2.md"

nA="seg-$rid1-A-cycle1.md"; nB="$rid1-B-c1.md"; nC="seg-$rid1-C-cycle1.md"
nD="seg-$rid1-D-cycle1.md"; nE="seg-$rid1-E-cycle1.md"; nF="seg-$rid2-F-cycle1.md"
directive_tail='이 세션은 파이프라인 런 밖에서 직접 띄운 리뷰다'

# ---------- usage ------------------------------------------------------------

mkdir -p "$tmp/empty"
rc=0; runner "$tmp/u1" run --repo "$R" || rc=$?
expect_rc "run without --budget-usd exits 2" 2 "$rc" "$tmp/u1.err"
rc=0; runner "$tmp/u2" --bogus --repo "$R" || rc=$?
expect_rc "an unknown argument exits 2" 2 "$rc" "$tmp/u2.err"
rc=0; runner "$tmp/u3" run --exp-id nope --budget-usd 10 --repo "$R" || rc=$?
expect_rc "a malformed --exp-id exits 2" 2 "$rc" "$tmp/u3.err"
rc=0; runner "$tmp/u4" run --dry-run --repo "$tmp/empty" || rc=$?
expect_rc "a --repo without docs/reviews/ exits 2" 2 "$rc" "$tmp/u4.err"
rc=0; runner "$tmp/u5" status --repo "$R" || rc=$?
expect_rc "status without --exp-id exits 2" 2 "$rc" "$tmp/u5.err"
rc=0; runner "$tmp/u6" --rerun-sample 6 --exp-id 20261101-0000aaaa --budget-usd 10 --repo "$R" || rc=$?
expect_rc "--rerun-sample past the sample count exits 2" 2 "$rc" "$tmp/u6.err"

# ---------- dry run ----------------------------------------------------------

D1=20261101-0000d001
E="$R/docs/review-seat-promotion-pair/$D1"
S="$tmp/state/$D1"
export STUB_DIR="$tmp/stub-d1"
rc=0; runner "$tmp/d1" run --dry-run --exp-id "$D1" --repo "$R" || rc=$?
expect_rc "the dry run exits 0" 0 "$rc" "$tmp/d1.err"
if [[ ! -d "$STUB_DIR/calls" ]]; then pass "the dry run never calls the model CLI"; else fail "the dry run called the model CLI"; fi
expect_eq "the dry run prints 15 review command lines" 15 "$(grep -c "^cd '" "$tmp/d1" || true)"
expect_eq "every printed command line passes the caller's lane directory as CLAUDE_CONFIG_DIR" 15 \
  "$(grep "^cd '" "$tmp/d1" | grep -Fc " CLAUDE_CONFIG_DIR='$tmp/cfg' " || true)"
expect_eq "no branch directory gets a config directory of its own" "" "$(find "$S/runs" -mindepth 2 -maxdepth 2 -name config 2>/dev/null)"

sel_row() { awk -F'\t' -v n="$1" '$1 == n { print $2 "|" $3 "|" $4 }' "$E/selection.tsv"; }
expect_eq "quantile 1 picks the smallest P0+P1" "선정|-|1" "$(sel_row "$nA")"
expect_eq "quantile 2 picks the second" "선정|-|2" "$(sel_row "$nB")"
expect_eq "the left-over candidate is quantile 2's reserve (tie to the smaller quantile)" "예비|-|2" "$(sel_row "$nC")"
expect_eq "quantile 3" "선정|-|3" "$(sel_row "$nD")"
expect_eq "quantile 4" "선정|-|4" "$(sel_row "$nE")"
expect_eq "quantile 5 picks the largest" "선정|-|5" "$(sel_row "$nF")"
expect_eq "a later cycle of the same segment is left out" "제외|같은 세그먼트 뒤 사이클|-" "$(sel_row "seg-$rid1-A-cycle2.md")"
expect_eq "a range head other than 리뷰 HEAD is left out" "제외|리뷰 HEAD 불일치 (${h_A})|-" "$(sel_row "seg-$rid1-G-cycle1.md")"
expect_eq "a commit no ref reaches is left out" "제외|ref 에서 닿지 않는 커밋|-" "$(sel_row "seg-$rid1-H-cycle1.md")"
expect_eq "P0+P1 of 0 is left out" "제외|P0+P1 이 0 이다|-" "$(sel_row "seg-$rid1-I-cycle1.md")"
expect_eq "a report whose inputs cannot be restored is left out with the field and why" \
  "제외|입력 복원 불가 — 설계 문서: 원 런 매니페스트가 없다 (${rid3})|-" "$(sel_row "seg-$rid3-J-cycle1.md")"
expect_eq "a report without a promoted row is left out" "제외|출처=승격 행이 없다|-" "$(sel_row "seg-$rid1-K-cycle1.md")"
expect_eq "a report without a commit range is left out" "제외|리뷰 대상에 커밋 범위가 없다|-" "$(sel_row "seg-$rid1-L-cycle1.md")"
expect_eq "a cap re-check written as 전체 is left out" "제외|리뷰 모드가 전체가 아니다 (전체 (상한 사이클 2 재확인, \`--recheck\`))|-" "$(sel_row "seg-$rid1-M-cycle1.md")"
expect_eq "a delta review is left out" "제외|리뷰 모드가 전체가 아니다 (델타 (기준 사이클 1))|-" "$(sel_row "seg-$rid1-N-cycle1.md")"
expect_eq "a pull request gh cannot find is left out as 입력 복원 불가" \
  "제외|입력 복원 불가 — PR 제목·본문·라벨: gh pr view #99 조회 실패|-" "$(sel_row "seg-$rid1-O-cycle1.md")"
expect_eq "a PR line that tells nothing is left out as 입력 복원 불가" \
  "제외|입력 복원 불가 — PR 제목·본문·라벨: 원 리뷰가 PR 을 받았는지 가릴 수 없다 (나중에 정한다)|-" "$(sel_row "seg-$rid1-P-cycle1.md")"
expect_line "select reads the pull request from the origin's GitHub repository" "$STUB_DIR/gh-calls" "pr view 11 --repo fx/repo --json title,body,labels"
if ! grep -q -e '^\.hidden\.md' -e 'lead-fix' "$E/selection.tsv"; then pass "hidden and .lead-fix.md files are not read"; else fail "selection.tsv lists a hidden or .lead-fix.md file"; fi
expect_eq "a three-dot short-sha range resolves to the merge-base and the full head" \
  "${c0}|${h_B}" "$(awk -F'\t' -v n="$nB" '$1 == n { print $5 "|" $6 }' "$E/selection.tsv")"
expect_line "meta records the commit C" "$E/meta" "$(printf 'commit\t%s' "$C")"

# The branches.
go="$S/promo-opus"; gs="$S/promo-sonnet"
expect_eq "promo-opus is C, detached, no remote" "${C}|HEAD|" "$(cd "$go" && git rev-parse HEAD)|$(cd "$go" && git rev-parse --abbrev-ref HEAD)|$(cd "$go" && git remote)"
expect_eq "promo-sonnet's one local commit changes only the tier file's three lines" \
  "$(printf '3\t3\tplugins/cc-cmds/skills/_common/team-model-tier.md')" "$(cd "$gs" && git diff --numstat "$C" HEAD)"
expect_eq "promo-sonnet is one commit past C with no remote" "${C}|" "$(cd "$gs" && git rev-parse HEAD~1)|$(cd "$gs" && git remote)"
tier_s="$gs/plugins/cc-cmds/skills/_common/team-model-tier.md"
if grep -Fq 'A promoted seat runs its class model; the record still writes `출처=승격` and its `지표`.' "$tier_s" \
  && grep -Fq 'the triggers below mark its seat as promoted' "$tier_s" \
  && grep -Fq 'marks as promoted every `sonnet` seat' "$tier_s" \
  && ! grep -Fq 'A promoted seat runs `opus`.' "$tier_s"; then
  pass "promo-sonnet's tier file carries the three new sentences and not the old ones"
else
  fail "promo-sonnet's tier file does not carry the three swaps"
fi

# The target clones.
t1="$S/runs/1-opus-1/target"
expect_eq "the target clone holds only the local branch and refs/exp/base" \
  "$(printf 'refs/exp/base\nrefs/heads/work')" "$(cd "$t1" && git for-each-ref --format='%(refname)' | LC_ALL=C sort)"
expect_eq "the target clone has no remote" "" "$(cd "$t1" && git remote)"
expect_eq "the target branch is checked out at 리뷰 HEAD and the base ref at the range base" \
  "${h_A}|work|${p_A}" "$(cd "$t1" && git rev-parse HEAD)|$(cd "$t1" && git rev-parse --abbrev-ref HEAD)|$(cd "$t1" && git rev-parse refs/exp/base)"
if (cd "$t1" && ! git cat-file -e "${x_A}^{commit}" 2>/dev/null); then pass "the fix commit past 리뷰 HEAD is not in the target clone"; else fail "the target clone still holds the fix commit"; fi
if cmp -s "$S/runs/1-opus-1/inputs" "$S/runs/1-sonnet/inputs" && cmp -s "$S/runs/1-opus-1/inputs" "$S/runs/1-opus-2/inputs"; then
  pass "the three branches of a sample get byte-identical inputs"
else
  fail "the inputs of sample 1 differ across branches"
fi
expect_line "inputs records the design document copy and its sha256" "$S/runs/1-opus-1/inputs" \
  "$(printf '설계 문서\tdocs/design-x.md\t%s' "$(shasum -a 256 "$R/docs/design-x.md" | cut -d' ' -f1)")"
expect_line "inputs records the restored --expand" "$S/runs/1-opus-1/inputs" "$(printf -- '--expand\tperf')"
expect_line "inputs records the bare declared files" "$S/runs/1-opus-1/inputs" "$(printf -- '--declared-files\tf-A.sh, README.md')"
expect_line "inputs records the pull request's number, title, body sha256 and labels" "$S/runs/1-opus-1/inputs" \
  "$(printf 'PR 제목·본문·라벨\t#11\tfeat(x): 픽스처 PR\t본문 sha256 %s\t라벨 bug,autopilot' "$(printf '%s' "$pr_body" | shasum -a 256 | cut -d' ' -f1)")"
expect_line "a report with no PR line restores the PR field as 없음" "$S/runs/2-opus-1/inputs" "$(printf 'PR 제목·본문·라벨\t없음')"
expect_line "a PR line reading 없음 restores the PR field as 없음" "$S/runs/3-opus-1/inputs" "$(printf 'PR 제목·본문·라벨\t없음')"
expect_line "a PR line reading 해당 없음 restores the PR field as 없음" "$S/runs/4-opus-1/inputs" "$(printf 'PR 제목·본문·라벨\t없음')"
pr_piece='이 대상은 로컬 diff 모드라 PR 이 없으므로, 원 리뷰가 받은 PR 메타데이터를 여기 싣는다 — PR #11, 제목: feat(x): 픽스처 PR, 라벨: bug,autopilot, 본문: 첫 줄 \"인용\"'
if grep -Fq -- "$pr_piece" "$S/runs/1-opus-1/prompt" && grep -Fq '둘째 단락" "' "$S/runs/1-opus-1/prompt"; then
  pass "the prompt carries the restored pull request's number, title, labels and body"
else
  fail "sample 1's prompt does not carry the pull request"
fi
if ! grep -Fq 'PR 메타데이터' "$S/runs/2-opus-1/prompt"; then pass "a review that got no pull request gets no PR piece"; else fail "sample 2's prompt carries a PR piece"; fi
expect_line "a run with no design document gets the anchor brief" "$S/runs/5-opus-1/target/docs/anchor-brief-$rid2.md" "# 앵커 브리프 — 설계 문서 없는 런"
expect_line "the anchor brief carries the manifest" "$S/runs/5-opus-1/target/docs/anchor-brief-$rid2.md" "- 앵커 키: fx-intent"
expect_line "no declared files and no --expand restore as 없음" "$S/runs/5-opus-1/inputs" "$(printf -- '--declared-files\t없음')"
if grep -Fq -- '--slice B ' "$S/runs/2-opus-1/prompt"; then pass "the report's slice is restored as --slice"; else fail "no --slice B in sample 2's prompt"; fi
if grep -Fq -- '--declared-files "f-E.sh, docs/long.md"' "$S/runs/4-opus-1/prompt"; then pass "a truncated declared set is read from its full record"; else fail "sample 4's declared files are not the full record"; fi
if ! grep -Fq -- '--declared-files' "$S/runs/5-opus-1/prompt" && ! grep -Fq -- '--expand' "$S/runs/5-opus-1/prompt"; then
  pass "an input the original review did not get is not passed"
else
  fail "sample 5's prompt passes an input the original review did not get"
fi

# The closed list.
env_rows=$(awk 'NR > 1' "$E/session-env.tsv" | wc -l | tr -d ' ')
expect_eq "session-env.tsv holds the closed list's 29 rows" 29 "$env_rows"
expect_line "session-env.tsv header" "$E/session-env.tsv" "$(printf '칸\t종류\t실행기 값\t게이트 review 스테이지 값\t같음\t사유')"
expect_line "the wait ceiling agrees with the gate" "$E/session-env.tsv" "$(printf 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS\t환경 변수\t14400000\t14400000\t같음\t-')"
expect_line "the lead model agrees with the gate's review stage" "$E/session-env.tsv" "$(printf -- '--model\t플래그\topus\topus\t같음\t-')"
expect_line "the lead effort agrees with the gate's review stage" "$E/session-env.tsv" "$(printf -- '--effort\t플래그\tmedium\tmedium\t같음\t-')"
expect_line "the autocompact window agrees with the gate's review stage" "$E/session-env.tsv" "$(printf -- '--autocompact\t플래그\t300000\t300000\t같음\t-')"
expect_line "the config directory row is 같음: the lane directory the gate also gives a stage" "$E/session-env.tsv" \
  "$(printf 'CLAUDE_CONFIG_DIR\t환경 변수\t(호출자가 해석한 레인의 설정 디렉터리)\t(호출자가 해석한 레인의 설정 디렉터리)\t같음\t-')"

# Determinism: a second experiment selects the same.
D2=20261101-0000d002
rc=0; runner "$tmp/d2" run --dry-run --exp-id "$D2" --repo "$R" || rc=$?
if (( rc == 0 )) && cmp -s "$E/selection.tsv" "$R/docs/review-seat-promotion-pair/$D2/selection.tsv"; then
  pass "selection is deterministic"
else
  fail "a second selection differs (exit $rc)"
fi

# A gate whose review stage moved stops the call.
G="$tmp/repo-g"
git clone -q "$R" "$G"
cp -R "$R/docs" "$G/docs"
(cd "$G" && git remote set-url origin https://github.com/fx/repo.git)
(cd "$G" && printf 'stage_launch_flags() { printf -- "--effort high --model opus"; }\n[ "${CC_ORCH_SOURCE_ONLY:-}" = "1" ] && return 0\n' > plugins/cc-cmds/orchestrator/run.sh \
  && git commit -q -am "move the review effort")
rc=0; runner "$tmp/g1" run --dry-run --exp-id 20261101-0000d003 --repo "$G" || rc=$?
if (( rc == 1 )) && grep -q 'the closed list disagrees' "$tmp/g1.err"; then pass "a row marked 같음 the gate no longer gives stops the call"; else fail "a moved gate effort did not stop the call (exit $rc)"; fi

# ---------- pilot gate and pilot ---------------------------------------------

P1=20261101-0000e001
E="$R/docs/review-seat-promotion-pair/$P1"
S="$tmp/state/$P1"
export STUB_DIR="$tmp/stub-e1"
mkdir -p "$STUB_DIR"
rc=0; runner "$tmp/m0" run --exp-id "$P1" --budget-usd 1000 --repo "$R" || rc=$?
if (( rc == 1 )) && [[ ! -d "$STUB_DIR/calls" ]]; then pass "the main run stops with exit 1 before any billed call without a passed pilot"; else fail "the main run without a pilot: exit $rc, calls $(ls "$STUB_DIR/calls" 2>/dev/null | wc -l)"; fi

rc=0; runner "$tmp/p1" run --pilot --exp-id "$P1" --budget-usd 1000 --repo "$R" || rc=$?
expect_rc "the pilot exits 0 when it passes" 0 "$rc" "$tmp/p1.err"
expect_eq "the pilot calls one branch once" 1 "$(find "$STUB_DIR/calls" -name '*.argv' | wc -l | tr -d ' ')"
expect_eq "pilot/result says 통과" "통과" "$(head -n 1 "$E/pilot/result")"
if [[ -f "$E/pilot/report.md" ]]; then pass "the pilot report is kept in pilot/"; else fail "no pilot/report.md"; fi
expect_eq "the pilot cost is a costs.tsv row with n=pilot" "pilot|opus-1|0|1.25" "$(awk -F'\t' '$1 == "pilot" { print $1 "|" $2 "|" $5 "|" $6 }' "$E/costs.tsv")"

# The stub's arguments and environment against the closed list.
rd="$S/pilot/opus-1"
lead=$(awk -F'\t' '$1 == "lead" { print $2 }' "$S/instructions.state")
members=$(awk -F'\t' '$1 == "members" { print $2 }' "$S/instructions.state")
prompt=$(cat "$rd/prompt")
{
  printf '%s\n' -p "$prompt" --plugin-dir "$S/promo-opus/plugins/cc-cmds" --settings "$S/settings/pilot-opus-1.json" \
    --model opus --effort medium --strict-mcp-config --autocompact 300000 \
    --append-system-prompt-file "$lead" --append-subagent-system-prompt-file "$members" \
    --exclude-dynamic-system-prompt-sections --no-session-persistence --output-format json --max-budget-usd 150
} > "$tmp/want.argv"
if cmp -s "$tmp/want.argv" "$STUB_DIR/calls/1.argv"; then pass "the review call carries exactly the closed list's flags"; else fail "the review call's arguments differ from the closed list"; diff "$tmp/want.argv" "$STUB_DIR/calls/1.argv" >&2 || true; fi
want_prefix="/cc-cmds:review-unattended work --base-sha ${p_A} --report-path ${rd}/report.md --declared-files \"f-A.sh, README.md\" --expand perf \"설계는 ${rd}/target/docs/design-x.md\" \"${pr_piece}"$'\n\n'"둘째 단락\" \"${directive_tail}"
if [[ "$prompt" == "$want_prefix"* ]]; then pass "the prompt passes the local branch with --base-sha and the restored inputs"; else fail "the prompt is [$prompt]"; fi
if [[ "$prompt" == *"${rd}/halt/review.md"* ]]; then pass "the directive names the branch's halt record path"; else fail "the directive does not name ${rd}/halt/review.md"; fi
for kvp in "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=14400000" "CC_CMDS_STATUSLINE_AUTOINSTALL=0" "XDG_STATE_HOME=$rd/state" \
           "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1" "CLAUDE_CODE_ENABLE_APPEND_SUBAGENT_PROMPT=1" "CLAUDE_CONFIG_DIR=$tmp/cfg"; do
  expect_line "the session gets ${kvp%%=*}" "$STUB_DIR/calls/1.env" "value $kvp"
done
expect_line "the session runs in the target clone" "$STUB_DIR/calls/1.env" "cwd $rd/target"
if ! grep -q '^name CC_PIPELINE_' "$STUB_DIR/calls/1.env"; then pass "the inherited CC_PIPELINE_* are unset"; else fail "a CC_PIPELINE_* reached the session"; fi
{
  compgen -e | grep -v '^CC_PIPELINE_' || true
  printf '%s\n' CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS CC_CMDS_STATUSLINE_AUTOINSTALL XDG_STATE_HOME \
    CLAUDE_CODE_DISABLE_CLAUDE_MDS CLAUDE_CODE_ENABLE_APPEND_SUBAGENT_PROMPT CLAUDE_CONFIG_DIR
} | grep -v -x -e PWD -e OLDPWD -e SHLVL -e _ | LC_ALL=C sort -u > "$tmp/want.names"
awk '$1 == "name" { print $2 }' "$STUB_DIR/calls/1.env" | grep -v -x -e PWD -e OLDPWD -e SHLVL -e _ | LC_ALL=C sort -u > "$tmp/got.names"
if cmp -s "$tmp/want.names" "$tmp/got.names"; then pass "the session's environment adds and removes nothing outside the closed list"; else fail "the session's environment names differ"; diff "$tmp/want.names" "$tmp/got.names" >&2 || true; fi

# The settings and the instruction files.
st="$S/settings/pilot-opus-1.json"
expect_eq "the settings turn the account's plugins off" "false|false" "$(jq -r '[.enabledPlugins["cc-cmds@cc-cmds"], .enabledPlugins["other@market"]] | map(tostring) | join("|")' "$st")"
expect_eq "the settings refuse push and network tools, and a mktemp that climbs out with .." "true|true|true|true" \
  "$(jq -r '[(.permissions.deny | index("Bash(git push:*)") != null), (.permissions.deny | index("WebFetch") != null), (.permissions.deny | index("Bash(gh:*)") != null), (.permissions.deny | index("Bash(mktemp *..*)") != null)] | map(tostring) | join("|")' "$st")"
expect_eq "the settings open writes in the target clone, the state home, the halt directory and the report file itself" "true|true|true|true" \
  "$(jq -r --arg t "Edit(/$rd/target/**)" --arg s "Edit(/$rd/state/**)" --arg h "Edit(/$rd/halt/**)" --arg r "Edit(/$rd/report.md)" \
    '.permissions.allow as $a | [$t, $s, $h, $r] | map(. as $x | $a | index($x) != null) | map(tostring) | join("|")' "$st")"
expect_eq "the settings run in acceptEdits, carry no Write rule and no rule under the report path, and add only the state home and the halt directory" \
  "acceptEdits|0|0|$rd/state $rd/halt" \
  "$(jq -r --arg r "Edit(/$rd/report.md/**)" '[.permissions.defaultMode, ([.permissions.allow[] | select(startswith("Write("))] | length), ([.permissions.allow[] | select(. == $r)] | length), (.permissions.additionalDirectories | join(" "))] | map(tostring) | join("|")' "$st")"
pdx="$S/promo-opus/plugins/cc-cmds"
expect_eq "the settings open the plugin's scripts below its directory, a path naming .. refused, and no :* plugin rule" \
  "Bash(bash $pdx/*)|Bash($pdx/*)|Bash(bash $pdx/*..*)|Bash($pdx/*..*)|0" \
  "$(jq -r --arg p "$pdx" '[(.permissions.allow[] | select(. == ("Bash(" + $p + "/*)") or . == ("Bash(bash " + $p + "/*)"))), (.permissions.deny[] | select(. == ("Bash(" + $p + "/*..*)") or . == ("Bash(bash " + $p + "/*..*)"))), ([.permissions.allow[] | select(contains($p) and endswith(":*)"))] | length)] | map(tostring) | join("|")' "$st")"
expect_eq "the settings refuse a second mktemp template and the other network copy tools" "true|true|true|true|true|true|true" \
  "$(jq -r '[("Bash(mktemp *X *)", "Bash(mktemp *X\" *)", "Bash(scp:*)", "Bash(rsync:*)", "Bash(nc:*)", "Bash(git clone:*)", "Bash(git ls-remote:*)") as $x | (.permissions.deny | index($x) != null)] | map(tostring) | join("|")' "$st")"
expect_eq "the settings open mktemp only under the state home and the halt directory" \
  "Bash(mktemp \"$rd/halt/*)|Bash(mktemp \"$rd/state/*)|Bash(mktemp -d \"$rd/halt/*)|Bash(mktemp -d \"$rd/state/*)|Bash(mktemp -d $rd/halt/*)|Bash(mktemp -d $rd/state/*)|Bash(mktemp $rd/halt/*)|Bash(mktemp $rd/state/*)" \
  "$(jq -r '[.permissions.allow[] | select(startswith("Bash(mktemp"))] | sort | join("|")' "$st")"

# The witness hook, fed the commands as the team protocol writes them: the
# member header's temp and publish commands and the checkpoint clause's mkdir.
expect_eq "the settings register one Bash PreToolUse hook" 1 "$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash")] | length' "$st")"
hc=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command' "$st")
# hook_says <command> — the hook's decision for a Bash call, `none` for none.
hook_says() {
  local out
  out=$(jq -n --arg c "$1" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}' | bash -c "$hc" 2>/dev/null) || { echo error; return 0; }
  [[ -n "$out" ]] || { echo none; return 0; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null || echo unparsed
}
proto="$repo_root/plugins/cc-cmds/skills/_common/agent-team-protocol.md"
wp="$rd/state/cc-cmds/design/cc-team-witness-review-x.Ab12Cd/logic.round-1.md"
# from_proto <protocol text> — the text with the header's escaped quotes undone
# and its placeholders filled for one witness.
from_proto() { printf '%s' "$1" | sed -e 's/\\"/"/g' -e "s|{WITNESS_PATH}|$wp|g" -e 's/{role-slug}/logic/g' -e 's|{round/phase}|round-1|g'; }
p_mk=$(grep -oE 'T=\$\(mktemp \\"\$\(dirname \{WITNESS_PATH\}\)/[^ `]*\\"\)' "$proto" | head -n 1 || true)
p_mv=$(grep -oE 'mv -n \\"\$T\\" \{WITNESS_PATH\}' "$proto" | head -n 1 || true)
p_mkd=$(grep -oE 'mkdir -p "\$\(dirname \{WITNESS_PATH\}\)/partial"' "$proto" | head -n 1 || true)
if [[ -n "$p_mk" && -n "$p_mv" && -n "$p_mkd" ]]; then pass "the protocol still writes the three witness commands the hook is fed"; else fail "a witness command is gone from $proto: [$p_mk] [$p_mv] [$p_mkd]"; fi
c_mk=$(from_proto "$p_mk"); c_mv=$(from_proto "$p_mv"); c_mkd=$(from_proto "$p_mkd")
pdir=$(dirname "$wp")/partial
expect_eq "the hook allows the protocol's witness commands below the state home and the halt directory" \
  "allow|allow|allow|allow|allow|allow|allow" \
  "$(hook_says "$c_mk")|$(hook_says "$c_mk && echo \"\$T\"")|$(hook_says "$c_mk"$'\n'"$c_mv")|$(hook_says "mv -n $(dirname "$wp")/.logic.round-1.Qw3rTy $wp")|$(hook_says "$c_mkd")|$(hook_says "mv \"$pdir/.p.Zx9\" \"$pdir/logic.round-1.md\"")|$(hook_says "T=\$(mktemp \"$rd/halt/.review.XXXXXX\")")"
expect_eq "the hook gives no decision outside those directories, past .., to another command or to an unknown variable" \
  "none|none|none|none|none|none|none|none|none|none" \
  "$(hook_says "T=\$(mktemp \"$rd/target/.x.XXXXXX\")")|$(hook_says "mktemp \"$rd/state/../prompt.XXXXXX\"")|$(hook_says "mkdir -p $rd/state-other/x")|$(hook_says "$c_mk && curl https://example.com")|$(hook_says "$c_mv")|$(hook_says "mv -n \"\$U\" $wp")|$(hook_says "mv -n /etc/hosts $wp")|$(hook_says "$c_mk; rm -rf $rd/state")|$(hook_says "mkdir -p $rd/state/x & curl x")|$(hook_says "mkdir -p $rd/state/x | tee y")"
# A dirname operand ending in `/` or holding `//` prints a directory above the
# one the text names, so the hook does not resolve it.
expect_eq "the hook gives no decision to a dirname operand ending in / or holding //" "none|none|none" \
  "$(hook_says "mkdir -p \"\$(dirname $rd/state/)/escaped\"")|$(hook_says "mkdir -p \"\$(dirname \$(dirname \$(dirname $rd/state/a////)))/evil\"")|$(hook_says "mv $rd/state/x \"\$(dirname $rd/halt/)/report.md\"")"
# The body of a quoted-delimiter heredoc is literal; an unquoted one expands.
expect_eq "the hook allows the temp, a quoted heredoc into it and the publish in one call, and not an unquoted heredoc" "allow|none" \
  "$(hook_says "$c_mk && cat > \"\$T\" <<'EOF'"$'\n'"body \$(curl x) | rm -rf /"$'\n'"EOF"$'\n'"$c_mv")|$(hook_says "$c_mk && cat > \"\$T\" <<EOF"$'\n'"\$(curl x)"$'\n'"EOF"$'\n'"$c_mv")"
ml="$rd/witness-misses.log"
hook_says "ls $rd" > /dev/null
jq -n --arg c "mktemp /tmp/y.XXXXXX" '{tool_name: "Bash", agent_id: "m1", tool_input: {command: $c}}' | bash -c "$hc" > /dev/null 2>&1 || true
expect_eq "the hook logs each undecided call naming mktemp, mv or mkdir with its agent, and nothing else" \
  "15|m1	mktemp /tmp/y.XXXXXX" "$(awk 'END { print NR }' "$ml")|$(tail -n 1 "$ml")"
rm -f "$ml"
if grep -Fxq '# Personal rules' "$lead" && grep -Fxq -- '- fixture personal rule' "$lead" && grep -Fxq '# fx/repo/CLAUDE.md' "$lead" && grep -Fxq '# fixture repo rules' "$lead"; then
  pass "the lead instructions are the policy, the personal rules and the repository chain"
else
  fail "the lead instructions miss a part"
fi
if grep -Fxq "$R/CLAUDE.md" "$members" && ! grep -Fxq '# fixture repo rules' "$members"; then pass "the members instructions name the root file by path"; else fail "the members instructions carry the root file's text"; fi

# ---------- the main run -----------------------------------------------------

printf '2-sonnet#1\tnoreport\n2-opus-1#2\tbadformat\n3-opus-2#1\thalt\n4-sonnet#1\ttwoseats\n5-opus-1#1\tnocost\n' > "$STUB_DIR/plan"
rc=0; runner "$tmp/m1" run --exp-id "$P1" --budget-usd 1000 --repo "$R" || rc=$?
expect_rc "the main run exits 0 with a verdict written" 0 "$rc" "$tmp/m1.err"
samp() { awk -F'\t' -v n="$1" '$1 == n { print $2 "|" $5 "|" $6 "|" $7 }' "$E/samples.tsv"; }
expect_eq "sample 1 is valid with each branch's promoted seats" "$nA|유효|-|opus-1=logic-shell;sonnet=logic-shell;opus-2=logic-shell" "$(samp 1)"
if grep -Fq "sample 2: invalid — sonnet: 보고서 없음; next reserve" "$tmp/m1"; then pass "a branch the stub wrote no report for is 보고서 없음 and the slot moves to its reserve"; else fail "no 보고서 없음 for sample 2's sonnet branch"; fi
expect_eq "a branch report failing the format check is 보고서 형식, and the slot ends when its reserves are used" \
  "$nC|무효|opus-1: 보고서 형식 (항목 수)|opus-1=logic-shell;sonnet=-;opus-2=-" "$(samp 2)"
expect_eq "a halt record in the branch's halt directory is attached to the reason" \
  "$nD|무효|opus-2: 보고서 없음 — gate-unanswerable 사전 점검이 멈췄다|opus-1=logic-shell;sonnet=logic-shell;opus-2=-" "$(samp 3)"
expect_eq "branches with different promoted sets stay valid" "$nE|유효|-|opus-1=logic-shell;sonnet=logic-shell,code-quality;opus-2=logic-shell" "$(samp 4)"
expect_eq "sample 5 is valid" "$nF|유효|-" "$(samp 5 | cut -d'|' -f1-3)"
expect_eq "a call without total_cost_usd is a - row" "-" "$(awk -F'\t' '$1 == "5" && $2 == "opus-1" { print $6 }' "$E/costs.tsv")"
expect_eq "costs.tsv holds the pilot and every call" 16 "$(awk 'NR > 1' "$E/costs.tsv" | wc -l | tr -d ' ')"
expect_eq "every call of all three branches gets the same lane directory as CLAUDE_CONFIG_DIR" \
  "16|16" "$(find "$STUB_DIR/calls" -name '*.env' | wc -l | tr -d ' ')|$(cat "$STUB_DIR"/calls/*.env | grep -Fxc "value CLAUDE_CONFIG_DIR=$tmp/cfg" || true)"
expect_eq "the main run's sessions span the three branches" "opus-1 opus-2 sonnet" \
  "$(awk -F'\t' 'NR > 1 && $1 != "pilot" { print $2 }' "$E/costs.tsv" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')"
if [[ -f "$E/reports/1-opus-1.md" && -f "$E/reports/4-sonnet.md" && ! -f "$E/reports/2-opus-1.md" ]]; then pass "valid branch reports are copied to reports/, invalid slots' are not"; else fail "reports/ holds the wrong files"; fi
expect_eq "the verdict is the report's last line" "# verdict: 판정 불가(표본 수)" "$(tail -n 1 "$E/report.md")"
expect_line "the verdict report prints the cost total, a - row counting the whole reserve" "$E/report.md" "- 비용 합계(costs.tsv, \`-\` 행은 예비 전액): 168.7500 USD"
rc=0; runner "$tmp/s1" status --exp-id "$P1" --repo "$R" || rc=$?
if (( rc == 0 )) && grep -Fq -- '--- 비용 합계: 168.7500 USD' "$tmp/s1"; then pass "status prints the cost total"; else fail "status: exit $rc, no cost total"; fi

# --rerun-sample discards slot 3 and runs it again.
rc=0; runner "$tmp/r1" --rerun-sample 3 --exp-id "$P1" --budget-usd 1000 --repo "$R" || rc=$?
expect_rc "--rerun-sample exits 0" 0 "$rc" "$tmp/r1.err"
expect_eq "the rerun slot is valid now" "$nD|유효|-" "$(samp 3 | cut -d'|' -f1-3)"

# ---------- the budget guard -------------------------------------------------

P2=20261101-0000e002
E="$R/docs/review-seat-promotion-pair/$P2"
export STUB_DIR="$tmp/stub-e2"
mkdir -p "$STUB_DIR"
rc=0; runner "$tmp/b0" run --pilot --exp-id "$P2" --budget-usd 1000 --repo "$R" || rc=$?
expect_rc "the second experiment's pilot passes" 0 "$rc" "$tmp/b0.err"
rc=0; runner "$tmp/b1" run --exp-id "$P2" --budget-usd 152 --repo "$R" || rc=$?
expect_rc "the budget guard exits 4" 4 "$rc" "$tmp/b1.err"
expect_eq "the guard stops before the session that would pass the budget" 2 "$(find "$STUB_DIR/calls" -name '*.argv' | wc -l | tr -d ' ')"
expect_eq "every unfinished slot is 예산 상한" 5 "$(awk -F'\t' 'NR > 1 && $5 == "무효" && index($6, "예산 상한 — ") == 1' "$E/samples.tsv" | wc -l | tr -d ' ')"
if [[ -f "$E/report.md" ]]; then pass "the guard writes the verdict"; else fail "no report.md after the guard"; fi
rc=0; runner "$tmp/b2" run --exp-id "$P2" --budget-usd 1000 --repo "$R" || rc=$?
expect_rc "the same command with a larger budget carries on" 0 "$rc" "$tmp/b2.err"
expect_eq "the carried-on run finishes every slot" 5 "$(awk -F'\t' 'NR > 1 && $5 == "유효"' "$E/samples.tsv" | wc -l | tr -d ' ')"
expect_eq "the carried-on run does not repeat the finished session" 16 "$(find "$STUB_DIR/calls" -name '*.argv' | wc -l | tr -d ' ')"

# ---------- a pilot with a refused tool call ---------------------------------

P3=20261101-0000e003
E="$R/docs/review-seat-promotion-pair/$P3"
export STUB_DIR="$tmp/stub-e3"
mkdir -p "$STUB_DIR"
printf 'pilot-opus-1#1\tdenied\n' > "$STUB_DIR/plan"
rc=0; runner "$tmp/q0" run --pilot --exp-id "$P3" --budget-usd 1000 --repo "$R" || rc=$?
expect_eq "a pilot whose session had a tool call refused fails with exit 1, naming the count and the tool" \
  "1|실패 — 거부된 도구 호출 1건 (Bash)" "$rc|$(head -n 1 "$E/pilot/result")"
rc=0; runner "$tmp/q1" run --exp-id "$P3" --budget-usd 1000 --repo "$R" || rc=$?
expect_eq "after that failed pilot the main run stops with exit 1 and makes no call" "1|1" \
  "$rc|$(find "$STUB_DIR/calls" -name '*.argv' | wc -l | tr -d ' ')"
printf 'pilot-opus-1#2\twitnessmiss\n' >> "$STUB_DIR/plan"
rc=0; runner "$tmp/q2" run --pilot --exp-id "$P3" --budget-usd 1000 --repo "$R" || rc=$?
expect_eq "a pilot whose witness hook logged an undecided witness command fails with exit 1" \
  "1|실패 — 증인 명령 미승인 1건" "$rc|$(head -n 1 "$E/pilot/result")"

lane_list > "$tmp/lane.after"
if cmp -s "$tmp/lane.before" "$tmp/lane.after"; then pass "no runner call creates, removes or writes a file in the lane directory"; else fail "the lane directory's files changed"; diff "$tmp/lane.before" "$tmp/lane.after" >&2 || true; fi

echo "review-seat-promotion-pair: $passed passed, $failures failed"
(( failures == 0 ))
