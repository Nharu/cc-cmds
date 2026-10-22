#!/usr/bin/env bash
# Build the tree CI tests, and test it outside the working tree.
#
# CI DOES NOT TEST THE BRANCH HEAD. For a pull request it checks out the merge
# of the head into the base branch as the base stood when the run started, so a
# section the base added can change what an untouched section of the branch
# sees. This file builds that same tree locally: a merge commit in a throwaway
# shared clone of the repository's own object store, made from a base sha and a
# head sha, with the parents in GitHub's order (base, head).
#
# Sourced, it is a library for scripts/check-push.sh. Run, it is a CLI with two
# commands for reproducing a CI failure, declared as two separate acts:
#
#   bash scripts/test-tree.sh ci-base --run <id> --repo <owner/name> [--job <id>]
#       network read only (gh GET), writes no file: reads the failed job's log,
#       prints the base, head, merge and tree CI used, the job's section and
#       goal lists, and the repro line to run next.
#   bash scripts/test-tree.sh repro --base <40> --head <40> --expect <40tree>
#                                   [--sections <ids>] [--goals <goals>]
#       offline: builds the merged tree, refuses it unless it is <tree>, runs
#       the items on it and then on the head alone, and names the verdict.
#   bash scripts/test-tree.sh --self-test
#
# Nothing here writes a check-push stamp, on any path.
#
# Doubles, read the same way by the library and the CLI (unset in real runs;
# when set they are followed, and their names land in the `대역=` field):
#   CC_TEST_TREE_GATE   the command run instead of the tested tree's
#                       `bash scripts/test-gate.sh` (`--list`, `--sections`)
#   CC_TEST_TREE_MAKE   the make for `print-rest-goals` and the goal run
#   CC_TEST_TREE_GH     the gh of `ci-base`
#
# repro exit codes: 0 verdict given, 1 unknown item, 2 usage or item syntax,
# 3 the merge conflicts, 4 an object is missing, 5 the tree is not --expect,
# 6 no verdict on the head side. ci-base: 0, 1 a checkout line is missing,
# 2 usage / job choice / gh failure / a value fails the output check, 3 no list.

# The section and goal runs below start fixture suites, and a suite that calls
# the gate family must not reach the user's screen or leave a dashboard server.
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
CC_CMDS_DASHBOARD=off
export CC_CMDS_DASHBOARD

# Messages name their writer; check-push sets these to its own spelling.
TT_PREFIX="${TT_PREFIX:-test-tree}"
TT_SECVAR="${TT_SECVAR:---sections}"
TT_GOALVAR="${TT_GOALVAR:---goals}"
TT_DIR="${TT_DIR:-}"
TT_WORK="${TT_WORK:-}"

# --- small helpers -----------------------------------------------------------

tt_or_none() {
  if [ -n "$1" ]; then printf '%s' "$1"; else printf '없음'; fi
}

tt_is_sha() {
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 40 ]
}

# The double variables that are set, comma-joined, or 없음.
tt_doubles() {
  local n out=""
  for n in CC_CHECK_PUSH_MAKE CC_TEST_TREE_GATE CC_TEST_TREE_MAKE CC_TEST_TREE_GH; do
    if [ -n "${!n:-}" ]; then out="${out:+$out,}$n"; fi
  done
  tt_or_none "$out"
}

# Runs "$@" with the variables of this run's callers removed: check-push's own
# knobs, the doubles, and the pipeline and session variables CI never has.
tt_scrubbed() {
  (
    for v in $(compgen -e); do
      case "$v" in
        CHECK_PUSH_*|CC_TEST_TREE_*|CC_CHECK_PUSH_*|CC_PIPELINE_*|CLAUDE*) unset "$v" ;;
      esac
    done
    exec "$@"
  )
}

# git inside the clone. A GIT_DIR inherited from a hook or a linked worktree
# would otherwise point every command back at the caller's repository.
tt_git() {
  (cd "$TT_WORK" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git "$@")
}

# test-gate of the tested tree (or its double), run in the clone.
tt_gate() {
  local gate="${CC_TEST_TREE_GATE:-}"
  if [ -n "$gate" ]; then
    (cd "$TT_WORK" && tt_scrubbed "$gate" "$@" < /dev/null)
  else
    (cd "$TT_WORK" && tt_scrubbed bash scripts/test-gate.sh "$@" < /dev/null)
  fi
}

# make in the clone, with check-push's own command-line variables kept away
# from the recipes as scripts/rest-shard.sh does.
tt_make() {
  local mk="${CC_TEST_TREE_MAKE:-make}"
  (cd "$TT_WORK" && export MAKEFLAGS='' MFLAGS='' MAKELEVEL='' && tt_scrubbed "$mk" "$@" < /dev/null)
}

# The tested tree's section ids, one per line (first field of `--list`).
tt_list_sections() {
  local out id rest
  out=$(tt_gate --list 2>/dev/null) || return 1
  while read -r id rest; do
    [ -n "$id" ] && printf '%s\n' "$id"
  done <<EOF
$out
EOF
  return 0
}

tt_list_goals() {
  local out g
  out=$(tt_make -s --no-print-directory print-rest-goals 2>/dev/null) || return 1
  while read -r g; do
    [ -n "$g" ] && printf '%s\n' "$g"
  done <<EOF
$out
EOF
  return 0
}

# Syntax of one comma list: every item non-empty and in the item alphabet.
# Sets TT_HINT on failure.
tt_items_syntax() {
  local list="$1" what="$2" rest it re='^[A-Za-z0-9/._-]+$'
  [ -n "$list" ] || return 0
  rest="$list,"
  while [ -n "$rest" ]; do
    it="${rest%%,*}"
    rest="${rest#*,}"
    if [ -z "$it" ]; then
      TT_HINT="$TT_PREFIX: $what 목록 $(printf %q "$list") 에 빈 항목이 있다 — 쉼표로만 구분하고 앞뒤 쉼표를 두지 않는다"
      return 2
    fi
    if ! [[ $it =~ $re ]]; then
      TT_HINT="$TT_PREFIX: $what 항목 $(printf %q "$it") 은 형식이 아니다 — 영문자·숫자와 / . _ - 만 쓴다"
      return 2
    fi
  done
  return 0
}

# Prints the items of the comma list $1 that are lines of $2, in $2's order.
tt_keep_in_order() {
  local want=",$1," line
  while read -r line; do
    [ -n "$line" ] || continue
    case "$want" in *",$line,"*) printf '%s\n' "$line" ;; esac
  done <<EOF
$2
EOF
}

# Prints the items of the comma list $1 that are not lines of $2, in $1's order.
tt_missing_from() {
  local rest="$1," it hay="
$2
"
  [ -n "$1" ] || return 0
  while [ -n "$rest" ]; do
    it="${rest%%,*}"
    rest="${rest#*,}"
    case "$hay" in *"
$it
"*) ;; *) printf '%s\n' "$it" ;; esac
  done
}

tt_join() {
  local out="" line
  while read -r line; do
    [ -n "$line" ] && out="${out:+$out,}$line"
  done <<EOF
$1
EOF
  printf '%s' "$out"
}

# --- library -----------------------------------------------------------------

# The base sha from this worktree's FETCH_HEAD, when a fetch of <branch> from
# origin wrote it in the last ten minutes. The credential part of either URL is
# dropped before the comparison and never printed.
tt_url_norm() {
  local u="$1" scheme rest auth path
  case "$u" in
    *://*)
      scheme="${u%%://*}"
      rest="${u#*://}"
      auth="${rest%%/*}"
      path="${rest#"$auth"}"
      auth="${auth##*@}"
      u="$scheme://$auth$path"
      ;;
    *)
      rest="${u%%:*}"
      case "$rest" in *@*) u="${u#*@}" ;; esac
      ;;
  esac
  while [ "${u%/}" != "$u" ]; do u="${u%/}"; done
  u="${u%.git}"
  while [ "${u%/}" != "$u" ]; do u="${u%/}"; done
  printf '%s' "$u"
}

tt_base_from_fetch_head() {
  local b="$1" gd fh origin line sha rest nfm desc url why="" found=""
  TT_BASE=""
  TT_FETCH="없음"
  if ! git check-ref-format --branch "$b" > /dev/null 2>&1; then
    printf '%s: 베이스 브랜치 %s 는 브랜치 이름 형식이 아니다\n' "$TT_PREFIX" "$(printf %q "$b")" >&2
    return 2
  fi
  gd=$(git rev-parse --git-dir 2>/dev/null) || gd=""
  fh="$gd/FETCH_HEAD"
  origin=$(git remote get-url origin 2>/dev/null) || origin=""
  origin=$(tt_url_norm "$origin")
  if [ -z "$gd" ] || [ ! -f "$fh" ]; then
    why="FETCH_HEAD 없음"
  elif [ -z "$(find "$fh" -mmin -10 2>/dev/null)" ]; then
    why="FETCH_HEAD 가 10분보다 오래됨"
  else
    why="브랜치 $b 의 줄 없음"
    while IFS= read -r line || [ -n "$line" ]; do
      sha="${line%%$'\t'*}"
      rest="${line#*$'\t'}"
      [ "$rest" != "$line" ] || continue
      nfm="${rest%%$'\t'*}"
      desc="${rest#*$'\t'}"
      [ "$desc" != "$rest" ] || continue
      tt_is_sha "$sha" || continue
      case "$nfm" in ''|not-for-merge) ;; *) continue ;; esac
      case "$desc" in "branch '$b' of "*) ;; *) continue ;; esac
      url="${desc#"branch '$b' of "}"
      if [ -n "$origin" ] && [ "$(tt_url_norm "$url")" = "$origin" ]; then
        found="$sha"
        break
      fi
      why="브랜치 $b 의 줄이 origin 과 다른 URL 에서 왔음"
    done < "$fh"
  fi
  if [ -z "$found" ]; then
    printf '%s: 베이스 %s 를 이 워크트리에서 10분 안에 받지 않았다 — 먼저 git fetch --no-tags --refmap= origin refs/heads/%s (게이트 --surface 읽기 --reach 협업)\n' "$TT_PREFIX" "$b" "$b" >&2
    printf '%s: (사유: %s)\n' "$TT_PREFIX" "$why" >&2
    return 4
  fi
  TT_BASE="$found"
  TT_FETCH=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  return 0
}

