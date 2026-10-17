#!/usr/bin/env bash
# Test scripts/solo-audit-experiment.sh and scripts/solo-audit-compare.sh
# against tests/fixtures/solo-audit-experiment/.
#
# The real corpus (audit reports, run manifests, ledgers, interview records)
# lives under `docs/`, which is not tracked, so every input here is synthetic:
# a small git repository built under `mktemp -d` stands in for the main
# repository, the gate and the CLI are stubs swapped in by SOLO_EXP_GATE and
# SOLO_EXP_CLAUDE_BIN, and only the manifest check is real — the experiment
# script sources this checkout's plugins/cc-cmds/orchestrator/run.sh.
#
# The verdict rule is pinned by golden files: a threshold changed after the
# experiment breaks a golden instead of passing in silence. Regenerate the
# goldens only for an intended rule change: SOLO_EXP_UPDATE_GOLDEN=1.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/solo-audit-experiment"
exp_sh="$script_dir/solo-audit-experiment.sh"
compare="$script_dir/solo-audit-compare.sh"

failures=0
passed=0

pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }

for v in $(compgen -e | grep '^CC_PIPELINE_' || true); do unset "$v"; done

# The real gate snapshot and run.sh below would reach the user's screen and
# leave a dashboard server behind; this suite asserts neither, so both are off.
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
CC_CMDS_DASHBOARD=off
export CC_CMDS_DASHBOARD

tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-solo-audit-exp.XXXXXX")
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

# ---- compare: build an experiment directory from a spec ----------------------

# build_compare <spec> <dir> — pair records and classification results.
build_compare() {
  local spec="$1" d="$2"
  rm -rf "$d"; mkdir -p "$d/classify"
  awk -F'\t' -v d="$d" '
    function defects(f, u, sk,   i, sep) {
      printf "{\"defects\":[" > f
      for (i = 1; i <= u; i++) {
        printf "%s{\"id\":\"D%d\",\"routing\":\"조정 패스 적용\",\"class\":\"%s\",\"reason\":\"-\"}", (i > 1 ? "," : ""), i, (i <= sk ? "골격급" : "비골격") > f
      }
      printf "]}\n" > f
      close(f)
    }
    /^#/ || NF == 0 { next }
    $1 == "pair" {
      p = d "/pairs/" $2; system("mkdir -p \"" p "\"")
      f = p "/pair.tsv"
      printf "status\t유효\nteam_label\tt%s\nsolo_label\ts%s\n", $2, $2 > f
      printf "team_unique\t%s\nteam_bytes\t%s\nteam_unremedied\t%s\nteam_reviewers\t4\nteam_plugin\t2.80.0@aaaaaaaaaaaa\n", $3, $4, $5 > f
      printf "solo_unique\t%s\nsolo_bytes\t%s\nsolo_unremedied\t%s\nsolo_reviewers\t4\nsolo_plugin\t2.83.1@bbbbbbbbbbbb\n", $7, $8, $9 > f
      close(f)
      defects(d "/classify/t" $2 ".json", $3, $6)
      defects(d "/classify/s" $2 ".json", $7, $10)
    }
    $1 == "invalid" {
      p = d "/pairs/" $2; system("mkdir -p \"" p "\"")
      printf "status\t무효\ninvalid_reason\t%s\n", $3 > (p "/pair.tsv"); close(p "/pair.tsv")
    }
    $1 == "review" { rv[++nr] = $2 "\t" $3 "\t조정 패스 적용\t경계\t" ($4 == "-" ? "" : $4) }
    END {
      if (nr) { f = d "/classify/review.tsv"; print "표지\tid\t라우팅\t모델 사유\t사람 판정" > f; for (i = 1; i <= nr; i++) print rv[i] > f }
    }' "$spec"
  # An ambiguous defect is one more entry in its report's result.
  local l id
  while IFS='	' read -r l id; do
    jq --arg i "$id" '.defects += [{id: $i, routing: "조정 패스 적용", class: "애매", reason: "-"}]' "$d/classify/$l.json" > "$d/classify/$l.json.tmp"
    mv "$d/classify/$l.json.tmp" "$d/classify/$l.json"
  done < <(awk -F'\t' '$1 == "amb" { print $2 "\t" $3 }' "$spec")
}

# ---- compare: golden verdicts ----------------------------------------------

for c in approx ratio-ne veto invalid review-blank; do
  d="$tmp/compare/$c"
  build_compare "$fixtures/compare/$c.spec" "$d"
  if [[ "${SOLO_EXP_UPDATE_GOLDEN:-0}" == "1" ]]; then
    bash "$compare" --exp "$d" --out "$fixtures/compare/$c.expected.md"
  fi
  if bash "$compare" --exp "$d" --out - > "$tmp/out.md" 2>"$tmp/err"; then
    if diff -u "$fixtures/compare/$c.expected.md" "$tmp/out.md" > "$tmp/diff"; then
      pass "compare golden: $c ($(tail -n 1 "$tmp/out.md"))"
    else
      fail "compare golden diff: $c"; cat "$tmp/diff" >&2
    fi
  else
    fail "compare exited non-zero on $c"; cat "$tmp/err" >&2
  fi
done

want_verdict() {
  local c="$1" v="$2" got
  got=$(tail -n 1 "$fixtures/compare/$c.expected.md")
  [[ "$got" == "# verdict: $v" ]] && pass "golden $c carries verdict $v" || fail "golden $c carries '$got', not $v"
}
want_verdict approx "≈"
want_verdict ratio-ne "≠"
want_verdict veto "≠"
want_verdict invalid "판정 불가"
want_verdict review-blank "판정 불가"
grep -qF -- '- 발동: 예' "$fixtures/compare/veto.expected.md" && pass "veto golden: the veto decided it" || fail "veto golden: veto not fired"
grep -qF -- '- 발동: 아니오' "$fixtures/compare/ratio-ne.expected.md" && pass "ratio-ne golden: the ratio decided it" || fail "ratio-ne golden: the veto fired"

# ---- compare: mutation — one fence value changed flips the verdict -----------
#
# pair.tsv carries the disclosure-block values as read. Raising pair 3's solo
# unique-defect count from 6 to 7 moves the density median from 1.5 to 1.75.

d="$tmp/compare/approx"
awk -F'\t' 'BEGIN { OFS = "\t" } $1 == "solo_unique" { $2 = 7 } { print }' "$d/pairs/3/pair.tsv" > "$d/pairs/3/pair.tsv.m"
mv "$d/pairs/3/pair.tsv.m" "$d/pairs/3/pair.tsv"
jq '.defects += [{id: "D7", routing: "조정 패스 적용", class: "비골격", reason: "-"}]' "$d/classify/s3.json" > "$d/classify/s3.m"
mv "$d/classify/s3.m" "$d/classify/s3.json"
bash "$compare" --exp "$d" --out - > "$tmp/out.md" 2>/dev/null || true
if diff -q "$fixtures/compare/approx.expected.md" "$tmp/out.md" >/dev/null; then
  fail "mutation (pair 3 solo 6 -> 7) still matches the golden"
