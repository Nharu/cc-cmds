#!/usr/bin/env bash
#
# lint-macos-keepset-paths.sh — the narrowed macOS leg runs a short list of
# suites, and its `paths` filter has to name exactly what that list needs.
#
# The leg exists only for the handful of assertions no other host checks, so
# its filter decides whether a change to one of those suites is ever seen by
# the host that can check it. It goes wrong in two directions, and both are
# silent:
#
#   deficit  — a kept suite, or a file it sources, is matched by no glob. A PR
#              that edits it does not wake the job, and the only host that can
#              run those assertions never looks.
#   surplus  — a glob matches nothing the leg runs, sources or refers to. The
#              job wakes for changes it has no coverage for, and the filter
#              keeps entries for suites that were moved off the leg long ago.
#
# Both sides are derived; nothing is listed here.
#
#   filter side     — the union of `paths[]` over every event of the workflow,
#                     read after `explode(.)` so the push trigger's alias of the
#                     pull_request anchor yields the same globs. `.["on"]`
#                     rather than `.on`, because YAML 1.1 reads a bare `on` key
#                     as a boolean. An event with no `paths` at all is exit 2:
#                     the job would start on every such event and there is no
#                     filter to compare.
#
#   execution side  — every `run: make …` line of the workflow names its target
#                     as its last word, and `make -n` on those targets prints
#                     the recipe lines without running any of them. Each line
#                     must read `bash <path> [args…]`; any other shape is exit
#                     2, because a line this lint cannot read is a suite it
#                     cannot account for.
#
# The dependency closure follows `.`/`source` lines whose argument is a path
# literal, optionally behind one leading `$var/`. A source line whose path is
# held entirely in a variable is NOT followed — its value is not in the file's
# bytes. That is a known gap, not a claim of completeness.
#
# Matching follows GitHub's `paths` semantics: `*` stays inside one path
# segment and `**` crosses segments. The comparison is a glob MATCH and never
# name equality — a suite covered only by a directory glob is covered.
#
# What JUSTIFIES a glob in the surplus direction is deliberately wider than
# what the deficit direction requires. A glob is kept if it matches a file the
# leg runs or sources, the Makefile or the workflow itself, or a tracked file
# or directory that one of those run or sourced files names as a path literal
# anywhere in its bytes. Two consequences are stated rather than hidden. The
# literal scan reads the WHOLE file even when the leg runs one section of it,
# so a large suite can justify a glob for a part of itself this leg never
# executes. And a directory literal justifies every file under it, which is
# why a single-segment directory (`scripts`, `plugins`) is not counted: a
# top-level directory is a category, not a subject. The lint errs toward
# keeping a glob, never toward a false surplus report.
#
# Usage: bash scripts/lint-macos-keepset-paths.sh
#
# Env override:
#   KEEPSET_ROOT      repo root to analyze (default: this script's repo root)
#   KEEPSET_WORKFLOW  target workflow, root-relative
#                     (default .github/workflows/notify-macos.yml)
#
# Exit codes:
#   0  compared, no violation
#   1  compared, at least one violation
#   2  the comparison could not be carried out: yq or make missing, no
#      workflow or Makefile, an event without `paths`, no `run: make` line, a
#      `make -n` that fails or prints a line that is not `bash <path>`, or an
#      empty derivation on either side. An abort reached after a violation has
#      already been printed exits 1 instead, so a caller that skips on exit 2
#      does not throw away findings it was already shown.
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
default_root=$(cd "$script_dir/.." && pwd)
root="${KEEPSET_ROOT:-$default_root}"
workflow_rel="${KEEPSET_WORKFLOW:-.github/workflows/notify-macos.yml}"
workflow="$root/$workflow_rel"

fail=0

viol() {
  # $1 rule id, $2 target, $3 message
  printf 'FAIL: [%s] %s — %s\n' "$1" "$2" "$3" >&2
  fail=1
}

die2() {
  if [ "$fail" -ne 0 ]; then
    printf 'FAIL: %s\n' "$1" >&2
    printf 'FAIL: macos-keepset-paths — 비교를 끝까지 수행하지 못했으나 이미 기록된 위반이 있다 — exit 1\n' >&2
    exit 1
  fi
  printf 'ERR: %s\n' "$1" >&2
  exit 2
}

scratch=$(mktemp -d "${TMPDIR:-/tmp}/lint-macos-keepset-paths.XXXXXX") \
  || die2 "임시 디렉터리를 만들지 못했다"
trap 'rm -rf "$scratch"' EXIT

