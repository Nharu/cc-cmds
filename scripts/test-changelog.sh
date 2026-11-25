#!/usr/bin/env bash
# Test scripts/changelog.sh — new, check and assemble — in throwaway git
# repositories made under mktemp -d. The repository's own changelog.d/ is never
# read.
#
# check: at least one case per row of its verdict table (the script's header),
# an old-style PR whose base tip was bumped by a bot release after the merge
# base (pass), a fragment whose name only starts with the slug (fail), and the
# three cases of the broken-fragment exception — a malformed fragment of
# another branch removed (pass), rewritten into a correct format (pass), and a
# well-formed fragment of another branch rewritten (fail).
#
# new: refused on master and on a slug holding `--`, a second fragment needs
# --suffix, and the template it writes passes the format check.
#
# assemble: no fragment (exit 3, nothing written), one fragment (its body as it
# is), several fragments (lead paragraphs joined, subsections in their fixed
# order, first-parent order with one merge adding two fragments ordered by
# name, and a re-added path ordered by its newest add), the patch, minor and
# major raises, a malformed fragment and an existing archive directory (exit 1,
# nothing written), stdout holding the version alone, and plugin.json changed
# on its version line only. CHANGELOG_DATE pins the date, so no clock is read.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
CL="$script_dir/changelog.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/test-changelog.XXXXXX")
trap 'rm -rf "$work"' EXIT

passed=0
failures=0
pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }
check() {
  # check <name> <actual> <expected>
  if [ "$2" = "$3" ]; then pass "$1"; else
    fail "$1"; printf '  기대: %s\n  실제: %s\n' "$3" "$2" >&2
  fi
}

: > "$work/gitconfig"
export GIT_CONFIG_GLOBAL="$work/gitconfig" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export CHANGELOG_DATE=2026-01-02

PJ=plugins/cc-cmds/.claude-plugin/plugin.json

# new_repo <dir> — master with a CHANGELOG at 1.0.0, plugin.json at 1.0.0, a
# plugin file and a README.
new_repo() {
  mkdir -p "$1"
  (
    cd "$1" || exit 1
    git init -q -b master
    mkdir -p plugins/cc-cmds/.claude-plugin
    printf '# Changelog\n\nAll notable changes.\n\n## [1.0.0] - 2026-01-01\n\n처음.\n\n### Added\n\n- 처음\n' > CHANGELOG.md
    printf '{\n  "name": "cc-cmds",\n  "version": "1.0.0",\n  "author": {\n    "name": "x"\n  }\n}\n' > "$PJ"
    printf 'a\n' > plugins/cc-cmds/a.txt
    printf 'readme\n' > README.md
    git add -A && git commit -q -m init
  )
}

# frag <file> <grade> <lead> [<section> <body>]… — a well-formed fragment.
frag() {
  local f="$1" g="$2" lead="$3"
  shift 3
  mkdir -p "$(dirname "$f")"
  {
    printf '등급: %s\n\n%s\n' "$g" "$lead"
    while [ "$#" -ge 2 ]; do printf '\n### %s\n\n%s\n' "$1" "$2"; shift 2; done
  } > "$f"
}

commit_all() { git add -A && git commit -q -m "$1"; }

# legacy_bump <version> — the old style: a new head entry and a version bump.
legacy_bump() {
  awk -v v="$1" '!d && /^## \[/ { print "## [" v "] - 2026-01-02\n\n옛 방식.\n"; d = 1 } { print }' CHANGELOG.md > CHANGELOG.md.new
  mv CHANGELOG.md.new CHANGELOG.md
  set_version "$1"
}
set_version() {
  sed "s/\"version\": \"[^\"]*\"/\"version\": \"$1\"/" "$PJ" > "$PJ.new" && mv "$PJ.new" "$PJ"
}

# run_check <repo> <branch> — "<rc>|<output>" of check on master...<branch>.
run_check() {
  local out rc
  out=$(cd "$1" && bash "$CL" check --base master --head "$2" --branch "$2" 2>&1); rc=$?
  printf '%s|%s' "$rc" "$out"
}
rc_of() { printf '%s' "${1%%|*}"; }
has() { case "$1" in *"$2"*) printf yes ;; *) printf no ;; esac; }