elif [[ "$(tail -n 1 "$tmp/out.md")" == "# verdict: ≠" ]] && grep -qF '결함/KB 비 S/T 중앙값: 1.750' "$tmp/out.md"; then
  pass "mutation (pair 3 solo 6 -> 7) moves the median to 1.750 and the verdict to ≠"
else
  fail "mutation changed the output but not as expected"; cat "$tmp/out.md" >&2
fi

# ---- compare: input defects ------------------------------------------------

d="$tmp/compare/bad"
build_compare "$fixtures/compare/approx.spec" "$d"
awk -F'\t' 'BEGIN { OFS = "\t" } $1 == "team_bytes" { $2 = "많음" } { print }' "$d/pairs/2/pair.tsv" > "$d/p" && mv "$d/p" "$d/pairs/2/pair.tsv"
rc=0; bash "$compare" --exp "$d" --out - >/dev/null 2>&1 || rc=$?
[[ "$rc" == "1" ]] && pass "compare: non-numeric value → exit 1" || fail "compare: non-numeric value gave exit $rc"
build_compare "$fixtures/compare/approx.spec" "$d"
rm -f "$d/classify/s4.json"
rc=0; bash "$compare" --exp "$d" --out - >/dev/null 2>&1 || rc=$?
[[ "$rc" == "1" ]] && pass "compare: missing classification → exit 1" || fail "compare: missing classification gave exit $rc"
rc=0; bash "$compare" --exp "$tmp/nowhere" >/dev/null 2>&1 || rc=$?
[[ "$rc" == "2" ]] && pass "compare: missing directory → exit 2" || fail "compare: missing directory gave exit $rc"
build_compare "$fixtures/compare/veto.spec" "$d"
awk -F'\t' 'BEGIN { OFS = "\t" } NR > 1 && $2 == "D9" && $1 == "s4" { $5 = "글쎄" } { print }' "$d/classify/review.tsv" > "$d/r" && mv "$d/r" "$d/classify/review.tsv"
bash "$compare" --exp "$d" --out - > "$tmp/out.md" 2>/dev/null || true
if [[ "$(tail -n 1 "$tmp/out.md")" == "# verdict: 판정 불가" ]] && grep -qF '골격급·비골격 밖의 값' "$tmp/out.md"; then
  pass "compare: a judgment outside 골격급·비골격 → 판정 불가"
else
  fail "compare: an out-of-vocabulary judgment was accepted"
fi

# ---- the synthetic main repository -----------------------------------------

main="$tmp/main"
mkdir -p "$main"
(
  cd "$main"
  git init -q -b master
  git config user.email t@example.invalid; git config user.name t
  echo base > README; git add README; git commit -q -m base
  echo next >> README; git commit -q -am next
)
base=$(cd "$main" && git rev-list --max-parents=0 HEAD)
head_=$(cd "$main" && git rev-parse HEAD)
other="ffffffffffffffffffffffffffffffffffffffff"
mkdir -p "$main/docs/design-audit" "$main/docs/pipeline-run"
solo_src="$tmp/solo-reports"
mkdir -p "$solo_src"

FB='<!-- cc-design-audit-disclosure v1 begin -->'
FE='<!-- /cc-design-audit-disclosure v1 end -->'

# mk_report <file> <owner-doc> <frozen at> <bytes> <unremedied> <total> <skeletal> [<ambiguous>]
# Rows D1..: skeletal ones, ambiguous ones, local ones, and the last one 기각.
mk_report() {
  local f="$1" owner="$2" at="$3" bytes="$4" unrem="$5" total="$6" sk="$7" amb="${8:-0}"
  local i rows="" adj=0 rej=0 rt cl
  for i in $(seq 1 "$total"); do
    if (( i == total && total >= 2 )); then rt="기각"; cl="제외"; rej=$((rej + 1))
    elif (( i <= sk )); then rt="조정 패스 적용"; cl="골격급"; adj=$((adj + 1))
    elif (( i <= sk + amb )); then rt="조정 패스 적용"; cl="애매"; adj=$((adj + 1))
    else rt="조정 패스 적용"; cl="비골격"; adj=$((adj + 1)); fi
    rows="${rows}| D${i} | ${rt} | ${cl} |
"
  done
  cat > "$f" <<EOF
# 설계 감사 — ${owner} (${total}건)
<!-- cc-design-audit v1; writer=design-audit; reader=design-audit; owner-doc=${owner}; origin-worktree=${main}; NOT a design doc; mechanism-local, never staged by a skill -->

## 감사 개시
- 대상: ${main}/${owner}
- frozen-at: ${at}
**고유 결함 수**: 99

## 결정론적 검사
- 앵커 검사 통과

## 고유 결함
| id | 라우팅 | 분류 단서 |
| --- | --- | --- |
${rows}
${FB}
**동결 문서 sha256**: 0000000000000000000000000000000000000000000000000000000000000000
**동결 문서 바이트**: ${bytes}
**동결 시각**: ${at}
**리뷰어 수**: 4
**원시 발견 수**: $((total * 2))
**고유 결함 수**: ${total}
**미보강 잔여 수**: ${unrem}
**라우팅 — 조정 패스 적용**: ${adj}
**라우팅 — 미해결 이슈**: 0
**라우팅 — implement 사전 게이트**: 0
**라우팅 — design-conformance**: 0
**라우팅 — 기각**: ${rej}
**하류 흡수 가정**: 없음
**조정 패스 시작**: ${at}
**조정 패스 종료**: ${at}
${FE}
EOF
}

