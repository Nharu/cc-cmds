#!/usr/bin/env bash
# Release-note fragments: one file per branch instead of a hand-edited
# CHANGELOG.md head entry and plugin.json version bump.
#
#   bash scripts/changelog.sh new <patch|minor|major> [--suffix <덧붙임>]
#   bash scripts/changelog.sh check --base <sha> --head <sha> --branch <name>
#   bash scripts/changelog.sh assemble
#
# A fragment is `changelog.d/<slug>.md` or `changelog.d/<slug>--<덧붙임>.md`,
# where <slug> is the branch name with every `/` turned into `-`. Its first line
# is `등급: patch`, `등급: minor` or `등급: major`, then an empty line, then a
# Korean lead paragraph, then only the subsections `### Added`, `### Changed`,
# `### Fixed`, `### Removed`, `### Why` and `### Post-install notes`, each at
# most once. A `# ` or `## ` heading is never written: the version heading is
# the assembler's.
#
# new — writes a fragment template for the current branch and prints its path.
#   Refused on master, on a detached HEAD, and when the slug holds `--` (it
#   would collide with the suffix separator). When `<slug>.md` already exists a
#   second fragment needs `--suffix`.
#
# check — judges a pull request from `git diff --no-renames --name-status
#   <merge base> <head>`. A "fragment" is a top-level `changelog.d/*.md` with
#   status A. The "old style" is a release bump written by hand: the head's
#   first `## [X.Y.Z]` heading of CHANGELOG.md is one the merge base does not
#   have, and plugin.json's "version" is greater than the merge base's. Both
#   comparisons read the merge base, never the base tip, so a base the release
#   workflow bumped after the branch point does not turn an old-style PR into a
#   failure. The first matching row is the verdict:
#     1. fragments and a changed CHANGELOG.md or plugin.json version — fail
#     2. a fragment whose name is not one of the slug's two forms, or a slug
#        holding `--` — fail
#     3. a fragment whose format is wrong — fail
#     4. a changelog.d/ path the PR did not add is changed, removed or moved,
#        or anything is added outside the top-level fragments — fail. The one
#        exception: a top-level fragment that was already malformed at the
#        merge base may be removed, or rewritten into a correct format, so a
#        broken fragment that stops every release is fixed by one PR.
#     5. plugins/cc-cmds/ changed and there are fragments — pass
#     6. plugins/cc-cmds/ changed, no fragment, old style — pass (transition)
#     7. plugins/cc-cmds/ changed, no fragment, not old style — fail
#     8. plugins/cc-cmds/ unchanged — pass
#   Every violated row among 1–4 prints its own reason line. Exit 0 pass,
#   1 fail.
#
# assemble — run on master by the release workflow. Checks every top-level
#   fragment (one malformed fragment: nothing written, exit 1), raises
#   plugin.json's version by the highest grade among them, writes one version
#   section right after CHANGELOG.md's preamble (everything before the first
#   `## [` heading), rewrites the "version" line of plugin.json and nothing
#   else in it, `git mv`s the fragments into `changelog.d/archive/<X.Y.Z>/`,
#   and prints `X.Y.Z` alone on standard output. The version raised is
#   plugin.json's; CHANGELOG.md's head entry is not compared with it. An
#   existing archive directory for the new version: nothing written, exit 1.
#   No fragment: nothing written, exit 3.
#
#   One fragment: its body goes under the version heading as it is. Several:
#   the lead paragraphs follow one another as separate paragraphs, and each
#   subsection appears once, in the order above, holding every fragment's
#   content for it. Fragments are ordered by the first-parent commit of master
#   that added them (`git log --first-parent --diff-filter=A master -- <file>`,
#   its newest such commit when a path was added more than once), older first,
#   then by file name; no commit time is read. The date is `CHANGELOG_DATE`
#   (YYYY-MM-DD) when set, else today in Asia/Seoul.
#
# Exit 2 on a usage error or a repository that cannot be read.

set -euo pipefail

CL_DIR=changelog.d
CL_LOG=CHANGELOG.md
CL_PLUGIN=plugins/cc-cmds/.claude-plugin/plugin.json
CL_BASE_BRANCH=master

die() { printf 'changelog: %s\n' "$1" >&2; exit "${2:-2}"; }

usage() {
  printf 'changelog: 사용법 — new <patch|minor|major> [--suffix <덧붙임>] | check --base <sha> --head <sha> --branch <이름> | assemble\n' >&2
  exit 2
}

slug_of() { printf '%s' "$1" | tr '/' '-'; }

