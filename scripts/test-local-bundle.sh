#!/usr/bin/env bash
# Acceptance test: every component of `make check-cheap` fails on the class of
# defect it is there to catch, and the bundle itself does not swallow a failure.
#
# THE SHAPE, and why each piece is there:
#
#   - The working tree is copied into a scratch MIRROR that is its own git
#     repository, the way scripts/test-suite-isolation.sh builds its mirror.
#     Every mutation lands in the mirror; tracked files are never touched.
#   - A CONTROL run comes first for each component, on the untouched mirror.
#     Without it, "the component failed on the mutant" could mean the component
#     fails everywhere — on a mirror that lacks a file it reads, for instance.
#   - One mutation per class, each the smallest edit that reintroduces the
#     defect the class names, and each checked to have changed the file before
#     it is run: a mutation whose pattern no longer matches the tree would leave
#     the mirror clean and turn the assertion into a second control.
#   - The meta suite's four classes are mutated together and run once, and each
#     class is asserted by its own FAIL line rather than by the exit status, so
#     one class cannot stand in for another.
#   - Then the wiring: `make -n check-cheap` carries all three components and no
#     prefix that swallows a failure, and one `make check-cheap` on a mutated
#     mirror ends non-zero. The mutation used there is the keepset one, whose
#     component runs last, so a recipe that stopped early or ignored the last
#     status would pass on it.
#   - Last, the targets that put the bundle in front of a push: `check-push`,
#     `check-push-verify` and the self-test that `test` and `test-rest` run.
#     Only the Makefile wiring is asserted. The instruction to run them lives in
#     the repository CLAUDE.md, which is not tracked, so CI and the clone
#     `check-push` builds have no copy of it to read.
#
# Usage: bash scripts/test-local-bundle.sh

set -uo pipefail

# THE NOTIFIER IS OFF FOR THIS WHOLE PROCESS. This suite runs the gate suite's
# static sections inside the mirror, and the leak census in the meta suite
# selects every suite that runs a gate-family script and demands these exports.
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
CC_CMDS_DASHBOARD=off
export CC_CMDS_DASHBOARD
# A suite started inside a pipeline stage inherits the run's names; nothing
# here belongs to that run.
unset CC_PIPELINE_MANIFEST CC_PIPELINE_LEDGER CC_PIPELINE_RUN_ID \
      CC_PIPELINE_RUN_DIR CC_PIPELINE_GRANT CC_PIPELINE_GATE \
      CC_PIPELINE_TARGET CC_PIPELINE_SEGMENT CC_PIPELINE_STAGE_ID \
      CC_PIPELINE_SHIFT_ID CC_PIPELINE_PARENT_SESSION GATE_ACT_CWD

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

ROOT=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/test-local-bundle.XXXXXX")" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

passed=0
failed=0
ok()  { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }

# --- the mirror: the working tree as its own repository ----------------------
MIRROR="$ROOT/mirror"
mkdir -p "$MIRROR"
for d in plugins scripts tests .github Makefile; do
  [ -e "$repo_root/$d" ] && cp -R "$repo_root/$d" "$MIRROR/"
done
( cd "$MIRROR" && git init -q \
  && git -c user.email=t@example.invalid -c user.name=T add -A \
  && git -c user.email=t@example.invalid -c user.name=T \
       commit -q --no-gpg-sign -m mirror ) \
  || { echo "FAIL: 거울 레포를 만들지 못했다" >&2; exit 1; }

# restore <rel> — put the mirror's copy of one file back to the working tree's.
restore() { cp "$repo_root/$1" "$MIRROR/$1"; }

# mut_replace <rel> <old> <new> — replace every occurrence of a literal, and
# refuse when there is none: a mutation that changes nothing is a control.
mut_replace() {
  local f="$MIRROR/$1" n
  n=$(grep -cF -- "$2" "$f" || true)
  if [ "${n:-0}" -lt 1 ]; then
    bad "변이 준비" "$1 에 「$2」 가 없다 — 변이가 아무것도 바꾸지 않는다"
    return 1
  fi
  OLD="$2" NEW="$3" awk '{
    o = ENVIRON["OLD"]; r = ENVIRON["NEW"]; out = ""
    while ((i = index($0, o)) > 0) { out = out substr($0, 1, i - 1) r; $0 = substr($0, i + length(o)) }
    print out $0
  }' "$f" > "$f.mut" && mv "$f.mut" "$f"
}

