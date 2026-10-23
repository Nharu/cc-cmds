#!/usr/bin/env bash
# Test scripts/reader-model-pair-audit.sh with `run --dry-run`.
#
# The real corpus (audit reports, run manifests, ledgers) lives under `docs/`,
# which is not tracked, so every input here is synthetic: a git repository
# built under `mktemp -d` stands in for the main repository. Its commit C
# carries copies of this checkout's plugins/cc-cmds/orchestrator/ and
# plugins/cc-cmds/skills/, so the branch clones' own run.sh performs the real
# manifest check. Nothing is billed: a `claude` placed first on PATH fails the
# suite if it is ever called, and no run directory or seat log may appear.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
runner="$script_dir/reader-model-pair-audit.sh"

failures=0
passed=0

pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }

for v in $(compgen -e | grep '^CC_PIPELINE_' || true); do unset "$v"; done

# The real run.sh below would reach the user's screen and leave a dashboard
# server behind; this suite asserts neither, so both are off.
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
CC_CMDS_DASHBOARD=off
export CC_CMDS_DASHBOARD

# A short prefix: the gate's run row carries paths under this directory and
# has a byte cap, which a long TMPDIR such as macOS's would otherwise pass.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/rmpa.XXXXXX")
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

TIER="plugins/cc-cmds/skills/_common/team-model-tier.md"

# ---- a CLI stand-in that must never be called ---------------------------------

mkdir -p "$tmp/bin"
cat > "$tmp/bin/claude" <<EOF
#!/usr/bin/env bash
echo "claude \$*" >> "$tmp/claude.called"
exit 1
EOF
chmod +x "$tmp/bin/claude"
export PATH="$tmp/bin:$PATH"
# The gate resolves the CLI from this variable before PATH, and a pipeline
# stage exports it as the real CLI.
export CC_CLAUDE_BIN="$tmp/bin/claude"

# ---- the synthetic main repository -------------------------------------------

main="$tmp/main"
mkdir -p "$main"
(
  cd "$main"
  git init -q -b master
  git config user.email t@example.invalid; git config user.name t
  echo base > README; git add README; git commit -q -m base
)
base=$(cd "$main" && git rev-parse HEAD)
mkdir -p "$main/plugins/cc-cmds"
cp -R "$repo_root/plugins/cc-cmds/orchestrator" "$repo_root/plugins/cc-cmds/skills" "$repo_root/plugins/cc-cmds/hooks" "$main/plugins/cc-cmds/"
( cd "$main" && git add plugins && git commit -q -m "plugin at C" )
C=$(cd "$main" && git rev-parse HEAD)
# A later commit whose row is opus: a --ref there is refused.
awk 'index($0, "| `audit-reader` |") == 1 { n = split($0, c, "|"); c[n-1] = " opus "; s = ""; for (i = 1; i < n; i++) s = s c[i] "|"; print s; next } { print }' \
  "$main/$TIER" > "$main/$TIER.new" && mv "$main/$TIER.new" "$main/$TIER"
( cd "$main" && git commit -q -am "row opus" )
C_OPUS=$(cd "$main" && git rev-parse HEAD)
( cd "$main" && git checkout -q "$C" -- "$TIER" && git commit -q -am "row sonnet again" )
other="ffffffffffffffffffffffffffffffffffffffff"
mkdir -p "$main/docs/design-audit" "$main/docs/pipeline-run"

FB='<!-- cc-design-audit-disclosure v1 begin -->'
FE='<!-- /cc-design-audit-disclosure v1 end -->'
SB='<!-- cc-design-audit-skeletal v1 begin -->'
SE='<!-- /cc-design-audit-skeletal v1 end -->'