# ===========================================================================
# check
# ===========================================================================
R="$work/check"
new_repo "$R"
cd "$R" || exit 1
# A malformed fragment and a well-formed fragment of other branches on master.
printf '등급: huge\n\n깨짐\n' > changelog.d.tmp
mkdir -p changelog.d && mv changelog.d.tmp changelog.d/old-broken.md
frag changelog.d/old-good.md patch '남의 조각' Fixed '- x'
commit_all 'base fragments'

# branch <name> — a new branch from master, checked out.
branch() { git checkout -q master && git checkout -q -b "$1"; }

# Row 1: fragments mixed with the old style.
branch feat/mix
frag changelog.d/feat-mix.md minor '섞음' Added '- y'
printf 'b\n' >> plugins/cc-cmds/a.txt; legacy_bump 1.1.0; commit_all mix
r=$(run_check "$R" feat/mix)
check "1행: 조각과 CHANGELOG·version 을 함께 바꾸면 실패" "$(rc_of "$r")/$(has "$r" '섞었다')" "1/yes"
branch feat/mixver
frag changelog.d/feat-mixver.md minor '섞음' Added '- y'
printf 'b\n' >> plugins/cc-cmds/a.txt; set_version 1.1.0; commit_all mixver
r=$(run_check "$R" feat/mixver)
check "1행: 조각과 version 줄만 바꿔도 실패" "$(rc_of "$r")/$(has "$r" '섞었다')" "1/yes"

# Row 2: names.
branch fix/a
frag changelog.d/fix-a-b.md patch '접두' Fixed '- y'
printf 'b\n' >> plugins/cc-cmds/a.txt; commit_all prefix
r=$(run_check "$R" fix/a)
check "2행: 슬러그로 시작만 하는 이름(fix/a 의 fix-a-b.md)은 실패" "$(rc_of "$r")/$(has "$r" '두 꼴')" "1/yes"
branch a--b
frag changelog.d/a--b.md patch '대시' Fixed '- y'
printf 'b\n' >> plugins/cc-cmds/a.txt; commit_all dashes
r=$(run_check "$R" a--b)
check "2행: 슬러그에 -- 가 든 브랜치의 조각은 실패" "$(rc_of "$r")/$(has "$r" '-- 가 들어 있어')" "1/yes"
branch feat/two
frag changelog.d/feat-two.md patch '하나' Fixed '- y'
frag changelog.d/feat-two--more.md minor '둘' Added '- z'
printf 'b\n' >> plugins/cc-cmds/a.txt; commit_all two
r=$(run_check "$R" feat/two)
check "5행: 두 꼴(슬러그.md, 슬러그--덧붙임.md)의 조각과 플러그인 변경은 통과" "$(rc_of "$r")" "0"

# Row 3: format.
branch feat/fmt
printf '등급: huge\n\n리드\n\n## [9.9.9]\n\n### Misc\n' > changelog.d/feat-fmt.md
printf 'b\n' >> plugins/cc-cmds/a.txt; commit_all fmt
r=$(run_check "$R" feat/fmt)
check "3행: 형식이 틀린 조각은 실패 — 등급 줄·## 머리·쓸 수 없는 소절을 각각 적는다" \
  "$(rc_of "$r")/$(has "$r" '첫 줄이')/$(has "$r" '머리는 쓰지 않는다')/$(has "$r" '쓸 수 없는 소절')" "1/yes/yes/yes"