# mut_drop_line <rel> <line> — delete every line equal to <line>, refusing when
# there is none.
mut_drop_line() {
  local f="$MIRROR/$1" n
  n=$(grep -cxF -- "$2" "$f" || true)
  if [ "${n:-0}" -lt 1 ]; then
    bad "변이 준비" "$1 에 「$2」 줄이 없다 — 변이가 아무것도 바꾸지 않는다"
    return 1
  fi
  L="$2" awk '$0 != ENVIRON["L"]' "$f" > "$f.mut" && mv "$f.mut" "$f"
}

# The three components, run in the mirror. Each prints its exit status.
run_gate()    { ( cd "$MIRROR" && bash scripts/test-gate.sh --sections "$1" ) > "$ROOT/out" 2>&1; printf '%s' "$?"; }
run_meta()    { ( cd "$MIRROR" && bash scripts/test-meta-invariants.sh ) > "$ROOT/out" 2>&1; printf '%s' "$?"; }
run_keepset() { ( cd "$MIRROR" && KEEPSET_ROOT="$MIRROR" bash scripts/lint-macos-keepset-paths.sh ) > "$ROOT/out" 2>&1; printf '%s' "$?"; }
out_has() { grep -cF -- "$1" "$ROOT/out" || true; }

# --- controls ----------------------------------------------------------------
rc=$(run_gate 0a,0b,0c,0d)
if [ "$rc" = "0" ]; then ok "대조군: 변이 없는 거울에서 test-gate.sh --sections 0a,0b,0c,0d 가 통과한다"; else bad "대조군: test-gate.sh 0a~0d" "rc=$rc $(tail -n 5 "$ROOT/out" | tr '\n' ' ')"; fi
rc=$(run_meta)
if [ "$rc" = "0" ]; then ok "대조군: 변이 없는 거울에서 메타 스위트가 통과한다"; else bad "대조군: 메타 스위트" "rc=$rc $(grep '^FAIL' "$ROOT/out" | awk 'NR<=5' | tr '\n' ' ')"; fi
rc=$(run_keepset)
if [ "$rc" = "0" ]; then ok "대조군: 변이 없는 거울에서 keepset 린트가 통과한다"; else bad "대조군: keepset 린트" "rc=$rc $(tail -n 5 "$ROOT/out" | tr '\n' ' ')"; fi

# --- 0a: an early-exiting reader on the right of a pipe ----------------------
# Any `scripts/test-*.sh` is scanned; the line goes at the end of one. The bar
# is passed as an argument so this file does not carry the shape it plants.
cp "$MIRROR/scripts/test-watch.sh" "$ROOT/watch.orig"
printf 'x=$(printf a %s head -n 1)\n' '|' >> "$MIRROR/scripts/test-watch.sh"
rc=$(run_gate 0a)
if [ "$rc" != "0" ] && [ "$(out_has 'pipefail 함정')" -ge 1 ]; then ok "0a: 파이프 오른쪽의 조기 종료 읽기를 0a 가 잡는다"; else bad "0a: 조기 종료 읽기" "rc=$rc"; fi
restore scripts/test-watch.sh

# --- 0b: a column-zero call above its own definition -------------------------
{ sed -n '1p' "$ROOT/watch.orig"; printf 'cc_bundle_probe\n'; sed '1d' "$ROOT/watch.orig"; printf 'cc_bundle_probe() { :; }\n'; } > "$MIRROR/scripts/test-watch.sh"
rc=$(run_gate 0b)
if [ "$rc" != "0" ] && [ "$(out_has 'cc_bundle_probe(호출')" -ge 1 ]; then ok "0b: 정의보다 먼저 부르는 맨 앞 칸 호출을 0b 가 잡는다"; else bad "0b: 정의 전 호출" "rc=$rc"; fi
restore scripts/test-watch.sh

# --- 0c: orphan-assertion rejection disabled ---------------------------------
if mut_replace scripts/test-gate.sh 'if [ -n "$sec_orp" ]; then' 'if false; then'; then
  rc=$(run_gate 0c)
  if [ "$rc" != "0" ]; then ok "0c: 고아 단언 거절을 끈 test-gate.sh 사본을 0c 가 잡는다"; else bad "0c: 고아 단언 거절 해제" "rc=0"; fi
fi
restore scripts/test-gate.sh