# --- prerequisites ----------------------------------------------------------

command -v yq >/dev/null 2>&1 || die2 "yq (mikefarah v4) 를 찾지 못했다 — 비교를 수행할 수 없다"
command -v make >/dev/null 2>&1 || die2 "make 를 찾지 못했다 — 실행 집합을 유도할 수 없다"
[ -f "$workflow" ] || die2 "대상 워크플로가 없다: $workflow_rel"
[ -f "$root/Makefile" ] || die2 "Makefile 이 없다: $root/Makefile"

# --- tracked corpus ---------------------------------------------------------
# `-z` because the default quoting turns a non-ASCII path into an escaped
# string no comparison is ever handed, and the line count does not change.

corpus=$( (cd "$root" && git -c core.quotePath=false ls-files -z 2>/dev/null) | tr '\0' '\n' | sort )
enumerator="git ls-files"
if [ -z "$corpus" ]; then
  corpus=$( (cd "$root" && find . -type f 2>/dev/null) | sed -E 's|^\./||' | sort )
  enumerator="find"
fi
[ -n "$corpus" ] || die2 "tracked 코퍼스가 비었다 — 비교할 한쪽 변이 없다"

nl_corpus="
$corpus
"

in_corpus() {
  case "$nl_corpus" in
    *"
$1
"*) return 0 ;;
  esac
  return 1
}

# `a/b/../c` -> `a/c`. A literal written relative to its own script's directory
# climbs out of it, and the corpus only ever holds the folded spelling.
fold_dotdot() {
  awk '{ while (sub(/[^\/]+\/\.\.\//, "")) ; print }'
}

# --- glob -> ERE ------------------------------------------------------------
# GitHub `paths` semantics: `*` does not cross a separator, `**` does. `!`
# negation is not implemented; it stays a literal character, so a negated glob
# matches nothing and is reported as dead rather than silently honoured.

glob_body() {
  local g=$1 out='' i=0 n c
  n=${#g}
  while [ "$i" -lt "$n" ]; do
    c=${g:$i:1}
    case "$c" in
      '*')
        if [ "${g:$((i + 1)):1}" = '*' ]; then
          out="$out.*"
          i=$((i + 2))
          continue
        fi
        out="$out[^/]*"
        ;;
      '?') out="$out[^/]" ;;
      '.'|'^'|'$'|'('|')'|'['|']'|'{'|'}'|'+'|'|'|'\\') out="$out\\$c" ;;
      *) out="$out$c" ;;
    esac
    i=$((i + 1))
  done
  printf '%s\n' "$out"
}

# --- filter side ------------------------------------------------------------

events=$(yq -r 'explode(.) | .["on"] | keys | .[]' "$workflow" 2>/dev/null) \
  || die2 "워크플로의 on: 블록을 파싱하지 못했다: $workflow_rel"
[ -n "$events" ] || die2 "워크플로가 이벤트를 하나도 선언하지 않았다: $workflow_rel"

all_globs=""
for ev in $events; do
  tag=$(yq -r "explode(.) | .[\"on\"].\"$ev\".paths | tag" "$workflow" 2>/dev/null)
  if [ "$tag" != "!!seq" ]; then
    die2 "이벤트 '$ev' 가 paths 를 갖지 않는다 — 그 이벤트에서는 잡이 필터 없이 뜨므로 비교할 필터가 없다"
  fi
  globs=$(yq -r "explode(.) | .[\"on\"].\"$ev\".paths[]" "$workflow" 2>/dev/null)
  [ -n "$globs" ] || die2 "이벤트 '$ev' 의 paths 유도가 비었다"
  all_globs=$(printf '%s\n%s\n' "$all_globs" "$globs")
done

filter_globs=$(printf '%s\n' "$all_globs" | grep -v '^$' | sort -u)
[ -n "$filter_globs" ] || die2 "필터 변의 유도가 비었다"

filter_ere=""
while IFS= read -r g; do
  [ -n "$g" ] || continue
  b=$(glob_body "$g")
  if [ -z "$filter_ere" ]; then filter_ere="$b"; else filter_ere="$filter_ere|$b"; fi
done <<EOF
$filter_globs
EOF

# `=~` rather than a pipe into `grep -q`: under `pipefail` an early-exiting
# reader turns the answer "yes" into a failed pipeline.
matches_filter() {
  local re="^($filter_ere)$"
  [[ $1 =~ $re ]]
}

# --- execution side ---------------------------------------------------------