# A shared, unchecked-out clone of the current repository's common git
# directory. No trap: bash keeps one EXIT trap, and it belongs to the caller.
tt_clone() {
  local gd
  TT_DIR=""
  TT_WORK=""
  gd=$(git rev-parse --git-common-dir 2>/dev/null) && gd=$(cd "$gd" 2>/dev/null && pwd) || {
    printf '%s: 공통 git 디렉터리를 읽지 못했다\n' "$TT_PREFIX" >&2
    return 2
  }
  TT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cc-test-tree.XXXXXX") || {
    TT_DIR=""
    printf '%s: 임시 디렉터리를 만들지 못했다\n' "$TT_PREFIX" >&2
    return 2
  }
  TT_WORK="$TT_DIR/tree"
  if ! env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git clone --quiet --shared --no-checkout "$gd" "$TT_WORK" < /dev/null; then
    printf '%s: 임시 복제에 실패했다\n' "$TT_PREFIX" >&2
    return 2
  fi
  return 0
}

tt_cleanup() {
  if [ -n "${TT_DIR:-}" ]; then
    rm -rf "$TT_DIR"
    TT_DIR=""
    TT_WORK=""
  fi
  return 0
}

# Builds the tree to test from <base> and <head> and checks it out in the clone.
tt_build() {
  local base="$1" head="$2" out rc line paths=""
  TT_OUTCOME=""
  TT_TREE=""
  TT_COMMIT=""
  TT_CONFLICTS=""
  TT_MISSING_OBJ=""
  for line in "$base" "$head"; do
    if ! tt_git cat-file -e "$line^{commit}" 2>/dev/null; then
      TT_MISSING_OBJ="$line"
      return 4
    fi
  done
  base=$(tt_git rev-parse --verify --quiet "$base^{commit}") || return 2
  head=$(tt_git rev-parse --verify --quiet "$head^{commit}") || return 2
  if tt_git merge-base --is-ancestor "$base" "$head"; then
    TT_OUTCOME="조상"
    TT_COMMIT="$head"
    TT_TREE=$(tt_git rev-parse --verify --quiet "$head^{tree}") || return 2
    tt_git checkout --quiet --detach "$head" || return 2
    return 0
  fi
  out=$(tt_git merge-tree --write-tree --name-only --no-messages "$base" "$head" < /dev/null 2>/dev/null)
  rc=$?
  case "$rc" in
    0)
      TT_TREE="${out%%$'\n'*}"
      tt_is_sha "$TT_TREE" || return 2
      TT_COMMIT=$(tt_git -c user.name=test-tree -c user.email=test-tree@invalid -c commit.gpgsign=false commit-tree -m test-tree "$TT_TREE" -p "$base" -p "$head" < /dev/null) || return 2
      tt_git checkout --quiet --detach "$TT_COMMIT" || return 2
      TT_OUTCOME="합침"
      ;;
    1)
      local names=""
      case "$out" in *$'\n'*) names="${out#*$'\n'}" ;; esac
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        case ",$paths," in *",$line,"*) ;; *) paths="${paths:+$paths,}$line" ;; esac
      done <<EOF
$names
EOF
      TT_CONFLICTS="$paths"
      TT_OUTCOME="충돌"
      TT_COMMIT="$head"
      TT_TREE=$(tt_git rev-parse --verify --quiet "$head^{tree}") || return 2
      tt_git checkout --quiet --detach "$head" || return 2
      ;;
    *)
      return 2
      ;;
  esac
  return 0
}

# Checks <rev> out over whatever an earlier run left in the clone.
tt_checkout() {
  tt_git checkout --quiet --force --detach "$1" > /dev/null 2>&1 || return 2
  tt_git clean -ffdxq > /dev/null 2>&1 || return 2
  return 0
}

# Strict membership of both lists in the checked-out tree. Sets TT_MISSING (the
# unknown items), TT_HINT (the messages) and, on success, TT_SECTIONS in the
# tree's file order and TT_GOALS as given.
tt_check_items() {
  local secs="$1" goals="$2" slist="" glist="" have_s=0 have_g=0 it miss hint=""
  TT_MISSING=""
  TT_HINT=""
  TT_SECTIONS=""
  TT_GOALS=""
  tt_items_syntax "$secs" "절" || return 2
  tt_items_syntax "$goals" "목표" || return 2
  if [ -n "$secs" ]; then
    if ! slist=$(tt_list_sections); then
      TT_MISSING="$secs"
      TT_HINT="$TT_PREFIX: 목록 불가 — 이 트리의 test-gate.sh 로 절을 나열할 수 없다"
      return 1
    fi
    have_s=1
  fi
  if [ -n "$goals" ]; then
    if ! glist=$(tt_list_goals); then
      TT_MISSING="$goals"
      TT_HINT="$TT_PREFIX: 목록 불가 — 이 트리의 Makefile 로 목표를 나열할 수 없다"
      return 1
    fi
    have_g=1
  fi
  miss=$(tt_missing_from "$secs" "$slist")
  if [ -n "$miss" ] && [ "$have_g" = 0 ]; then
    glist=$(tt_list_goals) && have_g=1
  fi
  while read -r it; do
    [ -n "$it" ] || continue
    TT_MISSING="${TT_MISSING:+$TT_MISSING,}$it"
    case "
$glist
" in
      *"
$it
"*) hint="${hint}$TT_PREFIX: 절 $it 은 없다 — REST 목표이므로 $TT_GOALVAR 로 준다
" ;;
      *) hint="${hint}$TT_PREFIX: 모르는 절 $it
" ;;
    esac
  done <<EOF
$miss
EOF
  miss=$(tt_missing_from "$goals" "$glist")
  if [ -n "$miss" ] && [ "$have_s" = 0 ]; then
    slist=$(tt_list_sections) && have_s=1
  fi
  while read -r it; do
    [ -n "$it" ] || continue
    TT_MISSING="${TT_MISSING:+$TT_MISSING,}$it"
    if case "
$glist
" in *"
run/$it
"*) true ;; *) false ;; esac; then
      hint="${hint}$TT_PREFIX: 목표 $it 는 없다 — run/$it 를 뜻했다면 그 이름을 쓴다
"
    elif case "
$slist
" in *"
$it
"*) true ;; *) false ;; esac; then
      hint="${hint}$TT_PREFIX: 목표 $it 는 없다 — test-gate 절 id 이므로 $TT_SECVAR 로 준다
"
    else
      hint="${hint}$TT_PREFIX: 모르는 목표 $it
"
    fi
  done <<EOF
$miss
EOF
  if [ -n "$TT_MISSING" ]; then
    TT_HINT="${hint%$'\n'}"
    return 1
  fi
  TT_SECTIONS=$(tt_join "$(tt_keep_in_order "$secs" "$slist")")
  TT_GOALS="$goals"
  return 0
}

# The items the checked-out head can name. 1 when it cannot list them, 6 when
# nothing is left.
tt_head_filter() {
  local secs="$1" goals="$2" slist="" glist="" dropped
  TT_KEEP_SECTIONS=""
  TT_KEEP_GOALS=""
  TT_DROPPED=""
  if [ -n "$secs" ]; then
    slist=$(tt_list_sections) || return 1
  fi
  if [ -n "$goals" ]; then
    glist=$(tt_list_goals) || return 1
  fi
  TT_KEEP_SECTIONS=$(tt_join "$(tt_keep_in_order "$secs" "$slist")")
  TT_KEEP_GOALS=$(tt_join "$(tt_keep_in_order "$goals" "$glist")")
  dropped="$(tt_missing_from "$secs" "$slist")
$(tt_missing_from "$goals" "$glist")"
  TT_DROPPED=$(tt_join "$dropped")
  if [ -z "$TT_KEEP_SECTIONS" ] && [ -z "$TT_KEEP_GOALS" ]; then
    return 6
  fi
  return 0
}

# One test-gate call for every section, then one make for every goal. The
# failure names the whole list, because the list is what failed.
tt_run_items() {
  local secs="$1" goals="$2" rc
  TT_FAILED=""
  if [ -n "$secs" ]; then
    tt_gate --sections "$secs"
    rc=$?
    if [ "$rc" != 0 ]; then
      TT_FAILED="절=$secs"
      return "$rc"
    fi
  fi
  if [ -n "$goals" ]; then
    local words=() rest="$goals,"
    while [ -n "$rest" ]; do
      words+=("${rest%%,*}")
      rest="${rest#*,}"
    done
    tt_make --no-print-directory "${words[@]}"
    rc=$?
    if [ "$rc" != 0 ]; then
      TT_FAILED="목표=$goals"
      return "$rc"
    fi
  fi
  return 0
}

tt_section_markers() {
  tt_git show "$1:scripts/test-gate.sh" 2>/dev/null | sed -n 's/^# --- section: \([^ |]*\) |.*$/\1/p'
}

# Sections the base added since the merge base: a hint, never a list to run.
tt_base_added_ids() {
  local base="$1" head="$2" mb have want
  TT_ADDED="없음"
  case "${TT_OUTCOME:-}" in 조상|충돌) return 0 ;; esac
  mb=$(tt_git merge-base "$base" "$head" 2>/dev/null) || return 0
  have=$(tt_section_markers "$mb")
  want=$(tt_section_markers "$base")
  TT_ADDED=$(tt_or_none "$(tt_join "$(tt_missing_from "$(tt_join "$want")" "$have")")")
  return 0
}

# Reads a job log (`<job>\t<step>\t<time> <message>` per line) held in the
# variable named $1. Only the message is matched: the job name of a gate shard
# itself contains `gate-shard`, and old logs say `UNKNOWN STEP` in every step.
tt_ci_parse() {
  local __log="${!1}" f1 f2 f3 msg t ids="" in_block=0 block_done=0 got_list=0 rest
  TT_CI_MERGE=""
  TT_CI_HEAD=""
  TT_CI_BASE=""
  TT_CI_SECTIONS=""
  TT_CI_GOALS=""
  local re_rest='^rest shard [0-9]+/[0-9]+: (.*)$'
  while IFS=$'\t' read -r f1 f2 f3; do
    [ -n "$f3" ] || continue
    msg="${f3#* }"
    [ "$msg" != "$f3" ] || continue
    msg="${msg%$'\r'}"
    if [ "$in_block" = 1 ]; then
      case "$msg" in
        "test-gate:   id="*)
          t="${msg#test-gate:   id=}"
          ids="${ids:+$ids,}${t%% *}"
          continue
          ;;
        "test-gate: needs 로 함께 도는 절 — "*)
          continue
          ;;
        *)
          in_block=0
          block_done=1
          ;;
      esac
    fi
    case "$msg" in
      *" +"*":refs/remotes/pull/"*"/merge")
        if [ -z "$TT_CI_MERGE" ]; then
          t="${msg##* +}"
          TT_CI_MERGE="${t%%:*}"
        fi
        continue
        ;;
      "HEAD is now at "*" Merge "*" into "*)
        if [ -z "$TT_CI_HEAD" ]; then
          rest="${msg#HEAD is now at }"
          rest="${rest#* }"
          t="${rest#Merge }"
          TT_CI_HEAD="${t%% *}"
          t="${rest##* into }"
          TT_CI_BASE="${t%% *}"
        fi
        continue
        ;;
    esac
    [ -n "$TT_CI_HEAD" ] || continue
    if [ "$block_done" = 0 ] && [ "$in_block" = 0 ]; then
      case "$msg" in
        "test-gate: 좁힌 실행 — 절 "*)
          in_block=1
          got_list=1
          continue
          ;;
      esac
    fi
    if [ "$got_list" != 2 ] && [[ $msg =~ $re_rest ]]; then
      t="${BASH_REMATCH[1]}"
      if [ "$t" != "배정된 목표가 없습니다" ]; then
        TT_CI_GOALS=$(printf '%s' "$t" | tr -s ' ' ',')
        TT_CI_GOALS="${TT_CI_GOALS#,}"
        TT_CI_GOALS="${TT_CI_GOALS%,}"
      fi
      got_list=2
    fi
  done <<EOF