# Row 4: paths the PR did not add.
branch feat/touch
frag changelog.d/feat-touch.md patch '내 조각' Fixed '- y'
printf -- '- 더함\n' >> changelog.d/old-good.md
printf 'b\n' >> plugins/cc-cmds/a.txt; commit_all touch
r=$(run_check "$R" feat/touch)
check "4행: 형식이 맞는 남의 조각을 고치면 실패" "$(rc_of "$r")/$(has "$r" 'M changelog.d/old-good.md')" "1/yes"
branch feat/archive
mkdir -p changelog.d/archive/1.0.0 && printf 'x\n' > changelog.d/archive/1.0.0/x.md
commit_all archive
r=$(run_check "$R" feat/archive)
check "4행: 보관 디렉터리 아래를 더하면 실패" "$(rc_of "$r")/$(has "$r" 'changelog.d/archive/1.0.0/x.md')" "1/yes"
branch feat/move
git mv changelog.d/old-good.md changelog.d/feat-move.md; commit_all move
r=$(run_check "$R" feat/move)
check "4행: 형식이 맞는 남의 조각을 옮기면 실패" "$(rc_of "$r")/$(has "$r" 'D changelog.d/old-good.md')" "1/yes"

# Row 4's exception: a fragment already malformed at the merge base.
branch fix/rm-broken
git rm -q changelog.d/old-broken.md; commit_all rm
r=$(run_check "$R" fix/rm-broken)
check "깨진 조각의 복구: 병합 기준점에서 형식이 틀린 남의 조각을 지우면 통과" "$(rc_of "$r")" "0"
branch fix/fix-broken
frag changelog.d/old-broken.md patch '고침' Fixed '- 고침'; commit_all fixbroken
r=$(run_check "$R" fix/fix-broken)
check "깨진 조각의 복구: 그 조각을 맞는 형식으로 고치면 통과" "$(rc_of "$r")" "0"
branch fix/still-broken
printf '등급: still\n\n여전히\n' > changelog.d/old-broken.md; commit_all stillbroken
r=$(run_check "$R" fix/still-broken)
check "깨진 조각의 복구: 고친 뒤에도 형식이 틀리면 실패" "$(rc_of "$r")/$(has "$r" '고친 깨진 조각')" "1/yes"
branch fix/edit-good
printf -- '- 고침\n' >> changelog.d/old-good.md; commit_all editgood
r=$(run_check "$R" fix/edit-good)
check "깨진 조각의 복구: 형식이 맞는 남의 조각을 고치면 실패" "$(rc_of "$r")" "1"

# Rows 5–8.
branch feat/frag
frag changelog.d/feat-frag.md minor '조각 방식' Added '- y'
printf 'b\n' >> plugins/cc-cmds/a.txt; commit_all frag
r=$(run_check "$R" feat/frag)
check "5행: 플러그인 변경과 조각은 통과" "$(rc_of "$r")" "0"
branch feat/legacy
printf 'b\n' >> plugins/cc-cmds/a.txt; legacy_bump 1.1.0; commit_all legacy
r=$(run_check "$R" feat/legacy)
check "6행: 조각 없이 기존 방식 릴리스 메타면 통과(과도기)" "$(rc_of "$r")/$(has "$r" '과도기')" "0/yes"
# The base tip moves past the merge base by a bot release; the old-style
# branch is still judged against the merge base.
git checkout -q master
legacy_bump 1.0.1; commit_all 'chore(release): v1.0.1'
r=$(run_check "$R" feat/legacy)
check "6행: 병합 기준점 뒤 베이스 끝의 version 이 봇 릴리스로 올라도 기존 방식 PR 은 통과" "$(rc_of "$r")" "0"
branch feat/nofrag
printf 'b\n' >> plugins/cc-cmds/a.txt; commit_all nofrag
r=$(run_check "$R" feat/nofrag)
check "7행: 플러그인 변경에 조각도 기존 방식도 없으면 실패" "$(rc_of "$r")/$(has "$r" '조각(')" "1/yes"
branch feat/logonly
printf 'b\n' >> plugins/cc-cmds/a.txt
awk '!d && /^## \[/ { print "## [1.9.0] - 2026-01-02\n\n로그만.\n"; d = 1 } { print }' CHANGELOG.md > c.new && mv c.new CHANGELOG.md
commit_all logonly
r=$(run_check "$R" feat/logonly)
check "7행: 두 릴리스 파일 중 CHANGELOG 만 바꾸면 실패" "$(rc_of "$r")" "1"
branch feat/verdown
printf 'b\n' >> plugins/cc-cmds/a.txt; legacy_bump 0.9.0; commit_all verdown
r=$(run_check "$R" feat/verdown)
check "7행: version 이 내려가면 기존 방식이 아니어서 실패" "$(rc_of "$r")" "1"
branch docs/only
printf 'more\n' >> README.md; commit_all docs
r=$(run_check "$R" docs/only)
check "8행: 플러그인 경로를 바꾸지 않으면 조각 없이 통과" "$(rc_of "$r")" "0"
cd "$work" || exit 1

