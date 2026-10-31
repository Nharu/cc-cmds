#!/usr/bin/env bash
# lint-bash-portability: self-skip
# The static invariants that used to ride inside four large suites.
#
# WHY THESE BLOCKS LIVE HERE. Each one reads repository files and paths and
# nothing else — no fixture run, no ledger, no gate call — yet each sat in a
# suite that takes minutes, so the only way to run it was to run that whole
# suite, and a stage that ran only the axis it changed never ran them. Moved
# here, they run in seconds and `make check-cheap` can carry them. The blocks
# are moved whole: their assertions, wording and count are unchanged, and the
# suites they came from no longer carry them.
#
#   - the notifier-leak census          (from scripts/test-liveness-agreement.sh)
#   - the pipeline-marker set           (from scripts/test-session-notify-hook.sh)
#   - the detached-process fences       (from plugins/cc-cmds/orchestrator/test-run.sh, 28·28b)
#   - the router-copy sections          (from scripts/test-snapshot.sh, 6d–6e-4)
#
# ASSERTIONS THIS FILE ADDS ON ITS OWN: k = 14, plus the shift's branch index
# block (6e-6), which adds 5 + 3n for the shift's n reference files. The census selects every suite
# that runs or sources the gate family and asserts two exports and the
# pipeline-name clearing line for each, plus the line's position in a suite
# that is also sourced as a library. This file carries its recognition corpus,
# so it selects this file too, and scripts/test-local-bundle.sh runs
# test-gate.sh on its mirror, so it selects that one as well: two suites the
# source census did not see. The fix-cycle block (6e-3a) adds ten: the two pieces in the driver's
# two assignments and in the common file's start condition, the set of files
# pointing at that file, its missing question and notification surfaces, its
# missing copies, the phase sentence, and the start disposition and end
# obligation with their two spellings. Every other assertion here is one a
# source suite used to make.
#
# Usage: bash scripts/test-meta-invariants.sh

set -uo pipefail

# THE RUN NOTIFIER IS OFF FOR THIS WHOLE PROCESS. Nothing here starts the gate,
# but the census below selects this file as a gate-family caller by its corpus
# and demands these two exports of it, the same as of every other such suite.
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
# The dashboard server is off for the same reason.
CC_CMDS_DASHBOARD=off
export CC_CMDS_DASHBOARD
# And it clears the inherited pipeline names, for the same reason: the census
# demands this line of every suite it selects, this one included.
for v in $(compgen -e | grep '^CC_PIPELINE_' || true); do unset "$v"; done

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
PLUGIN_ROOT="$repo_root/plugins/cc-cmds"
DRIVER="$PLUGIN_ROOT/orchestrator/run.sh"
GATE="$PLUGIN_ROOT/orchestrator/gate.sh"
# The router copies the last block compares, defined once for all of its
# sections. `ap_all` reads the resident body and every reference together, so
# text moved between them can neither hide nor slip past an absence pin.
AP_SKILL="$PLUGIN_ROOT/skills/autopilot/SKILL.md"
AP_REFS="$PLUGIN_ROOT/skills/autopilot/references"
AP_ROUTER="$AP_REFS/router-lead-copy.md"
AP_SEAT="$AP_REFS/act2-seat.md"
ap_all() { cat "$AP_SKILL" "$AP_REFS"/*.md; }
# The shift's copy is read the same way: its rare branch procedures sit in
# `references/`, read only on their entry condition, so every pin on the shift
# reads `RS_CORPUS` — the body followed by every reference in glob order — and a
# section split across two files is still cut out as one by `router_section`.
RS_SKILL="$PLUGIN_ROOT/skills/autopilot-router-shift/SKILL.md"
RS_REFS="$PLUGIN_ROOT/skills/autopilot-router-shift/references"
rs_all() { cat "$RS_SKILL" "$RS_REFS"/*.md; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-meta-invariants.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
RS_CORPUS="$WORK/router-shift-corpus.md"
rs_all > "$RS_CORPUS"

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

# ---------------------------------------------------------------------------
# The notifier channel stays off for every suite that does not assert on it.
#
# This is a property OF THE SET, like the agreement above: any one suite can be
# guarded and the tree still reaches a person, because `make test` runs all of
# them and the gate's fire path defeats a PATH stub by prepending Homebrew's
# directories itself. Measured before the guard: two banners arrived at a user
# from an ordinary test run, one of them with sound.
#
# Asserted on the source rather than by firing, and the reason is the same one
# that makes the defect worth a test: to observe it behaviourally this suite
# would have to let a banner escape to the real notifier, which is the thing
# being prevented. So the check is that each suite carries the export, and the
# skip list names the ones that legitimately do not — for those the banner IS
# the subject, so a process-level kill would remove what they assert. The list
# is deliberately not counted here: it was, and the count outlived a change to
# the list itself, which is the same defect this file keeps finding one layer
# up — a statement that was true when written and became false with nothing
# about the statement changing.
# HOW MANY SUITES THIS SELECTS IS ITSELF AN OBSERVABLE. The predicate below has
# chosen nothing three times — a BRE `sed` whose alternation did not apply, a
# `grep -q` that lost a `pipefail` race on the largest file, and an ERE anchor
# written unescaped — and every time the suite ended with zero failures and a
# smaller total, which is what a clean tree looks like too. The count leaves the
# loop so that outcome can be asserted rather than left to a reader who happens
# to remember the previous total.
leak_pat() {
  # leak_pat <주석 걷어낸 소스> — build the ERE that recognises an invocation of
  # the gate, the driver or the watcher inside that source.
  #
  # A FUNCTION RATHER THAN A BLOCK INSIDE THE LOOP, because the tree the loop
  # reads does not exercise every branch of what it builds. Measured: the base
  # branch — a literal path after `bash` — selects ZERO suites here today, and
  # all four that are selected come from a handle branch. So that branch could be
  # deleted, or narrowed, without a single verdict moving. Lifted out, it can be
  # handed a corpus written for it; the recognition table below is that corpus.
  #
  # A `bash` THAT BEGINS INSIDE A STRING LITERAL IS DATA, NOT AN INVOCATION.
  # Some suites here carry command lines as fixtures — the pretool-hook suite
  # feeds `"bash $GATE snapshot …"` to the hook it is testing — and reading one
  # of those selects a suite that never runs the gate, then reports it as a
  # leak. So the character in front of `bash` may not be a double quote; nor may
  # it be part of a longer word, which is what keeps `bash_json` from counting.
  # Everything a real call site puts there — a line start, a space, a `(`, a
  # `/` — still counts.
  #
  # THE DERIVATION READS WORDS, NOT LINES, because a line-anchored extraction is
  # a closed list of assignment spellings wearing a regex — the same defect as
  # the hardcoded handle list it replaced, moved one layer down. Measured, it
  # missed `local`/`export`/`readonly` prefixes, a second assignment on the same
  # line, `H=$d/gate.sh` with no quotes, and `H="$d"/gate.sh` with the quotes
  # around the other half. Splitting on the shell's own separators first makes a
  # prefix its own word and every assignment its own word, so what is left to
  # recognise is `<name>=…<script>` — the one shape all of them share. A
  # trailing `;` needs no removal; the pattern's tail absorbs it.
  #
  # `sed -E`, and the flag is load-bearing. BSD sed's default BRE has no `|`
  # alternation, so the bracketed group matches nothing and the extraction
  # yields an empty handle list — which does not error, it selects no suites,
  # and every assertion in that loop disappears while the suite reports a
  # smaller green total. Measured: 30 assertions became 26 and nothing said so.
  #
  # THE FAMILY IS FOUR SCRIPTS AND THREE WAYS IN. The gate hook
  # `gate-pretool.sh` runs gate.sh, so a suite that drives the hook reaches the
  # gate as surely as one that calls it. Sourcing is running too: a suite that
  # sources the gate runs its functions in its own process and reads every
  # variable it inherited. And a `-c` shell handed a family path or handle as a
  # positional argument sources it as `"$1"`, a spelling no handle name shows.
  # Each of the three is a row of the corpus below, so narrowing any of them
  # fails that row rather than silently dropping a suite.
  local _src="$1" _h _ref _pat _fam _pre _shc
  _fam='(gate|run|watch|gate-pretool)\.sh'
  _pre='(^|[^"A-Za-z_0-9])'
  # The quote rule holds for `-c` as well: a `"` may stand only around `$BASH`,
  # never in front of a bare `bash`, or a fixture string would count again.
  _shc="$_pre"'(bash|sh|"\$\{?BASH\}?"|\$\{?BASH\}?) +-c +.*[[:space:]]'
  _pat="$_pre"'bash +[^ ]*'"$_fam"
  _pat="$_pat|$_pre"'(\.|source) +[^ ]*'"$_fam"
  _pat="$_pat|$_shc"'"?[^ ]*'"$_fam"
  for _h in $(printf '%s\n' "$_src" | tr ' \t' '\n\n' \
      | sed -n -E 's/^([A-Za-z_][A-Za-z_0-9]*)=.*(gate|run|watch|gate-pretool)\.sh.*$/\1/p' \
      | sort -u); do
    # `\\$` and not `$`: this string becomes an ERE, where a bare `$` is the
    # end-of-line anchor. Written unescaped the alternative reads as `bash "`
    # then end-of-line, matches nothing, and the caller selects no suites at
    # all — silently, with the suite reporting a smaller green total.
    #
    # The braces and the quotes are OPTIONAL in the reference, because
    # `bash "$H"`, `bash "${H}"` and `bash $H` are one act spelled three ways.
    # And running the handle DIRECTLY is a fourth — no `bash` in front of it at
    # all — so that one anchors on the start of the line instead. Requiring a
    # literal `bash "$H"` was a closed list of invocation spellings, which is
    # the same defect as the closed list of assignment spellings above.
    _ref="\\\$\\{?$_h\\}?"
    _pat="$_pat|(^|[^\"A-Za-z_0-9])bash +\"?$_ref\"?"
    _pat="$_pat|^[[:space:]]*\"?$_ref\"?([[:space:]]|\$)"
    _pat="$_pat|$_pre(\\.|source) +\"?$_ref\"?([[:space:]]|\$)"
    _pat="$_pat|$_shc\"?$_ref\"?([[:space:]]|\$)"
  done
  printf '%s' "$_pat"
}

# THE BRANCHES THE TREE DOES NOT REACH ARE CHECKED AGAINST A CORPUS WRITTEN FOR
# THEM. One row per branch and one per exclusion, spelled the way a real call
# site and a real non-call-site are spelled, so each row is failed by breaking
# the one thing it names — and the base branch, which today's tree cannot fail,
# is failed here.
_lp=$(leak_pat 'GATE=/x/plugins/cc-cmds/orchestrator/gate.sh HOOK=/x/plugins/cc-cmds/hooks/gate-pretool.sh')
while IFS='|' read -r _want _line; do
  [ -n "$_want" ] || continue
  _got=$(printf '%s\n' "$_line" | grep -cE "$_lp" || true)
  case "$_want:${_got:-0}" in
    y:0) bad "누출 술어 인식" "호출로 인식해야 하는 줄을 놓쳤다: $_line" ;;
    n:0) ok "누출 술어가 호출 아닌 줄을 세지 않는다: $_line" ;;
    y:*) ok "누출 술어가 호출 표기를 인식한다: $_line" ;;
    *)   bad "누출 술어 인식" "호출이 아닌 줄을 호출로 셌다: $_line" ;;
  esac
done <<'LEAKROWS'
y|bash /x/plugins/cc-cmds/orchestrator/gate.sh snapshot --manifest m
y|  bash "$GATE" act --kind segment
y|bash ${GATE} act --kind segment
y|  "$GATE" act --kind segment
n|  "bash $GATE snapshot --manifest m"
n|bash_json "$GATE" act
n|  echo "$GATEWAY" act
y|bash /x/plugins/cc-cmds/hooks/gate-pretool.sh --run-dir r
y|  bash "$HOOK" --run-dir "$RUN_DIR" --gate "$GATE"
y|. "$GATE" || die2 "could not source $GATE"
y|  source /x/plugins/cc-cmds/orchestrator/run.sh
y|  out=$(bash -c 'g="$1"; . "$g"' _ "$GATE" "$1")
y|  "$BASH" -c '. "$1"' _ "$ORCH/run.sh"
n|  "source $GATE"
n|  n=$(grep -c pat "$ORCH/run.sh")
LEAKROWS

_scrub_line='for v in $(compgen -e | grep '"'"'^CC_PIPELINE_'"'"' || true); do unset "$v"; done'
_selected=0
_selected_names=""
for f in "$repo_root"/scripts/test-*.sh "$repo_root"/plugins/cc-cmds/orchestrator/test-run.sh; do
  [ -f "$f" ] || continue
  b=$(basename "$f")
  case "$b" in
    # `test-gate.sh` is NOT skipped, and it was — which put the one file that
    # actually leaked, and the one holding a hundred-plus direct gate calls,
    # outside the only check that would catch a regression. It carries the
    # export like the others; what differs is only that it turns the channel
    # back ON inside two helpers, and that is a local override rather than an
    # absence. The two below are the real exceptions: for them the banner IS
    # the subject, so a process-level kill would remove what they assert.
    test-active-notify-*|test-watch.sh) continue ;;
  esac
  # Only suites that can reach a firing path need it — the gate, the driver and
  # the watcher are the three that fire, and what matters is EXECUTING one of
  # them rather than naming it.
  #
  # This predicate has been wrong twice in the same direction, so it is built
  # rather than written. The first version matched any mention, and reported
  # four lint suites that merely read `run.sh` for its vocabulary. The second
  # required `bash ` in front — and still matched `# Usage: bash …/test-run.sh`,
  # while missing that file's real invocations, which go through a handle
  # (`/usr/bin/env bash "$DRIVER"`) that a hardcoded list of variable names did
  # not contain. A closed list of handles is the same defect wearing a narrower
  # spelling: it is complete on the day it is written.
  #
  # So comments are cut first — the same treatment the `kill -0` census above
  # applies, and for the same reason — and the handles are DERIVED from the
  # file: whatever variable it assigns one of the three scripts to is what its
  # invocations will name.
  #
  # Comments are cut first, and the pattern is built from what is left — the
  # construction, and why it has the shape it has, live in `leak_pat` above.
  _src=$(sed 's/#.*//' "$f")
  _pat=$(leak_pat "$_src")
  # `grep -c`, never `grep -q`, and the reason is this file's own section 0a:
  # under `pipefail` an early-exiting reader on the right of a pipe kills the
  # writer with SIGPIPE and the pipeline reports that failure. `grep -q` leaves
  # as soon as it matches, so the bigger the file the likelier the writer is
  # still going — which selected against exactly the file that matters. Measured:
  # `test-gate.sh` matched 124 lines and was dropped, while three smaller suites
  # whose writers finished first were kept. `grep -c` reads to the end.
  #
  # AN ERROR IS NOT A "NO". `grep` answers 1 for "nothing matched" and 2 or more
  # for "the search could not be done" — a malformed ERE, an unreadable input —
  # and `|| true` folded those together, so a pattern broken by an edit dropped
  # every suite and looked exactly like a tree with nothing to check. The count
  # is captured rather than discarded because BSD `grep` short-circuits when its
  # output goes to /dev/null, which brings back the SIGPIPE this uses `-c` to
  # avoid.
  _n=$(printf '%s\n' "$_src" | grep -cE "$_pat")
  _rc=$?
  if [ "$_rc" -gt 1 ]; then
    bad "누출 술어" "$b 에 대해 선택 검사가 오류로 끝났다 (grep rc=$_rc) — 오류를 매치 없음과 같이 처리하면 모든 스위트가 조용히 빠진다"
    continue
  fi
  [ "${_n:-0}" != "0" ] || continue
  _selected=$((_selected + 1))
  _selected_names="$_selected_names $b"
  if grep -q '^export CC_CMDS_AUTOPILOT_NOTIFY$' "$f"; then
    ok "$b 가 알림 채널을 프로세스 수준에서 끈다"
  else
    bad "알림 누출" "$b 가 게이트 계열을 부르면서 CC_CMDS_AUTOPILOT_NOTIFY 를 내보내지 않는다 — 이 스위트가 도는 동안 사용자 화면에 실제 배너가 도달한다"
  fi
  # The same set runs the gate's run-open branch, which starts the dashboard
  # server. Left on, every fixture run that opens there leaves a real server
  # listening on this host after the suite ends.
  if grep -q '^export CC_CMDS_DASHBOARD$' "$f"; then
    ok "$b 가 대시보드 자동 기동을 프로세스 수준에서 끈다"
  else
    bad "대시보드 누출" "$b 가 게이트 계열을 부르면서 CC_CMDS_DASHBOARD 를 내보내지 않는다 — 픽스처 런 개시마다 실제 서버가 남는다"
  fi
  # And the same set clears every `CC_PIPELINE_*` it inherited, by prefix rather
  # than by a list of names. A list is complete only on the day it is written:
  # the gate later began exporting names the suites' lists did not carry, and a
  # suite run inside a stage then read the stage's real ledger and manifest.
  # The whole line, because only the exact spelling is known to clear by prefix.
  if grep -qxF -- "$_scrub_line" "$f"; then
    ok "$b 가 물려받은 파이프라인 변수를 접두어로 걷는다"
  else
    bad "파이프라인 변수 누출" "$b 가 게이트 계열을 부르면서 최상위에 '$_scrub_line' 줄을 두지 않는다 — 스테이지 안에서 돌면 스테이지의 원장·매니페스트를 그대로 읽는다"
  fi
  # A FILE THAT IS ALSO SOURCED keeps the line inside its direct-run guard.
  # Its sourcer reads `CC_PIPELINE_RUN_ID` after sourcing it — check-push picks
  # its unattended merge mode that way — so a line above the guard would clear
  # the variable the moment the library is sourced and switch that mode off
  # without a word. Only the position is asserted, and only where a guard
  # exists: a file without one is never sourced for its functions.
  _guard_ln=$(grep -n -m 1 -E '^[[:space:]]*if \[ "\$\{BASH_SOURCE\[0\]\}" = "\$0" \]' "$f")
  _guard_ln=${_guard_ln%%:*}
  if [ -n "$_guard_ln" ]; then
    _scrub_ln=$(grep -n -m 1 -xF -- "$_scrub_line" "$f")
    _scrub_ln=${_scrub_ln%%:*}
    if [ -n "$_scrub_ln" ] && [ "$_scrub_ln" -gt "$_guard_ln" ]; then
      ok "$b 의 걷기 줄이 직접 실행 가드 안에 있다 (소싱하는 쪽의 변수를 지우지 않는다)"
    else
      bad "파이프라인 변수 누출" "$b 는 직접 실행 가드(:$_guard_ln)를 가진 라이브러리인데 걷기 줄이 그 뒤에 없다 (첫 걷기 줄 :${_scrub_ln:-없음}) — 소싱하는 순간 소싱한 쪽의 CC_PIPELINE_RUN_ID 가 지워진다"
    fi
  fi
done

# ZERO SELECTED IS A BROKEN PREDICATE, NOT A CLEAN TREE. Nothing inside the loop
# can report this, because the assertions that would have spoken are exactly the
# ones that disappear.
if [ "$_selected" -gt 0 ]; then
  ok "누출 술어가 게이트 계열을 부르는 스위트를 실제로 골랐다 (${_selected}개)"
else
  bad "누출 술어" "게이트 계열을 부르는 스위트를 하나도 고르지 못했다 — 술어가 깨졌다는 뜻이지 트리가 깨끗하다는 뜻이 아니다"
fi
# And a NAMED one, because a count above zero can still be the wrong set. This
# is the file that actually leaked and the one holding the most direct gate
# calls, so a derivation that stops recognising a spelling drops it first.
case " $_selected_names " in
  *" test-gate.sh "*) ok "그 선택에 test-gate.sh 가 들어 있다 (가장 많이 부르는 스위트가 빠지지 않았다)" ;;
  *) bad "누출 술어" "test-gate.sh 를 고르지 못했다 — 핸들 유도나 호출 표기 인식이 좁아졌다" ;;