$__log
EOF
  TT_CI_SECTIONS="$ids"
  if [ -z "$TT_CI_MERGE" ] || [ -z "$TT_CI_HEAD" ] || [ -z "$TT_CI_BASE" ]; then
    return 1
  fi
  if [ "$got_list" = 0 ]; then
    return 3
  fi
  return 0
}

# The read that tells whether the base itself was green. check-push and repro
# print it unfiltered; neither calls gh.
tt_base_status_line() {
  printf '%s: base 상태 — gh run list --repo Nharu/cc-cmds --commit %s --json workflowName,conclusion,databaseId — 워크플로마다, 런 없음 또는 진행 중이면 그 워크플로의 베이스 상태는 모름이다 (초록이 아니다)\n' "$1" "$2"
}

# --- CLI: ci-base ------------------------------------------------------------

tt_cli_usage() {
  printf '%s: 사용법 — ci-base --run <id> --repo <owner/name> [--job <id>] / repro --base <40> --head <40> --expect <40> [--sections <ids>] [--goals <goals>] / --self-test\n' "$TT_PREFIX" >&2
}

tt_cli_ci_base() {
  local run="" repo="" job="" gh jobs jid jname jconc failed="" nfail=0 name="" log rc tree v bad=""
  TT_PREFIX="ci-base"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run) run="${2:-}"; shift 2 || { tt_cli_usage; return 2; } ;;
      --repo) repo="${2:-}"; shift 2 || { tt_cli_usage; return 2; } ;;
      --job) job="${2:-}"; shift 2 || { tt_cli_usage; return 2; } ;;
      *) tt_cli_usage; return 2 ;;
    esac
  done
  case "$run" in ''|*[!0-9]*) tt_cli_usage; return 2 ;; esac
  case "$job" in *[!0-9]*) tt_cli_usage; return 2 ;; esac
  if ! [[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    tt_cli_usage
    return 2
  fi
  gh="${CC_TEST_TREE_GH:-gh}"

  jobs=$("$gh" run view "$run" --repo "$repo" --json jobs --jq '.jobs[] | [(.databaseId|tostring), .name, (.conclusion // "")] | @tsv' < /dev/null) || {
    printf 'ci-base: 런 %s 의 잡 목록을 읽지 못했다 (gh run view 실패)\n' "$run" >&2
    return 2
  }
  while IFS=$'\t' read -r jid jname jconc; do
    [ -n "$jid" ] || continue
    if [ -n "$job" ] && [ "$jid" = "$job" ]; then name="$jname"; fi
    if [ "$jconc" = "failure" ]; then
      nfail=$((nfail + 1))
      failed="${failed}  job=${jid} 「${jname}」
"
      if [ -z "$job" ]; then name="$jname"; fi
    fi
  done <<EOF
$jobs
EOF
  if [ -z "$job" ]; then
    if [ "$nfail" != 1 ]; then
      printf 'ci-base: --job 없이는 실패한 잡이 하나여야 한다 — 실패한 잡 %s개\n' "$nfail" >&2
      [ -n "$failed" ] && printf '%s' "$failed" >&2
      return 2
    fi
    job=$(printf '%s' "$failed" | sed -n '1s/^  job=\([0-9]*\) .*$/\1/p')
  elif [ -z "$name" ]; then
    printf 'ci-base: 런 %s 에 잡 %s 가 없다\n' "$run" "$job" >&2
    return 2
  fi

  if [ "$name" = "lint-and-test-macos" ]; then
    printf 'ci-base: 목록 없음 — job=%s 「%s」 는 다윈 목표와 다윈 절을 함께 돌려 로그에 그 잡의 목록 전체가 없다\n' "$job" "$name"
    return 3
  fi

  log=$("$gh" run view "$run" --repo "$repo" --job "$job" --log < /dev/null) || {
    printf 'ci-base: 잡 %s 의 로그를 읽지 못했다 (gh run view --log 실패)\n' "$job" >&2
    return 2
  }
  tt_ci_parse log
  rc=$?
  if [ "$rc" = 1 ]; then
    printf 'ci-base: 체크아웃 줄 없음 — job=%s 의 로그에 merge ref fetch 줄이나 HEAD is now at 줄이 없다\n' "$job" >&2
    return 1
  fi
  tree=$("$gh" api "repos/$repo/git/commits/$TT_CI_MERGE" --jq .tree.sha < /dev/null) || {
    printf 'ci-base: merge 커밋 %s 의 트리를 읽지 못했다 (gh api 실패)\n' "$(printf %q "$TT_CI_MERGE")" >&2
    return 2
  }

  # The values came from a script that ran on the PR's tree; check them before
  # they become a line to paste into a shell.
  for v in "base=$TT_CI_BASE" "head=$TT_CI_HEAD" "merge=$TT_CI_MERGE" "tree=$tree"; do
    tt_is_sha "${v#*=}" || bad="${bad} ${v%%=*}=$(printf %q "${v#*=}")"
  done
  TT_PREFIX="ci-base"
  tt_items_syntax "$TT_CI_SECTIONS" "절" || bad="${bad} sections=$(printf %q "$TT_CI_SECTIONS")"
  tt_items_syntax "$TT_CI_GOALS" "목표" || bad="${bad} goals=$(printf %q "$TT_CI_GOALS")"
  if [ -n "$bad" ]; then
    printf 'ci-base: 로그에서 읽은 값이 형식에 맞지 않아 repro 줄을 찍지 않는다 —%s\n' "$bad" >&2
    return 2
  fi

  printf 'ci-base: run=%s job=%s base=%s head=%s merge=%s tree=%s\n' "$run" "$job" "$TT_CI_BASE" "$TT_CI_HEAD" "$TT_CI_MERGE" "$tree"
  if [ "$rc" = 3 ]; then
    printf 'ci-base: 목록 없음 — job=%s 「%s」 의 로그에 절 목록도 목표 목록도 없다\n' "$job" "$name"
    return 3
  fi
  printf 'ci-base: sections=%s goals=%s\n' "$(tt_or_none "$TT_CI_SECTIONS")" "$(tt_or_none "$TT_CI_GOALS")"
  if [ -z "$TT_CI_SECTIONS" ] && [ -z "$TT_CI_GOALS" ]; then
    printf 'ci-base: 목록 없음 — job=%s 「%s」 의 로그에 절 목록도 목표 목록도 없다\n' "$job" "$name"
    return 3
  fi
  printf 'bash scripts/test-tree.sh repro --base %s --head %s --expect %s%s%s\n' \
    "$TT_CI_BASE" "$TT_CI_HEAD" "$tree" \
    "${TT_CI_SECTIONS:+ --sections $TT_CI_SECTIONS}" "${TT_CI_GOALS:+ --goals $TT_CI_GOALS}"
  return 0
}

# --- CLI: repro --------------------------------------------------------------

# The `도장:` line: what check-push recorded for this head's tree, against CI.
tt_repro_stamp_line() {
  local base="$1" head="$2" secs="$3" gd htree stamp sbase="" ssecs="" v="" cmp only line
  gd=$(git rev-parse --git-common-dir 2>/dev/null) && gd=$(cd "$gd" 2>/dev/null && pwd) || gd=""
  htree=$(tt_git rev-parse --verify --quiet "$head^{tree}" 2>/dev/null) || htree=""
  stamp="$gd/cc-cmds-check-push/$htree"
  if [ -z "$gd" ] || [ -z "$htree" ] || [ ! -f "$stamp" ]; then
    printf '%s: 도장: base=도장없음 CI base=%s 도장없음 · CI 에만 있는 절=도장없음\n' "$TT_PREFIX" "$base"
    return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      v=*) v="${line#v=}" ;;
      base=*) sbase="${line#base=}" ;;
      sections=*) ssecs="${line#sections=}" ;;
    esac
  done < "$stamp"
  if [ "$v" != 2 ]; then
    printf '%s: 도장: base=v1 CI base=%s v1 · CI 에만 있는 절=기록없음\n' "$TT_PREFIX" "$base"
    return 0
  fi
  if [ "$sbase" = "$base" ]; then cmp="같음"; else cmp="다름"; fi
  [ "$ssecs" != "없음" ] || ssecs=""
  only=$(tt_join "$(tt_missing_from "$secs" "$(printf '%s' "$ssecs" | tr ',' '\n')")")
  printf '%s: 도장: base=%s CI base=%s %s · CI 에만 있는 절=%s\n' "$TT_PREFIX" "$(tt_or_none "$sbase")" "$base" "$cmp" "$(tt_or_none "$only")"
}