# mk_report <file> <owner-doc> <frozen at> <unique> [<model>] [double|nofence]
mk_report() {
  local f="$1" owner="$2" at="$3" u="$4" model="${5:-opus}" shape="${6:-}" block
  block="${FB}
**동결 문서 sha256**: 0000000000000000000000000000000000000000000000000000000000000000
**동결 문서 바이트**: 2048
**동결 시각**: ${at}
**리뷰어 수**: 3
**고유 결함 수**: ${u}
**미보강 잔여 수**: 0
**라우팅 — 기각**: 0
${FE}"
  {
    echo "# 설계 감사 — ${owner}"
    echo "<!-- cc-design-audit v1; writer=design-audit; reader=design-audit; owner-doc=${owner}; origin-worktree=${main}; NOT a design doc; mechanism-local, never staged by a skill -->"
    echo
    echo "## 감사 개시"
    echo "- 대상: ${main}/${owner}"
    echo "- frozen-at: ${at}"
    echo "- reader-model: ${model}"
    echo
    if [[ "$shape" != "nofence" ]]; then
      echo "$block"
      [[ "$shape" != "double" ]] || echo "$block"
      printf '%s\n**골격급 수**: 0\n**합성 요구 골격급 수**: 0\n%s\n' "$SB" "$SE"
    fi
  } > "$f"
}