esac
# AND THE WHOLE SET, because "above zero" and "contains one name" both survive a
# predicate that narrowed. A narrowing drops suites one at a time, and the suite
# then ends with zero failures and a smaller total — which is what a clean tree
# looks like too. Measured: a derivation broken so that a whole branch matched
# nothing left this count at four and this name present, and nothing said so.
#
# Spelling the set out means a suite added to this tree that calls the gate
# family has to be added here as well. That edit is the point rather than a cost:
# it is the one moment somebody looks at whether the new suite kills the channel.
_selected_want="test-gate-chain-equiv.sh test-gate-oracle.sh test-gate.sh test-kickoff-defaults.sh test-kickoff-hook-probe.sh test-liveness-agreement.sh test-local-bundle.sh test-lost-dispatch.sh test-measure-test-share.sh test-meta-invariants.sh test-orchestrator-pretool-hook.sh test-reader-model-pair-audit.sh test-rekick.sh test-run-issue-filing.sh test-run.sh test-snapshot.sh test-solo-audit-experiment.sh test-stage-supervisor.sh test-suite-isolation.sh test-tree.sh test-visual-check.sh"
_selected_got=$(printf '%s\n' $_selected_names | sort | tr '\n' ' ' \
                  | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')
check "누출 술어가 고르는 스위트 집합이 그대로다" "$_selected_got" "$_selected_want"

# ---------------------------------------------------------------------------
# The TypeScript seat predicates read at least the shell router's markers
#
# A mod decides "am I inside a pipeline" from its own list of `CC_PIPELINE_`
# names, and the shell decides "may a banner reach the user" from
# `cc_caller_is_router`. The TS list is a strict superset on purpose (it adds
# the run id), which is the safe direction; the failure this pins is someone
# "aligning" the two by dropping a name from the TS side, after which a stage
# that sets only that marker opens a form. Both sets are pulled from source so
# a marker added to the router is demanded of every TS reader without an edit
# here. Test files are left out: they SET markers to drive a case and do not
# read them, so the subset they happen to set says nothing about a predicate.
# ---------------------------------------------------------------------------
EMITTER_SRC="$PLUGIN_ROOT/orchestrator/notify-run.sh"
ROUTER_NAMES=$(awk '/^cc_caller_is_router\(\) \{/ {f=1; next} f && /^\}/ {exit} f' "$EMITTER_SRC" \
  | sed 's/#.*//' | grep -oE 'CC_PIPELINE_[A-Z_]+' | LC_ALL=C sort -u || true)
n_router=$(printf '%s\n' "$ROUTER_NAMES" | grep -c . || true)
if [ "${n_router:-0}" -gt 0 ]; then
  ok "라우터 표지 집합을 소스에서 뽑았다 (${n_router}개)"
else
  bad "라우터 표지 집합" "cc_caller_is_router 에서 CC_PIPELINE_ 이름을 하나도 뽑지 못했다"
fi

# Prints the router names the file does not carry, one per line; empty = covered.
ts_missing_markers() {
  local file="$1" have nm
  have=$(grep -oE 'CC_PIPELINE_[A-Z_]+' "$file" 2>/dev/null | LC_ALL=C sort -u || true)
  while IFS= read -r nm; do
    [ -n "$nm" ] || continue
    grep -qxF -- "$nm" <<HAVE || printf '%s\n' "$nm"
$have
HAVE
  done <<EOF
$ROUTER_NAMES
EOF
}

ts_readers=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  ts_readers=$((ts_readers + 1))
  missing=$(ts_missing_markers "$f")
  rel="${f#"$PLUGIN_ROOT"/}"
  if [ -z "$missing" ]; then
    ok "표지 집합 ⊇ 라우터 집합 — $rel"
  else
    bad "표지 집합 ⊇ 라우터 집합 — $rel" "빠진 이름: $(printf '%s' "$missing" | tr '\n' ' ')"
  fi
done <<EOF
$(find "$PLUGIN_ROOT/hooks" -type f \( -name '*.ts' -o -name '*.tsx' \) ! -name '*.test.ts' ! -name '*.test.tsx' 2>/dev/null \
    | while IFS= read -r g; do grep -lE 'CC_PIPELINE_' "$g" 2>/dev/null || true; done | LC_ALL=C sort)
EOF
if [ "$ts_readers" -gt 0 ]; then
  ok "표지를 읽는 TS 파일 ${ts_readers}개를 대조했다"
else
  bad "표지를 읽는 TS 파일" "hooks 아래에서 CC_PIPELINE_ 를 읽는 TS 파일을 하나도 찾지 못했다"
fi

# The negative control: a copy of the form's entry with one router marker
# removed must be reported, or the comparison above could pass on anything.
QF_ENTRY="$PLUGIN_ROOT/hooks/question-form/index.tsx"
drop_name=$(printf '%s\n' "$ROUTER_NAMES" | sed -n '1p')
if [ -f "$QF_ENTRY" ] && [ -n "$drop_name" ]; then
  sed "s/${drop_name}/CC_PIPELINE_DROPPED_FOR_TEST/g" "$QF_ENTRY" > "$WORK/index-minus-one.tsx"
  check "표지 하나를 뺀 사본은 빠진 이름으로 잡힌다" \
    "$(ts_missing_markers "$WORK/index-minus-one.tsx")" "$drop_name"
else
  bad "표지 하나를 뺀 사본" "질문지 진입 파일이 없거나 라우터 집합이 비었다"
fi

# ---------------------------------------------------------------------------
# 28. The detached run-scope processes' fence, which no lint can hold.
#
# Neither `feed.sh` nor `checks.sh` can raise a banner, because neither sources
# the emitter and neither names its two functions. The banner-site lint counts
# occurrences of the notifier BINARY, so a sourcing path is invisible to it —
# these assertions are the fence itself rather than a supplement to one.
#
# THE ASSERTIONS WALK A FILE LIST RATHER THAN NAMING ONE FILE. A fence written
# for one file has to be copied for the next one, and a copy that is not made is
# a seat that quietly opens. `checks.sh` carries the same fence for the same
# reason and additionally needs the verb allowlist below, because it is the first
# detached process in this tree that calls the network at all.
# ---------------------------------------------------------------------------
FEED_SH="$(dirname "$DRIVER")/feed.sh"
CHECKS_SH="$(dirname "$DRIVER")/checks.sh"
for fence_f in "$FEED_SH" "$CHECKS_SH"; do
  fence_n=$(basename "$fence_f")
  if [ ! -f "$fence_f" ]; then
    bad "울타리" "$fence_n 이 없다 — 이 펜스가 지킬 대상이 실재하지 않는다"
    continue
  fi
  ok "$fence_n 이 있다"
  # A WHITELIST, NOT A DENYLIST. Asking "does it source the emitter" only closes
  # the door that is already named; asking which files it may source at all also
  # closes the one a future emitter under another name would use.
  #
  # THE LIST IS THREE NAMES, AND THE LAST TWO PAY THEIR WAY BELOW. `pin.sh` joined
  # it because these processes have to hop into the run's pinned copy before they
  # write anything, and the predicate that decides that is shared with the gate
  # and the watcher rather than re-implemented here. `display-tz.sh` joined it
  # because the feed's line prefix shows the time in the display zone, and that
  # conversion lives in the one helper every surface shares rather than in a
  # copy here. Widening a whitelist weakens it unless the new entry is fenced
  # too, so the assertions after this loop hold `pin.sh` and `display-tz.sh` to
  # the same rule: each sources nothing and names no emitter.
  fence_src_other=$( { grep -nE '^[[:space:]]*(\.|source)[[:space:]]' "$fence_f" || true; } \
                    | { grep -v 'liveness\.sh' || true; } \
                    | { grep -v 'pin\.sh' || true; } \
                    | { grep -v 'display-tz\.sh' || true; } )
  if [ -n "$fence_src_other" ]; then
    bad "울타리" "$fence_n 이 허용 목록(liveness.sh · pin.sh · display-tz.sh) 밖의 것을 소스한다: $fence_src_other"
  else
    ok "$fence_n 이 소스하는 것은 liveness.sh·pin.sh·display-tz.sh 뿐이다 — notify-run.sh 를 소스하지 않는다"
  fi
  # And the name reaches no executable line. A header sentence explaining the
  # fence is not a breach of it, so the comment lines are excluded rather than
  # the file being required never to mention what it refuses to load.
  fence_notify_code=$( { grep -n 'notify-run\.sh' "$fence_f" || true; } \
                      | { grep -vE '^[0-9]+:[[:space:]]*#' || true; } )
  if [ -n "$fence_notify_code" ]; then
    bad "울타리" "$fence_n 의 주석이 아닌 줄이 notify-run.sh 를 이름으로 담는다: $fence_notify_code"
  else
    ok "$fence_n 의 실행 줄 어디에도 notify-run.sh 가 없다"
  fi
  if grep -q 'cc_notify_fire\|cc_notify_clear' "$fence_f"; then
    bad "울타리" "$fence_n 이 방출 함수를 이름으로 담고 있다"
  else
    ok "$fence_n 이 방출 함수를 이름으로도 부르지 않는다"
  fi
done

if [ -f "$FEED_SH" ]; then
  PIN_SH="$(dirname "$DRIVER")/pin.sh"
  if [ -f "$PIN_SH" ]; then
    pin_src_any=$( grep -nE '^[[:space:]]*(\.|source)[[:space:]]' "$PIN_SH" || true )
    if [ -n "$pin_src_any" ]; then
      bad "피드 울타리" "pin.sh 가 무언가를 소스한다 — 허용 목록이 그만큼 넓어진다: $pin_src_any"
    else
      ok "pin.sh 는 아무것도 소스하지 않는다 (허용 목록이 이 한 파일로 닫힌다)"
    fi
    # THE NOTIFIER'S NAME IS SPLIT ACROSS TWO LITERALS. `lint-notify-fire-sites.sh`
    # counts the lines under `orchestrator/` that name the binary and expects
    # exactly the emitter's two, so a pattern that spells it whole turns this
    # fence into a lint violation — the check would be reported as the thing it
    # is checking against.
    if grep -qE 'notify-run\.sh|cc_notify_fire|cc_notify_clear|terminal-''notifier' "$PIN_SH"; then
      bad "피드 울타리" "pin.sh 가 방출 경로를 이름으로 담고 있다"
    else
      ok "pin.sh 의 어디에도 방출 경로가 없다"
    fi
  else
    bad "피드 울타리" "pin.sh 가 없다 — 피드가 소스하는 파일이 실재하지 않는다"
  fi
  # The display-zone helper is held to the rule `pin.sh` is held to above, with
  # the notifier's name split the same way and for the same reason.
  DTZ_SH="$(dirname "$DRIVER")/display-tz.sh"
  if [ -f "$DTZ_SH" ]; then
    dtz_src_any=$( grep -nE '^[[:space:]]*(\.|source)[[:space:]]' "$DTZ_SH" || true )
    if [ -n "$dtz_src_any" ]; then
      bad "피드 울타리" "display-tz.sh 가 무언가를 소스한다 — 허용 목록이 그만큼 넓어진다: $dtz_src_any"
    else
      ok "display-tz.sh 는 아무것도 소스하지 않는다 (허용 목록이 이 한 파일로 닫힌다)"
    fi
    if grep -qE 'notify-run\.sh|cc_notify_fire|cc_notify_clear|terminal-''notifier' "$DTZ_SH"; then
      bad "피드 울타리" "display-tz.sh 가 방출 경로를 이름으로 담고 있다"
    else
      ok "display-tz.sh 의 어디에도 방출 경로가 없다"
    fi
  else
    bad "피드 울타리" "display-tz.sh 가 없다 — 피드가 소스하는 파일이 실재하지 않는다"
  fi
else
  bad "진행 채널" "feed.sh 가 없다 — 라우팅이 리드를 떠난 밤에 사람이 볼 것이 없다"
fi

# ---------------------------------------------------------------------------
# 28b. The CI poller's `gh` verb allowlist.
#
# The gate's enforcement is a `PreToolUse` hook matching TOOL CALLS, so a command
# run inside a detached `bash checks.sh &` is not matched and no axis-2 grade is
# ever consulted. That is not a bypass — the grade is simply not asked for — but
# it means one `pr merge` added to that file would merge on an unattended night
# with neither a record nor an approval. This assertion is the only control left.
#
# THE SHAPE OF THE ASSERTION CARRIES THE WEIGHT, and it is not the shape of the
# banner fence above. That one counts an emitter name and expects zero — a check
# for something ABSENT. Here the dangerous thing is a verb nobody has thought of,
# so grepping for the three allowed spellings would let a fourth through in
# silence. The verb pairs are EXTRACTED and the SET DIFFERENCE against the
# allowlist must be empty, and a `gh` call this extractor cannot parse counts as
# a violation too — otherwise an unparsable spelling is a hole of its own.
#
# RECOGNITION IS WHERE THE FIRST VERSION OF THIS FENCE WAS OPEN, and the shape of
# the fix is that the extractor and the unparsable-detector now look at the SAME
# lines. That version picked a token that was exactly `gh` or ended in `gh`
# behind a shell character, and both halves of that test were anchored at the END
# of the token — so `"gh" -R "$slug" pr merge "$n"` (quoted command word, ending
# in `h"`) was neither, the line produced NO output at all, not even the
# unparsable marker, and the set difference was empty on a file that merges PRs.
# `'gh'`, `"$GH"` after a quoted assignment and `$(command -v gh)` behaved the
# same. It failed CLOSED on shape and OPEN on recognition, and its negative
# control planted a spelling recognition already handled, so it tested the
# closed half twice and the open half never.
#
# Now every well-formed call `gh -R "$slug" pr <verb>` is extracted — whatever
# the verb, so a fourth one reaches the set difference — and then taken OUT of
# its line. Whatever still looks like a call afterwards is unparsable:
#
#   - `gh` as a word, or the repo flag `-R`. TWO RECOGNITION TOKENS, because the
#     command word is the part an indirect call hides and the repo flag is the
#     part it cannot: `"$GH" -R "$slug" pr merge` has no `gh` on it anywhere;
#   - a `pr <verb>` behind anything that is NOT A BARE IDENTIFIER — a quote, a
#     `)`, a `}`, a `]`, or a `$name` expansion. That is argument position, where
#     a subcommand goes, and it catches `"$GH" pr merge "$n"`, `$GH pr merge "$n"`
#     and `${GH:-gh} pr merge "$n"`, none of which carries a recognition token.
#     What keeps it off `local ts seg pr sha st` and `read -r ts seg pr sha st` is
#     that there `pr` follows a bare identifier run — a variable name. The first
#     version demanded a quote or a `)` in front, so the unquoted and the
#     braced expansions walked through. `pr` and its verb may be quoted, since
#     `$GH pr "merge"` is the same call;
#   - an expansion in command position followed by any word, which is what a
#     variable command word looks like whichever subcommand it runs —
#     `$GH api -X PUT …/merge` carries no `pr` for the rule above to read;
#   - `eval`, or a `command -v`/`which`/`type` resolution of the binary, because
#     indirection defeats any line-based rule and banning it is cheaper than
#     parsing it.
#
# WHAT IS STILL NOT COVERED, stated rather than implied: a command word assembled
# from pieces, or read out of a file or the environment. That is deliberate
# obfuscation rather than the accident this fence is for — someone adding a
# fourth verb — and every spelling that writes the binary's name down is caught.
# ---------------------------------------------------------------------------
# `gh` AS A WORD. A plain substring search reports every English word ending in
# those letters — `through`, `high` — so the character before `gh` must be a
# non-word one, which is what `$(gh`, `(gh`, `"gh` and a line-leading `gh` are.
GH_FORM_RE='(^|[^A-Za-z0-9_-])gh -R "\$slug" pr [a-z][a-z-]*'
# `:-` is let in front of `gh` because `${GH:-gh}` spells the binary's name as a
# default, and `-` alone stays out so a hyphenated name ending in `gh` does not.
GH_WORD_RE='(^|[^A-Za-z0-9_-]|:-)(gh|-R)([^A-Za-z0-9_-]|$)'
GH_PR_RE="([\"')}]|\\]|\\\$[A-Za-z_][A-Za-z0-9_]*)[[:space:]]+[\"']?pr[\"']?[[:space:]]+[\"']?[a-z][a-z-]*([^A-Za-z0-9_-]|\$)"
# AN EXPANSION IN COMMAND POSITION followed by a word, whatever that word is.
# The rule above knows `pr` and nothing else, so `$GH api -X PUT …/merge` — the
# generic escape hatch that can do anything a verb can — carried no token it
# reads. Command position is the start of a line or what follows `;` `&` `|`
# `(` or a backquote, or a word that runs the next one (`then`, `do`, `else`,
# `exec`, `command`, `env`, `nohup`, `time`, `!`). A quoted path after the
# expansion is not a word, which keeps `exec "${BASH:-/bin/bash}" "$…/checks.sh"`
# off it.
GH_CMDVAR_RE="(^|[;&|(\`]|(^|[^A-Za-z0-9_])(then|do|else|exec|command|env|nohup|time|!))[[:space:]]*\"?\\\$(\\{[^}]*\\}|[A-Za-z_][A-Za-z0-9_]*)\"?[[:space:]]+[\"']?[a-z][a-z-]*([^A-Za-z0-9_-]|\$)"
GH_INDIRECT_RE='(^|[^A-Za-z0-9_-])(eval|command[[:space:]]+-v|which|type)[[:space:]]+[^[:space:]]*gh([^A-Za-z0-9_-]|$)'
GH_EVAL_RE='(^|[^A-Za-z0-9_-])eval([^A-Za-z0-9_-]|$)'

gh_verbs_of() {
  # gh_verbs_of <file> — one `pr <verb>` pair per well-formed `gh` call on a
  # non-comment line, and the literal `(추출 실패)` for any line that still looks
  # like a call once those are removed, or that resolves the binary indirectly.
  # WHOLE-LINE COMMENTS ONLY are dropped; a trailing comment stays attached to
  # its code, which errs toward reporting rather than hiding.
  local src
  src=$({ grep -vE '^[[:space:]]*#' "$1" || true; })
  {
    printf '%s\n' "$src" \
      | { grep -oE "$GH_FORM_RE" || true; } \
      | sed -E 's/.* pr ([a-z][a-z-]*)$/pr \1/'
    printf '%s\n' "$src" \
      | sed -E "s/$GH_FORM_RE/\\1 /g" \
      | { grep -E "$GH_WORD_RE|$GH_PR_RE|$GH_CMDVAR_RE" || true; } \
      | sed 's/.*/(추출 실패)/'
    printf '%s\n' "$src" \
      | { grep -E "$GH_INDIRECT_RE|$GH_EVAL_RE" || true; } \
      | sed 's/.*/(추출 실패)/'
  } | sort -u
}
if [ -f "$CHECKS_SH" ]; then
  gh_allowed=$(printf '%s\n' 'pr list' 'pr view' 'pr checks' | sort -u)
  gh_seen=$(gh_verbs_of "$CHECKS_SH")
  gh_extra=$(printf '%s\n' "$gh_seen" | { grep -v '^$' || true; } \
             | { grep -vxF "$gh_allowed" || true; } )
  if [ -n "$gh_extra" ]; then
    bad "폴러 울타리" "checks.sh 의 gh 호출이 허용 집합 {pr list, pr view, pr checks} 밖이다: $(printf '%s' "$gh_extra" | tr '\n' ' ')"
  else
    ok "checks.sh 의 gh 호출이 전부 허용 집합 안이다 (차집합이 비었다)"
  fi
  # THE EXTRACTOR MUST HAVE SEEN SOMETHING. An empty extraction also gives an
  # empty difference, and "the fence holds" and "the extractor saw nothing" are
  # exactly the two states this section exists to tell apart.
  if [ -n "$(printf '%s\n' "$gh_seen" | { grep -xF "$gh_allowed" || true; })" ]; then
    ok "추출기가 진짜 파일에서 허용 동사를 실제로 읽었다 ($(printf '%s' "$gh_seen" | tr '\n' ' '))"
  else
    bad "폴러 울타리" "진짜 checks.sh 에서 동사를 하나도 추출하지 못했다 — 위의 빈 차집합은 아무것도 증명하지 않는다"
  fi
  # THE NEGATIVE CONTROL, out of tree, AND IT PLANTS THE SPELLINGS THAT BROKE THE
  # FIRST VERSION — not only the one it already handled. An assertion whose only
  # evidence is that the real file passes cannot tell "the fence holds" from "the
  # extractor finds nothing", and a control that plants only the easy spelling
  # cannot tell the recognition gate from the shape gate. The last case puts an
  # allowed call and a forbidden one on the same line, so extraction has to take
  # every call on a line rather than the first.
  for gh_fx_case in \
    '  gh -R "$slug" pr merge "$n" --squash' \
    '  "gh" -R "$slug" pr merge "$n" --squash' \
    "  'gh' -R \"\$slug\" pr merge \"\$n\" --squash" \
    '  "$GH" -R "$slug" pr merge "$n" --squash' \
    '  GH_BIN=$(command -v gh); "$GH_BIN" -R "$slug" pr merge "$n"' \
    '  eval "$cmd -R \"$slug\" pr merge \"$n\""' \
    '  "$GH" pr merge "$n" --squash' \
    '  ${GH:-gh} pr merge "$n"' \
    '  $GH pr merge "$n"' \
    '  ${GH} pr merge "$n"' \
    '  "${GH:-gh}" pr merge "$n"' \
    '  "${gh[@]}" pr merge "$n"' \
    '  $GH pr "merge" "$n"' \
    '  "$GH" "pr" "merge" "$n"' \
    '  $GH api -X PUT "repos/$slug/pulls/$n/merge"' \
    '  out=$($GH api -X PUT "repos/$slug/pulls/$n/merge")' \
    '  out=$(gh -R "$slug" pr checks "$n"); gh -R "$slug" pr merge "$n"'
  do
    GH_FX=$(mktemp "${TMPDIR:-/tmp}/cc-checks-gh.XXXXXX") \
      || { bad "폴러 울타리" "음성 대조군 임시 파일을 만들지 못했다"; break; }
    { cat "$CHECKS_SH"; printf '%s\n' "$gh_fx_case"; } > "$GH_FX"
    gh_fx_extra=$(gh_verbs_of "$GH_FX" | { grep -v '^$' || true; } \
                  | { grep -vxF "$gh_allowed" || true; } )
    if [ -n "$gh_fx_extra" ]; then
      ok "오염 사본을 차집합이 잡아낸다 ($(printf '%s' "$gh_fx_extra" | tr '\n' ' ')— $(printf '%s' "$gh_fx_case" | sed 's/^[[:space:]]*//'))"
    else
      bad "폴러 울타리" "오염 사본의 차집합이 비었다 — 이 철자에 대해 단언이 아무것도 지키지 않는다: $(printf '%s' "$gh_fx_case" | sed 's/^[[:space:]]*//')"
    fi
    rm -f "$GH_FX"
  done
fi

# ---------------------------------------------------------------------------
# 6d. The design dispatch is carried by BOTH router copies
#
# The lead's loop and the shift skill each carry their own prose for dispatching
# the design stage, and that duplication is deliberate: the shift decides from
# the snapshot and nothing else, so factoring the section into a shared file
# would open a second read path for it. What the duplication costs is that a
# section landing in one file only is a section the other path never reads — a
# shipped router already lost the design dispatch that way, with nothing to
# catch it. The two sections are not byte-identical prose, so what is asserted
# is the load-bearing literals: without any one of them the dispatch cannot be
# issued, waited on, held back while the stage runs, re-attached after a cut,
# dispatched again after a stage ended without carrying anything off, held to
# one fresh dispatch after an ending that does not clear by itself, or closed
# by the gate on the same depth — the claim that condition 1 stays on its plain
# line after that stop was false, and it must not come back.
# ---------------------------------------------------------------------------
design_section() {
  # design_section <skill file> — the design-dispatch subsection body, read up
  # to the next heading of any level.
  awk '/^#### Dispatching the design stage$/ { f = 1; next } f && /^#+ / { exit } f' "$1"
}
design_sel=""
design_sel_rs=""
for pair in "리드:$AP_ROUTER" "교대:$RS_CORPUS"; do
  who=${pair%%:*}
  sec=$(design_section "${pair#*:}")
  if [ -n "$sec" ]; then
    ok "$who 사본에 설계 파견 절이 있다"
  else
    bad "$who 사본의 설계 파견 절" "표제가 없거나 본문이 비었다"
  fi
  for lit in \
    '--segment -' \
    'live_stages[]' \
    'orphan_stages[]' \
    'gate.sh wait --manifest <매니페스트> --segment <step id>' \
    'no single design step' \
    'The gate records that proposal as `무효화`, never as satisfied.' \
    'only when it was opened by the design step' \
    'the last such row decides' \
    'Take 「Re-attaching a cut stage」 first' \
    '`외부 종료`, `크래시` and `공허한 성공` may be dispatched afresh, and only onto an absent document' \
    '`한도 종료` is read exactly as `크래시` here' \
    'Two of the three buy one fresh dispatch and no more: a `크래시` whose stream holds no 429 envelope, and a `공허한 성공`.' \
    'When the last row is one of these two and two or more fresh attempts already stand, stop the design as below' \
    'counts the same fresh attempts by the same definition'
  do
    # A count, not `grep -q`: the early exit on the right of a pipe SIGPIPEs the
    # left under pipefail. `case` would drop the pipe but reads `[]` as a glob.
    nlit=$(printf '%s\n' "$sec" | grep -cF -- "$lit" || true)
    if [ "${nlit:-0}" != "0" ]; then
      ok "$who 사본의 설계 파견 절이 「${lit}」을 싣는다"
    else
      bad "$who 사본의 설계 파견 절" "「${lit}」이 없다"
    fi
  done
  # The absence is pinned, not the sentence: the depth stop once told the router
  # that condition 1 keeps its plain line, and the gate then refused every
  # proposal that sentence sent it to make.
  nlit=$(printf '%s\n' "$sec" | grep -cF -- 'stays on its plain line' || true)
  if [ "${nlit:-0}" = "0" ]; then
    ok "$who 사본의 설계 파견 절이 깊이 멈춤 뒤 평이한 줄이 남는다고 말하지 않는다"
  else
    bad "$who 사본의 설계 파견 절" "깊이 멈춤 뒤 조건 1 이 평이한 줄에 머문다는 주장이 남아 있다"
  fi
  # The step id selector is the one literal both copies must agree on to the
  # byte: it reads the frozen plan's graph, and two spellings of it are two
  # answers to "which step is the design" on the two paths that dispatch it.
  # And that one spelling is the gate's own — the `type == "object"` guard and
  # the `// empty` fallback are what make a step carrying no `id` read as "no
  # design step" on every path instead of resolving to `null` on one of them.
  # The pattern below therefore matches only the aligned form, so a copy that
  # drifts back to the bare spelling extracts nothing and fails here loudly.
  # But the selector is only the front half of the gate's decision: the blank
  # line filter and the "exactly one" count are shell, not jq, and they are what
  # settle an empty-string `id` and a plan with two `design` steps. Each copy
  # carries that back half as prose instead, and the `no single design step`
  # literal in the loop above is what measures it — reading selector equality by
  # itself as "aligned" is the mechanism that left those two shapes unstated in
  # both copies after the spellings had already been matched.
  sel=$(printf '%s\n' "$sec" | grep -oE '\.steps\[\][?] \| select\([^)]*\) \| \.id // empty' | sort -u)
  check "$who 사본의 설계 파견 절에 설계 단계 id 선택식이 한 벌 실린다" \
    "$(printf '%s\n' "$sel" | grep -c '^\.steps')" "1"
  if [ -z "$design_sel" ]; then design_sel="$sel"; else design_sel_rs="$sel"; fi
done
check "두 사본의 설계 단계 id 선택식이 바이트 동일하다" "$design_sel_rs" "$design_sel"

# ---------------------------------------------------------------------------
# 6d-v. The visual dispatch and its screen-slice wait are carried by BOTH copies
#
# The lead's loop and the shift each carry the visual-stage section for the same
# reason the design section is duplicated. What the duplication costs here is a
# screen slice that one path holds back and the other dispatches: the gate still
# refuses that dispatch, but the run then ends on a refusal instead of a wait the
# seat can answer. The literals below are what the section needs to dispatch the
# stage, to tell a screen slice from one that never waits, to submit the one
# fixed question, and to take a visual-wait park back up once it is approved —
# and only then: a resubmission that consumes a person's refusal also ends on
# exit 0, so each copy has to say that adoption is the `결정=채택` row and that
# a consumed refusal leaves the segment parked. A run whose plan carries the
# publish step `S2P` dispatches it from the same section, so its dispatch line
# and terminal literal are carried by both copies too.
# ---------------------------------------------------------------------------
visual_section() {
  # visual_section <skill file> — the visual-dispatch subsection body, read up
  # to the next heading of any level.
  awk '/^#### Dispatching the visual stage$/ { f = 1; next } f && /^#+ / { exit } f' "$1"
}
for pair in "리드:$AP_ROUTER" "교대:$RS_CORPUS"; do
  who=${pair%%:*}
  sec=$(visual_section "${pair#*:}")
  if [ -n "$sec" ]; then
    ok "$who 사본에 시각 파견 절이 있다"
  else
    bad "$who 사본의 시각 파견 절" "표제가 없거나 본문이 비었다"
  fi
  for lit in \
    '-- visual -p "/cc-cmds:visual-unattended <스냅숏 design_doc>"' \
    '시각 디자인을 검토 통과로 확정했습니다.' \
    '**상태**: 검토 통과' \
    'reading `**상태**: 검토 통과` or `**상태**: 발행됨`' \
    'A slice whose `**화면**` reads `없음` never waits.' \
    '--surface 읽기 -- <plugin root>/orchestrator/visual-check.sh approval <스냅숏 design_doc>' \
    "-- 등급=2 '판단 부류=시각-승인' '기준=시각 승인 대기' '근거=<화면 세그먼트> 의 화면이 고정 좌석에서 구현 승인되었는가'" \
    "\`'사유=시각 승인 대기'\`" \
    'before any branch or worktree is cut for them' \
    'write `상태=실행중` with the plan row'"'"'s `선행` and dispatch its implementation as any planned slice' \
    'A `park` the fixed-graph driver wrote is not taken over' \
    'leave the slice at `park`' \
    '`결정=거절 소비`' \
    'the approval is adopted only when that row carries `결정=채택`' \
    'go to item 5 whatever the predicate says' \
    'A consumed refusal does not make the segment `실행중` again' \
    '-- visual-publish -p "/cc-cmds:visual-publish-unattended <스냅숏 design_doc>"' \
    '시각 발행 단계를 마쳤습니다.' \
    'no implement step waits on `S2P`'
  do
    nlit=$(printf '%s\n' "$sec" | grep -cF -- "$lit" || true)
    if [ "${nlit:-0}" != "0" ]; then
      ok "$who 사본의 시각 파견 절이 「${lit}」을 싣는다"
    else
      bad "$who 사본의 시각 파견 절" "「${lit}」이 없다"
    fi
  done
  # The predicate read names the helper as argv0. Behind `bash` the gate grades
  # an opaque script, and with the auto-resolve switch off the read declaration
  # is refused, so the approved screen slice would never be dispatched.
  nbash=$(printf '%s\n' "$sec" | grep -cF -- 'bash <plugin root>/orchestrator/visual-check.sh' || true)
  if [ "${nbash:-0}" = "0" ]; then
    ok "$who 사본의 승인 술어 읽기는 bash 뒤에 두지 않는다"
  else
    bad "$who 사본의 승인 술어 읽기" "bash 뒤에 도우미를 둔 표기가 남았다"
  fi
done
# Both router copies accept a `발행됨` sidecar because a re-kicked run's visual
# stage reuses its source's sidecar without writing it. That holds only while
# the stage itself still runs the reuse check, so pin the call in its text.
VU_SKILL="$PLUGIN_ROOT/skills/visual-unattended/SKILL.md"
nreuse=$(grep -cF -- 'visual-check.sh reuse' "$VU_SKILL" || true)
if [ "${nreuse:-0}" != "0" ]; then
  ok "visual-unattended 문면이 visual-check.sh reuse 로 재사용을 판정한다"
else
  bad "visual-unattended 문면의 재사용 판정" "visual-check.sh reuse 호출이 없다"
fi

# ---------------------------------------------------------------------------
# 6e. Re-attaching a cut stage is carried by BOTH router copies
#
# The gate has accepted `act --kind skill --resume <세션 id>` for a long time,
# and every re-attachment a run ever made was improvised by a shift reading the
# gate's source — no router text offered one. Where nothing was improvised, a
# design stage cut by the account's session limit was re-kicked as a new run five
# times, each paying again for the discussion round the last one had published.
# The literals below are what the re-attachment needs to be issued at all and
# issued safely: the cut classes — `한도 종료` among them, which qualifies on its
# class alone — and the envelope that tells a limit crash filed `크래시` from a
# broken stage, the session-started probe, the attempt cap, the reset-time
# hold, the flag itself, and the continuation prompt — which must be one string
# in both copies, since a slash command in its place restarts the skill.
# ---------------------------------------------------------------------------
reattach_section() {
  awk '/^#### Re-attaching a cut stage$/ { f = 1; next } f && /^#+ / { exit } f' "$1"
}
reattach_prompt=""
reattach_prompt_rs=""
for pair in "리드:$AP_ROUTER" "교대:$RS_CORPUS"; do
  who=${pair%%:*}
  sec=$(reattach_section "${pair#*:}")
  if [ -n "$sec" ]; then
    ok "$who 사본에 재부착 절이 있다"
  else
    bad "$who 사본의 재부착 절" "표제가 없거나 본문이 비었다"
  fi
  for lit in \
    '`종단 부류=크래시` and that attempt'"'"'s stream carries the usage-limit envelope' \
    '"api_error_status":429' \
    '`종단 부류=외부 종료`' \
    '`종단 부류=한도 종료`' \
    '"session_id":"<세션 id>"' \
    'Four or more means the original and three re-attachments all ended cut' \
    'and only a cut adds to this count' \
    'A limit must have cleared first.' \
    '--resume <세션 id>' \
    'never the slash command again' \
    '| 서수=<n> |' \
    '^- `한도 해제` |' \
    'resetsAt'
  do
    nlit=$(printf '%s\n' "$sec" | grep -cF -- "$lit" || true)
    if [ "${nlit:-0}" != "0" ]; then
      ok "$who 사본의 재부착 절이 「${lit}」을 싣는다"
    else
      bad "$who 사본의 재부착 절" "「${lit}」이 없다"
    fi
  done
  prompt=$(printf '%s\n' "$sec" | grep -oE -- '-p "계정 사용량 한도[^"]*"' | sort -u)
  check "$who 사본의 재부착 절에 이어 가기 프롬프트가 한 벌 실린다" \
    "$(printf '%s\n' "$prompt" | grep -c '^-p ')" "1"
  if [ -z "$reattach_prompt" ]; then reattach_prompt="$prompt"; else reattach_prompt_rs="$prompt"; fi
done
check "두 사본의 이어 가기 프롬프트가 바이트 동일하다" "$reattach_prompt_rs" "$reattach_prompt"

# THE RULES AROUND THE RE-ATTACHMENT, which all sit outside the section the
# extraction above cuts out — the fourth and fifth ending reasons, the gate's `무기록` row,
# a handoff entry read as a past observation, the seat's exception for a person
# who asks to continue, and the input contract that admits the prescribed
# gate-routed reads. Each copy is read whole, so the section extraction above
# keeps its own range.
for pair in \
  "교대:$RS_CORPUS:상한·승인·종단·중단·대기에서 인수인계 행을 남기고 끝난다" \
  "교대:$RS_CORPUS:**The gate-routed reads this skill names are input too**" \
  "교대:$RS_CORPUS:Five reasons end a shift:" \
  "교대:$RS_CORPUS:**\`무기록\` is the gate's value and never yours**" \
  "교대:$RS_CORPUS:**A \`handoff\` entry is what that shift observed at its own \`기록 시각\`, not what holds now.**" \
  "교대:$RS_CORPUS:or you are ending on \`중단\` (the gate answered exit 7, or no act is left to dispatch)" \
  "교대:$RS_CORPUS:**A live stage holds back none of the other four.**" \
  "교대:$RS_CORPUS:or you are ending on \`대기\` (all that is left is a live stage's result, a pending CI verdict or the reset of a cut stage's limit)" \
  "교대:$RS_CORPUS:end the shift with \`사유=대기\` and \`'리셋 대기=<key>[,<key>…]'\` naming the cut keys" \
  "리드:$AP_SEAT:issue the same call again at once with \`대기\` as its reason" \
  "리드:$AP_SEAT:**The same holds when the latest \`handoff\` is the gate's \`무기록\` for a shift that died of the limit and the gate took your \`대기\` on it**" \
  "교대:$RS_CORPUS:CFI-S1 still holds: the snapshot and the gate-routed reads this skill prescribes are the input" \
  "교대:$RS_CORPUS:CFI-S1 still holds: whether to dispatch was decided from the snapshot" \
  "리드:$AP_SEAT:**Five reasons end a shift, and a live stage holds back none of them but \`대기\`.**" \
  "리드:$AP_SEAT:When the returned call's latest \`handoff\` is \`대기\` and no \`교대 기동\` follows it" \
  "리드:$AP_SEAT:**\`무기록\` is the gate's alone**" \
  "리드:$AP_ROUTER:or from a gate-routed read of the ledger or the run directory that this skill prescribes" \
  "리드:$AP_ROUTER:read from the snapshot, not from a read of the plan" \
  "리드:$AP_SEAT:start the next shift only when a person at this seat asked for it or the reset has passed" \
  "리드:$AP_SEAT:**except when the person at this seat asks to continue or says the limit has cleared.**" \
  "리드:$AP_SEAT:a \`handoff\` row with \`사유=무기록\`, its \`종료 코드\` and its \`행위 수\`"
do
  who=${pair%%:*}; rest=${pair#*:}; file=${rest%%:*}; lit=${rest#*:}
  nlit=$(grep -cF -- "$lit" "$file" || true)
  if [ "${nlit:-0}" != "0" ]; then
    ok "$who 사본이 「${lit}」을 싣는다"
  else
    bad "$who 사본의 개정 문구" "「${lit}」이 없다"
  fi
done

# ---------------------------------------------------------------------------
# 6e-2. The audit dispatch and segment planning are carried by BOTH router copies
#
# Once the design froze, no router text named the next act: the audit was never
# dispatched, no segment was planned, and the run sat on a frozen document until
# its budget ran out. The literals below are the two acts' forms and the facts
# that order them — the audit step's selector, which lives here and not in the
# design subsection, the re-check of the freeze line after the audit edits the
# document, the per-slice order that makes the worktree exist before its row, and
# the predecessor rule. The design subsection keeps its own closing sentence.
# ---------------------------------------------------------------------------
router_section() {
  awk -v h="$2" '$0 == h { f = 1; next } f && /^#+ / { exit } f' "$1"
}
for pair in "리드:$AP_ROUTER" "교대:$RS_CORPUS"; do
  who=${pair%%:*}; file=${pair#*:}
  for spec in \
    '#### Dispatching the audit stage|.steps[]? | select(type == "object" and .skill == "design-audit") | .id // empty' \
    '#### Dispatching the audit stage|-- audit -p "/cc-cmds:design-audit-unattended <스냅숏 design_doc>[ --base]"' \
    '#### Dispatching the audit stage|`세그먼트=- | 스테이지=<audit step id> | 종류=audit`' \
    '#### Dispatching the audit stage|docs/design-audit/<slug>.reader-*.md' \
    "#### Dispatching the audit stage|grep -qxF '**상태**: 동결됨' <문서>" \
    '#### Dispatching the audit stage|`<main worktree>-run-<run id>-<audit step id>` with `git worktree add --detach`' \
    '#### Dispatching the audit stage|do not write a `segment` row to name it' \
    '#### Planning the segments|`슬라이싱`' \
    '#### Planning the segments|git worktree add -b <슬라이싱 의 브랜치> <슬라이싱 의 워크트리> <베이스>' \
    '#### Planning the segments|--from-declaration' \
    '#### Planning the segments|-- 상태=계획됨 워크트리=<슬라이싱 의 워크트리>' \
    '#### Planning the segments|its predecessor'"'"'s `segments[]` entry reads `"착지": true`' \
    '#### Planning the segments|end the shift with a `사유=중단` handoff' \
    '#### Planning the segments|`슬라이싱` entry carries `입양`' \
    '#### Planning the segments|skip calls 1 and 2 and issue call 3 alone' \
    '#### Planning the segments|An adopted segment'"'"'s first stage is a full review, not the implementation' \
    '#### Planning the segments|Open no pull request for it'
  do
    head=${spec%%|*}; lit=${spec#*|}
    sec=$(router_section "$file" "$head")
    nlit=$(printf '%s\n' "$sec" | grep -cF -- "$lit" || true)
    if [ "${nlit:-0}" != "0" ]; then
      ok "$who 사본의 「${head#'#### '}」 절이 「${lit}」을 싣는다"
    else
      bad "$who 사본의 「${head#'#### '}」 절" "「${lit}」이 없다"
    fi
  done
  dsec=$(router_section "$file" '#### Dispatching the design stage')
  nlit=$(printf '%s\n' "$dsec" | grep -cF '.skill == "design-audit"' || true)
  if [ "${nlit:-0}" != "0" ]; then
    bad "$who 사본의 설계 파견 절" "감사 단계 선택 식이 설계 절 안에 있다"
  else
    ok "$who 사본의 감사 단계 선택 식은 설계 절 밖에 있다"
  fi
  nlit=$(printf '%s\n' "$dsec" | grep -cF 'An unfrozen document never goes on to the audit or to segment planning.' || true)
  if [ "${nlit:-0}" != "0" ]; then
    ok "$who 사본의 설계 절이 동결 전 감사·계획 금지 문장을 그대로 싣는다"
  else
    bad "$who 사본의 설계 절" "동결 전 감사·계획 금지 문장이 없다"
  fi
done

# The shift posts a pull request review a termination clause asks for, and both
# copies' settling sections give the same REST spelling with the declaration the
# gate judges it at. A copy that dropped either would leave the review to a
# stage or to a declaration the cutpoint rule refuses.
for pair in "리드:$AP_ROUTER|### Proposing that the run is done" \
            "교대:$RS_CORPUS|### Settling the termination clauses and proposing done"; do
  who=${pair%%:*}; rest=${pair#*:}; file=${rest%%|*}; head=${rest#*|}
  sec=$(router_section "$file" "$head")
  n1=$(printf '%s\n' "$sec" | grep -cF -- '--cutpoint 커밋 --surface 외부상태변경 --reach 협업' || true)
  n2=$(printf '%s\n' "$sec" | grep -cF -- 'pulls/<n>/reviews' || true)
  if [ "${n1:-0}" != "0" ] && [ "${n2:-0}" != "0" ]; then
    ok "$who 사본의 「${head#'### '}」 절이 리뷰 게시 철자와 신고를 함께 싣는다"
  else
    bad "$who 사본의 「${head#'### '}」 절" "리뷰 게시 철자 또는 신고가 없다 (신고 $n1, 철자 $n2)"
  fi
done

# ---------------------------------------------------------------------------
# 6e-2b. The kickoff writes no design document on any tier
#
# The tiers are `solo` and `team-4`, and on both the design is the run's first
# stage — `design-solo-unattended` or `design-discuss-unattended`. The tier
# under which the kickoff conversation wrote the document itself is gone, and
# with it the reference that carried its contract. A copy of that contract left
# behind anywhere in the kickoff would be a second document-production path the
# router and the gate no longer know.
# ---------------------------------------------------------------------------
if [ -e "$AP_REFS/lead-solo-document.md" ]; then
  bad "킥오프의 설계 문서 경로" "references/lead-solo-document.md 가 남아 있다"
else
  ok "킥오프에 대화가 설계 문서를 쓰는 계약 파일이 없다"
fi
# Counted, not `grep -q`: an early exit SIGPIPEs `cat` on the left, and under
# pipefail the match then reads as a miss.
for lit in \
  '(c) **Freeze line and `sha256`**' \
  '(c) **Freeze and `sha256`**' \
  'A `lead-solo` document is written after 5m' \
  'Write the freeze line of (c) into it, then take its path and whole-file `sha256`' \
  'the tier is `lead-solo` and the document `설계 문서` names does not carry the line `**상태**: 동결됨` exactly once' \
  '| `lead-solo` | this conversation, after Step 5m'
do
  nlit=$(ap_all | grep -cF -- "$lit" || true)
  if [ "${nlit:-0}" = "0" ]; then
    ok "킥오프는 「${lit}」을 싣지 않는다"
  else
    bad "킥오프의 설계 문서 경로" "옛 lead-solo 계약 「${lit}」이 ${nlit}번 남아 있다"
  fi
done
# The tier table names the stage each tier dispatches, once, in the resident
# body the kickoff always reads.
for lit in \
  '| `solo` | the `design-solo-unattended` stage' \
  '| `team-4` | the `design-discuss-unattended` stage'
do
  nlit=$(grep -cF -- "$lit" "$AP_SKILL" || true)
  if [ "${nlit:-0}" = "1" ]; then
    ok "킥오프 상주 본문의 티어 표가 「${lit}」을 한 번 싣는다"
  else
    bad "킥오프의 티어 표" "「${lit}」이 SKILL.md 에 ${nlit:-0}번 있다"
  fi
done

# ---------------------------------------------------------------------------
# 6e-2c. The kickoff's pre-authorization rows cover the REST merge
#
# The gate binds only the REST merge spelling, and the matcher compares whole
# words from the front, so a run whose rows hold `gh pr` alone sends every merge
# to approval. The literals below are the check that host defaults do not skip
# and the read-back that offers `gh api -X PUT` when no default exists. Both
# run under every review policy, because the routers merge with the REST
# spelling under every policy pin; the old wording that confined them to
# `선리뷰후머지` must be gone.
# ---------------------------------------------------------------------------
for lit in \
  'with one check they do not skip: when the plan predicts a merge under any review policy, see whether a confirmed form covers the REST merge spelling' \
  'The check is not limited to `선리뷰후머지`: the routers merge with the REST spelling under every policy pin' \
  '사유: 워크트리 HEAD 에 결속된 REST 머지 — 머지 말고도 모든 대상의 PUT REST 호출을 승인 없이 엽니다' \
  '**When the plan predicts a merge under any review policy, the rows read back carry `gh api -X PUT`**'
do
  # The 5p paragraph lives in boundaries.md, and the resident body carries none
  # of it.
  nlit=$(grep -cF -- "$lit" "$AP_REFS/boundaries.md" || true)
  if [ "${nlit:-0}" = "1" ]; then
    ok "킥오프의 사전 인가 행 계약이 「${lit}」을 한 번 싣는다"
  else
    bad "킥오프의 사전 인가 행 계약" "「${lit}」이 ${nlit:-0}번 있다"
  fi
  nlit=$(grep -cF -- "$lit" "$AP_SKILL" || true)
  if [ "${nlit:-0}" = "0" ]; then
    ok "킥오프의 상주 본문은 「${lit}」을 싣지 않는다"
  else
    bad "킥오프의 상주 본문" "「${lit}」이 SKILL.md 에 ${nlit:-0}번 남아 있다"
  fi
done
for lit in \
  'when the plan predicts a merge under `선리뷰후머지`, see whether' \
  'When the plan predicts a merge under `선리뷰후머지`, the rows read back'
do
  nlit=$(ap_all | grep -cF -- "$lit" || true)
  if [ "${nlit:-0}" = "0" ]; then
    ok "킥오프의 사전 인가 행 계약이 「${lit}」로 정책을 좁히지 않는다"
  else
    bad "킥오프의 사전 인가 행 계약 — 정책 한정 잔존" "「${lit}」이 ${nlit:-0}번 있다"
  fi
done

# ---------------------------------------------------------------------------
# 6e-2b. Push and pull request from the snapshot, in BOTH router copies
#
# No run skill opens a new segment's pull request, so the router takes it from
# the snapshot's `원격 단계`: the remote-check act that refreshes it, the bare
# issue and `admit --request last` with no `--cutpoint` where the session's
# root is hooked, and `guard_refusals[]` read before a remote act. A target-hook
# refusal stops one segment at site `대상 훅 거절` in the shift's copy; the lead
# has no such site and parks the segment with a cone block. Both copies also
# say where a stage session starts — the dispatcher's directory, not the
# segment worktree — because the hook that judges its Bash is that root's.
# ---------------------------------------------------------------------------
for pair in "리드:$AP_ROUTER" "교대:$RS_CORPUS"; do
  who=${pair%%:*}; file=${pair#*:}
  for spec in \
    '#### Pushing and opening a pull request|`원격 단계`' \
    '#### Pushing and opening a pull request|--kind remote-check --target <alias> --segment <id>' \
    '#### Pushing and opening a pull request|gate.sh admit --request last' \
    '#### Pushing and opening a pull request|`guard_refusals[]`' \
    "#### Pushing and opening a pull request|The target's cutpoint comes first, because \`원격 단계\` does not read it" \
    '#### Pushing and opening a pull request|open none — dispatch the review with `리뷰 줄`' \
    '#### Pushing and opening a pull request|git push origin <브랜치>' \
    '#### Pushing and opening a pull request|push with anything before `git`' \
    '#### Pushing and opening a pull request|carry `PR.번호` as `PR=`' \
    '교대=#### Pushing and opening a pull request|stop the segment at site `대상 훅 거절`' \
    '교대=#### Pushing and opening a pull request|never `settings.json` while the run is open' \
    '리드=#### Pushing and opening a pull request|there is no shift-halt site for this loop to use' \
    '교대=#### Pushing and opening a pull request|Never copy `명령` or `거절 문면` into any gate argument' \
    '리드=#### Pushing and opening a pull request|a `스코프=cone` block whose `사유` names the refusal by the element'"'"'s `행위 다이제스트` and `형태`, never quoting `명령` or `거절 문면`'
  do
    case "$spec" in
      리드=*|교대=*) [ "${spec%%=*}" = "$who" ] || continue; spec=${spec#*=} ;;
    esac
    head=${spec%%|*}; lit=${spec#*|}
    sec=$(router_section "$file" "$head")
    nlit=$(printf '%s\n' "$sec" | grep -cF -- "$lit" || true)
    if [ "${nlit:-0}" != "0" ]; then
      ok "$who 사본의 「${head#'#### '}」 절이 「${lit}」을 싣는다"
    else
      bad "$who 사본의 「${head#'#### '}」 절" "「${lit}」이 없다"
    fi
  done
  case "$who" in
    리드) lit='The stage session itself starts in the directory this loop is in, not in that worktree' ;;
    *)    lit='The stage session itself starts in the directory this shift is in, not in that worktree' ;;
  esac
  if grep -qF -- "$lit" "$file"; then
    ok "$who 사본이 리드 수정 스테이지의 세션이 시작하는 디렉터리를 적는다"
  else
    bad "$who 사본의 리드 수정 기동" "「${lit}」이 없다"
  fi
done
if grep -qF -- '| `대상 훅 거절` |' "$RS_CORPUS"; then
  ok "교대 사본의 정지 자리 표가 「대상 훅 거절」을 싣는다"
else
  bad "교대 사본의 정지 자리 표" "「대상 훅 거절」 행이 없다"
fi
if grep -qF -- 'the refused act for `대상 훅 거절`' "$RS_CORPUS"; then
  ok "교대 사본의 재시도 목록이 「대상 훅 거절」의 거절된 행위를 싣는다"
else
  bad "교대 사본의 재시도 목록" "「대상 훅 거절」이 없다"
fi
if grep -qF -- 'so the project hooks it loads are that directory'"'"'s repository'"'"'s' "$RS_CORPUS"; then
  ok "교대 사본이 스테이지가 디스패처의 디렉터리에서 시작한다고 적는다"
else
  bad "교대 사본의 스테이지 시작 디렉터리" "문장이 없다"
fi

# ---------------------------------------------------------------------------
# 6e-3. Merge, apply and the fix re-dispatch are carried by BOTH router copies
#
# After a review passed, no router text merged with a pinned head, recorded the
# merge commit, or issued the apply; after a review raised P0·P1, none sent the
# implementation back with the report as its fix target. The literals below are
# the two merge pins (the prescribed REST merge with its method, bound by its
# `sha` field to the worktree HEAD's full sha rather than a cycle row's review
# HEAD, and the sentence that a `gh pr merge` without `--admin` binds nothing),
# the disposition of a merge refused with 405 by its cause — an already merged
# pull request goes on to the merge record only when its `headRefOid` is the
# worktree HEAD, and otherwise, or when that record is refused, takes the
# park-and-cone disposition, a required check still pending is
# waited on and left routable with a cone block and no `park`, and every other
# cause takes the park-and-cone disposition in the lead's copy (a router has no
# halt record to write, and without the `park` the next shift sends the same
# merge again) and a `shift-halt` stop of that one segment in the shift's, the
# fetch before the apply, the apply act's fixed token, the same split for a
# precondition refusal, the cycle cap, and the `다음` branches that send a
# segment to the carry-over procedure, the lead fix, the re-check, the residual
# park and a sliced review. The fix prompt must
# be one string in both copies, and the fix section
# does not restate the delta basis expression, which belongs to the delta
# subsection.
# ---------------------------------------------------------------------------
fix_prompt=""
fix_prompt_rs=""
for pair in "리드:$AP_ROUTER" "교대:$RS_CORPUS"; do
  who=${pair%%:*}; file=${pair#*:}
  for spec in \
    '#### Merging and applying a segment|**Below the `머지` cutpoint nothing is merged.**' \
    '#### Merging and applying a segment|-- 상태=완료 커밋=<구현 워크트리 HEAD> 브랜치=<브랜치> 워크트리=<구현 워크트리> 선행=<계획 행의 선행>' \
    '#### Merging and applying a segment|gh api -X PUT repos/<owner>/<repo>/pulls/<n>/merge -f sha=<구현 워크트리 HEAD> -f merge_method=merge' \
    '#### Merging and applying a segment|A `gh pr merge` without `--admin` is refused as unbound even with `--match-head-commit`' \
    '#### Merging and applying a segment|gh pr view <n> --json state,headRefOid,mergeCommit,mergeStateStatus' \
    '#### Merging and applying a segment|- **Already merged** (`state` reads `MERGED` and `headRefOid` equals the implementation worktree'"'"'s HEAD, all 40 characters' \
    '#### Merging and applying a segment|**`MERGED` with any other `headRefOid`, or a `상태=머지됨` record the gate refuses, is the last bullet'"'"'s case, not this one**' \
    '#### Merging and applying a segment|so take **Any other cause** with `MERGED` and the `headRefOid` (or the refusal) as its `사유`' \
    '#### Merging and applying a segment|Still pending → write no block and no `park`; route other work, and when nothing else is dispatchable end with `대기` carrying `'"'"'CI 대기=<id>'"'"'`' \
    '#### Merging and applying a segment|- **Any other cause** — a base that requires a merge queue' \
    '리드=#### Merging and applying a segment|a `스코프=cone` block whose `사유` names the 405' \
    '리드=#### Merging and applying a segment|The `park` makes the segment terminal, so the next shift does not send the same merge again' \
    '교대=#### Merging and applying a segment|stop the segment at site `병합 거절` (「Stopping one segment for a person」)' \
    '교대=#### Merging and applying a segment|No shift sends the same merge again until the answer comes back' \
    '#### Merging and applying a segment|gh pr view <n> --json mergeCommit' \
    "#### Merging and applying a segment|-- 상태=머지됨 PR=<n> '머지 커밋=<M>' 워크트리=<구현 워크트리> 선행=<계획 행의 선행>" \
    '#### Merging and applying a segment|`대기` or `인계` → first issue the pre-authorized `gate.sh exec … -- git fetch` once more' \
    '#### Merging and applying a segment|look at `적용` on that segment'"'"'s `segments[]` element. `없음` → the merge is the segment'"'"'s end' \
    '#### Merging and applying a segment|so issue neither the fetch nor the apply act' \
    '#### Merging and applying a segment|is answered with `적용 불필요` and exit 0, and the gate writes nothing: that too is the segment'"'"'s end, not a refusal' \
    '#### Merging and applying a segment|--kind apply --target <alias> --segment <id>' \
    '#### Merging and applying a segment|--cutpoint 배포 --surface 외부상태변경 --snapshot-digest <H> -- 적용' \
    '#### Merging and applying a segment|fetch and issue it once more, and only once' \
    '리드=#### Merging and applying a segment|a `스코프=cone` block whose `사유` names the refused precondition number' \
    '교대=#### Merging and applying a segment|stop the segment at site `적용 전제 거부` (「Stopping one segment for a person」)' \
    '교대=#### Merging and applying a segment|so write no `shift-halt` for it: a `park` segment is terminal and no answer could retry its apply' \
    '#### Re-dispatching the implementation after review findings|element reads `다음` `수정`' \
    '#### Branching on `다음` after a review|`_common/carryover-issue.md`' \
    "#### Branching on \`다음\` after a review|-- lead-fix -p '/cc-cmds:review-unattended <브랜치> --lead-fix <리포트 경로> \"설계는 <문서 인자>\"'" \
    '#### Spelling a review dispatch|`gate.sh review-line --manifest <매니페스트> --segment <seg> [-- <flag>…]`' \
    '#### Spelling a review dispatch|Do not rebuild these arguments from an earlier stage'"'"'s stream log or from memory' \
    '#### Spelling a review dispatch|the gate refuses a review dispatch naming any other (exit 2)' \
    '#### Spelling a review dispatch|**Declare why the review goes** with `--trigger '"'"'<토큰>'"'"'` before `--`, on the `act` and on its `plan` alike' \
    '#### Spelling a review dispatch|`라우터 판단` together with `--trigger-reason '"'"'<사유>'"'"'` only when none of those holds' \
    '#### Spelling a review dispatch|`첫 리뷰`, `리뷰 P0`, `리뷰 P1`, `CI 실패`, `베이스 충돌`, `버전 경합`, `리베이스`, `해소 리뷰`, `중단 답`, `중단 인계`' \
    '#### Branching on `다음` after a review|with `--recheck <리포트 경로>` added to the prompt' \
    '#### Branching on `다음` after a review|`gate.sh residual-body --manifest <매니페스트> --segment <seg>`' \
    "#### Branching on \`다음\` after a review|\`'사유=리뷰 잔여'\`" \
    '#### Branching on `다음` after a review|adds `--slice <seg>` to the prompt' \
    '#### Re-dispatching the implementation after review findings|once they reach `REIMPL_CYCLE_CAP` (2)'
  do
    # A `<사본>=` prefix pins a literal to one copy: the shift stops one
    # segment with `shift-halt`, which a lead running alone cannot write, so
    # the lead keeps the park-and-cone disposition.
    case "$spec" in
      리드=*|교대=*) [ "${spec%%=*}" = "$who" ] || continue; spec=${spec#*=} ;;
    esac
    head=${spec%%|*}; lit=${spec#*|}
    sec=$(router_section "$file" "$head")
    nlit=$(printf '%s\n' "$sec" | grep -cF -- "$lit" || true)
    if [ "${nlit:-0}" != "0" ]; then
      ok "$who 사본의 「${head#'#### '}」 절이 「${lit}」을 싣는다"
    else
      bad "$who 사본의 「${head#'#### '}」 절" "「${lit}」이 없다"
    fi
  done
  msec=$(router_section "$file" '#### Merging and applying a segment')
  nold=$(printf '%s\n' "$msec" | grep -cF -- 'last cycle row>' || true)
  if [ "${nold:-0}" = "0" ]; then
    ok "$who 사본의 「Merging and applying a segment」 절에 사이클 행의 리뷰 HEAD 로 묶는 옛 머지 처방이 없다"
  else
    bad "$who 사본의 「Merging and applying a segment」 절" "옛 자리표시 「last cycle row>」가 ${nold}번 있다"
  fi
  nold=$(printf '%s\n' "$msec" | grep -cF -e '--json state,mergeCommit,mergeStateStatus' \
    -e '(`state` reads `MERGED` — an earlier shift' || true)
  if [ "${nold:-0}" = "0" ]; then
    ok "$who 사본의 「Merging and applying a segment」 절에 head 를 대조하지 않는 옛 「이미 머지됨」 갈래가 없다"
  else
    bad "$who 사본의 「Merging and applying a segment」 절" "headRefOid 없는 옛 405 읽기·갈래 문면이 ${nold}줄 있다"
  fi
  # The lead's absence is read across the whole skill, not only its router
  # reference: the instruction must not reach the lead from any file it reads.
  if [ "$who" = "리드" ]; then
    nhalt=$(ap_all | grep -cF -- 'write a halt record' || true)
  else
    nhalt=$(grep -cF -- 'write a halt record' "$file" || true)
  fi
  if [ "${nhalt:-0}" = "0" ]; then
    ok "$who 사본은 라우터에게 halt 기록을 쓰라고 지시하지 않는다"
  else
    bad "$who 사본" "라우터가 쓸 수 없는 halt 기록을 쓰라는 지시가 ${nhalt}줄 있다"
  fi
  fsec=$(router_section "$file" '#### Re-dispatching the implementation after review findings')
  prompt=$(printf '%s\n' "$fsec" | grep -oE -- '-- implement -p "/cc-cmds:implement-unattended .*"$' | sort -u)
  check "$who 사본의 수정 재파견 절에 지시 문구가 한 벌 실린다" \
    "$(printf '%s\n' "$prompt" | grep -c -- '수정 대상: <리포트 절대 경로> 의 P0·P1')" "1"
  if [ -z "$fix_prompt" ]; then fix_prompt="$prompt"; else fix_prompt_rs="$prompt"; fi
  nlit=$(printf '%s\n' "$fsec" | grep -cF 'max_by((.["사이클"]' || true)
  if [ "${nlit:-0}" != "0" ]; then
    bad "$who 사본의 수정 재파견 절" "델타 리뷰 기준 선택 식을 다시 적었다"
  else
    ok "$who 사본의 수정 재파견 절은 델타 기준 선택 식을 다시 적지 않는다"
  fi
done
check "두 사본의 수정 재파견 지시 문구가 바이트 동일하다" "$fix_prompt_rs" "$fix_prompt"

# ---------------------------------------------------------------------------
# 6e-3a. The fix cycle reads the same two pieces every producer writes
#
# An implementation stage knows it is a fix cycle only by two pieces of its
# prompt, `수정 대상: ` and ` 의 P0·P1`. The router copies above write them,
# and so do the driver's two `fix_target` assignments; the common fix-cycle
# file is the one reader. A piece reworded on any side switches the start
# condition off without an error, so every side is pinned here. The common
# file is pointed at by the two unattended skills alone, carries no question
# or notification surface, and holds no copy of the passages its checker
# prompt names. The implementation skill carries the phase sentence, the
# start disposition and the end obligation, with the two spellings one writes
# and the other reads.
# ---------------------------------------------------------------------------
FC="$PLUGIN_ROOT/skills/_common/fix-cycle.md"
IU="$PLUGIN_ROOT/skills/implement-unattended/SKILL.md"
check "수정 대상 조각: run.sh 의 fix_target 대입 두 줄이 두 조각을 모두 싣는다" \
  "$(grep -cE -- 'fix_target=" · 수정 대상: \$[a-z_]+ 의 P0·P1"' "$DRIVER" || true)" "2"
fc_start=$(awk '/^## Start condition$/{on=1; next} on && /^## /{exit} on' "$FC" 2>/dev/null)
check "수정 대상 조각: 공통 파일의 시작 조건이 두 조각을 모두 싣는다" \
  "$(printf '%s\n' "$fc_start" | grep -F -- '수정 대상: ' | grep -cF -- ' 의 P0·P1' || true)" "2"
check "공통 fix-cycle 파일을 가리키는 파일은 두 무인 스킬뿐이다" \
  "$(cd "$repo_root" && grep -rl 'fix-cycle' plugins/cc-cmds/skills | LC_ALL=C sort | tr '\n' ' ')" \
  "plugins/cc-cmds/skills/implement-unattended/SKILL.md plugins/cc-cmds/skills/review-unattended/SKILL.md "
check "공통 fix-cycle 파일에 질문 면과 알림 면 문자열이 없다" \
  "$(grep -cE -- 'AskUserQuestion|question_form|EnterPlanMode|ExitPlanMode|PushNotification|notify\.sh|terminal-notifier' "$FC" 2>/dev/null || true)" "0"
fc_copies=0
for lit in \
  'There is no human-question surface.' \
  'Research is open: `WebFetch`' \
  '같은 커밋이 두 번 리뷰됐다' \
  '같은 파일 집합이 세 리뷰 연속 P0/P1 발견을 지녔다' \
  '발견의 파일 집합이 네 리뷰에 걸쳐 번갈아 나왔다' \
  '발견의 사례가 아니라 그 부류를 고친다'
do
  n=$(grep -cF -- "$lit" "$FC" 2>/dev/null || true)
  fc_copies=$((fc_copies + ${n:-0}))
done
check "공통 fix-cycle 파일에 질문 면 부재 불변식·조사 문단·정체 지시 문구의 사본이 없다" \
  "$([ -f "$FC" ] && echo "$fc_copies" || echo 없음)" "0"
IFS= read -r fix_phase_s <<'EOF'
A dispatch whose scope directive carries `수정 대상:` is process B whenever a plan row that has not been voided exists, even when that plan's `Scope:` line names a different report.
EOF
check "구현 무인 스킬의 국면 판정에 수정 파견의 프로세스 B 문장이 한 줄 있다" \
  "$(grep -cF -- "$fix_phase_s" "$IU" || true)" "1"
iu_start=$(grep -F -- '**Start disposition — what an earlier turn left in the worktree.**' "$IU" || true)
iu_end=$(grep -F -- '**End obligation — process B leaves none of its files in `git status --short`.**' "$IU" || true)
check "구현 무인 스킬에 시작 처분과 끝 의무 문장이 있다" \
  "$([ -n "$iu_start" ] && echo 시작)/$([ -n "$iu_end" ] && echo 끝)" "시작/끝"
check "끝 의무가 보존 경로= 조각을 쓰고 시작 처분이 그것을 읽는다" \
  "$(printf '%s\n' "$iu_end" | grep -cF -- '`보존 경로=<path>,<path>`' || true)/$(grep -cF -- 'the `보존 경로=` piece of its `**관측 상세**`' "$IU" || true)" "1/1"
check "프로세스 A 가 물려받은 변경: 줄을 쓰고 프로세스 B 가 그것을 읽는다" \
  "$(grep -cF -- 'one `물려받은 변경:` line' "$IU" || true)/$(grep -cF -- 'the plan'"'"'s `물려받은 변경:` line marks `되돌림`' "$IU" || true)" "1/1"
check "보존 경로= 와 물려받은 변경: 은 구현 무인 스킬에서 한 꼴로만 쓰인다" \
  "$(grep -cE -- '보존경로|보존 경로 ?:|보존 경로 =|물려받은변경|물려받은 변경 ?=' "$IU" || true)" "0"

# ---------------------------------------------------------------------------
# 6e-3b. Routing after an implementation is carried by BOTH router copies
#
# A process A that only emitted its plan ends `정상 완료` exactly as a process B
# does, and the routers used to send either straight to a review — so a branch
# with no commit was reviewed, the review stopped, and the night waited on a
# person. The literals below are the subsection that branches on
# `implement_next[]`'s `다음` instead: the sentence that holds a review to
# `리뷰`, the four values, and the three cone reasons. Only the lead's copy has
# a snapshot key table, so its row is pinned there; only the shift answers a
# halt record, so the empty-target branch and its item are pinned there.
# ---------------------------------------------------------------------------
in_head='#### Routing a segment after its implementation ends `정상 완료`'
in_sec_ap=""; in_sec_rs=""
for pair in "리드:$AP_ROUTER" "교대:$RS_CORPUS"; do
  who=${pair%%:*}; file=${pair#*:}
  check "$who 사본에 구현 뒤 라우팅 절 표제가 한 줄 있다" \
    "$(grep -cxF -- "$in_head" "$file" || true)" "1"
  sec=$(router_section "$file" "$in_head")
  for lit in \
    '`implement_next[]`' \
    '**Do not dispatch a review for a segment whose element reads a `다음` other than `리뷰`.**' \
    '- **`리뷰`** →' \
    '- **`구현`** →' \
    '- **`사람`** →' \
    '- **`판정 불가`** →' \
    "\`'사유=구현 재파견 거절'\`" \
    "\`'사유=무커밋 구현 한도'\`" \
    "\`'사유=구현 산출 판정 불가'\`"
  do
    nlit=$(printf '%s\n' "$sec" | grep -cF -- "$lit" || true)
    if [ "${nlit:-0}" != "0" ]; then
      ok "$who 사본의 구현 뒤 라우팅 절이 「${lit}」을 싣는다"
    else
      bad "$who 사본의 구현 뒤 라우팅 절" "「${lit}」이 없다"
    fi
  done
  if [ -z "$in_sec_ap" ]; then in_sec_ap="$sec"; else in_sec_rs="$sec"; fi
done
check "두 사본의 구현 뒤 라우팅 절이 바이트 동일하다" "$in_sec_rs" "$in_sec_ap"
check "리드 사본의 키 표가 implement_next[] 행을 싣는다" \
  "$(grep -c -- '^| `implement_next\[\]` |' "$AP_ROUTER" || true)" "1"
ha_sec=$(router_section "$RS_CORPUS" "#### Handing on a person's answer to a halt")
for lit in \
  '| `빈-대상` | 7 |' \
  '7. **A review that stopped on an empty target is answered by an implementation or a park — no session is re-attached.**' \
  "- **\`구현 재파견\`** → dispatch the segment's implementation" \
  "\`'사유=빈 대상 리뷰 정지'\`"
do
  nlit=$(printf '%s\n' "$ha_sec" | grep -cF -- "$lit" || true)
  if [ "${nlit:-0}" != "0" ]; then
    ok "교대 사본의 중단 답 넘김 절이 「${lit}」을 싣는다"
  else
    bad "교대 사본의 중단 답 넘김 절" "「${lit}」이 없다"
  fi
done

# ---------------------------------------------------------------------------
# 6e-4. The merge-order sentences are byte-identical in BOTH router copies
#
# The two copies are not compared whole — their paragraphs already differ in
# parentheses and wording — so each sentence that carries the second kind of
# ordering is pinned on its own: the dependency condition that reads `선행`
# alone, the planning rule over both lists, the merge that waits for an empty
# `머지 대기`, the 405 disposition that never brings the base into the branch,
# and the disposition of the gate's planning-order refusal — a deferred slice
# cuts no branch, that refusal is a wait rather than an ending, and a slice
# planned again reuses the branch and worktree an earlier pass made. Each
# literal must occur exactly once in each copy, which is what makes the two
# byte-identical without comparing the paragraphs around them. A literal under a
# heading both copies share is searched inside that section; the dependency
# sentence sits under different headings in the two copies and is counted over
# the whole file. The clause that chooses which live stage to wait on belongs
# to the lead copy alone, which holds its wait itself: a shift waits in no
# turn, ends with one `대기`, and the gate wakes its successor on whichever
# live stage leaves first, so the shift's copy says it picks none and carries
# no foreground stage wait.
# ---------------------------------------------------------------------------
mo_count() {  # mo_count <text> <literal> — occurrences, not lines
  printf '%s\n' "$1" | grep -oF -- "$2" | wc -l | tr -d ' '
}
for pair in "리드:$AP_ROUTER" "교대:$RS_CORPUS"; do
  who=${pair%%:*}; file=${pair#*:}
  for spec in \
    '|The **dependency** condition reads `선행` alone — implementation precedence, a predecessor that has not landed. A predecessor named only in `머지 순서` does not hold back the dispatch; it holds back the merge alone (see 「Merging and applying a segment」).' \
    '#### Planning the segments|That value is the dispatch floor'"'"'s own landing judgment, and it covers both a segment whose last `segment` row is `머지됨` or `완료` and one parked after a `머지됨` — unless that merge still owed this run its apply.' \
    '#### Planning the segments|**A slice is planned when two conditions hold together**: every `선행` token'"'"'s predecessor reads `"착지": true` in its `segments[]` entry, and every `머지 순서` token of the slice — read from the snapshot'"'"'s `슬라이싱.세그먼트[]`, because a slice with no row yet is not in `segments[]` — already has a `segment` row.' \
    '#### Planning the segments|A slice whose `선행` is `없음` and whose `머지 순서` tokens all have rows is planned and dispatched at once, cut from the current base.' \
    '#### Planning the segments|**A slice whose `슬라이싱` entry reads `"착지 행": true` and that has no `segments[]` entry is brought in, not built**: the manifest carries a `선행 착지` row for it, so issue call 3 alone at once, whatever its `선행` and `머지 순서` read — no `git fetch` and no `git worktree add -b` — with `--target` the entry'"'"'s `대상`, or the alias whose `home` is `예` in `targets[]` when `대상` is empty, and `워크트리=` the entry'"'"'s `워크트리`, or `-` when it is empty; the act writes the slice'"'"'s own `상태=머지됨 · 출처=매니페스트` row and no planned row, so do not dispatch it, and its dependents are planned by the rule above once its `segments[]` entry reads `"착지": true`. A refusal with exit 3 here ends the shift as the predecessor import'"'"'s refusal below does.' \
    '#### Planning the segments|A `머지 순서` token with no row yet (that slice still waits on its own `선행`) defers the slice until the row appears, and a slice carrying both lists follows the same product: with D `선행` A and D `머지 순서` C, D waits for C'"'"'s row even after A has landed.' \
    '#### Planning the segments|Planned earlier, the slice is refused with exit 2 by the floor that requires every token to name a segment this ledger knows.' \
    '#### Planning the segments|The two imports below — a predecessor an earlier run already merged, and one the manifest'"'"'s `선행 착지` row names — apply to a `머지 순서` token as well, and the planning act writes that predecessor'"'"'s row itself; without them the row would never appear and the slice would never be planned.' \
    '#### Planning the segments|With C `머지 순서` B and B `선행` A, B is planned after A lands, and C is planned once B'"'"'s row exists and runs alongside B.' \
    '#### Planning the segments|Pass no `머지 순서` on the planning row: the gate writes it from the declaration and carries it forward.' \
    '#### Planning the segments|A slice the planning rule below defers gets none of the three calls — no `git fetch` and no `git worktree add -b` either — until that rule plans it.' \
    '#### Planning the segments|**A refusal with exit 2 saying a token 「is declared in the frozen document and has no segment row on this ledger yet」 is a deferral, not an ending**: write nothing, make no `사유=중단` handoff, say nothing of a new run, and plan the same slice again once that token has a row.' \
    '#### Planning the segments|Any other refusal with exit 2 naming a predecessor that no ledger shows landed — a slice the document does not declare, or one whose `레포` is not a target of this run — is the same ending: a run cannot gain a `선행 착지` row after its kickoff, so say in the handoff that a new run with that row is what plans the slice.' \
    '#### Planning the segments|When an earlier pass already made the slice'"'"'s derived branch and worktree (the `슬라이싱` entry'"'"'s branch and worktree), planning it again does not cut them a second time: skip calls 1 and 2 and issue call 3 alone.' \
    '#### Merging and applying a segment|**Whatever the review policy, merge a segment only when its snapshot `머지 대기` is empty.** A non-empty `머지 대기` names the predecessors, by `선행` or `머지 순서`, that have not landed yet: do other work, or wait as 「Waiting on a stage」 chooses.' \
    '#### Merging and applying a segment|A refusal with exit 3 that names such a predecessor and its `상태` means the same — wait — whether the refused act was the merge or another act leaving the worktree whose grade the gate could not read; it is not **Any other cause** below, and nothing is written for it. A predecessor that was parked has already parked this segment through its cone.' \
    '#### Merging and applying a segment|Never merge or rebase the moved base into a branch yourself: only a `베이스 해소` dispatch does that, and what it adds is reviewed before it merges.'
  do
    head=${spec%%|*}; lit=${spec#*|}
    if [ -n "$head" ]; then
      text=$(router_section "$file" "$head"); where="「${head#'#### '}」 절"
    else
      text=$(cat "$file"); where="파일 전체"
    fi
    n=$(mo_count "$text" "$lit")
    if [ "$n" = "1" ]; then
      ok "$who 사본의 ${where}에 머지 순서 문장이 한 번 실린다 — 「${lit:0:60}…」"
    else
      bad "$who 사본의 ${where} — 머지 순서 문장" "「${lit:0:60}…」이 ${n}번 있다 (기대 1)"
    fi
  done
done
mo_wait='When nothing is dispatchable or mergeable and two or more segment stages are live, wait (`gate.sh wait --segment <id> --timeout 540`) on the earliest-declared live segment among those named in some segment'"'"'s `머지 대기`; if none is named, on the earliest-declared live segment. On exit 13 or when that stage ends, take a fresh snapshot and route every stage that has left `live_stages[]` before waiting again.'
mo_pick='on the earliest-declared live segment among those named in some segment'"'"'s `머지 대기`; if none is named, on the earliest-declared live segment.'
mo_none='When nothing is dispatchable or mergeable and two or more segment stages are live, end with the same single `대기`: you do not pick a segment to wait on.'
check "리드 사본에 대기할 세그먼트를 고르는 문장이 한 번 실린다" "$(mo_count "$(cat "$AP_ROUTER")" "$mo_pick")" "1"
check "교대 사본에는 대기할 세그먼트를 고르는 문장이 없다" "$(mo_count "$(cat "$RS_CORPUS")" "$mo_pick")" "0"
check "교대 사본의 「Waiting on a stage」 절에 고르지 않고 대기로 끝낸다는 문장이 한 번 실린다" \
  "$(mo_count "$(router_section "$RS_CORPUS" '### Waiting on a stage')" "$mo_none")" "1"
check "교대 사본에는 포그라운드 스테이지 대기 문장 전체가 없다" "$(mo_count "$(cat "$RS_CORPUS")" "$mo_wait")" "0"
check "리드 사본에는 포그라운드 대기 문장 전체가 없다" "$(mo_count "$(cat "$AP_ROUTER")" "$mo_wait")" "0"
# The planning-order refusal is consumed by the router, not only written by the
# gate: the copies quote the gate's own words, so a gate rewording that leaves
# the router text behind fails here, and the broad sentence that sent this
# refusal to `사유=중단` and a new run must not come back in either copy.
mo_defer='is declared in the frozen document and has no segment row on this ledger yet'
check "게이트가 계획 순서 거부 문면을 낸다" "$(mo_count "$(cat "$GATE")" "$mo_defer")" "1"
mo_old='A refusal with exit 2 naming a predecessor that no ledger shows landed is the same ending: a run cannot gain a `선행 착지` row after its kickoff, so say in the handoff that a new run with that row is what plans the slice.'
for pair in "리드:$AP_ROUTER" "교대:$RS_CORPUS"; do
  who=${pair%%:*}; file=${pair#*:}
  check "$who 사본의 계획 절이 게이트의 계획 순서 거부 문면을 인용한다" \
    "$(mo_count "$(router_section "$file" '#### Planning the segments')" "$mo_defer")" "1"
  check "$who 사본에 계획 순서 거부를 새 런으로 보내던 옛 문장이 없다" \
    "$(mo_count "$(cat "$file")" "$mo_old")" "0"
done

# ---------------------------------------------------------------------------
# 6e-5. The review stage checks its own report with `report-check`
#
# The gate records a report's shape on the `cycle` row and refuses nothing on
# it, so the only place a malformed report is repaired is the review stage
# that wrote it. The sentences below are that loop, in the ordinary Step 5 and
# in the recovery arm: the verb and its spelling, the two-round cap, the gate
# failure that ends without editing, and the two edits that are never made — a
# summary bent to the items, and a review HEAD line invented for a recovery.
# The verb's verdict line is quoted from the gate, so a rewording of either
# side fails here.
# ---------------------------------------------------------------------------
RU_SKILL="$PLUGIN_ROOT/skills/review-unattended/SKILL.md"
RU_RECOVER="$PLUGIN_ROOT/skills/review-unattended/references/recovery-arm.md"
rc_verdict='report-check: 불일치 <n>'
check "게이트가 report-check 의 판정 줄을 낸다" \
  "$(mo_count "$(cat "$GATE")" "printf 'report-check: 불일치 %s")" "1"
for pair in "Step 5:$RU_SKILL" "복구 팔:$RU_RECOVER"; do
  who=${pair%%:*}; file=${pair#*:}
  for lit in \
    'gate.sh report-check --manifest "$CC_PIPELINE_MANIFEST" --report <' \
    "$rc_verdict" \
    'at most two rewrites, then' \
    'Never edit the summary counts to match the items' \
    'Nothing here halts.'
  do
    case "$who:$lit" in
      'Step 5:Never edit the summary counts to match the items') lit='Never edit the `발견 요약` counts to match the items' ;;
    esac
    check "$who 의 report-check 고리가 「${lit:0:50}」 을 싣는다" "$(mo_count "$(cat "$file")" "$lit")" "1"
  done
done
check "Step 5 의 report-check 고리는 게이트 실패를 고치지 않고 끝낸다" \
  "$(mo_count "$(cat "$RU_SKILL")" 'is the gate failing, not the report: end the stage without editing')" "1"
check "복구 팔은 복구 리포트에 리뷰 HEAD 줄을 지어 넣지 않는다" \
  "$(mo_count "$(cat "$RU_RECOVER")" 'never write a `리뷰 HEAD` line into a recovered report')" "1"

# ---------------------------------------------------------------------------
# CFI-11 — a re-kickoff carries no ledger row as a permission, with one
# re-derived exception
#
# The clause that keeps the re-kickoff from carrying a ledger row now names the
# one row it derives again instead, the `세그먼트 입양` row, and says what
# happens to every segment that fails the derivation. Both halves are pinned in
# the resident body, so a rewording that keeps the exception and drops the
# report of what was not adopted fails here.
# ---------------------------------------------------------------------------
for lit in \
  'a ledger row only triggers a question — or, for a `세그먼트 입양` row alone, a re-derivation' \
  'anything else is not adopted and is reported with its cause'
do
  check "CFI-11 이 「${lit:0:50}」 을 싣는다" "$(mo_count "$(cat "$AP_SKILL")" "$lit")" "1"
done

# ---------------------------------------------------------------------------
# 6e-6. The shift's branch index and its reference files agree
#
# The shift reads a reference file only through the table of
# `## Branch procedures read on entry` in its body. A file the table names and
# the directory lacks is a branch the shift is told to read and cannot; a file
# the table does not name is a branch no entry condition ever opens; and a file
# over 24000 bytes comes back from a gate-routed read as a saved path rather
# than inline, which the shift's settings give it no way to open.
# ---------------------------------------------------------------------------
rs_index=$(router_section "$RS_SKILL" '## Branch procedures read on entry')
rs_named=$(printf '%s\n' "$rs_index" | grep -E '^\| `[a-z0-9-]+\.md`' \
           | grep -oE '`[a-z0-9-]+\.md`' | tr -d '`' | sort -u)
check "교대 색인 표가 references 파일을 적는다" "$([ -n "$rs_named" ] && echo 예 || echo 아니오)" "예"
for f in $rs_named; do
  check "교대 색인이 적은 ${f} 가 references 에 있다" "$([ -f "$RS_REFS/$f" ] && echo 예 || echo 아니오)" "예"
done
for p in "$RS_REFS"/*.md; do
  f=${p##*/}
  check "교대 references 의 ${f} 가 색인 표에 있다" "$(printf '%s\n' "$rs_named" | grep -cxF -- "$f")" "1"
  sz=$(wc -c < "$p" | tr -d ' ')
  if [ "$sz" -le 24000 ]; then
    ok "교대 references 의 ${f} 가 24000바이트 이하다 (${sz})"
  else
    bad "교대 references 의 ${f} 크기" "${sz}바이트 — 게이트 경유 읽기가 인라인으로 돌아오지 않는다"
  fi
done

# A re-convergence a halt answer sent for the design or audit step leaves that
# step's last row reading `종류=reconverge`: the answer element has already left
# `answered_halts[]`, the last row is no park, and the refutation row is keyed on
# segments. Only this condition opens the halt-answer files there, whose
# after-the-re-convergence dispositions decide between a fresh audit and a stop.
# The design-dispatch file opens on the same state and sends the step to the
# audit, so the row also says which of the two decides the step's next act.
rs_halt_row=$(printf '%s\n' "$rs_index" | grep -E '^\| `halt-answer-1\.md`, `halt-answer-2\.md` \|')
check "교대 색인의 할트 답 행이 설계·감사 스텝의 재수렴 뒤 진입 조건을 싣는다" \
  "$(printf '%s\n' "$rs_halt_row" | grep -cF -- 'the last `stage-result` row of the design step or of the audit step reads `종류=reconverge`')" "1"
check "교대 색인의 할트 답 행이 그 상태에서 설계 파견 절보다 할트 답 절의 처분을 앞세운다" \
  "$(printf '%s\n' "$rs_halt_row" | grep -cF -- '**After it ends** disposition of 「Handing on a person'"'"'s answer to a halt」, not `design-dispatch.md` opened beside it, sets that step'"'"'s next act')" "1"
# A settled answer on a segment key, or a re-convergence a binding-tier answer
# dispatched, leaves the segment's last row reading `종류=reconverge` after the
# answer has left `answered_halts[]`. A shift that starts then has nothing else
# that opens the files holding the dispositions that read that row, and the
# refutation file's item 6 hands such a row to them rather than calling it a
# failed re-convergence.
check "교대 색인의 할트 답 행이 세그먼트의 재수렴 행 진입 조건을 싣는다" \
  "$(printf '%s\n' "$rs_halt_row" | grep -cF -- 'the last `stage-result` row of a segment reads `종류=reconverge` — a settled row carrying `정산=` and a re-convergence dispatched for a binding-tier answer alike')" "1"
check "반증 재수렴 6번이 정산= 행을 할트 답 절의 몫으로 넘긴다" \
  "$(grep -cF -- 'So is a re-convergence row carrying `정산=`: the gate wrote it when item 3 of that subsection settled an answer' "$RS_REFS/refutation-reconverge.md")" "1"

printf '\n통과 %s · 실패 %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