tt_cli_repro() {
  local base="" head="" expect="" secs="" goals="" rc mrc hrc=0 verdict
  TT_PREFIX="test-tree repro"
  TT_SECVAR="--sections"
  TT_GOALVAR="--goals"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base) base="${2:-}"; shift 2 || { tt_cli_usage; return 2; } ;;
      --head) head="${2:-}"; shift 2 || { tt_cli_usage; return 2; } ;;
      --expect) expect="${2:-}"; shift 2 || { tt_cli_usage; return 2; } ;;
      --sections) secs="${2:-}"; shift 2 || { tt_cli_usage; return 2; } ;;
      --goals) goals="${2:-}"; shift 2 || { tt_cli_usage; return 2; } ;;
      *) tt_cli_usage; return 2 ;;
    esac
  done
  if ! tt_is_sha "$base" || ! tt_is_sha "$head" || ! tt_is_sha "$expect"; then
    printf 'test-tree repro: --base·--head·--expect 는 모두 40자 hex 여야 한다\n' >&2
    return 2
  fi
  if [ -z "$secs" ] && [ -z "$goals" ]; then
    printf 'test-tree repro: --sections 나 --goals 가 적어도 하나 있어야 한다\n' >&2
    return 2
  fi
  TT_HINT=""
  if ! tt_items_syntax "$secs" "절" || ! tt_items_syntax "$goals" "목표"; then
    printf '%s\n' "$TT_HINT" >&2
    return 2
  fi

  trap 'tt_cleanup' EXIT
  tt_clone || return 2
  tt_build "$base" "$head"
  rc=$?
  if [ "$rc" = 4 ]; then
    printf 'test-tree repro: 객체 없음 — %s 가 이 저장소에 없다. git fetch --no-tags --refmap= origin %s (게이트 --surface 읽기 --reach 협업) 로 받은 뒤 다시 돌린다\n' "$TT_MISSING_OBJ" "$TT_MISSING_OBJ" >&2
    printf 'test-tree repro: 닫힌 PR 의 head 는 refs/pull/<n>/head 로 광고되지만 merge ref 는 광고되지 않는다 — 그래서 repro 는 merge ref 를 받지 않고 base 와 head 로 트리를 만든다\n' >&2
    return 4
  fi
  [ "$rc" = 0 ] || { printf 'test-tree repro: 트리를 만들지 못했다\n' >&2; return 2; }
  if [ "$TT_OUTCOME" = "충돌" ]; then
    printf 'test-tree repro: 합침=충돌 %s — 합친 트리가 없어 아무것도 돌리지 않았다\n' "$(tt_or_none "$TT_CONFLICTS")"
    return 3
  fi
  if [ "$TT_TREE" != "$expect" ]; then
    printf 'test-tree repro: 트리 불일치 — 만든 트리 %s 가 --expect %s 와 다르다, 아무것도 돌리지 않았다\n' "$TT_TREE" "$expect" >&2
    return 5
  fi
  printf 'test-tree repro: 시험 트리 — 합침=%s base=%s base출처=지정 head=%s tree=%s 절=%s 목표=%s 절+베이스=없음 fetch=없음 대역=%s\n' \
    "$TT_OUTCOME" "$base" "$head" "$TT_TREE" "$(tt_or_none "$secs")" "$(tt_or_none "$goals")" "$(tt_doubles)"

  tt_check_items "$secs" "$goals"
  rc=$?
  if [ "$rc" != 0 ]; then
    printf '%s\n' "$TT_HINT" >&2
    return "$rc"
  fi
  tt_run_items "$TT_SECTIONS" "$TT_GOALS"
  mrc=$?

  if [ "$TT_OUTCOME" = "조상" ]; then
    if [ "$mrc" != 0 ]; then verdict="브랜치 결함"; else verdict="재현 불가"; fi
  else
    if ! tt_checkout "$head"; then
      printf 'test-tree repro: 판정 없음 — head 를 꺼낼 수 없다\n'
      return 6
    fi
    tt_head_filter "$secs" "$goals"
    rc=$?
    if [ "$rc" = 1 ]; then
      printf 'test-tree repro: 판정 없음 — head 트리에서 항목을 나열할 수 없다\n'
      return 6
    fi
    if [ "$rc" = 6 ]; then
      printf 'test-tree repro: 판정 없음 — head 에 남는 항목이 없다 (헤드에 없는 항목=%s)\n' "$(tt_or_none "$TT_DROPPED")"
      return 6
    fi
    printf 'test-tree repro: 헤드에 없는 항목=%s\n' "$(tt_or_none "$TT_DROPPED")"
    tt_run_items "$TT_KEEP_SECTIONS" "$TT_KEEP_GOALS"
    hrc=$?
    if [ "$mrc" = 0 ]; then
      verdict="재현 불가"
    elif [ "$hrc" = 0 ]; then
      verdict="트리 차이"
    else
      verdict="브랜치 결함"
    fi
  fi

  printf 'test-tree repro: 판정=%s\n' "$verdict"
  case "$verdict" in
    "트리 차이") tt_base_status_line "test-tree repro" "$base" ;;
    "재현 불가") printf 'test-tree repro: CI 에서 실패한 것은 잡의 목록 전체다 — 돌린 항목이 그 전부가 아니면 ci-base 가 찍은 목록 전체로 다시 돌린다\n' ;;
  esac
  tt_repro_stamp_line "$base" "$head" "$secs"
  return 0
}

# --- self-test ---------------------------------------------------------------

# What every case starts from: no git location, pipeline, check-push or make
# variable inherited from whoever ran the self-test.
tt_st_scrub() {
  local v
  for v in $(compgen -e); do
    case "$v" in
      GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_COMMON_DIR|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES|CC_PIPELINE_*|CHECK_PUSH_*|CC_TEST_TREE_*|CC_CHECK_PUSH_*|MAKEFLAGS|MFLAGS|MAKELEVEL) unset "$v" ;;
    esac
  done
  GIT_CONFIG_GLOBAL=/dev/null
  GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
}

# The self-test's own build, run as a separate process so a case can start it
# under a decoy GIT_DIR and an open stdin.
tt_st_probe() {
  tt_st_scrub
  cd "$1" || return 2
  tt_clone || return 2
  tt_build "$2" "$3" || { tt_cleanup; return 2; }
  printf '%s %s %s\n' "$TT_OUTCOME" "$TT_TREE" "$(tt_git log -1 --format=%s HEAD)"
  tt_cleanup
}

tt_self_test() {
  local passed=0 failed=0 T self out rc line W sa sb1 sb2 sm sh shb shn sx tm tb2 th snap1 snap2 log fh v rec stamps before
  ok()  { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
  bad() { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
  check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got「$2」 want「$3」"; fi; }
  has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "「$3」 없음: $2" ;; esac; }
  hasnt() { case "$2" in *"$3"*) bad "$1" "「$3」 있음: $2" ;; *) ok "$1" ;; esac; }
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  tt_st_scrub
  unset CLAUDE_X
  T=$(mktemp -d "${TMPDIR:-/tmp}/test-tree-selftest.XXXXXX") || return 1
  T=$(cd "$T" && pwd)
  mkdir -p "$T/tmp" "$T/bin"
  TMPDIR="$T/tmp"
  export TMPDIR
  sgit() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c init.defaultBranch=master "$@"; }

  # Doubles. Each logs its argv and any caller variable that leaked into it.
  sed "s|@T@|$T|g" > "$T/bin/gate" <<'EOF'
#!/usr/bin/env bash
printf 'argv:%s\n' "$*" >> "@T@/gate.log"
for v in $(compgen -e); do
  case "$v" in CC_PIPELINE_*|CLAUDE*|CC_TEST_TREE_*|CC_CHECK_PUSH_*|CHECK_PUSH_*) printf 'leak:%s\n' "$v" >> "@T@/gate.log" ;; esac
done
ids=$(sed -n 's/^# --- section: \([^ |]*\) |.*$/\1/p' scripts/test-gate.sh)
case "$1" in
  --list)
    [ ! -f "@T@/gate-list-fail" ] || exit 3
    for id in $ids; do printf '%s # t\n' "$id"; done ;;
  --sections)
    [ ! -f "@T@/break-alternates" ] || rm -f .git/objects/info/alternates
    rc=0
    for id in $ids; do
      case ",$2," in *",$id,"*) printf 'GATE-RUN %s\n' "$id"; bash "sections/$id.sh" || rc=1 ;; esac
    done
    exit "$rc" ;;
esac
EOF
  sed "s|@T@|$T|g" > "$T/bin/make" <<'EOF'
#!/usr/bin/env bash
printf 'argv:%s|MAKEFLAGS=%s|MFLAGS=%s|MAKELEVEL=%s\n' "$*" "${MAKEFLAGS-unset}" "${MFLAGS-unset}" "${MAKELEVEL-unset}" >> "@T@/make.log"
for v in $(compgen -e); do
  case "$v" in CC_PIPELINE_*|CLAUDE*|CC_TEST_TREE_*|CC_CHECK_PUSH_*|CHECK_PUSH_*) printf 'leak:%s\n' "$v" >> "@T@/make.log" ;; esac
done
if [ "$*" = "-s --no-print-directory print-rest-goals" ]; then
  [ -f goals.txt ] || exit 2
  cat goals.txt goals-m.txt 2>/dev/null
  exit 0
fi
printf 'MAKE-RUN %s\n' "$*"
rc=0
for g in "$@"; do
  case "$g" in -*) continue ;; esac
  f="goals.d/${g//\//_}.sh"
  if [ -f "$f" ]; then bash "$f" || rc=1; fi
done
exit "$rc"
EOF
  sed "s|@T@|$T|g" > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf 'argv:%s\n' "$*" >> "@T@/gh.log"
case "$*" in
  *" --json jobs "*) cat "@T@/gh-jobs" ;;
  *" --log"*)
    if [ -f "@T@/gh-log-fail" ]; then cat "@T@/gh-log-fail" >&2; exit 1; fi
    cat "@T@/gh-log" ;;
  "api "*) cat "@T@/gh-tree" ;;
  *) exit 9 ;;