# mk_run <run id> <owner-doc> <kickoff> <tier> <scope> <base> [hash-mismatch]
mk_run() {
  local rid="$1" owner="$2" ko="$3" tier="$4" scope="$5" b="$6" bad="${7:-}"
  local pr="$main/docs/pipeline-run" ip="docs/pipeline-run/$1.interview.md" sha
  {
    echo "# 인터뷰 기록 — $rid"
    echo "<!-- cc-run-interview v2; writer=autopilot; reader=orchestrator; run-id=$rid; NOT a design doc -->"
    echo
    echo "문 1. ${owner} 를 설계한다."
  } > "$main/$ip"
  sha=$(shasum -a 256 "$main/$ip" | cut -d' ' -f1)
  [[ -z "$bad" ]] || sha="1111111111111111111111111111111111111111111111111111111111111111"
  cat > "$pr/$rid.plan.md" <<EOF
# 파이프라인 런 매니페스트 — ${rid}
<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=${rid};
     anchor-kind=intent; anchor-key=x;
     owner-doc=${owner}; origin-worktree=${main};
     NOT a design doc; mechanism-local, never staged by a skill -->

## 런 정체
**킥오프 일시**: ${ko}
**런 id**: ${rid}

## 의도
\`\`\`text
${owner} 를 설계한다
\`\`\`

## 실행 계획
**승인 문면**: 예
\`\`\`json
{"design_tier": "${tier}", "design_scope": "${scope}"}
\`\`\`

## 인가
- \`사전 인가\` | 인터뷰 기록=${ip} | sha256=${sha}
EOF
  cat > "$pr/$rid.md" <<EOF
# 파이프라인 런 보고서 — ${rid}
- \`run\` | 교대=0 | run-id=${rid} | 판본=${b} | prev=0
- \`stage-result\` | 교대=1 | 세그먼트=- | 스테이지=D1 | 종류=design | 종료 코드=0 | 종단 부류=정상 완료 | prev=1
EOF
}

# mk_teamdoc <owner-doc> <tree commit>
mk_teamdoc() {
  printf '# 팀 설계 — %s\n**상태**: 동결됨\n**기준 트리**: %s master %s (v2.80.0)\n' "$1" "$main" "${2:0:8}" > "$main/$1"
}

dar="$main/docs/design-audit"
# Candidates: unique 2 4 6 8 10 12 → ranks 0 1 3 4 5 pick c1 c2 c4 c5 c6.
mk_teamdoc docs/c1.md "$base"; mk_run 20261011-00000c11 docs/c1.md 2026-10-11T00:00:00Z team-4 single "$base"
mk_report "$dar/docs-c1.md" docs/c1.md 2026-10-12T10:00:00+09:00 2000 0 2 1
# A re-audit of c1, frozen later: the first audit is the one kept.
mk_report "$dar/docs-c1.A1-3.md" docs/c1.md 2026-10-14T00:00:00Z 1000 0 1 0
# n1's first audit parked without the block; its re-audit is still not the
# first audit and must not become a candidate.
mk_teamdoc docs/n1.md "$base"; mk_run 20261011-00000f11 docs/n1.md 2026-10-11T00:00:00Z team-4 single "$base"
mk_report "$dar/docs-n1.md" docs/n1.md 2026-10-12T00:00:00Z 1000 0 3 1
awk -v b="$FB" -v e="$FE" 'index($0, b) == 1 { s = 1; next } index($0, e) == 1 { s = 0; next } !s' "$dar/docs-n1.md" > "$dar/docs-n1.md.t"
mv "$dar/docs-n1.md.t" "$dar/docs-n1.md"
mk_report "$dar/docs-n1.A1-3.md" docs/n1.md 2026-10-14T00:00:00Z 3000 0 3 1
# n2's first report has neither the block nor a frozen-at line: with no time
# to compare, its plain name still marks it as the first audit.
mk_report "$dar/docs-n2.md" docs/n2.md 2026-10-12T00:00:00Z 1000 0 3 1
awk -v b="$FB" -v e="$FE" 'index($0, b) == 1 { s = 1; next } index($0, e) == 1 { s = 0; next } !s && index($0, "- frozen-at: ") != 1' "$dar/docs-n2.md" > "$dar/docs-n2.md.t"
mv "$dar/docs-n2.md.t" "$dar/docs-n2.md"
mk_report "$dar/docs-n2.A1-3.md" docs/n2.md 2026-10-14T00:00:00Z 3000 0 3 1

mk_teamdoc docs/c2.md "$base"
# Three runs on c2: the latest kickoff before the freeze is the team-4 one.
mk_run 20261011-00000c21 docs/c2.md 2026-10-11T00:00:00Z solo single "$other"
mk_run 20261012-00000c22 docs/c2.md 2026-10-12T00:00:00Z team-4 single "$base"
mk_run 20261014-00000c23 docs/c2.md 2026-10-14T00:00:00Z solo single "$other"
mk_report "$dar/docs-c2.md" docs/c2.md 2026-10-13T00:00:00Z 4000 0 4 1

for s in 3 4 5; do
  mk_teamdoc "docs/c$s.md" "$base"; mk_run "20261011-00000c${s}1" "docs/c$s.md" 2026-10-11T00:00:00Z team-2 single "$base"
done
# c3's first audit was moved aside to .prior-<hash> and its re-audit took the
# plain name: the earlier freeze, not the name, makes the first audit.
mk_report "$dar/docs-c3.prior-0000c3c3.md" docs/c3.md 2026-10-13T00:00:00Z 6000 0 6 1
mk_report "$dar/docs-c3.md" docs/c3.md 2026-10-15T00:00:00Z 6000 0 7 1
mk_report "$dar/docs-c4.md" docs/c4.md 2026-10-13T00:00:00Z 8000 0 8 1
mk_report "$dar/docs-c5.md" docs/c5.md 2026-10-13T00:00:00Z 10000 0 10 1
# Frozen 2026-10-17 08:00 +09:00 is 2026-10-16 23:00 UTC: inside the window.
mk_teamdoc docs/c6.md "$base"; mk_run 20261011-00000c61 docs/c6.md 2026-10-11T00:00:00Z team-4 single "$base"
mk_report "$dar/docs-c6.md" docs/c6.md 2026-10-17T08:00:00+09:00 12000 0 12 1

# Excluded.
mk_report "$dar/docs-w1.md" docs/w1.md 2026-10-10T08:30:00+09:00 1000 0 3 1    # 10-09 23:30 UTC
mk_report "$dar/docs-w2.md" docs/w2.md 2026-10-17T00:30:00+00:00 1000 0 3 1    # 10-17 UTC
mk_teamdoc docs/t1.md "$base"; mk_run 20261011-00000a11 docs/t1.md 2026-10-11T00:00:00Z solo single "$base"
mk_report "$dar/docs-t1.md" docs/t1.md 2026-10-13T00:00:00Z 1000 0 3 1
mk_teamdoc docs/b1.md "$base"; mk_run 20261011-00000b11 docs/b1.md 2026-10-11T00:00:00Z team-4 base "$base"
mk_report "$dar/docs-b1.md" docs/b1.md 2026-10-13T00:00:00Z 1000 0 3 1
mk_teamdoc docs/g1.md "$head_"; mk_run 20261011-00000d11 docs/g1.md 2026-10-11T00:00:00Z team-4 single "$base"
mk_report "$dar/docs-g1.md" docs/g1.md 2026-10-13T00:00:00Z 1000 0 3 1
mk_teamdoc docs/h1.md "$base"; mk_run 20261011-00000e11 docs/h1.md 2026-10-11T00:00:00Z team-4 single "$base" bad
mk_report "$dar/docs-h1.md" docs/h1.md 2026-10-13T00:00:00Z 1000 0 3 1
mk_report "$dar/docs-reader-c1.md" docs/c1.md 2026-10-12T00:00:00Z 1000 0 3 1

# Solo reports the stub gate's audit run drops in. Solo densities against a
# team density of 1.0: c1 1.0, c2 1.0, c4 1.5, c5 2.0, c6 2.0 → median 1.5 → ≈.
# c2's solo report carries one ambiguous defect.
mk_report "$solo_src/docs-c1.md" docs/c1.md 2026-10-17T01:00:00Z 2000 0 2 1
mk_report "$solo_src/docs-c2.md" docs/c2.md 2026-10-17T01:00:00Z 4000 0 4 1 1
mk_report "$solo_src/docs-c4.md" docs/c4.md 2026-10-17T01:00:00Z 4000 0 6 1
mk_report "$solo_src/docs-c5.md" docs/c5.md 2026-10-17T01:00:00Z 2000 0 4 1
mk_report "$solo_src/docs-c6.md" docs/c6.md 2026-10-17T01:00:00Z 2000 0 4 1

# ---- environment for experiment calls --------------------------------------

export SOLO_EXP_GATE="$fixtures/gate-stub.sh"
export SOLO_EXP_CLAUDE_BIN="$fixtures/claude-stub.sh"
export STUB_SOLO_REPORTS="$solo_src"
export CC_GATE_PIN_DISABLE=1

# scenario <name> — fresh state for one experiment.
scenario() {
  sc="$tmp/sc-$1"
  mkdir -p "$sc"
  export XDG_STATE_HOME="$sc/xdg" SOLO_EXP_STATE_ROOT="$sc/state" CLAUDE_CONFIG_DIR="$sc/cfg"
  export STUB_GATE_LOG="$sc/gate.log" STUB_CLI_LOG="$sc/cli.log"
  : > "$STUB_GATE_LOG"; : > "$STUB_CLI_LOG"
  unset STUB_GATE_MODE STUB_NO_FREEZE STUB_CONTAM STUB_CLI_DROP STUB_HANDOFF STUB_HALT STUB_HALT_ANSWER_RC
}
xp() { bash "$exp_sh" --repo "$main" "$@"; }
acts() { grep -c '^act ' "$STUB_GATE_LOG" || true; }
calls() { grep -c '^call' "$STUB_CLI_LOG" || true; }
pstate() { awk -F'\t' -v k="$3" '$1 == k { print substr($0, length(k) + 2); exit }' "$SOLO_EXP_STATE_ROOT/$1/pair-$2/pair.state"; }

# ---- usage and the cost guard ----------------------------------------------

scenario usage
rc=0; xp run --exp-id 20261017-0000000a >/dev/null 2>&1 || rc=$?
[[ "$rc" == "2" ]] && pass "usage: billed call without --budget-usd → exit 2" || fail "usage: no --budget-usd gave exit $rc"
rc=0; xp run --exp-id 2026-bad --budget-usd 9 >/dev/null 2>&1 || rc=$?
[[ "$rc" == "2" ]] && pass "usage: malformed --exp-id → exit 2" || fail "usage: malformed --exp-id gave exit $rc"
rc=0; xp --rerun-pair 1 --exp-id 20261017-0000000a >/dev/null 2>&1 || rc=$?
[[ "$rc" == "2" ]] && pass "usage: --rerun-pair without --budget-usd → exit 2" || fail "usage: --rerun-pair without budget gave exit $rc"
[[ ! -e "$main/docs/solo-audit-experiment/20261017-0000000a" ]] && pass "usage: a refused call writes no experiment directory" || fail "usage: a refused call wrote the experiment directory"

# ---- selection and preparation (dry run) -----------------------------------

scenario dry
E1=20261017-000000d1
rc=0; xp run --dry-run --exp-id "$E1" --budget-usd 1 > "$sc/out" 2>&1 || rc=$?
if [[ "$rc" == "0" ]]; then pass "dry run exits 0"; else fail "dry run gave exit $rc"; cat "$sc/out" >&2; fi
[[ "$(acts)" == "0" && "$(calls)" == "0" ]] && pass "dry run: no router-shift and no CLI call" || fail "dry run: $(acts) act / $(calls) CLI calls"
sel="$main/docs/solo-audit-experiment/$E1/selection.tsv"
disp() { awk -F'\t' -v r="$1" '$1 == r { print $7 "|" $8 }' "$sel"; }
got=$(awk -F'\t' '$7 ~ /^선정 / { print $7 "=" $1 }' "$sel" | LC_ALL=C sort | tr '\n' ' ')
[[ "$got" == "선정 1=docs-c1.md 선정 2=docs-c2.md 선정 3=docs-c4.md 선정 4=docs-c5.md 선정 5=docs-c6.md " ]] \
  && pass "selection: quantile ranks 0 1 3 4 5 of six candidates" || fail "selection: picked '$got'"
[[ "$(disp docs-c3.prior-0000c3c3.md)" == "후보|-" ]] && pass "selection: the unpicked candidate stays a 후보" || fail "selection: c3 prior is '$(disp docs-c3.prior-0000c3c3.md)'"
case "$(disp docs-c3.md)" in "제외|같은 owner-doc 의 첫 감사 보고서 docs-c3.prior-0000c3c3.md 가 따로 있다 (재감사)") pass "selection: a re-audit under the plain name is excluded when the first audit was moved to .prior" ;; *) fail "selection: c3 re-audit is '$(disp docs-c3.md)'" ;; esac
case "$(disp docs-w1.md)" in "제외|창 밖 (UTC 2026-10-09)") pass "window: +09:00 freeze on 10-10 is 10-09 UTC → out" ;; *) fail "window: w1 is '$(disp docs-w1.md)'" ;; esac
case "$(disp docs-w2.md)" in "제외|창 밖 (UTC 2026-10-17)") pass "window: 10-17 00:30 UTC → out" ;; *) fail "window: w2 is '$(disp docs-w2.md)'" ;; esac
[[ "$(disp docs-c6.md)" == "선정 5|-" ]] && pass "window: +09:00 freeze on 10-17 is 10-16 UTC → in" || fail "window: c6 is '$(disp docs-c6.md)'"
case "$(disp docs-t1.md)" in "제외|팀 티어가 아니다"*) pass "selection: solo-tier original run excluded" ;; *) fail "selection: t1 is '$(disp docs-t1.md)'" ;; esac
case "$(disp docs-b1.md)" in "제외|design_scope 가 base 다") pass "selection: base scope excluded" ;; *) fail "selection: b1 is '$(disp docs-b1.md)'" ;; esac
case "$(disp docs-c1.A1-3.md)" in "제외|같은 owner-doc 의 첫 감사 보고서 docs-c1.md 가 따로 있다 (재감사)") pass "selection: the first audit per owner-doc is kept" ;; *) fail "selection: re-audit is '$(disp docs-c1.A1-3.md)'" ;; esac
case "$(disp docs-n1.A1-3.md)" in "제외|같은 owner-doc 의 첫 감사 보고서 docs-n1.md 가 따로 있다 (재감사)") pass "selection: a re-audit is excluded when the first audit has no block" ;; *) fail "selection: n1 re-audit is '$(disp docs-n1.A1-3.md)'" ;; esac
case "$(disp docs-n2.A1-3.md)" in "제외|같은 owner-doc 의 첫 감사 보고서 docs-n2.md 가 따로 있다 (재감사)") pass "selection: with no readable freeze time on the plain-named report, the name marks the first audit" ;; *) fail "selection: n2 re-audit is '$(disp docs-n2.A1-3.md)'" ;; esac
[[ "$(disp docs-n1.md)" == "제외|공시 블록이 없다" ]] && pass "selection: a report without the block is recorded as 제외" || fail "selection: n1 is '$(disp docs-n1.md)'"
case "$(disp docs-g1.md)" in "제외|기준 트리"*) pass "selection: 기준 트리 ≠ 판본= excluded" ;; *) fail "selection: g1 is '$(disp docs-g1.md)'" ;; esac
case "$(disp docs-h1.md)" in "제외|인터뷰 기록 해시"*) pass "selection: interview hash mismatch excluded" ;; *) fail "selection: h1 is '$(disp docs-h1.md)'" ;; esac
[[ -z "$(disp docs-reader-c1.md)" ]] && pass "selection: reader- files are not in the population" || fail "selection: reader file listed"
[[ "$(awk -F'\t' '$1 == "docs-c2.md" { print $5 }' "$sel")" == "20261012-00000c22" ]] \
  && pass "selection: of three runs, the latest kickoff before the freeze is the original" || fail "selection: c2's original run is wrong"
[[ "$(awk -F'\t' '$1 == "docs-c6.md" { print $3 }' "$sel")" == "2026-10-16T23:00:00Z" ]] \
  && pass "selection: freeze time rendered in UTC" || fail "selection: c6 freeze column wrong"

scenario dry2
E2=20261017-000000d2
xp run --dry-run --exp-id "$E2" >/dev/null 2>&1 || true
if diff -q "$sel" "$main/docs/solo-audit-experiment/$E2/selection.tsv" >/dev/null; then
  pass "selection: the same input gives the same selection"
else
  fail "selection: two runs disagree"
fi

# Preparation of the dry run.
ST1="$tmp/sc-dry/state"
SOLO_EXP_STATE_ROOT="$ST1"
c1clone=$(pstate "$E1" 1 clone)
[[ "$(cd "$c1clone" && git rev-parse HEAD)" == "$base" ]] && pass "prepare: the clone's HEAD is the base commit" || fail "prepare: clone HEAD is not the base commit"
[[ "$(cd "$c1clone" && git rev-parse --abbrev-ref HEAD)" == "exp-base" ]] && pass "prepare: branch exp-base" || fail "prepare: not on exp-base"
[[ "$(cd "$c1clone" && git for-each-ref --format='%(refname)')" == "refs/heads/exp-base" && -z "$(cd "$c1clone" && git remote)" ]] \
  && pass "prepare: the clone keeps only exp-base and no remote" || fail "prepare: the clone keeps other refs or a remote"
( cd "$main" && git cat-file -e "${head_}^{commit}" ) || fail "prepare: the commit past the base is missing from the main repository"
if ( cd "$c1clone" && git cat-file -e "${head_}^{commit}" ) 2>/dev/null; then
  fail "prepare: a commit past the base is still readable in the clone"
else
  pass "prepare: no commit past the base is readable in the clone"
fi
drid=$(pstate "$E1" 1 design_run)
if cmp -s "$main/docs/pipeline-run/20261011-00000c11.interview.md" "$c1clone/docs/pipeline-run/$drid.interview.md"; then
  pass "prepare: the interview copy is byte-identical"
else
  fail "prepare: the interview copy differs"
fi
dm=$(pstate "$E1" 1 design_manifest)
isha=$(shasum -a 256 "$c1clone/docs/pipeline-run/$drid.interview.md" | cut -d' ' -f1)
grep -qxF -- "- \`사전 인가\` | 인터뷰 기록=docs/pipeline-run/$drid.interview.md | sha256=$isha" "$dm" \
  && pass "prepare: the 사전 인가 row binds the copy's hash" || fail "prepare: 사전 인가 row missing or wrong"
grep -qF '"design_tier": "solo"' "$dm" && grep -qF '"entry_skill": "design"' "$dm" && ! grep -q '^- `재킥오프`' "$dm" \
  && pass "prepare: solo design plan, no 재킥오프 row" || fail "prepare: the design plan is not the solo one"
am=$(pstate "$E1" 1 audit_manifest)
grep -qF '"entry_skill": "design-audit"' "$am" && grep -qF 'anchor-kind=doc; anchor-key=docs/c1.md;' "$am" \
  && pass "prepare: the audit manifest anchors the document" || fail "prepare: audit manifest wrong"
# The check itself is the driver's, not a stub: re-run it here on every
# manifest, then take the real gate's snapshot of it.
ok=1; snap=1
for n in 1 2 3 4 5; do
  for k in design audit; do
    m=$(pstate "$E1" "$n" "${k}_manifest"); cl=$(pstate "$E1" "$n" clone)
    ( cd "$cl" && CC_ORCH_SOURCE_ONLY=1 && . "$repo_root/plugins/cc-cmds/orchestrator/run.sh" && MANIFEST="$m" && check_manifest ) >/dev/null 2>"$sc/check.err" || { ok=0; echo "check_manifest failed: $m" >&2; cat "$sc/check.err" >&2; }
    ( cd "$cl" && bash "$repo_root/plugins/cc-cmds/orchestrator/gate.sh" snapshot --manifest "$m" --fields H ) >"$sc/snap.out" 2>"$sc/snap.err" \
      && [[ -s "$sc/snap.out" ]] || { snap=0; echo "gate snapshot failed: $m" >&2; cat "$sc/snap.err" >&2; }
  done
done
(( ok == 1 )) && pass "prepare: all ten manifests pass the real check_manifest" || fail "prepare: a manifest fails check_manifest"
(( snap == 1 )) && pass "prepare: the real gate snapshot exits 0 on all ten manifests" || fail "prepare: gate snapshot fails on a manifest"
# A broken manifest is refused by the same check.
cp "$dm" "$sc/broken.plan.md"
sed 's/^\*\*구속 다이제스트\*\*: .*/**구속 다이제스트**: 0000/' "$sc/broken.plan.md" > "$dm.broken"
if ( cd "$c1clone" && CC_ORCH_SOURCE_ONLY=1 && . "$repo_root/plugins/cc-cmds/orchestrator/run.sh" && MANIFEST="$dm.broken" && check_manifest ) >/dev/null 2>&1; then
  fail "prepare: check_manifest accepted a wrong binding digest (the check is not biting)"
else
  pass "prepare: check_manifest refuses a wrong binding digest"
fi
rm -f "$dm.broken"

# ---- candidate shortage ----------------------------------------------------

scenario short
short="$tmp/short"
cp -R "$main" "$short"
rm -f "$short/docs/design-audit/docs-c5.md" "$short/docs/design-audit/docs-c6.md"
rm -rf "$short/docs/solo-audit-experiment"
rc=0; bash "$exp_sh" --repo "$short" run --exp-id 20261017-000000e1 --budget-usd 1000 >/dev/null 2>&1 || rc=$?
rep="$short/docs/solo-audit-experiment/20261017-000000e1/report.md"
if [[ "$rc" == "0" && "$(tail -n 1 "$rep" 2>/dev/null)" == "# verdict: 판정 불가" ]] && grep -qF '후보 부족' "$rep" && [[ "$(acts)" == "0" ]]; then
  pass "selection: four candidates → 판정 불가 (후보 부족), exit 0, nothing started"
else
  fail "selection: shortage gave exit $rc"
fi

# ---- the full chain ---------------------------------------------------------

scenario full
EF=20261017-000000f1
rc=0; xp run --exp-id "$EF" --budget-usd 1000 > "$sc/out" 2>&1 || rc=$?
EXPF="$main/docs/solo-audit-experiment/$EF"
if [[ "$rc" == "3" ]]; then pass "full: stops with exit 3 on an ambiguous defect"; else fail "full: first call gave exit $rc"; cat "$sc/out" >&2; fi
[[ "$(acts)" == "20" ]] && pass "full: the seat called router-shift until done (2 calls × 10 runs)" || fail "full: $(acts) act calls"
grep -q -- '--kind router-shift --target exp --cutpoint 커밋 --surface 워크트리쓰기 --snapshot-digest stub-h -- 상한 -p /cc-cmds:autopilot-router-shift ' "$STUB_GATE_LOG" \
  && pass "full: router-shift in the seat's call form" || fail "full: act argv differs from the seat's form"
[[ "$(calls)" == "10" ]] && pass "full: one classification call per report" || fail "full: $(calls) CLI calls"
grep -qE '^call .*--output-format json --strict-mcp-config --tools  --no-session-persistence --max-budget-usd 3$' "$STUB_CLI_LOG" \
  && pass "full: the classification call carries --no-session-persistence and --max-budget-usd 3" || fail "full: CLI flags $(head -n 1 "$STUB_CLI_LOG")"
rv="$EXPF/classify/review.tsv"
[[ "$(awk -F'\t' 'NR > 1' "$rv" | wc -l | tr -d ' ')" == "1" ]] && awk -F'\t' 'NR == 2 && $2 == "D2" && $5 == "" { f = 1 } END { exit !f }' "$rv" \
  && pass "full: the ambiguous defect lands in review.tsv with a blank judgment" || fail "full: review.tsv wrong"
grep -qF "fill the 사람 판정 column" "$sc/out" && grep -qF "run --exp-id $EF --budget-usd 1000" "$sc/out" \
  && pass "full: prints the file to fill and the command to call again" || fail "full: no fill instruction"
p1="$EXPF/pairs/1/pair.tsv"
[[ "$(awk -F'\t' '$1 == "team_unique" { print $2 }' "$p1")" == "2" ]] && pass "collect: reads the fence, not the prose decoy" || fail "collect: team_unique of pair 1 is not 2"
[[ "$(awk -F'\t' '$1 == "solo_plugin" { print $2 }' "$p1")" == "9.9.9@0123456789ab" ]] && pass "collect: records the audit run's plugin pin" || fail "collect: solo plugin pin missing"
in1=$(sed -n 's/^\*\*고유 결함 수\*\*: //p' "$EXPF/classify/$(awk -F'\t' '$1 == "team_label" { print $2 }' "$p1").json" 2>/dev/null || true)
[[ -z "$in1" ]] && pass "classify: stores the structured output only" || fail "classify: result file carries report text"
# Fill the judgment and call again: resumes to the verdict, no new run, no new call.
awk -F'\t' 'BEGIN { OFS = "\t" } NR > 1 && $5 == "" { $5 = "비골격" } { print }' "$rv" > "$rv.t" && mv "$rv.t" "$rv"
rc=0; xp run --exp-id "$EF" --budget-usd 1000 > "$sc/out" 2>&1 || rc=$?
if [[ "$rc" == "0" && "$(tail -n 1 "$EXPF/report.md")" == "# verdict: ≈" ]]; then
  pass "full: after the judgment, the same command reaches the verdict ≈"
else
  fail "full: second call gave exit $rc / $(tail -n 1 "$EXPF/report.md" 2>/dev/null)"; cat "$sc/out" >&2
fi
[[ "$(acts)" == "20" && "$(calls)" == "10" ]] && pass "full: the resumed call starts nothing again" || fail "full: resume re-ran $(acts) acts / $(calls) calls"
xp status --exp-id "$EF" > "$sc/status" 2>&1 || true
grep -qF 'pair 5: 수집 완료' "$sc/status" && grep -qF '# verdict: ≈' "$sc/status" && grep -qF 'spent usd: 22.5000' "$sc/status" \
  && pass "status: pair states, spent amount and verdict" || { fail "status output"; cat "$sc/status" >&2; }

# ---- the cost guard ---------------------------------------------------------

scenario budget
rc=0; xp run --exp-id 20261017-000000b1 --budget-usd 100 >/dev/null 2>&1 || rc=$?
[[ "$rc" == "4" && "$(acts)" == "0" ]] && pass "budget: 0 + 150 > 100 → exit 4 before any run" || fail "budget: gave exit $rc with $(acts) acts"
scenario budget2
rc=0; xp run --exp-id 20261017-000000b2 --budget-usd 153 >/dev/null 2>&1 || rc=$?
nm=$(sed -n 's/.*--manifest \([^ ]*\) .*/\1/p' "$STUB_GATE_LOG" | sort -u | wc -l | tr -d ' ')
[[ "$rc" == "4" && "$nm" == "2" ]] && pass "budget: spent 4 + 150 > 153 stops before the third run" || fail "budget: gave exit $rc after $nm runs"
# An opened run that stopped is resumed only while spent is below the budget.
scenario budget3
export STUB_GATE_MODE=failopen STUB_RUN_COST=200
rc=0; xp run --exp-id 20261017-000000b3 --budget-usd 1000 >/dev/null 2>&1 || rc=$?
unset STUB_GATE_MODE
[[ "$rc" == "1" && "$(acts)" == "1" ]] || fail "budget: the opened run's first call gave exit $rc with $(acts) acts"
rc=0; xp run --exp-id 20261017-000000b3 --budget-usd 200 >/dev/null 2>&1 || rc=$?
[[ "$rc" == "4" && "$(acts)" == "1" ]] && pass "budget: spent 200 ≥ 200 → exit 4 before resuming an opened run" || fail "budget: resume gave exit $rc with $(acts) acts"
rc=0; xp run --exp-id 20261017-000000b3 --budget-usd 201 >/dev/null 2>&1 || rc=$?
[[ "$rc" == "4" && "$(acts)" == "3" ]] && pass "budget: spent 200 < 201 resumes the opened run, then stops before the next" || fail "budget: resume under budget gave exit $rc with $(acts) acts"
unset STUB_RUN_COST

# ---- the seat loop's stops --------------------------------------------------

scenario wait
export STUB_GATE_MODE=wait
rc=0; xp run --exp-id 20261017-000000a1 --budget-usd 1000 >/dev/null 2>&1 || rc=$?
[[ "$rc" == "3" && "$(pstate 20261017-000000a1 1 status)" == "사람 대기" && "$(acts)" == "1" ]] \
  && pass "seat: gate exit 5 → pair 사람 대기, exit 3" || fail "seat: exit 5 gave exit $rc"
scenario failgate
export STUB_GATE_MODE=fail
rc=0; xp run --exp-id 20261017-000000a2 --budget-usd 1000 >/dev/null 2>&1 || rc=$?
[[ "$rc" == "1" && "$(pstate 20261017-000000a2 1 status)" == "실패" ]] && pass "seat: other gate exit → pair 실패, exit 1" || fail "seat: exit 7 gave exit $rc"
# A shift that handed off with 승인 or 중단 waits on a person: the seat sends no
# 대기 after it.
for h in 승인 중단; do
  scenario "handoff-$h"
  export STUB_GATE_MODE=handoff STUB_HANDOFF="$h"
  rc=0; xp run --exp-id 20261017-000000a4 --budget-usd 1000 > "$sc/out" 2>&1 || rc=$?
  [[ "$rc" == "3" && "$(pstate 20261017-000000a4 1 status)" == "사람 대기" && "$(acts)" == "1" ]] \
    && pass "seat: a ${h} handoff → pair 사람 대기, exit 3, no 대기 call" || fail "seat: ${h} handoff gave exit $rc with $(acts) acts"
  grep -q 'wall-clock deadline 20' "$sc/out" \
    && pass "seat: the ${h} stop prints the run's deadline" || fail "seat: the ${h} stop does not print the deadline"
done
grep -q 'a shell seat cannot close an approval' "$tmp/sc-handoff-승인/out" \
  && pass "seat: the 승인 stop says a shell seat cannot close the approval" || fail "seat: the 승인 stop does not say the shell seat cannot close it"

# A 중단 handoff whose halt record carries a recommendation is answered by the
# seat, which then relaunches with 중단 and carries the run on.
scenario halt-rec
export STUB_GATE_MODE=handoff STUB_HANDOFF=중단 STUB_HALT=rec
rc=0; xp run --exp-id 20261017-000000a5 --budget-usd 1000 > "$sc/out" 2>&1 || rc=$?
ha=$(grep -c -- '--kind halt-answer' "$STUB_GATE_LOG" || true)
first_ha=$(grep -n -- '--kind halt-answer' "$STUB_GATE_LOG" | head -n 1 | cut -d: -f1)
after=$(sed -n "$((first_ha + 1))p" "$STUB_GATE_LOG")
# Every run finishes, so the call goes on to classification and stops on its
# ambiguous defect, as the full scenario's first call does.
[[ "$rc" == "3" && "$ha" == "10" ]] && grep -q 'ambiguous defect(s) wait on a person' "$sc/out" \
  && pass "seat: a recommended halt is answered on every run and the experiment reaches classification" || { fail "seat: recommended halt gave exit $rc with $ha answers"; cat "$sc/out" >&2; }
grep -- '--kind halt-answer' "$STUB_GATE_LOG" | head -n 1 | grep -q '답한 주체=좌석 근거=중단 기록의 추천을 받았다 — 근거 종류 인터뷰 기록,상시 지침 첨부=' \
  && pass "seat: the answer is a seat answer naming the grounds' kinds" || fail "seat: the answer argv is $(grep -- '--kind halt-answer' "$STUB_GATE_LOG" | head -n 1)"
[[ "$after" == *"--kind router-shift"*" -- 중단 -p "* ]] \
  && pass "seat: after the answer the seat relaunches with 중단" || fail "seat: the call after the answer is $after"
ans=$(ls "$sc"/xdg/cc-cmds/run/*/halt/D1#1.answer.md 2>/dev/null | head -n 1)
[[ -n "$ans" ]] && grep -q '^- 인터뷰 기록:첫째로 한다$' "$ans" && grep -q '^되돌리는 법: ' "$ans" \
  && pass "seat: the attachment carries each ground and how to take the answer back" || fail "seat: the attachment is missing or incomplete"

# A record with no recommendation, or one the gate refuses a seat answer for,
# stops on a person with the record and a halt-answer command to run.
scenario halt-norec
export STUB_GATE_MODE=handoff STUB_HANDOFF=중단 STUB_HALT=norec
rc=0; xp run --exp-id 20261017-000000a6 --budget-usd 1000 > "$sc/out" 2>&1 || rc=$?
[[ "$rc" == "3" && "$(acts)" == "1" ]] && grep -q 'Halt record: .*/halt/D1#1.md$' "$sc/out" && grep -q -- "--kind halt-answer --target exp --segment D1 .* '답한 주체=사람'" "$sc/out" \
  && pass "seat: a halt with no recommendation stops with the record and a halt-answer command" || { fail "seat: a halt with no recommendation gave exit $rc with $(acts) acts"; cat "$sc/out" >&2; }
scenario halt-refused
export STUB_GATE_MODE=handoff STUB_HANDOFF=중단 STUB_HALT=rec STUB_HALT_ANSWER_RC=3
rc=0; xp run --exp-id 20261017-000000a7 --budget-usd 1000 > "$sc/out" 2>&1 || rc=$?
ls "$sc"/xdg/cc-cmds/run/*/halt/D1#1.answer.md >/dev/null 2>&1 && left=1 || left=0
[[ "$rc" == "3" && "$(pstate 20261017-000000a7 1 status)" == "사람 대기" && "$left" == "0" ]] && grep -q 'Halt record: .*/halt/D1#1.md$' "$sc/out" \
  && pass "seat: a refused seat answer leaves the record for a person and no attachment" || fail "seat: a refused seat answer gave exit $rc (attachment left: $left)"

# A run the wall-clock deadline closed is not a finished run.
scenario deadline
export STUB_GATE_MODE=deadline
rc=0; xp run --exp-id 20261017-000000a8 --budget-usd 1000 >/dev/null 2>&1 || rc=$?
r8="$main/docs/solo-audit-experiment/20261017-000000a8"
[[ "$rc" == "0" && "$(awk -F'\t' '$1 == "invalid_reason" { print $2 }' "$r8/pairs/1/pair.tsv")" == "벽시계 마감으로 닫힘" ]] \
  && pass "seat: a run closed by the deadline makes the pair invalid under that reason" || fail "seat: a deadline-closed run gave exit $rc"

scenario nofreeze
export STUB_NO_FREEZE=1
rc=0; xp run --exp-id 20261017-000000a3 --budget-usd 1000 >/dev/null 2>&1 || rc=$?
r3="$main/docs/solo-audit-experiment/20261017-000000a3"
[[ "$rc" == "0" && "$(awk -F'\t' '$1 == "invalid_reason" { print $2 }' "$r3/pairs/1/pair.tsv")" == "동결 문서 없음" && "$(tail -n 1 "$r3/report.md")" == "# verdict: 판정 불가" ]] \
  && pass "seat: no 동결됨 line → pair invalid, verdict 판정 불가" || fail "seat: no-freeze gave exit $rc"
[[ "$(acts)" == "10" ]] && pass "seat: an invalid pair does not start its audit run" || fail "seat: $(acts) acts with every design invalid"

# ---- contamination ----------------------------------------------------------

scenario contam
export STUB_CONTAM="Read ${main}/docs/c1.md"
rc=0; xp run --exp-id 20261017-000000c1 --budget-usd 1000 >/dev/null 2>&1 || rc=$?
rc1="$main/docs/solo-audit-experiment/20261017-000000c1"
[[ "$(awk -F'\t' '$1 == "invalid_reason" { print $2 }' "$rc1/pairs/1/pair.tsv")" == "오염 의심" ]] && grep -qF "docs/c1.md" "$rc1/pairs/1/contamination.txt" \
  && pass "contamination: the team document's path → 오염 의심, the hit recorded" || fail "contamination: path not detected"
[[ "$(awk -F'\t' '$1 == "status" { print $2 }' "$rc1/pairs/2/pair.tsv")" == "유효" ]] \
  && pass "contamination: another pair's document path is not a hit" || fail "contamination: pair 2 was not valid"
scenario contam2
export STUB_CONTAM="원 런 20261011-00000c11 의 인터뷰 기록"
xp run --exp-id 20261017-000000c2 --budget-usd 1000 >/dev/null 2>&1 || true
[[ "$(awk -F'\t' '$1 == "status" { print $2 }' "$main/docs/solo-audit-experiment/20261017-000000c2/pairs/1/pair.tsv")" == "유효" ]] \
  && pass "contamination: the original run id alone is not a hit" || fail "contamination: run id alone made the pair invalid"

# ---- classification cross-check --------------------------------------------

scenario dropid
export STUB_CLI_DROP=1
rc=0; xp run --exp-id 20261017-000000e2 --budget-usd 1000 >/dev/null 2>&1 || rc=$?
r4="$main/docs/solo-audit-experiment/20261017-000000e2"
case "$(awk -F'\t' '$1 == "invalid_reason" { print $2 }' "$r4/pairs/1/pair.tsv")" in
  "분류 교차 검사 실패 (team "*"id 수 1 ≠ 고유 결함 수 2)") pass "classify: id count ≠ fence → pair invalid" ;;
  *) fail "classify: id-count mismatch not caught (exit $rc)" ;;
esac
scenario route
alt="$tmp/solo-alt"; rm -rf "$alt"; cp -R "$solo_src" "$alt"
awk '{ if ($0 == "**라우팅 — 조정 패스 적용**: 1") print "**라우팅 — 조정 패스 적용**: 0"; else if ($0 == "**라우팅 — 미해결 이슈**: 0") print "**라우팅 — 미해결 이슈**: 1"; else print }' \
  "$solo_src/docs-c1.md" > "$alt/docs-c1.md"
export STUB_SOLO_REPORTS="$alt"
xp run --exp-id 20261017-000000e3 --budget-usd 1000 >/dev/null 2>&1 || true
export STUB_SOLO_REPORTS="$solo_src"
case "$(awk -F'\t' '$1 == "invalid_reason" { print $2 }' "$main/docs/solo-audit-experiment/20261017-000000e3/pairs/1/pair.tsv")" in
  "분류 교차 검사 실패 (solo "*"라우팅 조정 패스 적용: 1 ≠ 공시 0)") pass "classify: routing count ≠ fence → pair invalid" ;;
  *) fail "classify: routing mismatch not caught" ;;
esac

# ---- the solo side's first audit -------------------------------------------

# The audit run's first report parked without the block and a re-audit was
# written under another name: the pair is invalid for that reason.
scenario soloparked
alt="$tmp/solo-parked"; rm -rf "$alt"; cp -R "$solo_src" "$alt"
awk -v b="$FB" -v e="$FE" 'index($0, b) == 1 { s = 1; next } index($0, e) == 1 { s = 0; next } !s' "$solo_src/docs-c1.md" > "$alt/docs-c1.md"
mk_report "$alt/docs-c1.R2.md" docs/c1.md 2026-10-17T02:00:00Z 2000 0 2 1
export STUB_SOLO_REPORTS="$alt"
xp run --exp-id 20261017-000000e4 --budget-usd 1000 >/dev/null 2>&1 || true
export STUB_SOLO_REPORTS="$solo_src"
[[ "$(awk -F'\t' '$1 == "invalid_reason" { print $2 }' "$main/docs/solo-audit-experiment/20261017-000000e4/pairs/1/pair.tsv")" == "첫 감사가 공시 블록 없이 멈춤 (docs-c1.md)" ]] \
  && pass "solo audit: a first report without the block → pair invalid for that reason" || fail "solo audit: parked first report not reported"
# The audit run moved its first report to .prior and a re-audit took the plain
# name: the earlier report is the one compared.
scenario soloprior
alt="$tmp/solo-prior"; rm -rf "$alt"; cp -R "$solo_src" "$alt"
cp "$solo_src/docs-c1.md" "$alt/docs-c1.prior-0000c1c1.md"
mk_report "$alt/docs-c1.md" docs/c1.md 2026-10-17T02:00:00Z 2000 0 3 1
export STUB_SOLO_REPORTS="$alt"
xp run --exp-id 20261017-000000e5 --budget-usd 1000 >/dev/null 2>&1 || true
export STUB_SOLO_REPORTS="$solo_src"
[[ "$(basename "$(pstate 20261017-000000e5 1 solo_report)")" == "docs-c1.prior-0000c1c1.md" ]] \
  && pass "solo audit: the earlier-frozen .prior report is the solo first audit" || fail "solo audit: solo report is '$(pstate 20261017-000000e5 1 solo_report)'"

# ---- rerun one pair ---------------------------------------------------------

SOLO_EXP_STATE_ROOT="$tmp/sc-contam/state"
export XDG_STATE_HOME="$tmp/sc-contam/xdg" STUB_GATE_LOG="$tmp/sc-contam/gate.log" STUB_CLI_LOG="$tmp/sc-contam/cli.log"
export SOLO_EXP_STATE_ROOT
unset STUB_CONTAM
before=$(acts)
rc=0; xp --rerun-pair 1 --exp-id 20261017-000000c1 --budget-usd 1000 >/dev/null 2>&1 || rc=$?
[[ "$(awk -F'\t' '$1 == "status" { print $2 }' "$rc1/pairs/1/pair.tsv")" == "유효" && "$(( $(acts) - before ))" == "4" ]] \
  && pass "rerun: --rerun-pair 1 runs only pair 1 again and it is now valid" || fail "rerun: exit $rc, $(( $(acts) - before )) new acts"

echo
echo "test-solo-audit-experiment: ${passed} passed, ${failures} failed"
(( failures == 0 )) || exit 1