# ===========================================================================
# new
# ===========================================================================
N="$work/new"
new_repo "$N"
cd "$N" || exit 1
out=$(bash "$CL" new minor 2>&1); rc=$?
check "new: master 위에서는 거부한다" "$rc/$(has "$out" 'master 위에서는')" "1/yes"
git checkout -q -b a--b
out=$(bash "$CL" new patch 2>&1); rc=$?
check "new: 슬러그에 -- 가 든 브랜치는 거부한다" "$rc/$(has "$out" '-- 가 들어 있어')" "1/yes"
git checkout -q master && git checkout -q -b feat/y
out=$(bash "$CL" new minor); rc=$?
check "new: 브랜치 슬러그 이름의 조각 경로를 찍는다" "$rc/$out" "0/changelog.d/feat-y.md"
check "new: 틀의 첫 줄은 등급 줄이다" "$(sed -n '1p' changelog.d/feat-y.md)" "등급: minor"
out=$(bash "$CL" new patch 2>&1); rc=$?
check "new: 같은 이름이 있으면 --suffix 를 요구한다" "$rc/$(has "$out" '--suffix')" "1/yes"
out=$(bash "$CL" new patch --suffix more); rc=$?
check "new: --suffix 로 둘째 조각을 만든다" "$rc/$out" "0/changelog.d/feat-y--more.md"
printf 'b\n' >> plugins/cc-cmds/a.txt; commit_all newfrag
r=$(run_check "$N" feat/y)
check "new: 만든 틀 두 개는 check 를 통과한다" "$(rc_of "$r")" "0"
cd "$work" || exit 1

# ===========================================================================
# assemble
# ===========================================================================
# head_section — CHANGELOG.md from the first `## [` heading up to the next.
head_section() { awk '/^## \[/ { n++ } n == 1 { print }' CHANGELOG.md; }

A="$work/asm"
new_repo "$A"
cd "$A" || exit 1
out=$(bash "$CL" assemble 2>/dev/null); rc=$?
check "assemble: 조각이 없으면 3 이고 아무것도 쓰지 않는다" "$rc/$out/$(git status --porcelain | wc -l | tr -d ' ')" "3//0"

# One fragment: its body as it is, a patch raise.
frag changelog.d/zz.md patch 'ZZ 첫 리드' Fixed '- zz 고침'
commit_all 'add zz'
out=$(bash "$CL" assemble); rc=$?
check "assemble: patch 조각 하나 → Z+1, 표준 출력은 버전 한 줄" "$rc/$out" "0/1.0.1"
check "assemble: 조각 하나는 본문 그대로 버전 머리 아래에 들어간다" "$(head_section)" \
  "$(printf '## [1.0.1] - 2026-01-02\n\nZZ 첫 리드\n\n### Fixed\n\n- zz 고침\n')"
check "assemble: 머리말 뒤, 옛 첫 버전 머리 앞에 넣는다" \
  "$(grep -n '^## \[' CHANGELOG.md | cut -d: -f1 | tr '\n' ' ')/$(sed -n '3p' CHANGELOG.md)" "5 13 /All notable changes."
check "assemble: plugin.json 은 version 줄만 바뀐다" \
  "$(git diff -U0 -- "$PJ" | grep -E '^[-+] ' | tr '\n' '|')" '-  "version": "1.0.0",|+  "version": "1.0.1",|'