esac
EOF
  chmod +x "$T/bin/gate" "$T/bin/make" "$T/bin/gh"

  # The fixture history. master: A - B1 - B2 - M, where B1 adds the goal list
  # and M adds section s2 (in front of s1) and goal gm. Branches: H and HB from
  # B1, HN (no goal list: an old head) and X (conflicts with B1) from A.
  W="$T/work"
  sgit init -q --bare "$T/origin.git"
  mkdir -p "$W/scripts" "$W/sections" "$W/goals.d"
  (
    cd "$W" || exit 1
    sgit init -q
    sgit remote add origin "$T/origin.git"
    printf '#!/usr/bin/env bash\n# fixture\n# --- section: s1 | group: g | covers: x | anchors: y ---\n# f1\n# f2\n# f3\n# f4\n# f5\n# f6\n# end\n' > scripts/test-gate.sh
    printf '[ "$(cat tracked.txt)" = orig ] && [ ! -e rows.txt ] && [ ! -e junk.log ]\n' > sections/s1.sh
    printf 'orig\n' > tracked.txt
    printf '*.log\n' > .gitignore
    sgit add -A && sgit commit -q -m A
    sgit branch -q a
    printf 'run/scripts/x.sh\ng1\ng2\n' > goals.txt
    printf 'b1\n' > base1.txt
    sgit add -A && sgit commit -q -m B1
    sgit branch -q b1
    printf 'b2\n' > base2.txt
    sgit add -A && sgit commit -q -m B2
    sgit branch -q b2
    printf '#!/usr/bin/env bash\n# fixture\n# --- section: s2 | group: g | covers: x | anchors: y ---\n# --- section: s1 | group: g | covers: x | anchors: y ---\n# f1\n# f2\n# f3\n# f4\n# f5\n# f6\n# end\n' > scripts/test-gate.sh
    printf 'printf "changed\\n" > tracked.txt\nprintf "r\\n" >> rows.txt\nprintf "x\\n" > junk.log\n' > sections/s2.sh
    printf 'gm\n' > goals-m.txt
    sgit add -A && sgit commit -q -m M
    sgit checkout -q -b h b1
    printf '#!/usr/bin/env bash\n# fixture\n# --- section: s1 | group: g | covers: x | anchors: y ---\n# f1\n# f2\n# f3\n# f4\n# f5\n# f6\n# end\n# --- section: h1 | group: g | covers: x | anchors: y ---\n' > scripts/test-gate.sh
    printf 'exit 0\n' > sections/h1.sh
    printf 'h\n' > h.txt
    sgit add -A && sgit commit -q -m H
    sgit checkout -q -b hb b1
    printf 'exit 1\n' > goals.d/g2.sh
    sgit add -A && sgit commit -q -m HB
    sgit checkout -q -b hn a
    printf 'hn\n' > hn.txt
    sgit add -A && sgit commit -q -m HN
    sgit checkout -q -b x a
    printf 'other\n' > base1.txt
    sgit add -A && sgit commit -q -m X
    sgit checkout -q h
    sgit push -q origin master h hb hn x
  ) > /dev/null 2>&1 || { bad "픽스처 준비" "git 실패"; rm -rf "$T"; return 1; }
  sa=$(cd "$W" && git rev-parse a)
  sb1=$(cd "$W" && git rev-parse b1)
  sb2=$(cd "$W" && git rev-parse b2)
  sm=$(cd "$W" && git rev-parse master)
  sh=$(cd "$W" && git rev-parse h)
  shb=$(cd "$W" && git rev-parse hb)
  shn=$(cd "$W" && git rev-parse hn)
  sx=$(cd "$W" && git rev-parse x)
  th=$(cd "$W" && git rev-parse "h^{tree}")
  tm=$(cd "$W" && git merge-tree --write-tree "$sm" "$sh")
  tb2=$(cd "$W" && git merge-tree --write-tree "$sb2" "$sh")
  : "$sa"

  # A caller snapshot: refs, HEAD, index and loose objects.
  snap() { (cd "$1" && git for-each-ref && git rev-parse HEAD && cksum < "$(git rev-parse --git-dir)/index" && git count-objects); }

  # --- F1 합침 -----------------------------------------------------------------
  snap1=$(snap "$W")
  out=$( (cd "$W" && tt_clone && tt_build "$sm" "$sh" && printf '%s %s %s\n' "$TT_OUTCOME" "$TT_TREE" "$(tt_git log -1 --format='%s %P' HEAD)"; rc=$?; tt_cleanup; exit $rc) )
  rc=$?
  check "F1 합침: 결과와 트리, 부모 순서 (base, head), 메시지 test-tree" "$rc $out" "0 합침 $tm test-tree $sm $sh"
  sgit clone -q "$T/origin.git" "$T/indep" > /dev/null 2>&1
  (cd "$T/indep" && sgit checkout -q --detach "$sm" && sgit merge -q --no-ff --no-edit "$sh") > /dev/null 2>&1
  check "F1 합침: 다른 복제본의 git merge --no-ff 와 같은 트리" "$(cd "$T/indep" && git rev-parse 'HEAD^{tree}')" "$tm"
  if [ "$tm" != "$th" ]; then ok "F1 합침: 트리가 head 트리와 다르다"; else bad "F1 합침: 트리가 head 트리와 다르다" "$tm"; fi
  snap2=$(snap "$W")
  check "F1 호출자의 ref·HEAD·인덱스·느슨한 객체가 그대로다" "$snap2" "$snap1"
  mkdir -p "$T/decoy"
  (cd "$T/decoy" && sgit init -q && printf 'd\n' > d && sgit add d && sgit commit -q -m d) > /dev/null 2>&1
  snap1=$(snap "$T/decoy")
  mkfifo "$T/fifo"
  exec 7<> "$T/fifo"
  out=$(GIT_DIR="$T/decoy/.git" GIT_WORK_TREE="$T/decoy" GIT_INDEX_FILE="$T/decoy/.git/index" bash "$self" --self-test-probe "$W" "$sm" "$sh" <&7 2>&1)
  rc=$?
  exec 7>&-
  rm -f "$T/fifo"
  check "F1 미끼 GIT_DIR 와 열린 표준 입력 아래에서도 합침이 끝난다" "$rc $out" "0 합침 $tm test-tree"
  check "F1 미끼 저장소의 ref·인덱스·객체가 그대로다" "$(snap "$T/decoy")" "$snap1"

  # --- F2 조상 / F3 충돌 / F4 없는 객체 ---------------------------------------
  out=$( (cd "$W" && tt_clone && tt_build "$sb1" "$sh" && printf '%s %s' "$TT_OUTCOME" "$TT_TREE"; rc=$?; tt_cleanup; exit $rc) )
  check "F2 조상: 트리가 head 트리와 같다" "$out" "조상 $th"
  : > "$T/gate.log"
  out=$( (cd "$W" && tt_clone && tt_build "$sm" "$sx" && printf '%s %s' "$TT_OUTCOME" "$TT_CONFLICTS"; rc=$?; tt_cleanup; exit $rc) )
  check "F3 충돌: 결과와 경로" "$out" "충돌 base1.txt"
  check "F3 충돌: 아무것도 돌리지 않는다" "$(cat "$T/gate.log")" ""
  out=$( (cd "$W" && tt_clone; tt_build 0123456789abcdef0123456789abcdef01234567 "$sh"; rc=$?; printf '%s %s' "$rc" "${TT_OUTCOME:-none}"; tt_cleanup) )
  check "F4 base 가 없으면 4 이고 충돌이 아니다" "$out" "4 none"
  out=$( (cd "$W" && tt_clone; tt_build "$sm" 0123456789abcdef0123456789abcdef01234567; rc=$?; printf '%s %s' "$rc" "${TT_OUTCOME:-none}"; tt_cleanup) )
  check "F4 head 가 없으면 4 이고 충돌이 아니다" "$out" "4 none"

  # --- F5 FETCH_HEAD ----------------------------------------------------------
  (cd "$W" && sgit fetch -q --no-tags --refmap= origin refs/heads/master) > /dev/null 2>&1
  out=$( (cd "$W" && tt_base_from_fetch_head master; rc=$?; printf '%s %s %s' "$rc" "$TT_BASE" "${TT_FETCH%%T*}") 2>&1)
  case "$out" in "0 $sm "20*) ok "F5 --refmap= fetch 의 신선한 줄을 받는다" ;; *) bad "F5 --refmap= fetch 의 신선한 줄을 받는다" "$out" ;; esac
  fh="$W/.git/FETCH_HEAD"
  touch -t 202001010000 "$fh"
  out=$( (cd "$W" && tt_base_from_fetch_head master; printf '%s' "$?") 2>&1)
  has "F5 나이를 먹은 FETCH_HEAD 는 4 이고 fetch 를 이름 댄다" "$out" "git fetch --no-tags --refmap= origin refs/heads/master"
  case "$out" in *4) ok "F5 오래됨 → 4" ;; *) bad "F5 오래됨 → 4" "$out" ;; esac
  printf '%s\t\tbranch '"'"'other'"'"' of %s\n' "$sm" "$T/origin.git" > "$fh"
  out=$( (cd "$W" && tt_base_from_fetch_head master > /dev/null 2>&1; printf '%s' "$?") )
  check "F5 다른 브랜치 → 4" "$out" "4"
  printf '%s\t\tbranch '"'"'master'"'"' of /elsewhere/origin.git\n' "$sm" > "$fh"
  out=$( (cd "$W" && tt_base_from_fetch_head master > /dev/null 2>&1; printf '%s' "$?") )
  check "F5 다른 URL → 4" "$out" "4"
  printf '%s\tnot-for-merge\tbranch '"'"'master'"'"' of %s/\n' "$sm" "$T/origin.git" > "$fh"
  out=$( (cd "$W" && tt_base_from_fetch_head master > /dev/null 2>&1; printf '%s %s' "$?" "$TT_BASE") )
  check "F5 not-for-merge 와 끝 / 를 받는다" "$out" "0 $sm"
  printf '%s\t\tbranch '"'"'h'"'"' of %s\n%s\tnot-for-merge\tbranch '"'"'master'"'"' of %s\n' "$sh" "$T/origin.git" "$sm" "$T/origin.git" > "$fh"
  out=$( (cd "$W" && tt_base_from_fetch_head master > /dev/null 2>&1; printf '%s %s' "$?" "$TT_BASE") )
  check "F5 원격 전체 fetch 꼴 여러 줄에서 master 줄을 받는다" "$out" "0 $sm"
  (cd "$W" && git remote set-url origin 'https://user:tok@host.invalid/o/r.git')
  printf '%s\t\tbranch '"'"'master'"'"' of https://host.invalid/o/r\n' "$sm" > "$fh"
  out=$( (cd "$W" && tt_base_from_fetch_head master; printf 'rc=%s %s' "$?" "$TT_BASE") 2>&1)
  check "F5 자격이 든 origin 과 자격 없는 줄을 같은 URL 로 받는다" "$out" "rc=0 $sm"
  printf '%s\t\tbranch '"'"'other'"'"' of https://host.invalid/o/r\n' "$sm" > "$fh"
  out=$( (cd "$W" && tt_base_from_fetch_head master; printf 'rc=%s' "$?") 2>&1)
  hasnt "F5 자격 문자열은 출력 어디에도 없다" "$out" "tok"
  (cd "$W" && git remote set-url origin "$T/origin.git")
  out=$( (cd "$W" && tt_base_from_fetch_head 'a..b' > /dev/null 2>&1; printf '%s' "$?") )
  check "F5 형식이 틀린 브랜치 이름 → 2" "$out" "2"

  # --- F6 항목 ----------------------------------------------------------------
  export CC_TEST_TREE_GATE="$T/bin/gate" CC_TEST_TREE_MAKE="$T/bin/make"
  items() {  # <secs> <goals> → "<rc>|<missing>|<hint>"
    (cd "$W" && tt_clone > /dev/null && tt_build "$sm" "$sh" && { tt_check_items "$1" "$2"; printf '%s|%s|%s' "$?" "$TT_MISSING" "$TT_HINT"; }; tt_cleanup)
  }
  : > "$T/gate.log"
  out=$(items s9 "")
  has "F6 모르는 절 → 1" "$out" "1|s9|test-tree: 모르는 절 s9"
  hasnt "F6 모르는 절에 게이트 대역이 --sections 로 불리지 않는다" "$(cat "$T/gate.log")" "--sections"
  out=$(items "" g9)
  has "F6 print-rest-goals 에 없는 목표 → 1" "$out" "1|g9|test-tree: 모르는 목표 g9"
  out=$(items "" scripts/x.sh)
  has "F6 scripts/x.sh 는 run/scripts/x.sh 를 이름 댄다" "$out" "1|scripts/x.sh|test-tree: 목표 scripts/x.sh 는 없다 — run/scripts/x.sh 를 뜻했다면 그 이름을 쓴다"
  out=$(items g1 "")
  has "F6 목표를 절로 주면 목표 쪽 이름을 댄다" "$out" "--goals 로 준다"
  out=$(items "" s1)
  has "F6 절을 목표로 주면 절 쪽 이름을 댄다" "$out" "--sections 로 준다"
  : > "$T/make.log"
  out=$(items "" -k)
  case "$out" in 2\|*) ok "F6 -k 목표 → 형식 오류" ;; 1\|*) ok "F6 -k 목표 → 모르는 항목" ;; *) bad "F6 -k 목표는 거절된다" "$out" ;; esac
  hasnt "F6 -k 목표에 make 대역이 목표로 불리지 않는다" "$(cat "$T/make.log")" "argv:--no-print-directory"
  for v in 'a b' 'x=y' 'a$b' 'a,,b' ',a' 'a,'; do
    out=$(items "$v" "")
    case "$out" in 2\|*) ok "F6 형식 오류 $(printf %q "$v") → 2" ;; *) bad "F6 형식 오류 $(printf %q "$v") → 2" "$out" ;; esac
  done
  : > "$T/gate.log"
  touch "$T/gate-list-fail"
  out=$(items s1 "")
  rm -f "$T/gate-list-fail"
  has "F6 --list 실패 → 1, 목록 불가" "$out" "1|s1|test-tree: 목록 불가 — 이 트리의 test-gate.sh 로 절을 나열할 수 없다"
  hasnt "F6 --list 실패에 --sections 를 부르지 않는다" "$(cat "$T/gate.log")" "--sections"
  : > "$T/gate.log"
  : > "$T/make.log"
  out=$(cd "$W" && CC_PIPELINE_RUN_ID=x CLAUDE_X=y CHECK_PUSH_SECTIONS=z MAKEFLAGS=-k MFLAGS=-k MAKELEVEL=3 bash -c '
    . "$1"; cd "$2" && tt_clone > /dev/null && tt_build "$3" "$4" && tt_check_items "h1,s1" "g2,g1" && printf "%s|%s\n" "$TT_SECTIONS" "$TT_GOALS" && tt_run_items "$TT_SECTIONS" "$TT_GOALS" > /dev/null; printf "rc=%s\n" "$?"; tt_cleanup' _ "$self" "$W" "$sm" "$sh")
  has "F6 절은 파일 순서로 정렬되고 둘 다 돈다" "$out" "s1,h1|g2,g1
rc=0"
  check "F6 --sections 는 한 번, 파일 순서" "$(grep -c -- '--sections' "$T/gate.log")|$(grep -- '--sections' "$T/gate.log")" "1|argv:--sections s1,h1"
  log=$(cat "$T/make.log")
  has "F6 목표는 make --no-print-directory g2 g1 한 번, 세 make 변수가 비었다" "$log" "argv:--no-print-directory g2 g1|MAKEFLAGS=|MFLAGS=|MAKELEVEL="
  hasnt "F6 게이트 대역과 make 대역에 호출자 변수가 새지 않는다" "$(cat "$T/gate.log" "$T/make.log")" "leak:"

  # --- F11 절+베이스 -----------------------------------------------------------
  : > "$T/gate.log"
  out=$( (cd "$W" && tt_clone && tt_build "$sm" "$sh" && tt_base_added_ids "$sm" "$sh" && printf '%s' "$TT_ADDED"; tt_cleanup) )
  check "F11 base 가 더한 절만 절+베이스 (head 의 h1 은 빠짐)" "$out" "s2"
  check "F11 절+베이스는 돌리지 않는다" "$(cat "$T/gate.log")" ""
  out=$( (cd "$W" && tt_clone && tt_build "$sb1" "$sh" && tt_base_added_ids "$sb1" "$sh" && printf '%s %s' "$TT_OUTCOME" "$TT_ADDED"; tt_cleanup) )
  check "F11 조상이면 head 가 절을 더했어도 없음" "$out" "조상 없음"

  # --- F7 / F8 / F10 repro ------------------------------------------------------
  repro() { (cd "$W" && bash "$self" repro "$@" 2>&1); }
  out=$(repro --base "$sb2" --head "$sh" --expect "$tb2" --sections s1)
  rc=$?
  has "F7 끝이 B 를 지나도 repro 는 merge(B, head) 를 만든다" "$rc $out" "tree=$tb2"
  if [ "$tb2" != "$tm" ]; then ok "F7 merge(B, head) 는 merge(끝, head) 와 다르다"; else bad "F7 merge(B, head) 는 merge(끝, head) 와 다르다" "$tb2"; fi
  : > "$T/gate.log"
  out=$(repro --base "$sb2" --head "$sh" --expect "$tm" --sections s1)
  rc=$?
  check "F7 --expect 불일치 → 5" "$rc" "5"
  check "F7 --expect 불일치에 아무것도 돌지 않는다" "$(cat "$T/gate.log")" ""

  out=$(repro --base "$sm" --head "$sh" --expect "$tm" --sections s2,s1 --goals gm)
  rc=$?
  check "F8 트리 차이: 종료 0" "$rc" "0"
  has "F8 트리 차이: 판정" "$out" "test-tree repro: 판정=트리 차이"
  has "F8 트리 차이: head 에 없는 절과 목표를 빼고 나열한다" "$out" "test-tree repro: 헤드에 없는 항목=s2,gm"
  has "F8 트리 차이: 거르지 않은 base 상태 읽기" "$out" "gh run list --repo Nharu/cc-cmds --commit $sm --json workflowName,conclusion,databaseId — 워크플로마다"
  rec="test-tree repro: 시험 트리 — 합침=합침 base=$sm base출처=지정 head=$sh tree=$tm 절=s2,s1 목표=gm 절+베이스=없음 fetch=없음 대역=CC_TEST_TREE_GATE,CC_TEST_TREE_MAKE"
  has "F8 기록 줄" "$out" "$rec"
  case "$out" in "$rec"*GATE-RUN*) ok "F8 기록 줄이 첫 실행보다 먼저 나오고 실패 뒤에도 남는다" ;; *) bad "F8 기록 줄이 첫 실행보다 먼저 나오고 실패 뒤에도 남는다" "$out" ;; esac
  out=$(repro --base "$sm" --head "$sh" --expect "$tm" --sections s1)
  has "F8 s1 만 → 재현 불가" "$out" "판정=재현 불가"
  has "F8 재현 불가는 목록 전체로 다시 돌리라고 안내한다" "$out" "ci-base 가 찍은 목록 전체로 다시 돌린다"
  out=$(repro --base "$sm" --head "$shb" --expect "$(cd "$W" && git merge-tree --write-tree "$sm" "$shb")" --goals g2)
  has "F8 head 쪽 결함 → 브랜치 결함" "$out" "판정=브랜치 결함"
  : > "$T/gate.log"
  out=$(repro --base "$sb1" --head "$sh" --expect "$th" --sections s1)
  check "F8 조상은 한 번만 돈다" "$(grep -c -- '--sections' "$T/gate.log")" "1"
  has "F8 조상 통과 → 재현 불가" "$out" "합침=조상"
  out=$(repro --base "$sm" --head "$shn" --expect "$(cd "$W" && git merge-tree --write-tree "$sm" "$shn")" --sections s2,s1 --goals g1)
  rc=$?
  check "F8 head 의 print-rest-goals 실패 → 6" "$rc" "6"
  has "F8 head 목록 불가 문면" "$out" "판정 없음 — head 트리에서 항목을 나열할 수 없다"
  hasnt "F8 head 목록 불가에 트리 차이를 찍지 않는다" "$out" "트리 차이"
  : > "$T/make.log"
  out=$(repro --base "$sm" --head "$shn" --expect "$(cd "$W" && git merge-tree --write-tree "$sm" "$shn")" --sections s2,s1)
  rc=$?
  check "F8 --sections 만이면 print-rest-goals 없는 head 에서도 판정한다" "$rc" "0"
  has "F8 --sections 만인 repro 의 판정" "$out" "판정=트리 차이"
  hasnt "F8 --sections 만이면 head 의 print-rest-goals 를 부르지 않는다" "$(cat "$T/make.log")" "print-rest-goals"
  out=$(repro --base "$sm" --head "$sh" --expect "$tm" --sections s2 --goals gm)
  rc=$?
  check "F8 head 에 남는 항목이 없으면 6" "$rc" "6"
  has "F8 남는 항목 없음 문면" "$out" "판정 없음 — head 에 남는 항목이 없다 (헤드에 없는 항목=s2,gm)"
  touch "$T/break-alternates"
  out=$(repro --base "$sm" --head "$sh" --expect "$tm" --sections s2,s1)
  rc=$?
  rm -f "$T/break-alternates"
  check "F8 head 를 꺼낼 수 없으면 6" "$rc" "6"
  has "F8 꺼내기 실패 문면" "$out" "판정 없음 — head 를 꺼낼 수 없다"
  hasnt "F8 꺼내기 실패에 트리 차이를 찍지 않는다" "$out" "트리 차이"
  out=$(repro --base "$sm" --head "$sx" --expect "$tm" --sections s1)
  check "repro 충돌 → 3" "$?" "3"
  out=$(repro --base 0123456789abcdef0123456789abcdef01234567 --head "$sh" --expect "$tm" --sections s1)
  rc=$?
  check "repro 없는 객체 → 4" "$rc" "4"
  has "repro 없는 객체는 --refmap= fetch 를 이름 댄다" "$out" "git fetch --no-tags --refmap= origin 0123456789abcdef0123456789abcdef01234567"
  out=$(repro --base "$sm" --head "$sh" --expect "$tm")
  check "repro 항목이 없으면 2" "$?" "2"
  out=$(repro --base "${sm%?}" --head "$sh" --expect "$tm" --sections s1)
  check "repro 짧은 sha → 2" "$?" "2"
  out=$(repro --base "$sm" --head "$sh" --expect "$tm" --sections s9)
  check "repro 모르는 항목 → 1" "$?" "1"

  stamps="$W/.git/cc-cmds-check-push"
  mkdir -p "$stamps"
  printf 'v=2\ncommit=%s\nat=t\nbash=x\n합침=합침\nbase=%s\nbase출처=FETCH_HEAD\nfetch=t\ntested_tree=%s\nsections=s1\ngoals=없음\n절+베이스=없음\n충돌경로=없음\n대역=없음\n' "$sh" "$sm" "$tm" > "$stamps/$th"
  out=$(repro --base "$sm" --head "$sh" --expect "$tm" --sections s2,s1)
  has "F10 같은 base 와 CI 에만 있는 절" "$out" "test-tree repro: 도장: base=$sm CI base=$sm 같음 · CI 에만 있는 절=s2"
  out=$(repro --base "$sb2" --head "$sh" --expect "$tb2" --sections s1)
  has "F10 다른 base" "$out" "도장: base=$sm CI base=$sb2 다름 · CI 에만 있는 절=없음"
  printf 'commit=%s\nat=t\n' "$sh" > "$stamps/$th"
  out=$(repro --base "$sm" --head "$sh" --expect "$tm" --sections s2,s1)
  has "F10 v1 도장" "$out" "도장: base=v1 CI base=$sm v1 · CI 에만 있는 절=기록없음"
  rm -f "$stamps/$th"
  out=$(repro --base "$sm" --head "$sh" --expect "$tm" --sections s2,s1)
  has "F10 도장 없음" "$out" "도장: base=도장없음 CI base=$sm 도장없음 · CI 에만 있는 절=도장없음"
  unset CC_TEST_TREE_GATE CC_TEST_TREE_MAKE

  # --- F9 / F24 / F25 ci-base ---------------------------------------------------
  local mg="5959cca9b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6" hd="fce24f1dae7d48ecdf8a406d69b2f735c6da55c0" bs="a2514ee3c2981eeedadc4f5c3cf5f1703110cf4e" tr="94ec407d0a1b2c3d4e5f60718293a4b5c6d7e8f9"
  local G=$'gate-shards (11)\tRun shard 11\t' R=$'rest-tests (1)\tRun rest shard 1\t'
  cib() { (cd "$T/cwd" && CC_TEST_TREE_GH="$T/bin/gh" bash "$self" ci-base --run "${CIB_RUN:-39287256162}" --repo Nharu/cc-cmds "$@" 2>&1); }
  mkdir -p "$T/cwd"

  # F9(i): lines copied verbatim from a real gate shard log — run 39695324829,
  # job 119551256091 「gate-shards (9)」, PR 1385 — with @TAB@ standing for the
  # TAB that separates the three fields. The block is cut after three id lines
  # and closed by the first line that follows the real block.
  local gmg="5c6e3076812d4dad5a2728079105096e6f4580ab" ghd="bbe34da5141e0e17f19a61a8d0e2105b2d6c3e75" gbs="247cfe22693f32a8f27b711722db4a5a11e83e75" gtr="15b61fcbb13c113a56d5c25969df971f29d0a541"
  printf '%s\n' "$gtr" > "$T/gh-tree"
  printf '119551255926\tgate-shards (10)\tsuccess\n119551256091\tgate-shards (9)\tfailure\n' > "$T/gh-jobs"
  while IFS= read -r line; do printf '%s\n' "${line//@TAB@/$'\t'}"; done > "$T/gh-log" <<'EOF'