# top_md <path under changelog.d/> — rc 0 for a top-level `*.md` name.
top_md() {
  case "$1" in
    */*) return 1 ;;
    ?*.md) return 0 ;;
    *) return 1 ;;
  esac
}

# frag_problems <label> <file> — one line per format problem, nothing when the
# fragment is well formed.
frag_problems() {
  LC_ALL=C awk -v label="$1" '
    function bad(m) { print label ": " m }
    NR == 1 { if ($0 !~ /^등급: (patch|minor|major)$/) bad("첫 줄이 「등급: patch|minor|major」 가 아니다"); next }
    NR == 2 { if ($0 != "") bad("둘째 줄이 빈 줄이 아니다"); next }
    NR == 3 { if ($0 == "" || $0 ~ /^#/) bad("셋째 줄에 리드 문단이 없다") }
    /^##?[ \t]/ || /^##?$/ { bad(NR "행: # · ## 머리는 쓰지 않는다 — 버전 머리는 조립이 단다"); next }
    /^###[ \t]/ {
      h = $0; sub(/^###[ \t]+/, "", h); sub(/[ \t]+$/, "", h)
      if (h != "Added" && h != "Changed" && h != "Fixed" && h != "Removed" && h != "Why" && h != "Post-install notes")
        bad(NR "행: 쓸 수 없는 소절 「" h "」")
      else if (seen[h]++)
        bad(NR "행: 소절 「" h "」 이 두 번 나온다")
    }
    END { if (NR < 3) bad("등급 줄·빈 줄·리드 문단이 모두 있어야 한다") }' "$2"
}

ver_ok() { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }

# ver_gt <a> <b> — rc 0 when a > b, both X.Y.Z.
ver_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, x, "."); split(b, y, ".")
    for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
    exit 1 }'
}

ver_bump() {
  awk -v v="$1" -v g="$2" 'BEGIN {
    split(v, x, ".")
    if (g == "major") { x[1]++; x[2] = 0; x[3] = 0 }
    else if (g == "minor") { x[2]++; x[3] = 0 }
    else x[3]++
    printf "%d.%d.%d\n", x[1], x[2], x[3] }'
}

# plugin_version <file> — the "version" value, empty when absent or unreadable.
plugin_version() { jq -r '.version // empty' "$1" 2>/dev/null || true; }

# log_heads <file> — every `## [X]` heading's X, in file order.
log_heads() { awk 'match($0, /^## \[[^]]*\]/) { print substr($0, 5, RLENGTH - 5) }' "$1"; }

# blob <rev> <path> <out> — the file at that revision, empty when absent.
blob() { git show "$1:$2" > "$3" 2>/dev/null || : > "$3"; }

# trim — drop leading and trailing blank lines of stdin.
trim() {
  awk '{ l[NR] = $0 } END {
    s = 1; while (s <= NR && l[s] ~ /^[ \t]*$/) s++
    e = NR; while (e >= s && l[e] ~ /^[ \t]*$/) e--
    for (i = s; i <= e; i++) print l[i] }'
}

TMPW=""
cleanup() { [ -z "$TMPW" ] || rm -rf "$TMPW"; }
trap cleanup EXIT
mkwork() { TMPW=$(mktemp -d "${TMPDIR:-/tmp}/changelog.XXXXXX"); }

cmd_new() {
  local grade="${1:-}" suffix="" branch slug root name
  case "$grade" in patch|minor|major) ;; *) usage ;; esac
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --suffix) [ "$#" -ge 2 ] || usage; suffix="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  branch=$(git symbolic-ref --quiet --short HEAD) \
    || die "분리된 HEAD 에서는 조각을 만들지 않는다 — 브랜치를 체크아웃한다" 1
  [ "$branch" != "$CL_BASE_BRANCH" ] \
    || die "${CL_BASE_BRANCH} 위에서는 조각을 만들지 않는다 — 작업 브랜치를 만든다" 1
  slug=$(slug_of "$branch")
  case "$slug" in
    *--*) die "브랜치 슬러그 「${slug}」 에 -- 가 들어 있어 덧붙임 구분자와 겹친다 — 브랜치 이름을 바꾼다" 1 ;;
  esac
  if [ -n "$suffix" ]; then
    printf '%s' "$suffix" | grep -Eq '^[A-Za-z0-9._-]+$' \
      || die "덧붙임은 영문·숫자·. _ - 만 쓴다 — ${suffix}" 1
    name="$slug--$suffix.md"
  else
    name="$slug.md"
  fi
  root=$(git rev-parse --show-toplevel) || die "git 작업 트리가 아니다"
  if [ -e "$root/$CL_DIR/$name" ]; then
    if [ -z "$suffix" ]; then
      die "${CL_DIR}/${name} 이 이미 있다 — 둘째 조각은 --suffix <덧붙임> 으로 만든다" 1
    fi
    die "${CL_DIR}/${name} 이 이미 있다" 1
  fi
  mkdir -p "$root/$CL_DIR"
  {
    printf '등급: %s\n\n' "$grade"
    printf '이 변경이 사용자에게 무엇을 바꾸는지 한국어 한 문단으로 쓴다.\n\n'
    printf '### Changed\n\n'
    printf -- '- **바뀐 것** — 무엇이 어떻게 달라지는지 쓴다.\n'
  } > "$root/$CL_DIR/$name"
  printf '%s/%s\n' "$CL_DIR" "$name"
}

cmd_check() {
  local base="" head="" branch="" mb slug st path rest n sfx
  local plugin_changed=0 log_changed=0 ver_changed=0 nfrag=0
  local old_ver new_ver head_first legacy=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base) [ "$#" -ge 2 ] || usage; base="$2"; shift 2 ;;
      --head) [ "$#" -ge 2 ] || usage; head="$2"; shift 2 ;;
      --branch) [ "$#" -ge 2 ] || usage; branch="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$base" ] && [ -n "$head" ] && [ -n "$branch" ] || usage
  git rev-parse --verify --quiet "$base^{commit}" > /dev/null || die "베이스 커밋을 찾지 못했다 — $base"
  git rev-parse --verify --quiet "$head^{commit}" > /dev/null || die "머리 커밋을 찾지 못했다 — $head"
  mb=$(git merge-base "$base" "$head") || die "병합 기준점을 찾지 못했다 — $base $head"
  slug=$(slug_of "$branch")
  mkwork
  : > "$TMPW/why"; : > "$TMPW/frags"
  git -c core.quotepath=false diff --no-renames --name-status "$mb" "$head" > "$TMPW/diff" \
    || die "차이를 읽지 못했다 — $mb $head"

  while IFS="$(printf '\t')" read -r st path; do
    [ -n "$path" ] || continue
    case "$path" in plugins/cc-cmds/*) plugin_changed=1 ;; esac
    [ "$path" != "$CL_LOG" ] || log_changed=1
    case "$path" in
      "$CL_DIR"/*) rest=${path#"$CL_DIR"/} ;;
      *) continue ;;
    esac
    if [ "$st" = A ] && top_md "$rest"; then
      printf '%s\n' "$path" >> "$TMPW/frags"; nfrag=$((nfrag + 1)); continue
    fi
    if [ "$st" != A ] && top_md "$rest"; then
      blob "$mb" "$path" "$TMPW/old"
      if [ -n "$(frag_problems x "$TMPW/old")" ]; then
        # Already malformed at the merge base: removing it, or rewriting it
        # into a correct format, is the repair path.
        if [ "$st" = D ]; then continue; fi
        blob "$head" "$path" "$TMPW/new"
        frag_problems "$path (고친 깨진 조각)" "$TMPW/new" >> "$TMPW/why"
        continue
      fi
    fi
    if [ "$st" = A ]; then
      printf '조각이 아닌 changelog.d 경로를 더했다 — %s\n' "$path" >> "$TMPW/why"
    else
      printf '이 PR 이 더하지 않은 changelog.d 경로를 바꿨다 — %s %s\n' "$st" "$path" >> "$TMPW/why"
    fi
  done < "$TMPW/diff"

  blob "$mb" "$CL_PLUGIN" "$TMPW/pj.old"; blob "$head" "$CL_PLUGIN" "$TMPW/pj.new"
  old_ver=$(plugin_version "$TMPW/pj.old"); new_ver=$(plugin_version "$TMPW/pj.new")
  [ "$old_ver" = "$new_ver" ] || ver_changed=1

  if [ "$nfrag" -gt 0 ]; then
    if [ "$log_changed" = 1 ] || [ "$ver_changed" = 1 ]; then
      printf '조각과 기존 방식 릴리스 메타(%s 또는 %s 의 version)를 한 PR 에 섞었다 — 버전 절과 version 은 릴리스 워크플로가 쓴다\n' "$CL_LOG" "$CL_PLUGIN" >> "$TMPW/why"
    fi
    case "$slug" in
      *--*) printf '브랜치 슬러그 「%s」 에 -- 가 들어 있어 조각을 쓸 수 없다\n' "$slug" >> "$TMPW/why" ;;
    esac
    while IFS= read -r path; do
      n=${path#"$CL_DIR"/}
      case "$n" in
        "$slug.md") ;;
        "$slug--"*.md)
          sfx=${n#"$slug--"}; sfx=${sfx%.md}
          [ -n "$sfx" ] || printf '조각 이름이 브랜치 슬러그 「%s」 의 두 꼴(%s.md, %s--<덧붙임>.md) 밖이다 — %s\n' "$slug" "$slug" "$slug" "$path" >> "$TMPW/why" ;;
        *) printf '조각 이름이 브랜치 슬러그 「%s」 의 두 꼴(%s.md, %s--<덧붙임>.md) 밖이다 — %s\n' "$slug" "$slug" "$slug" "$path" >> "$TMPW/why" ;;
      esac
      blob "$head" "$path" "$TMPW/frag"
      frag_problems "$path" "$TMPW/frag" >> "$TMPW/why"
    done < "$TMPW/frags"
  fi

  if [ -s "$TMPW/why" ]; then
    sed 's/^/changelog check: 실패 — /' "$TMPW/why"
    return 1
  fi
  if [ "$plugin_changed" = 0 ]; then
    printf 'changelog check: 통과 — plugins/cc-cmds/ 를 바꾸지 않았다\n'; return 0
  fi
  if [ "$nfrag" -gt 0 ]; then
    printf 'changelog check: 통과 — 조각 %s개\n' "$nfrag"; return 0
  fi
  blob "$mb" "$CL_LOG" "$TMPW/log.old"; blob "$head" "$CL_LOG" "$TMPW/log.new"
  log_heads "$TMPW/log.new" > "$TMPW/heads.new"
  log_heads "$TMPW/log.old" > "$TMPW/heads.old"
  head_first=$(sed -n '1p' "$TMPW/heads.new")
  if [ -n "$head_first" ] && ! grep -Fxq -- "$head_first" "$TMPW/heads.old" \
     && ver_ok "$old_ver" && ver_ok "$new_ver" && ver_gt "$new_ver" "$old_ver"; then
    legacy=1
  fi
  if [ "$legacy" = 1 ]; then
    printf 'changelog check: 통과 — 기존 방식 릴리스 메타(과도기, %s → %s)\n' "$old_ver" "$new_ver"; return 0
  fi
  printf 'changelog check: 실패 — plugins/cc-cmds/ 를 바꿨는데 조각(%s/<브랜치 슬러그>.md)이 없다 — bash scripts/changelog.sh new <patch|minor|major> 로 만든다\n' "$CL_DIR"
  return 1
}

# lead_of <file> — the lead paragraph: from line 3 up to the first `### `.
lead_of() { awk 'NR >= 3 && /^###[ \t]/ { exit } NR >= 3 { print }' "$1" | trim; }

# section_of <file> <name> — the body of `### <name>`, blank edges dropped.
section_of() {
  awk -v s="$2" '
    /^###[ \t]/ { h = $0; sub(/^###[ \t]+/, "", h); sub(/[ \t]+$/, "", h); on = (h == s); next }
    on { print }' "$1" | trim
}

cmd_assemble() {
  local root f n=0 rank=0 g grade old new day pos c sec first content
  [ "$#" -eq 0 ] || usage
  root=$(git rev-parse --show-toplevel) || die "git 작업 트리가 아니다"
  cd "$root"
  mkwork
  : > "$TMPW/frags"; : > "$TMPW/why"
  for f in "$CL_DIR"/*.md; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f" >> "$TMPW/frags"
  done
  if [ ! -s "$TMPW/frags" ]; then
    printf 'changelog assemble: 조립할 조각이 없다\n' >&2
    return 3
  fi
  while IFS= read -r f; do
    frag_problems "$f" "$f" >> "$TMPW/why"
    git ls-files --error-unmatch -- "$f" > /dev/null 2>&1 \
      || printf '%s: git 이 추적하지 않는 조각이다\n' "$f" >> "$TMPW/why"
  done < "$TMPW/frags"
  if [ -s "$TMPW/why" ]; then
    sed 's/^/changelog assemble: 조각 형식 오류 — /' "$TMPW/why" >&2
    return 1
  fi

  old=$(plugin_version "$CL_PLUGIN")
  ver_ok "$old" || die "${CL_PLUGIN} 의 version 을 읽지 못했다 — 「${old}」" 1
  while IFS= read -r f; do
    g=$(sed -n '1s/^등급: //p' "$f")
    case "$g" in patch) n=1 ;; minor) n=2 ;; major) n=3 ;; esac
    if [ "$n" -gt "$rank" ]; then rank=$n; grade=$g; fi
  done < "$TMPW/frags"
  new=$(ver_bump "$old" "$grade")
  if [ -e "$CL_DIR/archive/$new" ]; then
    die "보관 디렉터리 ${CL_DIR}/archive/${new} 가 이미 있다 — 아무것도 쓰지 않는다" 1
  fi
  day=${CHANGELOG_DATE:-$(TZ=Asia/Seoul date +%Y-%m-%d)}
  printf '%s' "$day" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || die "날짜가 YYYY-MM-DD 가 아니다 — ${day}"
  [ -f "$CL_LOG" ] || die "${CL_LOG} 이 없다" 1

  # The order: the first-parent commit that added each fragment, older first.
  git rev-list --first-parent --reverse "$CL_BASE_BRANCH" > "$TMPW/fp" 2>/dev/null || : > "$TMPW/fp"
  : > "$TMPW/order"
  while IFS= read -r f; do
    git log --first-parent --diff-filter=A --format=%H "$CL_BASE_BRANCH" -- "$f" > "$TMPW/added" 2>/dev/null || : > "$TMPW/added"
    c=$(sed -n '1p' "$TMPW/added")
    pos=""
    [ -z "$c" ] || pos=$(awk -v c="$c" '$0 == c { print NR; exit }' "$TMPW/fp")
    [ -n "$pos" ] || pos=999999999
    printf '%s\t%s\n' "$pos" "$f" >> "$TMPW/order"
  done < "$TMPW/frags"
  LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2 "$TMPW/order" | cut -f2 > "$TMPW/sorted"

  {
    printf '## [%s] - %s\n\n' "$new" "$day"
    if [ "$(wc -l < "$TMPW/sorted" | tr -d ' ')" = 1 ]; then
      f=$(sed -n '1p' "$TMPW/sorted")
      tail -n +3 "$f" | trim
    else
      first=1
      while IFS= read -r f; do
        lead_of "$f" > "$TMPW/lead"
        [ -s "$TMPW/lead" ] || continue
        [ "$first" = 1 ] || printf '\n'
        cat "$TMPW/lead"; first=0
      done < "$TMPW/sorted"
      for sec in Added Changed Fixed Removed Why "Post-install notes"; do
        : > "$TMPW/sec"
        while IFS= read -r f; do
          section_of "$f" "$sec" > "$TMPW/part"
          [ -s "$TMPW/part" ] || continue
          [ ! -s "$TMPW/sec" ] || printf '\n' >> "$TMPW/sec"
          cat "$TMPW/part" >> "$TMPW/sec"
        done < "$TMPW/sorted"
        [ -s "$TMPW/sec" ] || continue
        printf '\n### %s\n\n' "$sec"
        cat "$TMPW/sec"
      done
    fi
  } > "$TMPW/section"

  awk -v sec="$TMPW/section" '
    function put() { while ((getline l < sec) > 0) print l; close(sec); print ""; done = 1 }
    !done && /^## \[/ { put() }
    { print }
    END { if (!done) { print ""; put() } }' "$CL_LOG" > "$TMPW/log"
  content=$(awk -v v="$new" '
    !done && /^[ \t]*"version"[ \t]*:/ { sub(/"version"[ \t]*:[ \t]*"[^"]*"/, "\"version\": \"" v "\""); done = 1 }
    { print }' "$CL_PLUGIN")
  printf '%s\n' "$content" > "$TMPW/plugin"
  [ "$(plugin_version "$TMPW/plugin")" = "$new" ] || die "${CL_PLUGIN} 의 version 줄을 바꾸지 못했다" 1

  cat "$TMPW/log" > "$CL_LOG"
  cat "$TMPW/plugin" > "$CL_PLUGIN"
  mkdir -p "$CL_DIR/archive/$new"
  while IFS= read -r f; do
    git mv -- "$f" "$CL_DIR/archive/$new/" || die "${f} 를 보관 디렉터리로 옮기지 못했다" 1
  done < "$TMPW/sorted"
  printf '%s\n' "$new"
}

[ "$#" -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  new) cmd_new "$@" ;;
  check) cmd_check "$@" ;;
  assemble) cmd_assemble "$@" ;;
  *) usage ;;
esac