check "assemble: 조각은 git mv 로 보관 디렉터리에 옮겨진다" \
  "$(git status --porcelain -- changelog.d | tr '\n' '|')" 'R  changelog.d/zz.md -> changelog.d/archive/1.0.1/zz.md|'
commit_all 'chore(release): v1.0.1'

# Several fragments: mm on master, then a merge adding bb and aa, then zz
# added again on master.
frag changelog.d/mm.md patch 'MM 리드' Fixed '- mm 고침'
commit_all 'add mm'
git checkout -q -b side
frag changelog.d/bb.md patch 'BB 리드' Fixed '- bb 고침'
frag changelog.d/aa.md minor 'AA 리드' Why 'aa 이유' Added '- aa 더함'
commit_all 'add aa bb'
git checkout -q master
git merge -q --no-ff -m 'merge side' side
frag changelog.d/zz.md patch 'ZZ 다시 리드' Changed '- zz 바꿈'
commit_all 'add zz again'
out=$(bash "$CL" assemble); rc=$?
check "assemble: 가장 높은 등급(minor)으로 Y+1·Z=0" "$rc/$out" "0/1.1.0"
check "assemble: 여러 조각 — 리드는 first-parent 순서로 잇고(한 머지의 둘은 이름 순, 다시 더한 경로는 가장 나중 추가), 소절은 정한 순서로 하나씩" \
  "$(head_section)" \
  "$(printf '## [1.1.0] - 2026-01-02\n\nMM 리드\n\nAA 리드\n\nBB 리드\n\nZZ 다시 리드\n\n### Added\n\n- aa 더함\n\n### Changed\n\n- zz 바꿈\n\n### Fixed\n\n- mm 고침\n\n- bb 고침\n\n### Why\n\naa 이유\n')"
check "assemble: 다음 버전 머리는 앞 릴리스 절이다" "$(grep '^## \[' CHANGELOG.md | sed -n '2p')" "## [1.0.1] - 2026-01-02"
check "assemble: 최상위 조각이 남지 않는다" "$(find changelog.d -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')/$(find changelog.d/archive/1.1.0 -name '*.md' | wc -l | tr -d ' ')" "0/4"
commit_all 'chore(release): v1.1.0'

# Major.
frag changelog.d/big.md major '큰 변경' Removed '- 뺌'
commit_all 'add big'
out=$(bash "$CL" assemble); rc=$?
check "assemble: major 조각 → X+1·Y=0·Z=0" "$rc/$out/$(jq -r .version "$PJ")" "0/2.0.0/2.0.0"
commit_all 'chore(release): v2.0.0'

# Malformed fragment: nothing written.
frag changelog.d/ok.md patch '맞음' Fixed '- 맞음'
printf '등급: patch\n리드가 붙음\n' > changelog.d/bad.md
commit_all 'add bad'
out=$(bash "$CL" assemble 2>"$work/err"); rc=$?
check "assemble: 형식이 틀린 조각이 하나라도 있으면 1 이고 아무것도 쓰지 않는다" \
  "$rc/$out/$(git status --porcelain | wc -l | tr -d ' ')/$(has "$(cat "$work/err")" 'changelog.d/bad.md')" "1//0/yes"
git rm -q changelog.d/bad.md; commit_all 'rm bad'

# Existing archive directory for the new version: nothing written.
mkdir -p changelog.d/archive/2.0.1 && printf 'x\n' > changelog.d/archive/2.0.1/x.md
commit_all 'archive collision'
out=$(bash "$CL" assemble 2>"$work/err"); rc=$?
check "assemble: 새 버전의 보관 디렉터리가 이미 있으면 1 이고 아무것도 쓰지 않는다" \
  "$rc/$out/$(git status --porcelain | wc -l | tr -d ' ')/$(has "$(cat "$work/err")" 'archive/2.0.1')" "1//0/yes"
cd "$work" || exit 1

echo "test-changelog: ${passed} passed, ${failures} failed"
[ "$failures" -eq 0 ]