# --- 0d: empty --sections rejection disabled ---------------------------------
# The guard keeps its message and stops refusing; disabling it outright would
# make the section's own `--sections ''` call run the whole suite. Its `exit 2`
# is not unique in the file, so it is located as the line under the message.
emp_line=$(grep -nF -- '--sections 에 빈 값이 왔습니다' "$MIRROR/scripts/test-gate.sh" | sed -n '1s/:.*$//p')
if [ -n "$emp_line" ] && [ "$(sed -n "$((emp_line + 1))p" "$MIRROR/scripts/test-gate.sh")" = "  exit 2" ]; then
  awk -v n="$((emp_line + 1))" 'NR == n { print "  exit 0"; next } { print }' "$MIRROR/scripts/test-gate.sh" > "$ROOT/tg.mut"
  mv "$ROOT/tg.mut" "$MIRROR/scripts/test-gate.sh"
  rc=$(run_gate 0d)
  if [ "$rc" != "0" ]; then ok "0d: 빈 --sections 거절을 끈 test-gate.sh 사본을 0d 가 잡는다"; else bad "0d: 빈 선택 거절 해제" "rc=0"; fi
else
  bad "변이 준비" "test-gate.sh 의 빈 --sections 가드 바로 아래 줄이 「  exit 2」 가 아니다"
fi
restore scripts/test-gate.sh

# --- the meta suite's four classes, mutated together -------------------------
m_ok=1
mut_drop_line scripts/test-rekick.sh 'export CC_CMDS_AUTOPILOT_NOTIFY' || m_ok=0
mut_replace plugins/cc-cmds/hooks/question-form/kit.ts 'CC_PIPELINE_REENTRY' 'CC_PIPELINE_REMOVED_BY_TEST' || m_ok=0
printf '%s\n' '. "$(dirname "$0")/stray-for-test.sh"' >> "$MIRROR/plugins/cc-cmds/orchestrator/feed.sh"
mut_replace plugins/cc-cmds/skills/autopilot/references/router-lead-copy.md \
  'fetch and issue it once more, and only once' 'fetch and issue it again' || m_ok=0
if [ "$m_ok" = "1" ]; then
  rc=$(run_meta)
  if [ "$rc" != "0" ]; then ok "메타 스위트가 네 변이를 넣은 거울에서 0 아닌 값으로 끝난다"; else bad "메타 스위트 변이" "rc=0"; fi
  if [ "$(out_has 'FAIL: 알림 누출 — test-rekick.sh 가')" -ge 1 ]; then ok "알림 누출: 내보내기를 지운 test-rekick.sh 를 메타 스위트가 잡는다"; else bad "알림 누출 변이" "test-rekick.sh 의 FAIL 줄이 없다"; fi
  if [ "$(out_has 'FAIL: 표지 집합 ⊇ 라우터 집합 — hooks/question-form/kit.ts')" -ge 1 ]; then ok "표지 집합: CC_PIPELINE_REENTRY 를 지운 kit.ts 를 메타 스위트가 잡는다"; else bad "표지 집합 변이" "kit.ts 의 FAIL 줄이 없다"; fi
  if [ "$(out_has 'feed.sh 이 허용 목록')" -ge 1 ]; then ok "울타리: 허용 목록 밖을 소스하는 feed.sh 를 메타 스위트가 잡는다"; else bad "울타리 변이" "feed.sh 의 FAIL 줄이 없다"; fi
  if [ "$(out_has '「fetch and issue it once more, and only once」이 없다')" -ge 1 ]; then ok "리드 사본 절: 고정 문구를 지운 router-lead-copy.md 를 메타 스위트가 잡는다"; else bad "리드 사본 절 변이" "고정 문구의 FAIL 줄이 없다"; fi
fi
restore scripts/test-rekick.sh
restore plugins/cc-cmds/hooks/question-form/kit.ts
restore plugins/cc-cmds/orchestrator/feed.sh
restore plugins/cc-cmds/skills/autopilot/references/router-lead-copy.md

# --- keepset: one glob dropped from the darwin leg's filter ------------------
if mut_drop_line .github/workflows/notify-macos.yml "      - 'scripts/test-gate.sh'"; then
  rc=$(run_keepset)
  if [ "$rc" != "0" ]; then ok "keepset: paths 에서 글로브 하나를 지운 워크플로를 keepset 린트가 잡는다"; else bad "keepset 변이" "rc=0"; fi
  # --- the whole bundle on that mutant: the last component's failure surfaces
  ( cd "$MIRROR" && make check-cheap ) > "$ROOT/out" 2>&1; rc=$?
  if [ "$rc" != "0" ]; then ok "변이 하나를 넣은 거울에서 make check-cheap 이 0 아닌 값으로 끝난다"; else bad "make check-cheap 변이" "rc=0"; fi