gate-shards (9)@TAB@UNKNOWN STEP@TAB@2026-10-21T23:44:33.8482210Z ##[group]Fetching the repository
gate-shards (9)@TAB@UNKNOWN STEP@TAB@2026-10-21T23:44:33.8487894Z [command]/usr/bin/git -c protocol.version=2 fetch --no-tags --prune --no-recurse-submodules --depth=1 origin +5c6e3076812d4dad5a2728079105096e6f4580ab:refs/remotes/pull/1385/merge
gate-shards (9)@TAB@UNKNOWN STEP@TAB@2026-10-21T23:44:34.8195282Z  * [new ref]         5c6e3076812d4dad5a2728079105096e6f4580ab -> pull/1385/merge
gate-shards (9)@TAB@UNKNOWN STEP@TAB@2026-10-21T23:44:34.8320896Z [command]/usr/bin/git checkout --progress --force refs/remotes/pull/1385/merge
gate-shards (9)@TAB@UNKNOWN STEP@TAB@2026-10-21T23:44:35.0079811Z HEAD is now at 5c6e307 Merge bbe34da5141e0e17f19a61a8d0e2105b2d6c3e75 into 247cfe22693f32a8f27b711722db4a5a11e83e75
gate-shards (9)@TAB@UNKNOWN STEP@TAB@2026-10-21T23:44:35.6530655Z ##[group]Run make gate-shard SHARD=9 GATE_TABLE="$RUNNER_TEMP/plan/table.tsv" GATE_TIMING_OUT="$RUNNER_TEMP/timing-9.tsv"
gate-shards (9)@TAB@UNKNOWN STEP@TAB@2026-10-21T23:44:37.1854713Z test-gate: 좁힌 실행 — 절 31개, 4899줄
gate-shards (9)@TAB@UNKNOWN STEP@TAB@2026-10-21T23:44:37.1937406Z test-gate:   id=8 group=base 줄 6099-6202 「# 8. Review-before-merge, and its five staleness grades」
gate-shards (9)@TAB@UNKNOWN STEP@TAB@2026-10-21T23:44:37.1994507Z test-gate:   id=9 group=base 줄 6900-6981 「# 9. The un-disableable rules ignore the manifest's rule settings」
gate-shards (9)@TAB@UNKNOWN STEP@TAB@2026-10-21T23:44:37.2051679Z test-gate:   id=10 group=base 줄 6982-7013 「# 10. The ledger the gate writes — chained, capped, and its own rows」
gate-shards (9)@TAB@UNKNOWN STEP@TAB@2026-10-21T23:44:41.6189930Z PASS: 구속 다이제스트가 있는 매니페스트가 통과한다
EOF
  : > "$T/gh.log"
  before=$(ls -A "$T/tmp" "$T/cwd")
  out=$(CIB_RUN=39695324829 cib)
  rc=$?
  check "F9(i) 축자 gate 샤드 발췌 → 세 줄 출력과 종료 0, 로그 순서의 id" "$rc
