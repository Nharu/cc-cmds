#!/usr/bin/env bash
# Which REST goals read the changed files, derived from the tested tree itself.
#
# scripts/check-push.sh runs the goals it was given and, besides them, every
# REST goal (`make -s print-rest-goals`) that reads a file the change touched.
# This script answers that second part statically, from the tree it is pointed
# at, so no table is kept and nothing depends on the host's history.
#
# WHAT A GOAL READS. A `run/<path>` goal's entry file is <path> (the shared
# wrappers scripts/test-slots.sh and scripts/suite-guard.sh are not entry
# files: their own self-test goals cover them). Any other goal's entry files
# are the tracked files `make -n --no-print-directory <goal>` names on its
# command lines. The scanned files are the entry files and, recursively, the
# tracked files a `.` or `source` line of a scanned file names; a script that
# is only run (`bash x.sh`) counts as a file read and is not followed. Every
# line of a scanned file, comments included, is cut into words at whitespace
# and at "'`$(){}[]<>|;&,=:*?!#~, a leading ./ or ../ is dropped, and bytes
# outside ASCII stay path characters. A word names the tracked files whose
# path equals, or ends in /, its longest suffix of whole components that names
# any: the whole word first, then without its first component, down to its
# last component alone. At a length where no file matches, a tracked directory
# that matches the same way names every tracked file under it. A one-component
# suffix counts only when exactly one tracked entry (file or directory) has
# that name, and when that entry is a directory only if the word ends in /:
# for a directory <d> no other tracked entry shares the name of, a bare <d>
# or $repo_root/<d> names nothing and <d>/ names every tracked file under
# it. A longer suffix counts
# however many paths it matches, a directory one whatever the word ends in. A goal
# reads its entry files, its scanned files and every file their words name.
# Deleted and renamed-away paths of the change count as tracked for the
# matching, so a reference the tree still holds to them is seen.
#
# Usage:
#   bash scripts/rest-readers.sh derive --tree <dir> --changed <file> [--make <make>]
#       <dir>    a git checkout (the tested tree); its Makefile lists the goals
#       <file>   the changed paths, one per line
#       <make>   the make to call (default make), with MAKEFLAGS, MFLAGS and
#                MAKELEVEL emptied
#     prints, in `print-rest-goals` order, `유도<TAB><goal>` for every goal that
#     reads a changed file, then `근거없음<TAB><path>` for every changed path no
#     goal reads, in the order given
#   bash scripts/rest-readers.sh --self-test
#
# Exit codes: 0 derived, 1 a computing step failed (standard error names it on
# a line `rest-readers: 유도 실패 — <step>`), 2 usage.

set -uo pipefail

RR_TREE=""
RR_MAKE="make"
RR_TMP=""

rr_usage() {
  printf 'rest-readers: 사용법 — derive --tree <dir> --changed <file> [--make <make>] / --self-test\n' >&2
  exit 2
}

rr_fail() {
  printf 'rest-readers: 유도 실패 — %s\n' "$1" >&2
  [ -z "$RR_TMP" ] || rm -rf "$RR_TMP"
  exit 1
}

rr_git() {
  (cd "$RR_TREE" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -c core.quotePath=false "$@" < /dev/null)
}

rr_make() {
  (cd "$RR_TREE" && export MAKEFLAGS='' MFLAGS='' MAKELEVEL='' && "$RR_MAKE" "$@" < /dev/null)
}