fi
restore .github/workflows/notify-macos.yml

# --- the recipe: three components, nothing that swallows a failure -----------
dry=$(cd "$repo_root" && make -n check-cheap 2>&1)
for comp in 'bash scripts/test-gate.sh --sections 0a,0b,0c,0d' \
            'bash scripts/test-meta-invariants.sh' \
            'bash scripts/lint-macos-keepset-paths.sh'; do
  if [ "$(printf '%s\n' "$dry" | grep -cxF -- "$comp" || true)" -ge 1 ]; then ok "make -n check-cheap 이 「${comp}」 를 담는다"; else bad "check-cheap 부품" "「${comp}」 가 없다: $dry"; fi
done
if [ "$(printf '%s\n' "$dry" | grep -cE '\|\| *(true|:)' || true)" = "0" ]; then ok "make -n check-cheap 에 실패를 삼키는 || true 가 없다"; else bad "check-cheap 삼킴" "$dry"; fi
# `make -n` drops a `-` prefix from what it prints, so the recipe is read as
# written as well.
recipe=$(awk '/^check-cheap:/ { f = 1; next } f && /^\t/ { print; next } f { exit }' "$repo_root/Makefile")
if [ -n "$recipe" ] && [ "$(printf '%s\n' "$recipe" | grep -cE '^	[@+]*-' || true)" = "0" ]; then ok "check-cheap 레시피 줄에 실패를 무시하는 - 접두가 없다"; else bad "check-cheap - 접두" "「${recipe}」"; fi
if [ "$(grep -cE '^\.IGNORE' "$repo_root/Makefile" || true)" = "0" ]; then ok "Makefile 에 .IGNORE 가 없다"; else bad ".IGNORE" "Makefile 이 레시피 실패를 무시한다"; fi
check_line=$(grep -E '^check:' "$repo_root/Makefile" || true)
case "$check_line" in
  *check-cheap*) bad "check 타깃" "check 가 check-cheap 을 선행으로 둔다: $check_line" ;;
  *) ok "check-cheap 은 make check 에 들어가지 않는다" ;;
esac

# --- the push-side wiring ----------------------------------------------------
dry=$(cd "$repo_root" && make -n check-push 2>&1)
if [ "$(printf '%s\n' "$dry" | grep -cxF 'bash scripts/check-push.sh run' || true)" -ge 1 ]; then ok "make check-push 가 check-push.sh run 을 부른다"; else bad "check-push 타깃" "$dry"; fi
# The section and goal lists reach the script through the environment make
# exports a command-line variable into, never through the recipe line. The
# comparison is exact, so the inner make must not inherit the outer one's
# jobserver: under `make -j` it warns "jobserver unavailable" into the output.
for v in CHECK_PUSH_SECTIONS=x CHECK_PUSH_GOALS=x; do
  dry=$(cd "$repo_root" && MAKEFLAGS='' MFLAGS='' MAKELEVEL='' make -n check-push "$v" 2>&1)
  if [ "$dry" = "bash scripts/check-push.sh run" ]; then ok "make -n check-push $v 도 정확히 check-push.sh run 을 찍는다"; else bad "check-push 타깃 ($v)" "$dry"; fi
done
dry=$(cd "$repo_root" && make -n check-push-verify 2>&1)
if [ "$(printf '%s\n' "$dry" | grep -cxF 'bash scripts/check-push.sh verify' || true)" -ge 1 ]; then ok "make check-push-verify 가 check-push.sh verify 를 부른다"; else bad "check-push-verify 타깃" "$dry"; fi
# The prerequisites are read from make's own database rather than the file: a
# rule may name them through a variable (`test-rest: $(REST_GOALS)`), and the
# database prints the list with every variable expanded, on one line.
mkdb=$(cd "$repo_root" && make -pRrq : 2>/dev/null || true)
for t in test test-rest; do
  tline=$(printf '%s\n' "$mkdb" | awk -v t="$t:" 'index($0, t) == 1 { print; exit }')
  case "$tline" in
    *run-check-push-selftest*) ok "$t 가 check-push 자가 시험을 선행으로 둔다" ;;
    *) bad "$t 선행" "run-check-push-selftest 가 없다: $tline" ;;
  esac
  case "$tline" in
    *run-test-tree-selftest*) ok "$t 가 test-tree 자가 시험을 선행으로 둔다" ;;
    *) bad "$t 선행" "run-test-tree-selftest 가 없다: $tline" ;;
  esac
done

printf 'test-local-bundle: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