$out" "0
ci-base: run=39695324829 job=119551256091 base=$gbs head=$ghd merge=$gmg tree=$gtr
ci-base: sections=8,9,10 goals=없음
bash scripts/test-tree.sh repro --base $gbs --head $ghd --expect $gtr --sections 8,9,10"
  check "F9(i) 축자 발췌에서 TMPDIR 와 현재 디렉터리에 파일이 생기지 않는다" "$(ls -A "$T/tmp" "$T/cwd")" "$before"
  check "F9(i) 축자 발췌의 tt_ci_parse 를 /bin/bash 로" "$(/bin/bash -c '. "$1"; L=$(cat "$2"); tt_ci_parse L; printf "%s|%s|%s|%s|%s" "$?" "$TT_CI_MERGE" "$TT_CI_BASE" "$TT_CI_SECTIONS" "$TT_CI_GOALS"' _ "$self" "$T/gh-log")" "0|$gmg|$gbs|8,9,10|"

  # F24: the real prefix shape with decoys in every field but the message.
  printf '%s\n' "$tr" > "$T/gh-tree"
  printf '11\tgate-shards (11)\tfailure\n12\tgate-shards (12)\tsuccess\n' > "$T/gh-jobs"
  {
    printf '%s2026-10-19T16:30:00.0000000Z /usr/bin/git -c protocol.version=2 fetch --no-tags --prune --no-recurse-submodules --depth=1 origin +%s:refs/remotes/pull/1360/merge\n' "$G" "$mg"
    printf '%s2026-10-19T16:30:01.0000000Z HEAD is now at 5959cca Merge %s into %s\n' "$G" "$hd" "$bs"
    printf 'gate-shard x\tRun shard 11\t2026-10-19T16:30:02.0000000Z 준비\n'
    printf 'test-gate:   id=zz\tRun shard 11\t2026-10-19T16:30:02.0000000Z 다른 줄\n'
    printf 'gate-shards (11)\trest shard 9/9: decoy\t2026-10-19T16:30:02.0000000Z 미끼\n'
    printf 'gate-shards (11)\tUNKNOWN STEP\t2026-10-19T16:30:02.0000000Z bash scripts/test-gate.sh --sections 0a\n'
    printf '%s2026-10-19T16:30:03.0000000Z test-gate: 좁힌 실행 — 절 3개, 120줄\n' "$G"
    printf '%s2026-10-19T16:30:03.0000000Z test-gate:   id=38-8 group=g 줄 10-40 「t」\n' "$G"
    printf '%s2026-10-19T16:30:03.0000000Z test-gate:   id=0a group=g 줄 50-90 「t」\n' "$G"
    printf '%s2026-10-19T16:30:03.0000000Z test-gate:   id=12b group=g 줄 95-130 「t」\n' "$G"
    printf '%s2026-10-19T16:30:04.0000000Z PASS: something test-gate said\n' "$G"
    printf '%s2026-10-19T16:30:05.0000000Z test-gate: 좁힌 실행 — 절 1개, 9줄\n' "$G"
    printf '%s2026-10-19T16:30:05.0000000Z test-gate:   id=99 group=g 줄 1-9 「t」\n' "$G"
  } > "$T/gh-log"
  : > "$T/gh.log"
  before=$(ls -A "$T/tmp" "$T/cwd")
  out=$(cib)
  rc=$?
  check "F24 미끼가 든 gate 샤드 발췌 → 세 줄 출력과 종료 0, 첫 id 블록만" "$rc