# The matcher. Inputs: the universe (tracked and changed paths), the changed
# paths, and the goal lines `<goal>\tE\t<entry path>` (a run/ goal) or
# `<goal>\tN\t<a make -n command line>`. Runs in the tree, so a scanned file
# is opened by its tracked path. Read with `read -d ''`, not inside $( ): bash
# 3.2 scans a here-document inside a command substitution for quotes.
RR_AWK=""
IFS= read -r -d '' RR_AWK <<'AWK'
BEGIN { FS = "\t" }
FILENAME == ARGV[1] { if ($0 != "") addpath($0); next }
FILENAME == ARGV[2] {
  if ($0 != "" && !($0 in changed)) { changed[$0] = 1; corder[++nc] = $0; addpath($0) }
  next
}
FILENAME == ARGV[3] {
  g = $1
  if (!(g in gseen)) { gseen[g] = 1; gorder[++ng] = g }
  if ($2 == "E") { if ($3 != "") gentry[g] = gentry[g] SUBSEP $3 }
  else if ($2 == "N") {
    n = words($3, w)
    for (i = 1; i <= n; i++) { t = strip(w[i]); if (t in isfile) gentry[g] = gentry[g] SUBSEP t }
  }
  next
}
function addpath(p,   c, n, i, j, s, d) {
  if (p in isfile) return
  isfile[p] = 1
  n = split(p, c, "/")
  s = c[n]; fsuf[s] = fsuf[s] SUBSEP p
  for (i = n - 1; i >= 1; i--) { s = c[i] "/" s; fsuf[s] = fsuf[s] SUBSEP p }
  if (!((c[n] SUBSEP "f" SUBSEP p) in named)) { named[c[n] SUBSEP "f" SUBSEP p] = 1; namecnt[c[n]]++ }
  d = ""
  for (j = 1; j < n; j++) {
    d = (j == 1) ? c[1] : d "/" c[j]
    if (!(d in isdir)) {
      isdir[d] = 1
      namecnt[c[j]]++
      s = c[j]; dsuf[s] = dsuf[s] SUBSEP d
      for (i = j - 1; i >= 1; i--) { s = c[i] "/" s; dsuf[s] = dsuf[s] SUBSEP d }
    }
  }
}
function words(line, w) {
  gsub(/[][ \t"'`$(){}<>|;&,=:*?!#~]+/, " ", line)
  sub(/^ +/, "", line); sub(/ +$/, "", line)
  if (line == "") return 0
  return split(line, w, " ")
}
function strip(t) {
  while (sub(/^\.\.?\//, "", t)) ;
  return t
}
# The keys a word names, each \035 followed by F<path> (a file) or D<dir> (a
# directory), concatenated; empty when the word names nothing.
function resolve(t,   raw, c, n, m, i, k, s, out, parts, np, q) {
  if (t in memo) return memo[t]
  n = split(strip(t), raw, "/")
  m = 0
  for (i = 1; i <= n; i++) if (raw[i] != "") c[++m] = raw[i]
  out = ""
  for (k = 1; k <= m; k++) {
    s = c[k]
    for (i = k + 1; i <= m; i++) s = s "/" c[i]
    if (k == m && namecnt[s] != 1) break
    if (k == m && !(s in fsuf) && t !~ /\/$/) break
    if (s in fsuf) {
      np = split(substr(fsuf[s], 2), parts, SUBSEP)
      for (q = 1; q <= np; q++) out = out "\035F" parts[q]
      break
    }
    if (s in dsuf) {
      np = split(substr(dsuf[s], 2), parts, SUBSEP)
      for (q = 1; q <= np; q++) out = out "\035D" parts[q]
      break
    }
  }
  memo[t] = out
  return out
}
# Reads file f once: reads[f] the keys its words name, srcs[f] the files its
# source lines name.
function scan(f,   line, rc, n, w, i, r, kk, nk, k, issrc) {
  if (f in scanned) return
  scanned[f] = 1
  reads[f] = ""
  srcs[f] = ""
  while ((rc = (getline line < f)) > 0) {
    issrc = (line ~ /(^|[ \t;&|(])(\.|source)[ \t]+[^ \t]/)
    n = words(line, w)
    for (i = 1; i <= n; i++) {
      r = resolve(w[i])
      if (r == "") continue
      nk = split(substr(r, 2), kk, "\035")
      for (k = 1; k <= nk; k++) {
        if (!((f SUBSEP kk[k]) in hasread)) { hasread[f SUBSEP kk[k]] = 1; reads[f] = reads[f] "\035" kk[k] }
        if (issrc && substr(kk[k], 1, 1) == "F") srcs[f] = srcs[f] "\035" substr(kk[k], 2)
      }
    }
  }
  close(f)
}
# 1 when key names a changed file, marking every changed file it names.
function hits(key,   p, np, parts, q, any) {
  p = substr(key, 2)
  if (substr(key, 1, 1) == "F") {
    if (p in changed) { covered[p] = 1; return 1 }
    return 0
  }
  if (!(p in cdir)) return 0
  np = split(substr(cdir[p], 2), parts, SUBSEP)
  for (q = 1; q <= np; q++) covered[parts[q]] = 1
  return 1
}
END {
  for (i = 1; i <= nc; i++) {
    n = split(corder[i], c, "/")
    d = ""
    for (j = 1; j < n; j++) { d = (j == 1) ? c[1] : d "/" c[j]; cdir[d] = cdir[d] SUBSEP corder[i] }
  }
  for (gi = 1; gi <= ng; gi++) {
    g = gorder[gi]
    split("", queue); split("", inq)
    qn = 0
    ne = split(substr(gentry[g], 2), ent, SUBSEP)
    for (i = 1; i <= ne; i++) if (!(ent[i] in inq)) { inq[ent[i]] = 1; queue[++qn] = ent[i] }
    derived = 0
    for (qi = 1; qi <= qn; qi++) {
      f = queue[qi]
      if (hits("F" f)) derived = 1
      scan(f)
      nk = split(substr(reads[f], 2), kk, "\035")
      for (k = 1; k <= nk; k++) if (hits(kk[k])) derived = 1
      ns = split(substr(srcs[f], 2), ss, "\035")
      for (k = 1; k <= ns; k++) if (!(ss[k] in inq)) { inq[ss[k]] = 1; queue[++qn] = ss[k] }
    }
    if (derived) printf "유도\t%s\n", g
  }
  for (i = 1; i <= nc; i++) if (!(corder[i] in covered)) printf "근거없음\t%s\n", corder[i]
}
AWK

rr_derive() {
  local changed="" goals g line
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tree) [ "$#" -ge 2 ] || rr_usage; RR_TREE="$2"; shift 2 ;;
      --changed) [ "$#" -ge 2 ] || rr_usage; changed="$2"; shift 2 ;;
      --make) [ "$#" -ge 2 ] || rr_usage; RR_MAKE="$2"; shift 2 ;;
      *) rr_usage ;;
    esac
  done
  [ -n "$RR_TREE" ] && [ -n "$changed" ] || rr_usage
  [ -d "$RR_TREE" ] || rr_fail "시험 트리 $RR_TREE 가 디렉터리가 아니다"
  [ -r "$changed" ] || rr_fail "변경 파일 목록 $changed 를 읽지 못했다"
  RR_TREE=$(cd "$RR_TREE" && pwd) || rr_fail "시험 트리 $RR_TREE"
  changed="$(cd "$(dirname "$changed")" && pwd)/$(basename "$changed")" || rr_fail "변경 파일 목록 $changed"
  RR_TMP=$(mktemp -d "${TMPDIR:-/tmp}/cc-rest-readers.XXXXXX") || { RR_TMP=""; rr_fail "임시 디렉터리"; }
  rr_git ls-files > "$RR_TMP/universe" || rr_fail "git ls-files"
  goals=$(rr_make -s --no-print-directory print-rest-goals) || rr_fail "make print-rest-goals"
  : > "$RR_TMP/goals"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    case "$g" in
      run/*) printf '%s\tE\t%s\n' "$g" "${g#run/}" >> "$RR_TMP/goals" ;;
      *)
        line=$(rr_make -n --no-print-directory "$g") || rr_fail "make -n $g"
        printf '%s\tN\t\n' "$g" >> "$RR_TMP/goals"
        printf '%s\n' "$line" | while IFS= read -r line; do
          [ -z "$line" ] || printf '%s\tN\t%s\n' "$g" "$(printf '%s' "$line" | tr '\t' ' ')"
        done >> "$RR_TMP/goals"
        ;;
    esac
  done <<EOF
$goals
EOF
  (cd "$RR_TREE" && LC_ALL=C awk "$RR_AWK" "$RR_TMP/universe" "$changed" "$RR_TMP/goals") > "$RR_TMP/out" || rr_fail "awk 대조"
  cat "$RR_TMP/out"
  rm -rf "$RR_TMP"
  RR_TMP=""
  return 0
}

# --- self-test ---------------------------------------------------------------

rr_self_test() {
  local passed=0 failed=0 T self R out rc
  ok()  { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
  bad() { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
  check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got「$2」 want「$3」"; fi; }
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE MAKEFLAGS MFLAGS MAKELEVEL
  T=$(mktemp -d "${TMPDIR:-/tmp}/rest-readers-selftest.XXXXXX") || return 1
  T=$(cd "$T" && pwd)
  mkdir -p "$T/tmp"
  TMPDIR="$T/tmp"
  export TMPDIR
  R="$T/repo"
  mkdir -p "$R/t" "$R/lib" "$R/fx/lib" "$R/pkg/deep" "$R/data/set" "$R/a" "$R/b" "$R/tools" "$R/notes" "$R/rules" "$R/solo" "$R/grp/sub"
  (
    cd "$R" || exit 1
    git init -q
    printf 'REST_GOALS := run/t/full.sh run/t/var.sh run/t/dir.sh run/t/bare.sh run/t/src.sh run/t/del.sh run-x-selftest\n' > Makefile
    printf 'print-rest-goals:\n\t@printf '"'"'%%s\\n'"'"' $(REST_GOALS)\n' >> Makefile
    printf 'run-x-selftest:\n\tbash tools/x.sh --self-test\n' >> Makefile
    printf '#!/usr/bin/env bash\nbash lib/target-full.sh "rules/사전-인가.sh"\n' > t/full.sh
    printf '#!/usr/bin/env bash\nf="$repo_root/pkg/deep/v.sh"\ng="$repo_root/solo"\n' > t/var.sh
    printf '#!/usr/bin/env bash\nfor f in data/set/*; do :; done\nls solo/ grp/sub\n' > t/dir.sh
    printf '#!/usr/bin/env bash\n# uses uniq.sh and dup.sh, then solo\n' > t/bare.sh
    printf '#!/usr/bin/env bash\n. "$here/t/helper.sh"\nbash t/runner.sh\n' > t/src.sh
    printf '# helper reads lib/via-source.txt\n' > t/helper.sh
    printf '# runner reads lib/via-exec.txt\n' > t/runner.sh
    printf '#!/usr/bin/env bash\ncat lib/gone.sh lib/old-name.sh\n' > t/del.sh
    printf 'x\n' > lib/target-full.sh
    printf 'x\n' > fx/lib/target-full.sh
    printf 'x\n' > pkg/deep/v.sh
    printf 'x\n' > data/set/one.txt
    printf 'x\n' > data/set/two.txt
    printf 'x\n' > lib/uniq.sh
    printf 'x\n' > a/dup.sh
    printf 'x\n' > b/dup.sh
    printf 'x\n' > lib/via-source.txt
    printf 'x\n' > lib/via-exec.txt
    printf 'x\n' > lib/new-name.sh
    printf 'x\n' > notes/readme.txt
    printf 'x\n' > rules/사전-인가.sh
    printf '# reads lib/x-data.txt\n' > tools/x.sh
    printf 'x\n' > lib/x-data.txt
    printf 'x\n' > solo/inner.txt
    printf 'x\n' > grp/sub/k.txt
    git add -A && git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m A
  ) > /dev/null 2>&1 || { bad "픽스처 준비" "git 실패"; rm -rf "$T"; return 1; }

  derive() {  # <changed paths...>
    printf '%s\n' "$@" > "$T/changed"
    bash "$self" derive --tree "$R" --changed "$T/changed" 2>&1
  }
  goals_of() { printf '%s\n' "$1" | sed -n 's/^유도	//p' | tr '\n' ' '; }
  none_of() { printf '%s\n' "$1" | sed -n 's/^근거없음	//p' | tr '\n' ' '; }

  out=$(derive lib/target-full.sh); rc=$?
  check "전체 경로 참조는 그 파일을 읽는 목표를 유도한다" "$rc $(goals_of "$out")" "0 run/t/full.sh "
  out=$(derive fx/lib/target-full.sh)
  check "두 구성 요소 이상의 접미는 같은 꼬리의 다른 사본도 가리킨다" "$(goals_of "$out")" "run/t/full.sh "
  out=$(derive 'rules/사전-인가.sh')
  check "비 ASCII 이름은 경로 문자로 둔다" "$(goals_of "$out")" "run/t/full.sh "
  out=$(derive pkg/deep/v.sh)
  check "변수 접두가 붙은 경로도 접미로 맞춘다" "$(goals_of "$out")" "run/t/var.sh "
  out=$(derive data/set/two.txt)
  check "디렉터리 참조는 그 아래 파일 전부를 덮는다" "$(goals_of "$out")" "run/t/dir.sh "
  out=$(derive solo/inner.txt)
  check "유일한 디렉터리 이름과 같은 맨 낱말은 펼치지 않고 / 를 붙인 낱말은 펼친다" "$(goals_of "$out")" "run/t/dir.sh "
  out=$(derive grp/sub/k.txt)
  check "두 구성 요소 이상의 디렉터리 접미는 / 없이도 센다" "$(goals_of "$out")" "run/t/dir.sh "
  out=$(derive lib/uniq.sh)
  check "유일한 맨 이름은 그 파일을 가리킨다" "$(goals_of "$out")" "run/t/bare.sh "
  out=$(derive a/dup.sh)
  check "모호한 맨 이름은 아무것도 가리키지 않는다" "$(goals_of "$out")|$(none_of "$out")" "|a/dup.sh "
  out=$(derive lib/via-source.txt)
  check "source 한 파일이 이름 댄 파일까지 읽는다" "$(goals_of "$out")" "run/t/src.sh "
  out=$(derive t/helper.sh)
  check "source 한 파일 자체도 읽는 파일이다" "$(goals_of "$out")" "run/t/src.sh "
  out=$(derive lib/via-exec.txt)
  check "실행만 하는 스크립트는 따라 들어가지 않는다" "$(goals_of "$out")|$(none_of "$out")" "|lib/via-exec.txt "
  out=$(derive t/runner.sh)
  check "실행하는 스크립트의 경로는 읽는 파일이다" "$(goals_of "$out")" "run/t/src.sh "
  out=$(derive lib/gone.sh)
  check "트리에 없는 지운 파일도 남은 참조가 가리키면 유도한다" "$(goals_of "$out")" "run/t/del.sh "
  out=$(derive lib/old-name.sh lib/new-name.sh)
  check "이름 바꾸기의 옛 경로는 유도하고 참조 없는 새 경로는 근거 없음" "$(goals_of "$out")|$(none_of "$out")" "run/t/del.sh |lib/new-name.sh "
  out=$(derive notes/readme.txt)
  check "참조 없는 파일은 근거 없음" "$(goals_of "$out")|$(none_of "$out")" "|notes/readme.txt "
  out=$(derive tools/x.sh)
  check "self-test 목표의 진입 파일은 make -n 이 이름 댄 파일이다" "$(goals_of "$out")" "run-x-selftest "
  out=$(derive lib/x-data.txt)
  check "self-test 목표의 진입 파일이 이름 댄 파일도 읽는다" "$(goals_of "$out")" "run-x-selftest "
  out=$(derive lib/x-data.txt lib/uniq.sh lib/target-full.sh notes/readme.txt)
  check "유도는 print-rest-goals 순서, 근거 없음은 준 순서" "$(printf '%s\n' "$out" | cut -f1,2 | tr '\t\n' ': ')" "유도:run/t/full.sh 유도:run/t/bare.sh 유도:run-x-selftest 근거없음:notes/readme.txt "
  out=$(derive)
  check "변경이 없으면 아무것도 찍지 않는다" "$out" ""

  printf '#!/usr/bin/env bash\nexit 1\n' > "$T/make-bad"
  chmod +x "$T/make-bad"
  printf 'lib/uniq.sh\n' > "$T/changed"
  out=$(bash "$self" derive --tree "$R" --changed "$T/changed" --make "$T/make-bad" 2>&1); rc=$?
  check "make 단계가 실패하면 1 과 그 단계" "$rc|$out" "1|rest-readers: 유도 실패 — make print-rest-goals"
  printf '#!/usr/bin/env bash\ncase "$1" in -n) exit 1 ;; *) exec make "$@" ;; esac\n' > "$T/make-n-bad"
  chmod +x "$T/make-n-bad"
  out=$(bash "$self" derive --tree "$R" --changed "$T/changed" --make "$T/make-n-bad" 2>&1); rc=$?
  check "make -n 이 실패하면 1 과 그 목표" "$rc|$out" "1|rest-readers: 유도 실패 — make -n run-x-selftest"
  mkdir -p "$T/nogit"
  out=$(cd "$T" && GIT_CEILING_DIRECTORIES="$T" bash "$self" derive --tree "$T/nogit" --changed "$T/changed" 2>&1); rc=$?
  check "git 저장소가 아니면 1 과 git 단계" "$rc|$(printf '%s\n' "$out" | tail -n 1)" "1|rest-readers: 유도 실패 — git ls-files"
  out=$(bash "$self" derive --tree "$R" 2>&1); rc=$?
  check "인자가 모자라면 2" "$rc" "2"

  out=$(find "$T/tmp" -maxdepth 1 -name 'cc-rest-readers.*' | wc -l | tr -d ' ')
  check "임시 디렉터리를 남기지 않는다" "$out" "0"

  rm -rf "$T"
  printf 'rest-readers self-test: %d passed, %d failed\n' "$passed" "$failed"
  if [ "$passed" -lt 25 ]; then
    printf 'rest-readers self-test: 통과 수 %d 가 하한 25 에 못 미칩니다\n' "$passed" >&2
    return 1
  fi
  [ "$failed" = "0" ]
}

# --- main --------------------------------------------------------------------

case "${1:-}" in
  derive) shift; rr_derive "$@" ;;
  --self-test) [ "$#" -eq 1 ] || rr_usage; rr_self_test ;;
  *) rr_usage ;;
esac