run_lines=$(yq -r 'explode(.) | .jobs[].steps[] | select(has("run")) | .run' "$workflow" 2>/dev/null) \
  || die2 "워크플로의 steps 를 파싱하지 못했다: $workflow_rel"

make_lines=$(printf '%s\n' "$run_lines" | grep -E '^[[:space:]]*make([[:space:]]|$)' || true)
[ -n "$make_lines" ] || die2 "'run: make …' 줄이 없다 — 실행 집합을 유도할 수 없다"

targets=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  t=$(printf '%s\n' "$line" | awk '{ print $NF }')
  case "$t" in
    ''|-*|*[!A-Za-z0-9_.-]*)
      die2 "'run: make …' 줄의 마지막 낱말이 타깃 이름이 아니다: $line" ;;
  esac
  targets=$(printf '%s\n%s\n' "$targets" "$t")
done <<EOF
$make_lines
EOF
targets=$(printf '%s\n' "$targets" | grep -v '^$' | sort -u)
targets_flat=$(printf '%s\n' "$targets" | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')

# The inherited make variables are cleared: run from inside `make lint`, a
# child make would otherwise pick up the parent's flags and print directory
# banners that are not recipe lines.
# shellcheck disable=SC2086
dry=$(cd "$root" && MAKEFLAGS= MFLAGS= MAKELEVEL= make --no-print-directory -n $targets 2>&1) \
  || die2 "make -n $targets_flat 이 실패했다: $(printf '%s\n' "$dry" | tail -3 | tr '\n' ' ')"

bash_line_re='^bash[[:space:]]+([^[:space:]]+)([[:space:]].*)?$'
exec_raw=""
unreadable=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if [[ $line =~ $bash_line_re ]]; then
    exec_raw=$(printf '%s\n%s\n' "$exec_raw" "${BASH_REMATCH[1]}")
  else
    unreadable=$(printf '%s\n  %s' "$unreadable" "$line")
  fi
done <<EOF
$dry
EOF
if [ -n "$unreadable" ]; then
  die2 "make -n $targets_flat 의 출력에 'bash <경로> [인자…]' 가 아닌 줄이 있다 — 그 줄이 무엇을 돌리는지 셀 수 없다:$unreadable"
fi
exec_raw=$(printf '%s\n' "$exec_raw" | grep -v '^$' | sort -u)
[ -n "$exec_raw" ] || die2 "실행 집합 변의 유도가 비었다 — '$targets_flat' 가 레시피 줄을 하나도 내지 않았다"

exec_set=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if in_corpus "$p"; then
    exec_set=$(printf '%s\n%s\n' "$exec_set" "$p")
  else
    viol "실행 집합" "$p" "레시피가 돌리는 경로가 tracked 파일이 아니다"
  fi
done <<EOF
$exec_raw
EOF
exec_set=$(printf '%s\n' "$exec_set" | grep -v '^$' | sort -u)

# --- dependency closure -----------------------------------------------------

source_literals() {
  # $1 = root-relative file. The path argument of each `.`/`source` line, with
  # quotes dropped and one leading `$var/` removed; what is still a variable
  # after that is not followed.
  grep -E '^[[:space:]]*(\.|source)[[:space:]]+' "$root/$1" 2>/dev/null \
    | sed -E 's/^[[:space:]]*(\.|source)[[:space:]]+//' \
    | tr -d "\"'" \
    | awk '{ print $1 }' \
    | sed -E 's/[;|&)].*$//; s#^\$\{?[A-Za-z_][A-Za-z_0-9]*\}?/##; s#^\./##' \
    | grep -v '\$' | grep -v '^$' || true
}

resolve_file() {
  # $1 = literal, $2 = directory of the file that wrote it. Tried against the
  # repository root first and then against that directory.
  local rel cand
  rel=$(printf '%s\n' "$1" | fold_dotdot)
  if in_corpus "$rel"; then printf '%s\n' "$rel"; return 0; fi
  if [ "$2" != "." ]; then
    cand=$(printf '%s/%s\n' "$2" "$1" | fold_dotdot)
    if in_corpus "$cand"; then printf '%s\n' "$cand"; return 0; fi
  fi
  return 1
}

closure=""
known="$exec_set"
frontier="$exec_set"
while [ -n "$frontier" ]; do
  found=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    owner=$(dirname "$f")
    while IFS= read -r lit; do
      [ -n "$lit" ] || continue
      r=$(resolve_file "$lit" "$owner") || continue
      case "
$known
" in
        *"
$r
"*) continue ;;
      esac
      known=$(printf '%s\n%s' "$known" "$r")
      closure=$(printf '%s\n%s' "$closure" "$r")
      found=$(printf '%s\n%s' "$found" "$r")
    done <<EOF
$(source_literals "$f")
EOF
  done <<EOF
$frontier
EOF
  frontier=$(printf '%s\n' "$found" | grep -v '^$' || true)
done
closure=$(printf '%s\n' "$closure" | grep -v '^$' | sort -u)

needed=$(printf '%s\n%s\n' "$exec_set" "$closure" | grep -v '^$' | sort -u)

# --- deficit ----------------------------------------------------------------

while IFS= read -r p; do
  [ -n "$p" ] || continue
  matches_filter "$p" \
    || viol "부족" "$p" "좁힌 레그가 돌리거나 소스하는 파일이 어떤 필터 글로브에도 매치되지 않는다 — 이 파일만 고치는 PR 이 잡을 깨우지 못한다"
done <<EOF
$needed
EOF

# --- surplus ----------------------------------------------------------------

path_literals() {
  grep -oE '(\$\{?[A-Za-z_][A-Za-z_0-9]*\}?/([A-Za-z0-9_.+-]+/)*|([A-Za-z0-9_.+-]+/)+)[A-Za-z0-9_.+-]+' "$root/$1" 2>/dev/null \
    | sed -E 's#^\$\{?[A-Za-z_][A-Za-z_0-9]*\}?/##; s#^\./##' \
    | sort -u || true
}

cand_file="$scratch/candidates"
: > "$cand_file"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  owner=$(dirname "$f")
  path_literals "$f" | awk -v o="$owner" '{ print; if (o != ".") print o "/" $0 }' >> "$cand_file"
done <<EOF
$needed
EOF
fold_dotdot < "$cand_file" | grep -v '^$' | sort -u > "$cand_file.sorted"

# A corpus path is referenced when it is itself a candidate, or when one of its
# ancestor directories of at least two segments is.
refs=$(printf '%s\n' "$corpus" | awk '
  NR == FNR { c[$0] = 1; next }
  {
    if ($0 in c) { print; next }
    p = $0
    while ((i = match(p, /\/[^\/]*$/)) > 0) {
      p = substr(p, 1, i - 1)
      if (split(p, parts, "/") >= 2 && (p in c)) { print $0; next }
    }
  }
' "$cand_file.sorted" -)

just_file="$scratch/justified"
printf '%s\n%s\nMakefile\n%s\n' "$needed" "$refs" "$workflow_rel" | grep -v '^$' | sort -u > "$just_file"

while IFS= read -r g; do
  [ -n "$g" ] || continue
  re="^($(glob_body "$g"))\$"
  matched=$(printf '%s\n' "$corpus" | grep -E "$re" || true)
  if [ -z "$matched" ]; then
    viol "죽은 글로브" "$g" "tracked 파일을 하나도 매치하지 않는다"
    continue
  fi
  hits=$(printf '%s\n' "$matched" | grep -cFx -f "$just_file" || true)
  if [ "${hits:-0}" -eq 0 ]; then
    viol "잉여" "$g" "필터가 잡을 깨우지만, 매치하는 파일을 좁힌 레그가 돌리지도 소스하지도 참조하지도 않는다"
  fi
done <<EOF
$filter_globs
EOF

# --- summary ----------------------------------------------------------------

count_lines() { printf '%s\n' "$1" | grep -c '[^[:space:]]' || true; }

exec_count=$(count_lines "$exec_set")
closure_count=$(count_lines "$closure")
glob_count=$(count_lines "$filter_globs")
corpus_count=$(count_lines "$corpus")

printf '유도: 타깃 %s — 실행 집합 %d 개, 의존 폐포 %d 개\n' "$targets_flat" "$exec_count" "$closure_count"
printf '%s\n' "$needed" | sed -E 's/^/  /'

if [ "$fail" -ne 0 ]; then
  printf 'FAIL: macos-keepset-paths — 필터 글로브 %d 개 대 실행 집합 %d 개 + 폐포 %d 개, tracked 코퍼스 %d 파일 (%s)\n' \
    "$glob_count" "$exec_count" "$closure_count" "$corpus_count" "$enumerator" >&2
  exit 1
fi

printf 'OK: macos-keepset-paths — 필터 글로브 %d 개, 실행 집합 %d 개 + 폐포 %d 개, tracked 코퍼스 %d 파일 (%s)\n' \
  "$glob_count" "$exec_count" "$closure_count" "$corpus_count" "$enumerator"
exit 0