$out" "0
ci-base: run=39287256162 job=11 base=$bs head=$hd merge=$mg tree=$tr
ci-base: sections=38-8,0a,12b goals=없음
bash scripts/test-tree.sh repro --base $bs --head $hd --expect $tr --sections 38-8,0a,12b"
  check "F9(vi) TMPDIR 와 현재 디렉터리에 파일이 생기지 않는다" "$(ls -A "$T/tmp" "$T/cwd")" "$before"
  log=$(TT_X="$(cat "$T/gh-log")"; tt_ci_parse TT_X; printf '%s|%s|%s' "$?" "$TT_CI_SECTIONS" "$TT_CI_GOALS")
  check "F24 /bin/bash 에서도 미끼 줄을 읽지 않는다" "$(/bin/bash -c '. "$1"; L=$(cat "$2"); tt_ci_parse L; printf "%s|%s|%s" "$?" "$TT_CI_SECTIONS" "$TT_CI_GOALS"' _ "$self" "$T/gh-log")" "0|38-8,0a,12b|"
  check "F24 같은 발췌의 tt_ci_parse" "$log" "0|38-8,0a,12b|"

  printf '21\trest-tests (1)\tfailure\n' > "$T/gh-jobs"
  {
    printf '%s2026-10-19T16:30:00.0000000Z /usr/bin/git -c protocol.version=2 fetch --no-tags --prune --no-recurse-submodules --depth=1 origin +%s:refs/remotes/pull/1360/merge\n' "$R" "$mg"
    printf '%s2026-10-19T16:30:01.0000000Z HEAD is now at 5959cca Merge fce24f1dae7d48ecdf8a406d69b2f735c6da55c0 into a2514ee3c2981eeedadc4f5c3cf5f1703110cf4e\n' "$R"
    printf '%s2026-10-19T16:39:58.1000000Z rest-shard: 미측정 목표 33개 (무게 2 으로 적재) — run/scripts/test-a.sh run/scripts/test-b.sh\n' "$R"
    printf '%s2026-10-19T16:39:59.6110449Z rest shard 1/3: run/scripts/test-stage-supervisor.sh run/scripts/test-run-issue-filing.sh\n' "$R"
  } > "$T/gh-log"
  out=$(cib)
  rc=$?
  check "F9(ii)(iii) rest 샤드 발췌 → --goals 만 있는 repro 줄, 바이트까지 같다" "$rc
$out" "0
ci-base: run=39287256162 job=21 base=$bs head=$hd merge=$mg tree=$tr
ci-base: sections=없음 goals=run/scripts/test-stage-supervisor.sh,run/scripts/test-run-issue-filing.sh
bash scripts/test-tree.sh repro --base $bs --head $hd --expect $tr --goals run/scripts/test-stage-supervisor.sh,run/scripts/test-run-issue-filing.sh"

  printf '%s2026-10-19T16:39:59.6110449Z rest shard 1/3: g1\n' "$R" > "$T/gh-log"
  out=$(cib)
  check "F9(iv) 체크아웃 줄 없음 → 1" "$?" "1"
  printf '11\ta\tfailure\n12\tb\tfailure\n' > "$T/gh-jobs"
  out=$(cib)
  rc=$?
  check "F9(v) 실패한 잡 둘 → 2" "$rc" "2"
  has "F9(v) 실패한 잡을 나열한다" "$out" "job=12 「b」"
  printf '11\ta\tsuccess\n' > "$T/gh-jobs"
  out=$(cib)
  check "F9(v) 실패한 잡 0 → 2" "$?" "2"

  printf '11\tgate-shards (11)\tfailure\n' > "$T/gh-jobs"
  {
    printf '%s2026-10-19T16:30:00.0000000Z fetch origin +%s:refs/remotes/pull/1360/merge\n' "$G" "$mg"
    printf '%s2026-10-19T16:30:01.0000000Z HEAD is now at 5959cca Merge %s into %s\n' "$G" "$hd" "$bs"
    printf '%s2026-10-19T16:30:03.0000000Z test-gate: 좁힌 실행 — 절 1개, 9줄\n' "$G"
    printf '%s2026-10-19T16:30:03.0000000Z test-gate:   id=$(touch${IFS}x) group=g 줄 1-9 「t」\n' "$G"
  } > "$T/gh-log"
  before=$(ls -A "$T/tmp" "$T/cwd")
  out=$(cib)
  rc=$?
  check "F9(vii) 형식이 아닌 id → 2" "$rc" "2"
  hasnt "F9(vii) repro 줄을 찍지 않는다" "$out" "bash scripts/test-tree.sh repro"
  check "F9(vii) 파일이 생기지 않는다" "$(ls -A "$T/tmp" "$T/cwd")" "$before"
  {
    printf '%s2026-10-19T16:30:00.0000000Z fetch origin +%s:refs/remotes/pull/1360/merge\n' "$G" "$mg"
    printf '%s2026-10-19T16:30:01.0000000Z HEAD is now at 5959cca Merge %s into %s\n' "$G" "${hd%?}" "$bs"
    printf '%s2026-10-19T16:30:03.0000000Z test-gate: 좁힌 실행 — 절 1개, 9줄\n' "$G"
    printf '%s2026-10-19T16:30:03.0000000Z test-gate:   id=0a group=g 줄 1-9 「t」\n' "$G"
  } > "$T/gh-log"
  out=$(cib)
  rc=$?
  check "F9(vii) 39자 head → 2" "$rc" "2"
  hasnt "F9(vii) 39자 head 에 repro 줄이 없다" "$out" "bash scripts/test-tree.sh repro"

  {
    printf '%s2026-10-19T16:30:00.0000000Z fetch origin +%s:refs/remotes/pull/1360/merge\n' "$G" "$mg"
    printf '%s2026-10-19T16:30:01.0000000Z HEAD is now at 5959cca Merge %s into %s\n' "$G" "$hd" "$bs"
    printf '%s2026-10-19T16:30:03.0000000Z make lint\n' "$G"
  } > "$T/gh-log"
  out=$(cib)
  rc=$?
  check "F25 목록 줄 없음 → 3, 첫 줄과 목록 없음 줄" "$rc
$out" "3
ci-base: run=39287256162 job=11 base=$bs head=$hd merge=$mg tree=$tr
ci-base: 목록 없음 — job=11 「gate-shards (11)」 의 로그에 절 목록도 목표 목록도 없다"
  printf '31\tlint-and-readme\tsuccess\n11\tgate-shards (11)\tfailure\n' > "$T/gh-jobs"
  out=$(cib --job 31)
  rc=$?
  check "F25 --job 이 lint-and-readme 꼴 잡이면 3" "$rc
$out" "3
ci-base: run=39287256162 job=31 base=$bs head=$hd merge=$mg tree=$tr
ci-base: 목록 없음 — job=31 「lint-and-readme」 의 로그에 절 목록도 목표 목록도 없다"
  printf '21\trest-tests (3)\tfailure\n' > "$T/gh-jobs"
  {
    printf '%s2026-10-19T16:30:00.0000000Z fetch origin +%s:refs/remotes/pull/1360/merge\n' "$R" "$mg"
    printf '%s2026-10-19T16:30:01.0000000Z HEAD is now at 5959cca Merge %s into %s\n' "$R" "$hd" "$bs"
    printf '%s2026-10-19T16:30:03.0000000Z rest shard 3/3: 배정된 목표가 없습니다\n' "$R"
  } > "$T/gh-log"
  out=$(cib)
  rc=$?
  check "F25 배정된 목표가 없습니다 → 빈 목록, 두 줄과 목록 없음, 종료 3" "$rc
$out" "3
ci-base: run=39287256162 job=21 base=$bs head=$hd merge=$mg tree=$tr
ci-base: sections=없음 goals=없음
ci-base: 목록 없음 — job=21 「rest-tests (3)」 의 로그에 절 목록도 목표 목록도 없다"
  printf '41\tlint-and-test-macos\tfailure\n' > "$T/gh-jobs"
  {
    printf '%s2026-10-19T16:30:00.0000000Z fetch origin +%s:refs/remotes/pull/1360/merge\n' "$G" "$mg"
    printf '%s2026-10-19T16:30:01.0000000Z HEAD is now at 5959cca Merge %s into %s\n' "$G" "$hd" "$bs"
    printf '%s2026-10-19T16:30:03.0000000Z test-gate: 좁힌 실행 — 절 1개, 9줄\n' "$G"
    printf '%s2026-10-19T16:30:03.0000000Z test-gate:   id=0a group=g 줄 1-9 「t」\n' "$G"
  } > "$T/gh-log"
  out=$(cib)
  rc=$?
  case "$rc|$out" in
    "3|ci-base: 목록 없음 — job=41 「lint-and-test-macos」"*) ok "F25 lint-and-test-macos → 3, 목록 없음 줄만" ;;
    *) bad "F25 lint-and-test-macos → 3, 목록 없음 줄만" "$rc|$out" ;;
  esac
  hasnt "F25 lint-and-test-macos 에 repro 줄이 없다" "$out" "repro"

  # A run still in progress: gh refuses the log of even a finished job with one
  # line and exit 1, so ci-base ends at the log read without a value line.
  printf '11\tgate-shards (11)\tfailure\n' > "$T/gh-jobs"
  printf 'run 39287256162 is still in progress; logs will be available when it is complete\n' > "$T/gh-log-fail"
  out=$(cib)
  rc=$?
  check "F9 진행 중인 런의 로그 거절 → 2" "$rc" "2"
  hasnt "F9 진행 중인 런에 ci-base: run= 줄이 없다" "$out" "ci-base: run="
  hasnt "F9 진행 중인 런에 repro 줄이 없다" "$out" "bash scripts/test-tree.sh repro"
  rm -f "$T/gh-log-fail"

  # --- F28 repro side ---------------------------------------------------------
  out=$(find "$T/tmp" -maxdepth 1 -name 'cc-test-tree.*' | wc -l | tr -d ' ')
  check "F28 repro(판정, 5, 6)와 라이브러리 뒤 TMPDIR 에 cc-test-tree.* 가 없다" "$out" "0"

  rm -rf "$T"
  printf 'test-tree self-test: %d passed, %d failed\n' "$passed" "$failed"
  # A floor on the count, so a refactor that silently skips cases cannot pass.
  if [ "$passed" -lt 106 ]; then
    printf 'test-tree self-test: 통과 수 %d 가 하한 106 에 못 미칩니다\n' "$passed" >&2
    return 1
  fi
  [ "$failed" = "0" ]
}

# --- main --------------------------------------------------------------------

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  case "${1:-}" in
    ci-base) shift; tt_cli_ci_base "$@"; exit $? ;;
    repro) shift; tt_cli_repro "$@"; exit $? ;;
    --self-test) tt_self_test; exit $? ;;
    --self-test-probe) shift; tt_st_probe "$@"; exit $? ;;
    *) tt_cli_usage; exit 2 ;;
  esac
fi