# mk_run <run id> <owner-doc> <kickoff> <base>
mk_run() {
  local rid="$1" owner="$2" ko="$3" b="$4" pr="$main/docs/pipeline-run"
  cat > "$pr/$rid.plan.md" <<EOF
# 파이프라인 런 매니페스트 — ${rid}
<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=${rid};
     anchor-kind=intent; anchor-key=x;
     owner-doc=${owner}; origin-worktree=${main};
     NOT a design doc; mechanism-local, never staged by a skill -->

## 런 정체
**킥오프 일시**: ${ko}
**런 id**: ${rid}
EOF
  cat > "$pr/$rid.md" <<EOF
# 파이프라인 런 보고서 — ${rid}
- \`run\` | 교대=0 | run-id=${rid} | 판본=${b} | prev=0
- \`stage-result\` | 교대=1 | 세그먼트=- | 스테이지=D1 | 종류=design | 종료 코드=0 | 종단 부류=정상 완료 | prev=1
EOF
}

# mk_doc <owner-doc> <tree commit> [<frozen lines>]
mk_doc() {
  mkdir -p "$(dirname "$main/$1")"
  {
    printf '# 설계 — %s\n' "$1"
    local i
    for i in $(seq 1 "${3:-1}"); do printf '**상태**: 동결됨\n'; done
    printf '**기준 트리**: %s master %s (v2.80.0)\n' "$main" "${2:0:8}"
  } > "$main/$1"
}

dar="$main/docs/design-audit"
# Candidates: unique 2 4 6 8 10 12 → ranks 0 1 3 4 5 pick c1 c2 c4 c5 c6.
for s in 1 2 3 4 5 6; do
  mk_doc "docs/c$s.md" "$base"; mk_run "20261011-00000c${s}1" "docs/c$s.md" 2026-10-11T00:00:00Z "$base"
  mk_report "$dar/docs-c$s.md" "docs/c$s.md" 2026-10-13T00:00:00Z $((s * 2))
done
mk_report "$dar/docs-c1.A1-3.md" docs/c1.md 2026-10-14T00:00:00Z 7
mk_report "$dar/docs-c1.reader-1.md" docs/c1.md 2026-10-13T00:00:00Z 40
mk_report "$dar/docs-c1.reader-2.fanout.md" docs/c1.md 2026-10-13T00:00:00Z 40
# Excluded, each for one reason.
mk_doc docs/s1.md "$base"; mk_run 20261011-00000a11 docs/s1.md 2026-10-11T00:00:00Z "$base"
mk_report "$dar/docs-s1.md" docs/s1.md 2026-10-13T00:00:00Z 3 sonnet
mk_doc docs/nf.md "$base"; mk_run 20261011-00000a21 docs/nf.md 2026-10-11T00:00:00Z "$base"
mk_report "$dar/docs-nf.md" docs/nf.md 2026-10-13T00:00:00Z 3 opus nofence
mk_doc docs/db.md "$base"; mk_run 20261011-00000a31 docs/db.md 2026-10-11T00:00:00Z "$base"
mk_report "$dar/docs-db.md" docs/db.md 2026-10-13T00:00:00Z 3 opus double
mk_run 20261011-00000a41 docs/md.md 2026-10-11T00:00:00Z "$base"
mk_report "$dar/docs-md.md" docs/md.md 2026-10-13T00:00:00Z 3
mk_doc docs/fz.md "$base" 2; mk_run 20261011-00000a51 docs/fz.md 2026-10-11T00:00:00Z "$base"
mk_report "$dar/docs-fz.md" docs/fz.md 2026-10-13T00:00:00Z 3
mk_doc docs/nr.md "$base"
mk_report "$dar/docs-nr.md" docs/nr.md 2026-10-13T00:00:00Z 3
mk_doc docs/g1.md "$C"; mk_run 20261011-00000a61 docs/g1.md 2026-10-11T00:00:00Z "$base"
mk_report "$dar/docs-g1.md" docs/g1.md 2026-10-13T00:00:00Z 3
mk_doc docs/nb.md "$other"; mk_run 20261011-00000a71 docs/nb.md 2026-10-11T00:00:00Z "$other"
mk_report "$dar/docs-nb.md" docs/nb.md 2026-10-13T00:00:00Z 3
# A lead report whose slug carries `reader-`: in the population, not a copy.
mk_doc docs/reader-x.md "$base"
mk_report "$dar/docs-reader-x.md" docs/reader-x.md 2026-10-13T00:00:00Z 3

# scenario <name> — fresh state for one experiment.
scenario() {
  sc="$tmp/sc-$1"
  mkdir -p "$sc"
  export XDG_STATE_HOME="$sc/xdg" READER_EXP_STATE_ROOT="$sc/state" CLAUDE_CONFIG_DIR="$sc/cfg"
}
xp() { bash "$runner" --repo "$main" "$@"; }
bstate() { awk -F'\t' -v k="$4" '$1 == k { print substr($0, length(k) + 2); exit }' "$READER_EXP_STATE_ROOT/$1/doc-$2/$3.state"; }

# ---- usage --------------------------------------------------------------------

scenario usage
rc=0; xp run --exp-id 20261022-0000000a >/dev/null 2>&1 || rc=$?
[[ "$rc" == "2" ]] && pass "usage: billed call without --budget-usd → exit 2" || fail "usage: no --budget-usd gave exit $rc"
rc=0; xp --rerun-doc 6 --exp-id 20261022-0000000a --budget-usd 9 >/dev/null 2>&1 || rc=$?
[[ "$rc" == "2" ]] && pass "usage: --rerun-doc outside 1..5 → exit 2" || fail "usage: --rerun-doc 6 gave exit $rc"
rc=0; xp run --dry-run --bogus >/dev/null 2>&1 || rc=$?
[[ "$rc" == "2" ]] && pass "usage: an unknown argument → exit 2" || fail "usage: an unknown argument gave exit $rc"
[[ ! -e "$main/docs/reader-model-pair-audit/20261022-0000000a" ]] && pass "usage: a refused call writes no experiment directory" || fail "usage: a refused call wrote the experiment directory"

# ---- selection, branches and preparation (dry run) -----------------------------

scenario dry
E1=20261022-000000d1
rc=0; xp run --dry-run --exp-id "$E1" > "$sc/out" 2>&1 || rc=$?
if [[ "$rc" == "0" ]]; then pass "dry run exits 0"; else fail "dry run gave exit $rc"; cat "$sc/out" >&2; fi
sel="$main/docs/reader-model-pair-audit/$E1/selection.tsv"
disp() { awk -F'\t' -v r="$1" '$1 == r { print $7 "|" $8 }' "$sel"; }
got=$(awk -F'\t' '$7 ~ /^선정 / { print $7 "=" $1 }' "$sel" | LC_ALL=C sort | tr '\n' ' ')
[[ "$got" == "선정 1=docs-c1.md 선정 2=docs-c2.md 선정 3=docs-c4.md 선정 4=docs-c5.md 선정 5=docs-c6.md " ]] \
  && pass "selection: quantile ranks 0 1 3 4 5 of six candidates" || fail "selection: picked '$got'"
[[ "$(disp docs-c3.md)" == "후보|-" ]] && pass "selection: the unpicked candidate stays a 후보" || fail "selection: c3 is '$(disp docs-c3.md)'"
# want_disp <report> <disposition|reason pattern> <what> — a trailing `*` in the
# pattern matches the rest of the reason.
want_disp() {
  # shellcheck disable=SC2254
  case "$(disp "$1")" in $2) pass "selection: $3" ;; *) fail "selection: $1 is '$(disp "$1")', not '$2'" ;; esac
}
want_disp docs-c1.A1-3.md "제외|같은 owner-doc 의 첫 감사 보고서 docs-c1.md 가 따로 있다 (재감사)" "a re-audit is excluded"
want_disp docs-s1.md "제외|reader-model 이 opus 가 아니다 (sonnet)" "a sonnet-reader audit is not a candidate"
want_disp docs-nf.md "제외|공시 v1 울타리가 없다" "a report without the fence is recorded as 제외"
want_disp docs-db.md "제외|공시 울타리가 한 쌍이 아니다 (모든 칸 미상)" "a doubled fence reads unknown and is excluded with its reason"
want_disp docs-md.md "제외|owner-doc 이 메인 체크아웃에 없다" "an owner-doc missing from the main checkout is excluded"
want_disp docs-fz.md "제외|**상태**: 동결됨 줄이 2개다" "an owner-doc without exactly one frozen line is excluded"
want_disp docs-nr.md "제외|원 런이 없다*" "a document without an original run is excluded"
want_disp docs-g1.md "제외|기준 트리*" "기준 트리 ≠ 판본= is excluded"
want_disp docs-nb.md "제외|기준 커밋이 저장소에 없다" "a 판본= outside the repository is excluded"
want_disp docs-reader-x.md "제외|원 런이 없다*" "a lead report whose slug carries reader- stays in the population"
[[ -z "$(disp docs-c1.reader-1.md)" && -z "$(disp docs-c1.reader-2.fanout.md)" ]] \
  && pass "selection: reader copies are not in the population" || fail "selection: a reader copy is listed"
[[ "$(awk -F'\t' '$1 == "docs-c2.md" { print $5 }' "$sel")" == "20261011-00000c21" ]] \
  && pass "selection: the original run is recorded" || fail "selection: c2's original run is wrong"

# Branches.
ST1="$READER_EXP_STATE_ROOT/$E1"
gs="$ST1/gate-sonnet"; go="$ST1/gate-opus"
head_c=$(cd "$main" && git rev-parse HEAD)
[[ "$(cd "$gs" && git rev-parse HEAD)" == "$head_c" && -z "$(cd "$gs" && git remote)" ]] \
  && pass "branches: the sonnet clone is HEAD of --repo with no remote" || fail "branches: the sonnet clone is not C without a remote"
[[ "$(cd "$go" && git rev-parse HEAD^)" == "$head_c" && -z "$(cd "$go" && git remote)" ]] \
  && pass "branches: the opus clone is one commit on C with no remote" || fail "branches: the opus clone is not one commit on C"
got=$(cd "$go" && git diff --numstat "$head_c" HEAD)
[[ "$got" == "1	1	${TIER}" ]] && pass "branches: the two branch commits differ by exactly the one row" || fail "branches: numstat is '$got'"
grep -qF '| `audit-reader` | every design-audit reader, identically | opus |' "$go/$TIER" \
  && pass "branches: the opus branch's row names opus" || fail "branches: the opus row is wrong"
[[ "$(cd "$go" && git log -1 --format='%an %aI')" == "reader-model-pair-audit 2026-01-01T00:00:00Z" ]] \
  && pass "branches: the opus commit has a fixed author and date" || fail "branches: the opus commit author/date is not fixed"

# Preparation.
ok=1
for n in 1 2 3 4 5; do
  ins=$(awk -F'\t' '$1 == "input_sha" { print $2 }' "$ST1/doc-$n/doc.state")
  doc=$(awk -F'\t' '$1 == "doc" { print $2 }' "$ST1/doc-$n/doc.state")
  [[ "$ins" == "$(shasum -a 256 "$main/$doc" | cut -d' ' -f1)" ]] || { ok=0; echo "doc $n: input sha differs" >&2; }
  for br in opus-1 sonnet opus-2; do
    cl=$(bstate "$E1" "$n" "$br" clone)
    [[ "$(cd "$cl" && git rev-parse HEAD)" == "$base" && "$(cd "$cl" && git for-each-ref --format='%(refname)')" == "refs/heads/exp-base" && -z "$(cd "$cl" && git remote)" ]] \
      || { ok=0; echo "doc $n $br: the target clone is not exp-base at the base commit alone" >&2; }
    cmp -s "$main/$doc" "$cl/$doc" || { ok=0; echo "doc $n $br: the input copy differs" >&2; }
  done
done
(( ok == 1 )) && pass "prepare: fifteen target clones at the base commit, each with the main checkout's bytes" || fail "prepare: a target clone is wrong"
r1=$(bstate "$E1" 1 opus-1 run); r2=$(bstate "$E1" 1 sonnet run); r3=$(bstate "$E1" 1 opus-2 run)
[[ "$r1" != "$r2" && "$r2" != "$r3" && "$r1" != "$r3" ]] && pass "prepare: each audit has its own run id" || fail "prepare: run ids collide"
am=$(bstate "$E1" 1 sonnet manifest)
grep -qF '"entry_skill": "design-audit"' "$am" && grep -qF 'anchor-kind=doc; anchor-key=docs/c1.md;' "$am" && grep -qF '원격 슬러그=local/reader-model-exp | 절단점=커밋' "$am" \
  && pass "prepare: the audit manifest anchors the document on the local slug at cutpoint 커밋" || fail "prepare: audit manifest wrong"

# The check itself is the branch driver's, not a stub: re-run it on every manifest.
ok=1
for n in 1 2 3 4 5; do
  for br in opus-1 sonnet opus-2; do
    m=$(bstate "$E1" "$n" "$br" manifest); cl=$(bstate "$E1" "$n" "$br" clone)
    rs="$ST1/gate-${br%-*}/plugins/cc-cmds/orchestrator/run.sh"
    ( cd "$cl" && CC_ORCH_SOURCE_ONLY=1 && . "$rs" && MANIFEST="$m" && check_manifest ) >/dev/null 2>"$sc/check.err" \
      || { ok=0; echo "check_manifest failed: $m" >&2; cat "$sc/check.err" >&2; }
  done
done
(( ok == 1 )) && pass "prepare: all fifteen manifests pass their branch's check_manifest" || fail "prepare: a manifest fails check_manifest"
m=$(bstate "$E1" 1 sonnet manifest); cl=$(bstate "$E1" 1 sonnet clone)
sed 's/^\*\*구속 다이제스트\*\*: .*/**구속 다이제스트**: 0000/' "$m" > "$m.broken"
if ( cd "$cl" && CC_ORCH_SOURCE_ONLY=1 && . "$gs/plugins/cc-cmds/orchestrator/run.sh" && MANIFEST="$m.broken" && check_manifest ) >/dev/null 2>&1; then
  fail "prepare: check_manifest accepted a wrong binding digest (the check is not biting)"
else
  pass "prepare: check_manifest refuses a wrong binding digest"
fi
rm -f "$m.broken"

# Nothing billed.
[[ ! -e "$tmp/claude.called" ]] && pass "dry run: the claude stand-in was never called" || fail "dry run: claude was called: $(cat "$tmp/claude.called")"
seatlogs=$(find "$ST1" -name 'seat-*.log' | wc -l | tr -d ' ')
runs=0
[[ ! -d "$XDG_STATE_HOME/cc-cmds/run" ]] || runs=$(find "$XDG_STATE_HOME/cc-cmds/run" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
if [[ "$seatlogs" == "0" && "$runs" == "0" ]] && ! grep -qE 'gate\.sh.* act ' "$sc/out"; then
  pass "dry run: no seat log, no run directory and no gate act in the runner's record"
else
  fail "dry run: ${seatlogs} seat log(s), ${runs} run dir(s)"
fi

# The gate a seat would act through reads every manifest: its snapshot, never
# act. The snapshot pins the plugin, and with no origin the pin is the branch
# clone's own HEAD — the commit that makes the two branches one row apart.
snap=1; pinok=1
oc=$(cd "$go" && git rev-parse HEAD)
for n in 1 2 3 4 5; do
  for br in opus-1 sonnet opus-2; do
    m=$(bstate "$E1" "$n" "$br" manifest); cl=$(bstate "$E1" "$n" "$br" clone); rid=$(bstate "$E1" "$n" "$br" run)
    ( cd "$cl" && bash "$ST1/gate-${br%-*}/plugins/cc-cmds/orchestrator/gate.sh" snapshot --manifest "$m" --fields H ) >"$sc/snap.out" 2>"$sc/snap.err" \
      && [[ -s "$sc/snap.out" ]] || { snap=0; echo "gate snapshot failed: $m" >&2; cat "$sc/snap.err" >&2; }
    if [[ "${br%-*}" == "opus" ]]; then want="$oc"; else want="$head_c"; fi
    got=$(awk -F'\t' '$1 == "commit" { print $2; exit }' "$XDG_STATE_HOME/cc-cmds/run/$rid/plugin-pin" 2>/dev/null || true)
    [[ "$got" == "$want" ]] || { pinok=0; echo "doc $n $br: pinned '${got}', branch commit ${want}" >&2; }
  done
done
(( snap == 1 )) && pass "prepare: the branch gates' snapshots exit 0 on all fifteen manifests" || fail "prepare: a branch gate snapshot fails on a manifest"
(( pinok == 1 )) && pass "prepare: each run's plugin pin is its branch commit" || fail "prepare: a run's plugin pin is not its branch commit"

# ---- the cost ceiling ends a run after its audit stage -------------------------
#
# One router-shift call runs the relay, which launches the successor shift as
# soon as the audit stage ends, so the seat cannot stop a re-convergence
# between calls. The run's cost ceiling stops it: the gate ends the run at the
# first gated call after the stage's `cost` row, and an ended run launches no
# stage. Driven here through the branch's real gate, with no stage launched.

ok=1
for n in 1 2 3 4 5; do
  for br in opus-1 sonnet opus-2; do
    grep -qxF '**비용 천장**: 0.01' "$(bstate "$E1" "$n" "$br" manifest)" || { ok=0; echo "doc $n $br: no cost ceiling 0.01" >&2; }
  done
done
(( ok == 1 )) && pass "ceiling: every audit manifest declares the cost ceiling 0.01" || fail "ceiling: a manifest lacks the cost ceiling"

m=$(bstate "$E1" 1 sonnet manifest); cl=$(bstate "$E1" 1 sonnet clone); rid=$(bstate "$E1" 1 sonnet run)
g1="$gs/plugins/cc-cmds/orchestrator/gate.sh"
led="$cl/docs/pipeline-run/$rid.md"
rdir="$XDG_STATE_HOME/cc-cmds/run/$rid"
snap_h() { ( cd "$cl" && bash "$g1" snapshot --manifest "$m" --fields H 2>/dev/null ) | tail -n 1; }
gread() {
  ( cd "$cl" && bash "$g1" exec --manifest "$m" --target exp --segment - --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(snap_h)" --rationale 'ceiling test read' -- git rev-parse HEAD ) >>"$sc/ceiling.log" 2>&1
}
rc=0; gread || rc=$?
if [[ "$rc" == "0" && ! -e "$rdir/done" ]]; then
  pass "ceiling: a gated read before any stage is costed leaves the run open"
else
  fail "ceiling: the read before any cost gave exit $rc (done: $([[ -e "$rdir/done" ]] && echo yes || echo no))"; cat "$sc/ceiling.log" >&2
fi
# The audit stage's cost row, chained the way the gate chains it.
last=$(grep '^- `' "$led" | tail -n 1)
printf -- '- `cost` | 누적 usd=12.5000 | 스테이지 수=1 | 관측 시각=2026-10-22T00:00:00Z | prev=%s\n' \
  "$(printf '%s' "$last" | shasum -a 256 | cut -d' ' -f1)" >> "$led"
rc=0; gread || rc=$?
if [[ -s "$rdir/done" ]] && grep -qF 'B4' "$rdir/done"; then
  pass "ceiling: the first gated call after the audit's cost row ends the run at the cost boundary"
else
  fail "ceiling: no B4 ending after the cost row (exit $rc)"; cat "$sc/ceiling.log" >&2
fi
# A dispatch whose own entry checks hold — the audit stage's, since no stage
# row stands — reaches the ended-run refusal.
rc=0
( cd "$cl" && bash "$g1" act --manifest "$m" --kind skill --target exp --segment - --cutpoint 커밋 --surface 워크트리쓰기 \
    --snapshot-digest "$(snap_h)" --rationale '감사 스테이지' \
    -- audit -p "/cc-cmds:design-audit-unattended $cl/docs/c1.md" ) >>"$sc/ceiling.log" 2>&1 || rc=$?
if [[ "$rc" != "0" && ! -e "$tmp/claude.called" ]] && grep -qF 'no new stage is launched' "$sc/ceiling.log"; then
  pass "ceiling: the ended run refuses a stage dispatch and launches nothing"
else
  fail "ceiling: the dispatch after the end gave exit $rc"; cat "$sc/ceiling.log" >&2
fi

# The same input gives the same selection.
scenario dry2
xp run --dry-run --exp-id 20261022-000000d2 >/dev/null 2>&1 || true
if diff -q "$sel" "$main/docs/reader-model-pair-audit/20261022-000000d2/selection.tsv" >/dev/null; then
  pass "selection: the same input gives the same selection"
else
  fail "selection: two runs disagree"
fi

# ---- C whose row is opus is refused ------------------------------------------

scenario opusref
rc=0; xp run --dry-run --exp-id 20261022-000000e1 --ref "$C_OPUS" > "$sc/out" 2>&1 || rc=$?
if [[ "$rc" == "1" ]] && grep -qF "is 'opus', not sonnet" "$sc/out" && [[ ! -e "$READER_EXP_STATE_ROOT/20261022-000000e1/doc-1" ]]; then
  pass "branches: a C whose audit-reader row is opus is refused with exit 1 before any preparation"
else
  fail "branches: --ref at the opus row gave exit $rc"; cat "$sc/out" >&2
fi
rc=0; xp run --dry-run --exp-id 20261022-000000e2 --ref "$C" > "$sc/out2" 2>&1 || rc=$?
[[ "$rc" == "0" ]] && pass "branches: --ref at a sonnet-row commit is accepted" || { fail "branches: --ref C gave exit $rc"; cat "$sc/out2" >&2; }

# ---- candidate shortage --------------------------------------------------------

scenario short
short="$tmp/short"
cp -R "$main" "$short"
rm -f "$short/docs/design-audit/docs-c5.md" "$short/docs/design-audit/docs-c6.md"
rm -rf "$short/docs/reader-model-pair-audit"
rc=0; bash "$runner" --repo "$short" run --exp-id 20261022-000000f1 --budget-usd 1000 >/dev/null 2>&1 || rc=$?
rep="$short/docs/reader-model-pair-audit/20261022-000000f1/report.md"
if [[ "$rc" == "0" && "$(tail -n 1 "$rep" 2>/dev/null)" == "# verdict: 판정 불가" ]] && grep -qF '후보 부족' "$rep" \
   && [[ ! -e "$READER_EXP_STATE_ROOT/20261022-000000f1/gate-sonnet" ]]; then
  pass "selection: four candidates → 판정 불가 (후보 부족), exit 0, no branch made"
else
  fail "selection: shortage gave exit $rc"
fi

# ---- status -----------------------------------------------------------------------

scenario dry
rc=0; xp status --exp-id "$E1" > "$sc/status" 2>&1 || rc=$?
if [[ "$rc" == "0" ]] && grep -qF 'document 1: 준비됨 · opus-1 준비됨 · sonnet 준비됨 · opus-2 준비됨' "$sc/status" && grep -qF 'verdict: pending' "$sc/status"; then
  pass "status: every document and branch reads 준비됨, verdict pending"
else
  fail "status: unexpected output (rc=$rc)"; cat "$sc/status" >&2
fi

# The guard's spent amount: a stage stream with no result line yet counts as
# the run reserve, a shift stream without one counts nothing, and a finished
# stream counts its result.
spent_of() { awk '/spent usd:/ { print $NF }' "$1"; }
s0=$(spent_of "$sc/status")
rl="$XDG_STATE_HOME/cc-cmds/run/$(bstate "$E1" 2 opus-1 run)/log"
mkdir -p "$rl"
printf '%s\n' '{"type":"system"}' > "$rl/A1#2.json"
printf '%s\n' '{"type":"system"}' > "$rl/shift-1.json"
printf '%s\n' '{"type":"result","total_cost_usd":2.5}' > "$rl/A1#1.json"
xp status --exp-id "$E1" > "$sc/status2" 2>&1 || true
s1=$(spent_of "$sc/status2")
if awk -v a="$s0" -v b="$s1" 'BEGIN { exit !(b - a == 152.5) }'; then
  pass "status: a running stage counts as the 150 reserve, a running shift as 0, a finished stage as its result"
else
  fail "status: spent went from '$s0' to '$s1', not up by 152.5"
fi

echo "test-reader-model-pair-audit: ${passed} passed, ${failures} failed"
(( failures == 0 ))
