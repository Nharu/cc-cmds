#!/usr/bin/env bash
# Check the committed tree once before push, and stamp it when it passes.
#
# WHAT IS CHECKED IS THE COMMIT, NOT THE WORKING TREE. `run` clones the
# repository's own object store into a temporary directory (scripts/test-tree.sh
# does the cloning and the tree building), checks a commit out detached there
# and runs the repository-wide local checks in that copy: `make lint`, `make
# readme` followed by a README freshness diff, and `make check-cheap`, then the
# sections and goals it was given. An uncommitted edit in the working tree is
# neither checked nor pushed, so it can neither rescue nor sink the result;
# `run` only warns about it.
#
# WHICH COMMIT. CI tests the merge of the head into the base branch, not the
# head. In an unattended run (CC_PIPELINE_RUN_ID set) `run` therefore tests that
# merge, with the base read from the FETCH_HEAD a fetch in this worktree wrote
# in the last ten minutes; CHECK_PUSH_BASE names the base instead. Otherwise it
# tests the head, as it always did, and records `합침=안함`.
#
# THE STAMP IS KEYED ON THE TREE, NOT THE COMMIT. A commit that only rewrites
# the message keeps the tree, and the same tree has already passed. Stamps live
# under the common git directory, so every worktree of the repository sees the
# same ones, and nothing is committed. A merged run deletes the stamp of its key
# before it starts, so a tree that passed on an older base and fails on the new
# one is left with none. A head run never replaces a merged stamp.
#
# A PASS IS REUSED ONLY WHEN ITS INPUTS ARE PROVEN THE SAME. check-cheap and
# every goal of the job pool run in a checkout of their own and leave a record
# of the tracked files they read (scripts/test-reuse.sh); a later run whose
# tree gives those files the same contents, under the same doubles and tools,
# within 24 hours, skips the item and says so. An item that called git on its
# checkout read the whole tree and is reused only on the same tree, input
# commit and base, unless its only git calls were location queries
# (`git rev-parse --show-toplevel` and its kin) and reads of objects named by
# full 40-digit ids: that pass is reused across a new HEAD and a new base while
# each of those ids is present or absent as it was. Sections do the same per lane:
# a lane that passed records the files it read and the digest of the cut it
# ran, and a later run skips the sections of every record whose files and cut
# are unchanged, then cuts and runs only the rest. `items` runs the goals,
# the sections and check-cheap only for those records, and leaves every stamp
# alone. A release commit on top of a recorded pass does not void it: when
# the only files that differ are CHANGELOG.md, grown by an entry inserted on
# top, and plugin.json, changed in its version line alone, the record's input
# commit is an ancestor of HEAD and the base is the same, the pass is reused
# and its reuse line ends in `릴리스 차이` (scripts/test-reuse.sh states the
# rule in full).
#
# THE GOALS ARE THE NAMED ONES PLUS THE ONES THE CHANGE REACHES. Before the
# items are checked, `run` and `items` take the change — the head against its
# merge-base with the base; in head mode, with refs/remotes/origin/<base
# branch>, else refs/heads/<base branch> — and ask scripts/rest-readers.sh,
# in the tested tree, which REST goals read a changed file. The goals that run
# are CHECK_PUSH_GOALS in the order given, then each derived goal not named,
# in `print-rest-goals` order. A line `check-push: 유도 목표 — …` says what was
# derived and a line `check-push: 유도 근거 없는 변경 파일 …` lists the changed
# files no goal reads; the stamp keeps `유도목표=` and `유도없음=`. A change of
# CHANGELOG.md or plugins/cc-cmds/.claude-plugin/plugin.json that has the shape
# of a release commit (scripts/test-reuse.sh's per-path check,
# tr_release_path_in) is left out of what rest-readers.sh reads, whatever else
# the change holds: a line `check-push: 릴리스 차이로 유도에서 뺀 변경 파일 …`
# names those paths and the stamp keeps them in `유도릴리스=`; a path the check
# cannot judge stays in. The changed-file count still counts every path. With
# neither base ref in head mode nothing is derived and the line and the stamp
# say 판정불가. A derivation that cannot be computed (a git or make step
# failed) ends 1 before any item runs, with `check-push: 유도 실패 — <step>`
# and no stamp.
#
# Usage:
#   bash scripts/check-push.sh run         check in a clean clone, stamp on pass
#   bash scripts/check-push.sh items       run the goals, the sections and
#                                          check-cheap the same way to record
#                                          their passes; no stamp
#   bash scripts/check-push.sh verify      0 when HEAD's tree carries a stamp
#   bash scripts/check-push.sh --self-test
#
#   CHECK_PUSH_BASE         base commit to merge with (interactive use; an
#                           unattended verify refuses the stamp it leaves)
#   CHECK_PUSH_BASE_BRANCH  branch whose FETCH_HEAD line is the base (default
#                           master)
#   CHECK_PUSH_SECTIONS     test-gate section ids to run, comma-separated
#   CHECK_PUSH_GOALS        REST goals to run (`make -s print-rest-goals`),
#                           comma-separated
#   CHECK_PUSH_JOBS         how many of the section lanes and goal jobs run at
#                           once (default 4; 1 runs the sections in one
#                           test-gate call and the goals in one make, in turn,
#                           and neither is recorded nor reused)
#   CHECK_PUSH_REUSE        0 turns the reuse of recorded passes off: run
#                           neither judges nor records and stamps 재사용=꺼짐,
#                           items refuses with 2 (default 1)
#   CC_TEST_SLOTS          host-wide test slots the runs of this host share
#                           (scripts/test-slots.sh): every step and job waits
#                           for as many as its weight before it starts; a
#                           positive whole number is that many, auto is
#                           max(4, CPUs), and 0 turns them off. Unset or
#                           empty, an unattended run (CC_PIPELINE_RUN_ID set)
#                           takes the default in scripts/test-slots.sh and any
#                           other run is off. The stamp's 자리대기= is the
#                           seconds waited
#   CC_TEST_SLOTS_DIR       the slot store (default: cc-cmds/test-slots under
#                           ${XDG_STATE_HOME:-$HOME/.local/state})
#   CHECK_PUSH_BUDGET_SECS  the time budget in seconds, counted from the start:
#                           past it no serial step and no job starts, the
#                           running jobs are stopped and the run ends 미완
#                           (5). 0 turns it off; unset or empty, an
#                           unattended run takes 6600 and any other run is
#                           off. With CHECK_PUSH_JOBS 1 it reaches only the
#                           serial bundle
#   CHECK_PUSH_FAIL_FAST    1 stops the job pool at its first failure, 0 runs
#                           every job to its end. Unset or empty, an
#                           unattended run is 1 and any other run 0; items
#                           is always 0
#   CC_CHECK_PUSH_STOP_GRACE  seconds a stopped job gets between TERM and
#                           KILL (default 60)
#   CC_CHECK_PUSH_MAKE      the make for lint, readme and check-cheap (default
#                           make); the self-test swaps in doubles through it,
#                           as it does through CC_TEST_TREE_GATE,
#                           CC_TEST_TREE_SHARD, CC_TEST_TREE_MAKE and
#                           CC_TEST_TREE_GH
#
# A RUN CUT BY ITS BUDGET IS TAKEN UP AGAIN, NOT STARTED OVER. An unattended
# merged run with its base from FETCH_HEAD keeps a record per head commit
# under the common git directory (cc-cmds-check-push-resume/<commit>): the
# base it tested, when the first attempt started, the attempt count and how
# often the budget cut each goal. The next attempt on the same head within six
# hours keeps that base when it is an ancestor of the base just fetched, so
# the passes the cut run recorded are reused, and stamps `base출처=이어감`
# with the fetched base in `fetch베이스=`. A goal the budget cut twice is left
# to the pull request's rest-tests when the tested tree's lint.yml runs them
# for a path this head changed (`CI몫=` in the stamp). A stamp removes the
# record; a failure leaves it.
#
# A HEAVY DERIVED GOAL IS LEFT TO CI FROM THE FIRST ATTEMPT when the tested
# tree's scripts/check-push-ci.tsv lists it, the run is unattended, the goal
# came in by derivation and CHECK_PUSH_GOALS does not name it, lint.yml runs
# the REST goals for this head, and the change holds neither the goal's entry
# script nor one of its direct targets nor the list itself. Whatever of this
# cannot be decided runs the goal here. Each such goal gets a `check-push: CI 몫
# — <goal> (유도로만 들어왔고 …)` line and joins `CI몫=` in the stamp. To run
# one here, name it in CHECK_PUSH_GOALS. items leaves nothing to CI.
#
# WHAT FAILED LAST STARTS FIRST. run and items keep the sections and goals that
# failed in cc-cmds-last-failed.tsv under this worktree's own git directory,
# and the next run's job pool starts those first (scripts/test-tree.sh).
#
# Exit codes: 0 passed / stamped, 1 a check failed or no stamp, 2 usage, a
# base that is not a commit, or an unattended run whose head changed
# plugins/cc-cmds/orchestrator/gate.sh against its merge-base with the base
# while CHECK_PUSH_SECTIONS is empty (refused before the clone, so the tree is
# left without a stamp), 4 no fresh base in FETCH_HEAD, 5 unfinished: the
# budget ran out before every item ended, and the `판정 — 미완` line names
# what ended and what is left (a failure wins over it). items ends the same
# way, except that it never refuses for gate.sh and ends 2 when
# CHECK_PUSH_REUSE is 0, or when CHECK_PUSH_GOALS or CHECK_PUSH_SECTIONS is
# given with CHECK_PUSH_JOBS 1.

set -uo pipefail

# shellcheck source=scripts/test-tree.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-tree.sh"
TT_PREFIX="check-push"
TT_SECVAR="CHECK_PUSH_SECTIONS"
TT_GOALVAR="CHECK_PUSH_GOALS"
CP_TMP_STAMP=""
CP_GATE_PATH="plugins/cc-cmds/orchestrator/gate.sh"
# The derivation runs this script's sibling, not the tested tree's copy, so a
# tree that lacks the script or carries an older one derives the same way.
CP_READERS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rest-readers.sh"
# Read once here: the children never see it, because tt_scrubbed drops every
# CHECK_PUSH_* variable.
CP_JOBS="${CHECK_PUSH_JOBS:-4}"
CP_REUSE="${CHECK_PUSH_REUSE:-1}"
CP_BUDGET="${CHECK_PUSH_BUDGET_SECS:-}"
CP_FAIL_FAST="${CHECK_PUSH_FAIL_FAST:-}"
CP_RESUME_DIR="cc-cmds-check-push-resume"
CP_CI_LIST="scripts/check-push-ci.tsv"
CP_LAST_FAILED="cc-cmds-last-failed.tsv"

check_push_usage() {
  printf 'check-push: 사용법 — run / items / verify / --self-test 중 하나\n' >&2
  exit 2
}

# The common git directory as an absolute path, read from the current directory.
check_push_common_dir() {
  local d
  d=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd "$d" && pwd)
}

# The field <name> of a stamp file, or nothing.
check_push_field() {
  local line
  while IFS= read -r line; do
    case "$line" in "$2="*) printf '%s' "${line#"$2="}"; return 0 ;; esac
  done < "$1"
  return 0
}

# Splits an item step into CP_FAILED_SECTIONS and CP_FAILED_GOALS, the way
# tt_failed_parts does for the repro command.
check_push_failed_parts() {
  tt_failed_parts "$1"
  CP_FAILED_SECTIONS="$TT_STEP_SECTIONS"
  CP_FAILED_GOALS="$TT_STEP_GOALS"
}

# The item step that names <sections> and <goals>, whichever are not empty.
check_push_items_step() {
  local s="${1:+절=$1}"
  printf '%s' "$s${2:+${s:+ }목표=$2}"
}

# The command that runs only the failed step on the head, in the worktree.
check_push_rerun_line() {
  local what=""
  case "$1" in
    절=*|목표=*)
      check_push_failed_parts "$1"
      [ -z "$CP_FAILED_SECTIONS" ] || what="bash scripts/test-gate.sh --sections $CP_FAILED_SECTIONS"
      [ -z "$CP_FAILED_GOALS" ] || what="${what:+$what && }make --no-print-directory $(printf '%s' "$CP_FAILED_GOALS" | tr ',' ' ')"
      ;;
    readme) what="make readme && git diff --exit-code -- README.md" ;;
    *) what="make $1" ;;
  esac
  printf 'check-push: head 만 다시 돌리기 (워크트리에서) — %s%s\n' "$what" "${2:+ $2}"
}

# The head rerun line after a merged failure. An item step keeps only what the
# head's own lists name: an id only the base has would send the head's
# test-gate into a full run.
check_push_merged_rerun_line() {
  local stage="$1" commit="$2" rc secs="" goals=""
  case "$stage" in
    절=*|목표=*)
      check_push_failed_parts "$stage"
      secs="$CP_FAILED_SECTIONS"
      goals="$CP_FAILED_GOALS"
      ;;
    *) check_push_rerun_line "$stage"; return 0 ;;
  esac
  if ! tt_checkout "$commit"; then
    printf 'check-push: head 만 다시 돌리기 — head 를 꺼낼 수 없어 항목 명령을 찍지 않는다\n'
    return 0
  fi
  tt_tree_filter "$secs" "$goals"
  rc=$?
  if [ "$rc" = 1 ]; then
    printf 'check-push: head 만 다시 돌리기 — head 트리에서 항목을 나열할 수 없어 항목 명령을 찍지 않는다\n'
    return 0
  fi
  if [ "$rc" = 6 ]; then
    printf 'check-push: head 만 다시 돌리기 — head 에 남는 항목이 없어 항목 명령을 찍지 않는다 (헤드에 없는 항목=%s)\n' "$(tt_or_none "$TT_DROPPED")"
    return 0
  fi
  check_push_rerun_line "$(check_push_items_step "$TT_KEEP_SECTIONS" "$TT_KEEP_GOALS")" "헤드에 없는 항목=$(tt_or_none "$TT_DROPPED")"
}

# 0 when <head> leaves gate.sh as it was at its merge-base with <base>; 1 when
# it changed it or when either git step fails.
check_push_gate_unchanged() {
  local mb changed
  mb=$(git merge-base "$1" "$2" 2>/dev/null) || return 1
  changed=$(git diff --name-only "$mb" "$2" -- "$CP_GATE_PATH" 2>/dev/null) || return 1
  [ -z "$changed" ]
}

# The derivation step. Writes the changed paths of <head> (against <base> in
# merge mode, against the base branch in head mode) to a file in TT_DIR, asks
# rest-readers.sh which goals of the tested tree read them, and sets
# CP_DERIVED (the derived goals comma-joined, or 판정불가), CP_UNREAD (the
# changed paths no goal reads, space-joined), CP_UNREAD_N, CP_CHANGED_N (every
# changed path), CP_RELEASE (the changed paths left out of the derivation as
# release-shaped, space-joined, in the order of the change) and CP_RELEASE_N.
# CP_CHANGED_LIST is every changed path, one per line, set only when the
# derivation ran to its end and empty otherwise. Returns 0, or 1
# with CP_DERIVE_STAGE naming the step that failed.
check_push_derive() {
  local mode="$1" base="$2" head="$3" br ref="" mb list input rel gdir p out err k v
  CP_DERIVED=""
  CP_UNREAD=""
  CP_UNREAD_N=0
  CP_CHANGED_N=0
  CP_CHANGED_LIST=""
  CP_RELEASE=""
  CP_RELEASE_N=0
  CP_DERIVE_STAGE=""
  CP_DERIVE_WHY=""
  if [ "$mode" = head ]; then
    br="${CHECK_PUSH_BASE_BRANCH:-master}"
    if git rev-parse --verify --quiet "refs/remotes/origin/$br^{commit}" > /dev/null; then
      ref="refs/remotes/origin/$br"
    elif git rev-parse --verify --quiet "refs/heads/$br^{commit}" > /dev/null; then
      ref="refs/heads/$br"
    else
      CP_DERIVED="판정불가"
      CP_DERIVE_WHY="베이스 브랜치 $br 의 refs/remotes/origin/$br 도 refs/heads/$br 도 없다"
      return 0
    fi
    base=$(git rev-parse --verify --quiet "$ref^{commit}") || { CP_DERIVE_STAGE="git rev-parse $ref"; return 1; }
  fi
  mb=$(git merge-base "$base" "$head" 2>/dev/null) || { CP_DERIVE_STAGE="git merge-base $base $head"; return 1; }
  list="$TT_DIR/derive-changed"
  out="$TT_DIR/derive-out"
  err="$TT_DIR/derive-err"
  git -c core.quotePath=false diff --name-only --no-renames "$mb" "$head" > "$list" 2>/dev/null || { CP_DERIVE_STAGE="git diff $mb $head"; return 1; }
  CP_CHANGED_N=$(grep -c . "$list")
  # A release-shaped change of a release path is not derivation input; with no
  # readable common git directory nothing is left out.
  input="$TT_DIR/derive-input"
  rel="$TT_DIR/derive-release"
  : > "$rel"
  if gdir=$(check_push_common_dir); then
    tr_release_paths "$gdir" "$mb" "$head" > "$rel"
  fi
  : > "$input"
  while IFS= read -r p; do
    if [ -n "$p" ] && grep -Fxq -- "$p" "$rel"; then
      CP_RELEASE="${CP_RELEASE:+$CP_RELEASE }$p"
      CP_RELEASE_N=$((CP_RELEASE_N + 1))
    else
      printf '%s\n' "$p" >> "$input"
    fi
  done < "$list"
  if ! tt_scrubbed bash "$CP_READERS" derive --tree "$TT_WORK" --changed "$input" --make "${CC_TEST_TREE_MAKE:-make}" > "$out" 2> "$err" < /dev/null; then
    CP_DERIVE_STAGE=$(sed -n 's/^rest-readers: 유도 실패 — //p' "$err" | tail -n 1)
    [ -n "$CP_DERIVE_STAGE" ] || CP_DERIVE_STAGE="rest-readers.sh"
    cat "$err" >&2
    return 1
  fi
  while IFS=$'\t' read -r k v; do
    case "$k" in
      유도) CP_DERIVED="${CP_DERIVED:+$CP_DERIVED,}$v" ;;
      근거없음) CP_UNREAD="${CP_UNREAD:+$CP_UNREAD }$v"; CP_UNREAD_N=$((CP_UNREAD_N + 1)) ;;
    esac
  done < "$out"
  CP_CHANGED_LIST=$(cat "$list")
  return 0
}

# <named> followed by every goal of <derived> it does not name, comma-joined.
check_push_union() {
  local all="$1" g
  for g in $(printf '%s' "$2" | tr ',' ' '); do
    case ",$all," in *",$g,"*) ;; *) all="${all:+$all,}$g" ;; esac
  done
  printf '%s' "$all"
}

# The sections this run took from lane records, comma-joined; 없음 when none;
# 꺼짐 when a switch kept lanes from being judged at all (CHECK_PUSH_REUSE=0,
# or CHECK_PUSH_JOBS=1, which runs every section in one test-gate call).
check_push_reused_sections() {
  if [ "$CP_REUSE" = 0 ] || [ "${TT_JOBS:-1}" = 1 ]; then
    printf '꺼짐'
  else
    tt_or_none "$TT_REUSED_SECTIONS"
  fi
}

# Writes the resume record $1 — head $2, base $3, first start $4, attempt $5,
# cut goals $6 — through a temporary file, and drops the records of the same
# directory older than 24 hours.
check_push_resume_write() {
  local f="$1" d tmp
  d="${f%/*}"
  mkdir -p "$d" || return 1
  find "$d" -type f -mmin +1440 -exec rm -f {} + 2>/dev/null
  tmp=$(mktemp "$d/.resume.XXXXXX") || return 1
  if ! printf 'v=1\ncommit=%s\nbase=%s\n처음=%s\n시도=%s\n잘린목표=%s\n' "$2" "$3" "$4" "$5" "$6" > "$tmp" \
    || ! mv -f "$tmp" "$f"; then
    rm -f "$tmp"
    return 1
  fi
  return 0
}

# How often the cut-goal list $1 (`<goal>:<count>,…`) counts goal $2; 0 when
# it does not name it.
check_push_cut_count() {
  local rest="$1," it
  while [ -n "$rest" ]; do
    it="${rest%%,*}"
    rest="${rest#*,}"
    case "$it" in "$2":*) printf '%s' "${it##*:}"; return 0 ;; esac
  done
  printf '0'
}

# The cut-goal list $1 with the count of each goal of the comma list $2 one up.
check_push_cut_bump() {
  local list="$1" rest="$2," g n out it r
  while [ -n "$rest" ]; do
    g="${rest%%,*}"
    rest="${rest#*,}"
    [ -n "$g" ] || continue
    n=$(check_push_cut_count "$list" "$g")
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    out=""
    r="$list,"
    while [ -n "$r" ]; do
      it="${r%%,*}"
      r="${r#*,}"
      [ -n "$it" ] || continue
      case "$it" in "$g":*) continue ;; esac
      out="${out:+$out,}$it"
    done
    list="${out:+$out,}$g:$((n + 1))"
  done
  printf '%s' "$list"
}

# 0 when the pull request's CI runs the REST goals for this head: the tested
# tree's .github/workflows/lint.yml has jobs.rest-tests, and one of its
# on.pull_request.paths patterns matches a path head $2 changed since its
# merge-base with base $1. Only `<path>/**` (a prefix) and an exact path are
# read; any other pattern, and a yq that fails, match nothing. Otherwise 1
# with the reason in CP_CI_WHY.
check_push_ci_covers() {
  local base="$1" commit="$2" wf="$TT_WORK/.github/workflows/lint.yml" has pats mb changed p pre f
  CP_CI_WHY=""
  if [ ! -f "$wf" ]; then
    CP_CI_WHY="시험 트리에 .github/workflows/lint.yml 이 없다"
    return 1
  fi
  has=$(yq '.jobs | has("rest-tests")' "$wf" 2>/dev/null) || has=""
  if [ "$has" != true ]; then
    CP_CI_WHY="시험 트리의 lint.yml 에 jobs.rest-tests 가 없다(또는 yq 로 읽지 못했다)"
    return 1
  fi
  if ! pats=$(yq '.on.pull_request.paths[]' "$wf" 2>/dev/null); then
    CP_CI_WHY="시험 트리의 lint.yml 의 on.pull_request.paths 를 yq 로 읽지 못했다"
    return 1
  fi
  if ! mb=$(git merge-base "$base" "$commit" 2>/dev/null) || ! changed=$(git diff --name-only "$mb" "$commit" 2>/dev/null); then
    CP_CI_WHY="head 가 merge-base 이후 바꾼 경로를 읽지 못했다"
    return 1
  fi
  while IFS= read -r p; do
    case "$p" in
      ?*/\*\*)
        pre="${p%\*\*}"
        case "$pre" in *[\*\?\[]*) continue ;; esac
        while IFS= read -r f; do
          case "$f" in "$pre"?*) return 0 ;; esac
        done <<EOF
$changed
EOF
        ;;
      ''|*[\*\?\[]*) ;;
      *)
        while IFS= read -r f; do
          [ "$f" != "$p" ] || return 0
        done <<EOF
$changed
EOF
        ;;
    esac
  done <<EOF
$pats
EOF
  CP_CI_WHY="시험 트리의 lint.yml 의 pull_request 경로가 head 가 바꾼 경로에 맞지 않는다"
  return 1
}

# 0 when goal $1 is left to CI from the first attempt: the run is unattended,
# the goal came in by derivation and is not in the named list $2, the tested
# tree's CP_CI_LIST lists it with at least one direct target, the change holds
# neither the list nor the goal's entry script nor a direct target, and CI runs
# the REST goals for head $4 against base $3. Anything else, an undecided step
# included, is 1.
check_push_ci_defers() {
  local g="$1" named="$2" list="$TT_WORK/$CP_CI_LIST" k v p t targets=() row=()
  [ -n "${CC_PIPELINE_RUN_ID:-}" ] && [ -n "${CP_CHANGED_LIST:-}" ] || return 1
  case "$g" in run/?*) ;; *) return 1 ;; esac
  case ",$named," in *",$g,"*) return 1 ;; esac
  case ",$CP_DERIVED," in *",$g,"*) ;; *) return 1 ;; esac
  [ -f "$list" ] && [ -r "$list" ] || return 1
  while IFS=$'\t' read -r k v || [ -n "$k" ]; do
    case "$k" in ''|'#'*) continue ;; esac
    [ "$k" = "$g" ] || continue
    IFS=' ' read -r -a row <<EOF
$v
EOF
    targets+=(${row[@]+"${row[@]}"})
  done < "$list"
  [ "${#targets[@]}" -gt 0 ] || return 1
  while IFS= read -r p; do
    for t in "$CP_CI_LIST" "${g#run/}" "${targets[@]}"; do
      case "$t" in
        */) case "$p" in "$t"*) return 1 ;; esac ;;
        *) [ "$p" != "$t" ] || return 1 ;;
      esac
    done
  done <<EOF
$CP_CHANGED_LIST
EOF
  check_push_ci_covers "$3" "$4"
}

# run (the default) checks and stamps; items runs check-cheap, the sections and
# the goals only so their passes are recorded, and touches no stamp.
check_push_run() {
  local verb="${1:-run}" make_bin commit tree gdir stamp_dir stamp mode src base="" fetch="없음" secs goals added="없음" doubles rc stage="" step old got how key steps it rec
  local start budget ff deadline="" sdone="" cutstep="" left="" prc=0 unfinished=0 now
  local rs="" rs_first="" tries="" cutl="" fbase="없음" ob of ot why ci="" g n keep rest named
  start=$(date +%s)
  make_bin="${CC_CHECK_PUSH_MAKE:-make}"
  secs="${CHECK_PUSH_SECTIONS:-}"
  goals="${CHECK_PUSH_GOALS:-}"
  named="$goals"
  case "$CP_JOBS" in
    ''|*[!0-9]*|0*)
      printf 'check-push: CHECK_PUSH_JOBS=%s 는 양의 정수가 아니다 — 비우면 4, 1 이면 직렬로 돈다\n' "$(printf %q "$CP_JOBS")" >&2
      return 2
      ;;
  esac
  case "$CP_BUDGET" in
    '') if [ -n "${CC_PIPELINE_RUN_ID:-}" ]; then budget=6600; else budget=0; fi ;;
    0) budget=0 ;;
    *[!0-9]*|0*)
      printf 'check-push: CHECK_PUSH_BUDGET_SECS=%s 는 0 이나 양의 정수가 아니다 — 비우면 무인 실행은 6600초, 그 밖은 끔, 0 은 끔\n' "$(printf %q "$CP_BUDGET")" >&2
      return 2
      ;;
    *) budget="$CP_BUDGET" ;;
  esac
  case "$CP_FAIL_FAST" in
    '') if [ -n "${CC_PIPELINE_RUN_ID:-}" ] && [ "$verb" = run ]; then ff=1; else ff=0; fi ;;
    0|1) ff="$CP_FAIL_FAST" ;;
    *)
      printf 'check-push: CHECK_PUSH_FAIL_FAST=%s 는 0 도 1 도 아니다 — 비우면 무인 run 은 1, 그 밖은 0\n' "$(printf %q "$CP_FAIL_FAST")" >&2
      return 2
      ;;
  esac
  # items runs to record passes, so it runs every job to its end.
  [ "$verb" != items ] || ff=0
  [ "${#budget}" -le 9 ] || budget=999999999
  [ "$budget" = 0 ] || deadline=$((start + budget))
  steps="lint readme check-cheap"
  if [ "$verb" = items ]; then
    if [ "$CP_REUSE" = 0 ]; then
      printf 'check-push: items 는 통과를 기록하려고 돈다 — CHECK_PUSH_REUSE=0 이면 기록하지 않으므로 돌지 않는다\n' >&2
      return 2
    fi
    if [ -n "$goals" ] && [ "$CP_JOBS" = 1 ]; then
      printf 'check-push: CHECK_PUSH_JOBS=1 의 목표는 한 make 로 돌아 기록되지 않는다 — items 는 CHECK_PUSH_JOBS 를 2 이상으로 둔다\n' >&2
      return 2
    fi
    if [ -n "$secs" ] && [ "$CP_JOBS" = 1 ]; then
      printf 'check-push: CHECK_PUSH_JOBS=1 의 절은 한 test-gate 호출로 돌아 기록되지 않는다 — items 는 CHECK_PUSH_JOBS 를 2 이상으로 둔다\n' >&2
      return 2
    fi
    steps="check-cheap"
  fi
  # More than the jobs there are is cut to that count by the pool itself.
  [ "${#CP_JOBS}" -le 4 ] || CP_JOBS=9999
  TT_JOBS="$CP_JOBS"
  case "${CC_CHECK_PUSH_PROGRESS_SECS:-}" in
    ''|*[!0-9]*|0*) TT_PROGRESS_SECS=60 ;;
    *) TT_PROGRESS_SECS="$CC_CHECK_PUSH_PROGRESS_SECS" ;;
  esac
  commit=$(git rev-parse --verify --quiet HEAD) || {
    printf 'check-push: HEAD 커밋을 읽지 못했다 — git 저장소 안에서 커밋 뒤에 돌린다\n' >&2
    return 1
  }
  tree=$(git rev-parse --verify --quiet 'HEAD^{tree}') || {
    printf 'check-push: HEAD 트리를 읽지 못했다\n' >&2
    return 1
  }
  gdir=$(check_push_common_dir) || {
    printf 'check-push: 공통 git 디렉터리를 읽지 못했다\n' >&2
    return 1
  }
  stamp_dir="$gdir/cc-cmds-check-push"
  stamp="$stamp_dir/$tree"
  # The lanes merge their times into this repository's record, not the clone's,
  # which is thrown away.
  TT_RECORD="$gdir/cc-cmds-gate-timing.tsv"
  # What failed last is this worktree's own, so it lives under this worktree's
  # git directory and not the common one; without it the pool keeps no record.
  if TT_LAST_FAILED=$(git rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$TT_LAST_FAILED" ]; then
    TT_LAST_FAILED="$TT_LAST_FAILED/$CP_LAST_FAILED"
  else
    TT_LAST_FAILED=""
  fi
  if ! git diff --quiet HEAD -- 2>/dev/null; then
    printf 'check-push: 경고 — 작업 트리에 커밋되지 않은 추적 변경이 있다. 그 변경은 검사되지도 push 되지도 않는다\n' >&2
  fi

  if [ -n "${CHECK_PUSH_BASE:-}" ]; then
    mode="merge"
    src="지정"
  elif [ -n "${CC_PIPELINE_RUN_ID:-}" ]; then
    mode="merge"
    src="FETCH_HEAD"
  else
    mode="head"
    src="없음"
  fi

  if [ "$mode" = "merge" ]; then
    # Whatever this run ends in, an older base's pass no longer speaks for it.
    # items stamps nothing, so it leaves the stamp to run.
    [ "$verb" = items ] || rm -f "$stamp"
    if [ "$src" = "지정" ]; then
      base=$(git rev-parse --verify --quiet "${CHECK_PUSH_BASE}^{commit}") || {
        printf 'check-push: CHECK_PUSH_BASE=%s 는 커밋으로 풀리지 않는다\n' "$(printf %q "$CHECK_PUSH_BASE")" >&2
        return 2
      }
    else
      tt_base_from_fetch_head "${CHECK_PUSH_BASE_BRANCH:-master}"
      rc=$?
      [ "$rc" = 0 ] || return "$rc"
      base="$TT_BASE"
      fetch="$TT_FETCH"
      fbase="$base"
    fi
  fi

  # THE ATTEMPT RECORD. Only an unattended merged run with its base from
  # FETCH_HEAD keeps one. A record of this head from the last six hours whose
  # base is here and is an ancestor of the base just fetched (or that base)
  # pins the tested base to it, so the passes an earlier attempt recorded
  # still hold; anything else starts the record over at attempt 1.
  if [ "$src" = "FETCH_HEAD" ]; then
    rs="$gdir/$CP_RESUME_DIR/$commit"
    now=$(date +%s)
    rs_first="$now"
    tries=1
    if [ -f "$rs" ]; then
      ob=$(check_push_field "$rs" base)
      of=$(check_push_field "$rs" 처음)
      ot=$(check_push_field "$rs" 시도)
      why=""
      if [ "$(check_push_field "$rs" v)" != 1 ] || [ "$(check_push_field "$rs" commit)" != "$commit" ]; then
        why="기록의 형식이나 커밋이 맞지 않는다"
      else
        case "$of$ot" in
          ''|*[!0-9]*) why="기록의 처음·시도 값이 숫자가 아니다" ;;
          *)
            if [ "$of" -gt "$now" ] || [ $((now - of)) -gt 21600 ]; then
              why="기록의 처음이 21600초 안이 아니다"
            elif ! git cat-file -e "$ob^{commit}" 2>/dev/null; then
              why="기록의 베이스 $ob 가 이 저장소에 없다"
            elif ! git merge-base --is-ancestor "$ob" "$base" 2>/dev/null; then
              why="기록의 베이스 $ob 가 방금 fetch 한 베이스 $base 의 조상이 아니다"
            fi
            ;;
        esac
      fi
      if [ -z "$why" ]; then
        base="$ob"
        src="이어감"
        rs_first="$of"
        tries=$((ot + 1))
        cutl=$(check_push_field "$rs" 잘린목표)
        printf 'check-push: 이어감 — 시도 %s, 기록의 베이스 %s 를 쓴다 (방금 fetch 한 베이스 %s)\n' "$tries" "$base" "$fbase" >&2
      else
        printf 'check-push: 시도 기록을 잇지 않는다 — %s, 새 베이스로 시도 1 을 쓴다\n' "$why" >&2
      fi
    fi
  fi

  # AN UNATTENDED RUN THAT CHANGED gate.sh NAMES ITS SECTIONS. check-push does
  # not run the gate suite on its own, so a stage whose last check is this one
  # and names no section would push a gate.sh change no local step tested —
  # the refusal `make check` makes through check-gate-suite, carried over to
  # this path. Goals alone do not count: what covers gate.sh is test-gate's
  # sections. A base object that is not here is left to tt_build, which ends 4
  # with the fetch to run; a base that is here but whose comparison fails counts
  # as changed, because reading an undecided comparison as unchanged is the
  # very gap this closes. items is never a stage's last check, so it does not
  # refuse.
  if [ "$verb" = run ] && [ -n "${CC_PIPELINE_RUN_ID:-}" ] && [ -z "$secs" ] && [ -n "$base" ] \
    && git cat-file -e "$base^{commit}" 2>/dev/null \
    && ! check_push_gate_unchanged "$base" "$commit"; then
    printf 'check-push: 무인 런에서 %s 를 바꾼 커밋은 시험할 절을 지명해야 한다 — CHECK_PUSH_SECTIONS=<id,...> 로 바꾼 축의 test-gate 절을 지명해 다시 부른다 (CHECK_PUSH_GOALS 만으로는 gate.sh 변경을 덮지 못한다. base %s 대비 변경을 판정하지 못한 경우도 바뀐 것으로 본다)\n' \
      "$CP_GATE_PATH" "$base" >&2
    return 2
  fi

  if [ -n "$rs" ] && ! check_push_resume_write "$rs" "$commit" "$base" "$rs_first" "$tries" "$cutl"; then
    printf 'check-push: 경고 — 시도 기록 %s 를 쓰지 못했다. 이번 시도는 이어 돌릴 수 없다\n' "$rs" >&2
    rs=""
  fi

  trap 'tt_cleanup; [ -z "$CP_TMP_STAMP" ] || rm -f "$CP_TMP_STAMP"' EXIT
  # An interrupt goes through the EXIT trap too, so the pool's jobs are stopped.
  trap 'exit 130' INT
  trap 'exit 143' TERM
  tt_clone || return 1
  if [ "$mode" = "merge" ]; then
    tt_build "$base" "$commit"
    rc=$?
    if [ "$rc" = 4 ]; then
      printf 'check-push: 객체 없음 — %s 가 이 저장소에 없다. git fetch --no-tags --refmap= origin refs/heads/%s (게이트 --surface 읽기 --reach 협업) 뒤 다시 돌린다\n' "$TT_MISSING_OBJ" "${CHECK_PUSH_BASE_BRANCH:-master}" >&2
      return 4
    fi
    [ "$rc" = 0 ] || { printf 'check-push: 시험할 트리를 만들지 못했다\n' >&2; return 1; }
    tt_base_added_ids "$base" "$commit"
    added="$TT_ADDED"
  else
    tt_checkout "$commit" || { printf 'check-push: 커밋 %s 을 임시 복제본에 꺼내지 못했다\n' "$commit" >&2; return 1; }
    TT_OUTCOME="안함"
    TT_TREE="$tree"
    TT_COMMIT="$commit"
    TT_CONFLICTS=""
  fi
  doubles=$(tt_doubles)
  if [ "$CP_REUSE" != 0 ]; then
    TT_REUSE=1
    TT_REUSE_GDIR="$gdir"
    TT_REUSE_COMMIT="$commit"
    TT_REUSE_BASE="$base"
  fi

  printf 'check-push: 시험 트리 — 합침=%s base=%s base출처=%s head=%s tree=%s 절=%s 목표=%s 절+베이스=%s fetch=%s 대역=%s fetch베이스=%s 시도=%s\n' \
    "$TT_OUTCOME" "$(tt_or_none "$base")" "$src" "$commit" "$TT_TREE" "$(tt_or_none "$secs")" "$(tt_or_none "$goals")" "$added" "$fetch" "$doubles" \
    "$fbase" "$(tt_or_none "$tries")"
  if [ "$TT_OUTCOME" = "충돌" ]; then
    printf 'check-push: 합침=충돌 %s — 합친 트리는 시험하지 않았다, CI 런 없음\n' "$(tt_or_none "$TT_CONFLICTS")"
  fi

  # The derivation: an undecided one is never read as an empty one.
  if ! check_push_derive "$mode" "$base" "$commit"; then
    printf 'check-push: 유도 실패 — %s\n' "$CP_DERIVE_STAGE" >&2
    printf 'check-push: 커밋 %s 검사 실패 — 도장을 찍지 않는다\n' "$commit" >&2
    return 1
  fi
  if [ "$CP_DERIVED" = "판정불가" ]; then
    printf 'check-push: 유도 판정불가 — %s\n' "$CP_DERIVE_WHY"
  else
    printf 'check-push: 유도 목표 — 변경 파일 %s개, 유도 %s개: %s\n' \
      "$CP_CHANGED_N" "$(printf '%s' "$CP_DERIVED" | tr ',' '\n' | grep -c .)" "$(tt_or_none "$CP_DERIVED")"
    if [ "$CP_UNREAD_N" -gt 0 ]; then
      printf 'check-push: 유도 근거 없는 변경 파일 %s개 — %s\n' "$CP_UNREAD_N" "$CP_UNREAD"
    fi
    if [ "$CP_RELEASE_N" -gt 0 ]; then
      printf 'check-push: 릴리스 차이로 유도에서 뺀 변경 파일 %s개 — %s\n' "$CP_RELEASE_N" "$CP_RELEASE"
    fi
    goals=$(check_push_union "$goals" "$CP_DERIVED")
  fi

  tt_check_items "$secs" "$goals"
  rc=$?
  if [ "$rc" != 0 ]; then
    printf '%s\n' "$TT_HINT" >&2
    return "$rc"
  fi

  # A GOAL THE BUDGET CUT TWICE ON THIS HEAD IS LEFT TO CI when CI runs it for
  # this head, and so is a listed heavy goal that only the derivation brought in
  # (check_push_ci_defers). Every goal left in TT_GOALS is in the tested tree's
  # REST goal list, because tt_check_items refuses any other. items does not
  # leave one out: recording its pass is what items is for.
  if [ "$verb" = run ] && [ -n "$TT_GOALS" ]; then
    keep=""
    rest="$TT_GOALS,"
    while [ -n "$rest" ]; do
      g="${rest%%,*}"
      rest="${rest#*,}"
      [ -n "$g" ] || continue
      n=0
      [ -z "$cutl" ] || n=$(check_push_cut_count "$cutl" "$g")
      case "$n" in ''|*[!0-9]*) n=0 ;; esac
      if [ "$n" -ge 2 ]; then
        if check_push_ci_covers "$base" "$commit"; then
          printf 'check-push: CI 몫 — %s (이 커밋의 시도에서 시간 예산에 두 번 잘림, PR 의 rest-tests 가 돌린다)\n' "$g" >&2
          ci="${ci:+$ci,}$g"
          continue
        fi
        printf 'check-push: CI 몫 아님 — %s (시간 예산에 %s번 잘렸지만 %s) · 로컬에서 다시 돈다\n' "$g" "$n" "$CP_CI_WHY" >&2
      fi
      if check_push_ci_defers "$g" "$named" "$base" "$commit"; then
        printf 'check-push: CI 몫 — %s (유도로만 들어왔고 직접 대상이 바뀌지 않음, PR 의 rest-tests 가 돌린다)\n' "$g" >&2
        ci="${ci:+$ci,}$g"
        continue
      fi
      keep="${keep:+$keep,}$g"
    done
    TT_GOALS="$keep"
  fi

  # Each step of the serial bundle waits for as many host-wide test slots as
  # its weight and runs under a foreground job shell, which measures it and
  # sends an interrupt on to make as TERM. The slots go back when it ends. A
  # step that holds slots, or started without one at the wait cap, passes
  # CC_TEST_SLOT_HELD=1 on, so nothing under it asks for a slot again.
  # check-cheap is an item like a goal: a recorded pass whose inputs this tree
  # keeps is reused, and otherwise it runs in a checkout of its own, made
  # before it waits for its slots, and its pass is recorded.
  # Past the deadline no step starts: it and every item after it are left.
  tt_slots_init
  for step in $steps; do
    if [ -n "$deadline" ] && [ "$(date +%s)" -ge "$deadline" ]; then
      cutstep="$step"
      break
    fi
    it=""
    rec=0
    if [ "$step" = check-cheap ]; then
      if tt_item_reuse "make:check-cheap"; then
        sdone="${sdone:+$sdone,}$step"
        continue
      fi
      tt_item_prepare cc "make:check-cheap"
      it="$TT_IT_DIR"
      rec="$TT_IT_REC"
    fi
    ts_slot_wait "단계 $step" "make:$step"
    got="$TS_GOT"
    how="$TS_MODE"
    key=$(ts_job_key "make:$step")
    (
      cd "${it:-$TT_WORK}" || exit 2
      if [ -n "$it" ]; then
        PATH="$it.shim:$PATH"
        unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
      fi
      if [ "$how" = exec ]; then exec "$make_bin" "$step"; fi
      CC_TEST_SLOT_HELD=1
      export CC_TEST_SLOT_HELD
      ts_job_shell fg "$key" "$make_bin" "$step"
    )
    rc=$?
    ts_release "$got"
    [ "$step" != check-cheap ] || tt_item_done "$it" "$rc" "make:check-cheap" "$rec"
    if [ "$rc" != 0 ]; then
      printf 'check-push: 실패 확정 — 단계 %s rc=%s\n' "$step" "$rc" >&2
      stage="$step"
      break
    fi
    if [ "$step" = readme ] && ! tt_git diff --exit-code -- README.md; then
      printf 'check-push: README.md 가 생성 결과와 다르다 (make readme 뒤 커밋한다)\n' >&2
      printf 'check-push: 실패 확정 — 단계 readme (README.md 신선도)\n' >&2
      stage="readme"
      break
    fi
    sdone="${sdone:+$sdone,}$step"
  done

  # The job pool stops at the deadline and, with fail-fast, at its first
  # failure. The CHECK_PUSH_JOBS=1 path runs the sections in one test-gate
  # call and the goals in one make, with no record a later attempt could
  # reuse, so the budget does not reach it.
  if [ -z "$stage" ] && [ -z "$cutstep" ]; then
    TT_FAIL_FAST="$ff"
    if [ "$TT_JOBS" -gt 1 ]; then
      TT_DEADLINE="$deadline"
    else
      TT_DEADLINE=""
      if [ -n "$deadline" ] && { [ -n "$TT_SECTIONS" ] || [ -n "$TT_GOALS" ]; }; then
        printf 'check-push: 경고 — CHECK_PUSH_JOBS=1 의 직렬 경로는 통과 기록이 없어 시간 예산 %s초를 절·목표에 적용하지 않는다\n' "$budget" >&2
      fi
    fi
    tt_run_items "$TT_SECTIONS" "$TT_GOALS"
    prc=$?
    if [ -n "$TT_FAILED" ]; then
      stage="$TT_FAILED"
    elif [ "$prc" = 5 ]; then
      unfinished=1
    elif [ "$prc" != 0 ]; then
      stage="$(check_push_items_step "$TT_SECTIONS" "$TT_GOALS")"
    fi
    if [ -n "$rs" ] && [ -n "${TT_CUT_GOALS:-}" ]; then
      cutl=$(check_push_cut_bump "$cutl" "$TT_CUT_GOALS")
      check_push_resume_write "$rs" "$commit" "$base" "$rs_first" "$tries" "$cutl" \
        || printf 'check-push: 경고 — 시도 기록 %s 에 잘린 목표를 적지 못했다\n' "$rs" >&2
    fi
  fi

  # UNFINISHED: the budget left items that did not end, and nothing failed.
  # What ended includes what was reused from a record; what is left is the
  # step the deadline kept from starting and everything after it, or the
  # pool's jobs that were stopped or never started.
  if [ -z "$stage" ] && { [ -n "$cutstep" ] || [ "$unfinished" = 1 ]; }; then
    if [ -n "$cutstep" ]; then
      left=""
      rest=0
      for step in $steps; do
        [ "$step" != "$cutstep" ] || rest=1
        [ "$rest" = 0 ] || left="${left:+$left,}$step"
      done
      [ -z "$TT_SECTIONS" ] || left="$left,$TT_SECTIONS"
      [ -z "$TT_GOALS" ] || left="$left,$TT_GOALS"
    else
      sdone="$sdone${TT_DONE_ITEMS:+${sdone:+,}$TT_DONE_ITEMS}"
      left="$TT_UNFINISHED_SECTIONS"
      [ -z "$TT_UNFINISHED_GOALS" ] || left="${left:+$left,}$TT_UNFINISHED_GOALS"
    fi
    if [ "$verb" = items ]; then
      printf 'check-push: items 미완(시간 예산 %s초) · 끝난 항목 %s · 남은 항목 %s · 시도 %s\n' \
        "$budget" "$(tt_or_none "$sdone")" "$(tt_or_none "$left")" "$(tt_or_none "$tries")" >&2
    else
      printf 'check-push: 판정 — 미완(시간 예산 %s초) · 끝난 항목 %s · 남은 항목 %s · 시도 %s\n' \
        "$budget" "$(tt_or_none "$sdone")" "$(tt_or_none "$left")" "$(tt_or_none "$tries")" >&2
    fi
    printf 'check-push: 같은 명령으로 다시 띄우면 끝난 항목은 기록으로 건너뛴다 (베이스 %s 유지)\n' "$(tt_or_none "$base")" >&2
    return 5
  fi

  if [ "$verb" = items ]; then
    if [ -n "$stage" ]; then
      printf 'check-push: items 실패 — 단계=%s, 실패한 항목은 기록하지 않았다. 도장은 건드리지 않는다\n' "$stage" >&2
      return 1
    fi
    printf 'check-push: items 통과 — 커밋 %s (시험 트리 %s) 의 통과를 기록했다 (재사용=%s 재사용절=%s). 도장은 건드리지 않는다\n' \
      "$commit" "$TT_TREE" "$(tt_or_none "$TT_REUSED")" "$(check_push_reused_sections)"
    return 0
  fi

  if [ -n "$stage" ]; then
    case "$TT_OUTCOME" in
      합침|조상)
        printf 'check-push: 합친 트리 실패 — base=%s 단계=%s\n' "$base" "$stage" >&2
        check_push_merged_rerun_line "$stage" "$commit" >&2
        # The cause line names only the failed step's items and runs them on
        # the base alone, in a pool as wide as this run's, so nothing this
        # tree already failed or passed is run again.
        case "$stage" in
          절=*|목표=*)
            check_push_failed_parts "$stage"
            printf 'check-push: 원인 판정 (게이트 --surface 트리밖쓰기 --reach 런로컬) — bash scripts/test-tree.sh base-verdict --base %s --head %s --expect %s%s%s --jobs %s\n' \
              "$base" "$commit" "$TT_TREE" "${CP_FAILED_SECTIONS:+ --sections $CP_FAILED_SECTIONS}" "${CP_FAILED_GOALS:+ --goals $CP_FAILED_GOALS}" "$TT_JOBS" >&2
            if [ "$TT_JOBS" = 1 ]; then
              printf 'check-push: CHECK_PUSH_JOBS=1 의 실패 단계는 목록 전체를 이름 댄다 — 원인 판정의 브랜치 결함 항목에는 이 트리에서 통과한 항목이 섞일 수 있다\n' >&2
            fi
            ;;
        esac
        tt_base_status_line "check-push" "$base" >&2
        ;;
      *)
        printf 'check-push: 실패 — 단계=%s\n' "$stage" >&2
        check_push_rerun_line "$stage" >&2
        ;;
    esac
    printf 'check-push: 커밋 %s 검사 실패 — 도장을 찍지 않는다\n' "$commit" >&2
    return 1
  fi

  if [ "$mode" = "head" ] && [ -f "$stamp" ]; then
    old=$(check_push_field "$stamp" "합침")
    if [ -n "$old" ] && [ "$old" != "안함" ]; then
      printf 'check-push: 통과 — 트리 %s 에는 합친 트리 도장(합침=%s)이 이미 있어 head 모드 도장으로 바꾸지 않는다\n' "$tree" "$old"
      return 0
    fi
  fi
  mkdir -p "$stamp_dir" || return 1
  CP_TMP_STAMP=$(mktemp "$stamp_dir/.stamp.XXXXXX") || return 1
  {
    printf 'v=2\n'
    printf 'commit=%s\n' "$commit"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'bash=%s\n' "$BASH_VERSION"
    printf '합침=%s\n' "$TT_OUTCOME"
    printf 'base=%s\n' "$(tt_or_none "$base")"
    printf 'base출처=%s\n' "$src"
    printf 'fetch=%s\n' "$fetch"
    printf 'tested_tree=%s\n' "$TT_TREE"
    printf 'sections=%s\n' "$(tt_or_none "$TT_SECTIONS")"
    printf 'goals=%s\n' "$(tt_or_none "$TT_GOALS")"
    printf '절+베이스=%s\n' "$added"
    printf '충돌경로=%s\n' "$(tt_or_none "$TT_CONFLICTS")"
    printf '대역=%s\n' "$doubles"
    printf '병렬=%s\n' "$TT_JOBS_USED"
    printf '자리대기=%s\n' "$TS_WAIT_TOTAL"
    if [ "$CP_REUSE" = 0 ]; then
      printf '재사용=꺼짐\n'
    else
      printf '재사용=%s\n' "$(tt_or_none "$TT_REUSED")"
    fi
    printf '재사용절=%s\n' "$(check_push_reused_sections)"
    if [ "$budget" = 0 ]; then printf '시간예산=꺼짐\n'; else printf '시간예산=%s\n' "$budget"; fi
    printf '시도=%s\n' "$(tt_or_none "$tries")"
    printf 'CI몫=%s\n' "$(tt_or_none "$ci")"
    printf 'fetch베이스=%s\n' "$fbase"
    printf '유도목표=%s\n' "$(tt_or_none "$CP_DERIVED")"
    printf '유도없음=%s\n' "$CP_UNREAD_N"
    printf '유도릴리스=%s\n' "$(tt_or_none "$(printf '%s' "$CP_RELEASE" | tr ' ' ',')")"
  } > "$CP_TMP_STAMP" || return 1
  mv -f "$CP_TMP_STAMP" "$stamp" || return 1
  CP_TMP_STAMP=""
  # The head passed: its attempts are over.
  [ -z "$rs" ] || rm -f "$rs"
  printf 'check-push: 통과 — 커밋 %s (트리 %s) 에 도장을 찍었다\n' "$commit" "$tree"
}

check_push_verify() {
  local tree gdir stamp v f
  tree=$(git rev-parse --verify --quiet 'HEAD^{tree}') || {
    printf 'check-push: HEAD 트리를 읽지 못했다\n' >&2
    return 1
  }
  gdir=$(check_push_common_dir) || {
    printf 'check-push: 공통 git 디렉터리를 읽지 못했다\n' >&2
    return 1
  }
  stamp="$gdir/cc-cmds-check-push/$tree"
  if [ ! -f "$stamp" ]; then
    printf 'check-push: 현재 HEAD 트리 %s 의 도장이 없다 — make check-push 를 먼저 돌린다\n' "$tree" >&2
    return 1
  fi
  v=$(check_push_field "$stamp" v)
  if [ "$v" != 2 ]; then
    if [ -n "${CC_PIPELINE_RUN_ID:-}" ]; then
      printf 'check-push: 무인 런은 v1 도장을 받지 않는다 — 트리 %s 는 합친 트리를 시험한 기록이 없다\n' "$tree" >&2
      return 1
    fi
    printf 'check-push: 도장 있음 — 트리 %s\n' "$tree"
    printf 'check-push: 기록 없음(v1 도장)\n'
    return 0
  fi
  printf 'check-push: 도장 있음 — 트리 %s\n' "$tree"
  printf 'check-push: 시험 트리 — 합침=%s base=%s base출처=%s head=%s tree=%s 절=%s 목표=%s 절+베이스=%s fetch=%s 대역=%s\n' \
    "$(check_push_field "$stamp" 합침)" "$(check_push_field "$stamp" base)" "$(check_push_field "$stamp" base출처)" \
    "$(check_push_field "$stamp" commit)" "$(check_push_field "$stamp" tested_tree)" "$(check_push_field "$stamp" sections)" \
    "$(check_push_field "$stamp" goals)" "$(check_push_field "$stamp" 절+베이스)" "$(check_push_field "$stamp" fetch)" \
    "$(check_push_field "$stamp" 대역)"
  # A goal left to CI is said, not refused: the pull request's rest-tests runs it.
  f=$(check_push_field "$stamp" CI몫)
  if [ -n "$f" ] && [ "$f" != "없음" ]; then
    printf 'check-push: CI 몫 — %s (로컬에서 돌리지 않았다)\n' "$f"
  fi
  if [ -n "${CC_PIPELINE_RUN_ID:-}" ]; then
    f=$(check_push_field "$stamp" 합침)
    case "$f" in
      합침|조상|충돌) ;;
      *) printf 'check-push: 무인 런은 합친 트리를 시험하지 않은 도장(합침=%s)을 받지 않는다\n' "$f" >&2; return 1 ;;
    esac
    f=$(check_push_field "$stamp" base출처)
    if [ "$f" = "지정" ]; then
      printf 'check-push: 무인 런은 CHECK_PUSH_BASE 로 base 를 지정한 도장을 받지 않는다\n' >&2
      return 1
    fi
    f=$(check_push_field "$stamp" 대역)
    if [ "$f" != "없음" ]; then
      printf 'check-push: 무인 런은 대역으로 돈 도장(대역=%s)을 받지 않는다\n' "$f" >&2
      return 1
    fi
  fi
  return 0
}

# --- self-test ---------------------------------------------------------------

check_push_self_test() {
  local passed=0 failed=0 T self rc out W sa sb1 sm2 sm3 sh shx th thx tm tg stamp before stamp_keep
  ok()  { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
  bad() { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
  check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got「$2」 want「$3」"; fi; }
  has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "「$3」 없음: $2" ;; esac; }
  hasnt() { case "$2" in *"$3"*) bad "$1" "「$3」 있음: $2" ;; *) ok "$1" ;; esac; }
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  tt_st_scrub
  T=$(mktemp -d "${TMPDIR:-/tmp}/check-push-selftest.XXXXXX") || return 1
  T=$(cd "$T" && pwd)
  mkdir -p "$T/tmp" "$T/bin"
  TMPDIR="$T/tmp"
  export TMPDIR
  sgit() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c init.defaultBranch=master "$@"; }

  # Doubles. All of them append to one order log, so a case can read the order
  # of the bundle, the section run and the goal run.
  sed "s|@T@|$T|g" > "$T/bin/bundle" <<'EOF'
#!/usr/bin/env bash
printf 'bundle:%s|MAKEFLAGS=%s|MFLAGS=%s|MAKELEVEL=%s\n' "$1" "${MAKEFLAGS-unset}" "${MFLAGS-unset}" "${MAKELEVEL-unset}" >> "@T@/order.log"
[ ! -f base-only.txt ] || printf 'saw-base-only\n' >> "@T@/seen.log"
printf '%s:%s\n' "$1" "${CC_TEST_SLOT_HELD-unset}" >> "@T@/held.log"
if [ -f breaker.txt ] && [ "$1" = check-cheap ]; then exit 1; fi
[ ! -f "@T@/bundle-slow" ] || [ "$1" != lint ] || sleep 3
if [ "$1" = check-cheap ]; then
  printf 'cc cwd=%s git=%s\n' "$(pwd -P)" "$(command -v git)" >> "@T@/cwd.log"
  [ ! -f "@T@/reads-cc" ] || while IFS= read -r f; do cat "$f" > /dev/null; done < "@T@/reads-cc"
  [ ! -f "@T@/git-cc" ] || git status --short > /dev/null 2>&1
fi
printf 'BUNDLE %s\n' "$1"
EOF
  printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/bundle-bad"
  # The gate double prints a total line as test-gate does, so a pool lane can
  # pass; flag files under $T make it slow, drop the total line, or name the
  # failed sections the way test-gate's rerun line does.
  sed "s|@T@|$T|g" > "$T/bin/gate" <<'EOF'
#!/usr/bin/env bash
printf 'gate:%s\n' "$*" >> "@T@/order.log"
ids=$(sed -n 's/^# --- section: \([^ |]*\) |.*$/\1/p' scripts/test-gate.sh)
case "$1" in
  --list) for id in $ids; do printf '%s # t\n' "$id"; done ;;
  --sections)
    # The cut digest: hex that depends only on the ids.
    if [ "${3:-}" = --cut-digest ]; then printf 'ab%s\n' "$(printf '%s' "$2" | cksum | cut -d' ' -f1)"; exit 0; fi
    printf 'env:TMPDIR=%s|OUT=%s|REC=%s\n' "${TMPDIR:-}" "${CC_GATE_TIMING_OUT:-}" "${CC_GATE_TIMING_RECORD:-}" >> "@T@/env.log"
    [ ! -f "@T@/gate-slow" ] || sleep 3
    # slow-<ids> holds the seconds a lane of exactly those ids sleeps; the
    # sleep's pid goes to slowpid-<ids>, so a case can see it was stopped.
    if [ -f "@T@/slow-$2" ]; then
      sleep "$(cat "@T@/slow-$2")" &
      printf '%s\n' "$!" > "@T@/slowpid-$2"
      wait "$!"
    fi
    rc=0; failed=""
    for id in $ids; do
      case ",$2," in *",$id,"*) bash "sections/$id.sh" || { rc=1; failed="${failed:+$failed,}$id"; } ;; esac
    done
    [ ! -f "@T@/gate-no-total" ] || exit 0
    if [ -n "$failed" ] && [ -f "@T@/gate-rerun-line" ]; then
      printf 'test-gate: 실패한 절만 다시 — bash scripts/test-gate.sh --sections %s\n' "$failed" >&2
    fi
    printf '\ntest-gate: 1 passed, %d failed\n' "$rc"
    exit "$rc" ;;
  --estimate) [ ! -f "@T@/estimate.txt" ] || cat "@T@/estimate.txt" ;;
  --record-add) { printf 'REC=%s\n' "${CC_GATE_TIMING_RECORD:-}"; cat "$2"; } >> "@T@/recadd.log" ;;
esac
EOF
  # A `-n` call is the derivation reading a goal's command lines: it prints
  # what n-<goal> holds, or fails when derive-n-fail is there, and runs nothing.
  sed "s|@T@|$T|g" > "$T/bin/make" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -n ]; then
  [ ! -f "@T@/derive-n-fail" ] || exit 1
  for a in "$@"; do last="$a"; done
  [ ! -f "@T@/n-$last" ] || cat "@T@/n-$last"
  exit 0
fi
printf 'make:%s\n' "$*" >> "@T@/order.log"
if [ "$*" = "-s --no-print-directory print-rest-goals" ]; then cat goals.txt; exit 0; fi
printf 'menv:%s|REC=%s\n' "$*" "${CC_GATE_TIMING_RECORD-unset}" >> "@T@/env.log"
for a in "$@"; do last="$a"; done
[ ! -f "@T@/reads-$last" ] || while IFS= read -r f; do cat "$f" > /dev/null; done < "@T@/reads-$last"
[ ! -f "@T@/run-$last" ] || bash "@T@/run-$last"
[ ! -f "@T@/fail-$last" ] || exit 1
exit 0
EOF
  sed "s|@T@|$T|g" > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh:%s\n' "$*" >> "@T@/gh.log"
exit 9
EOF
  # The lane-cut double puts every section in a lane of its own.
  sed "s|@T@|$T|g" > "$T/bin/shard" <<'EOF'
#!/usr/bin/env bash
printf 'shard:%s\n' "$*" >> "@T@/order.log"
only=""
while [ "$#" -gt 0 ]; do case "$1" in --only) only="${2-}"; shift 2 ;; *) shift ;; esac; done
k=0
for id in $(printf '%s' "$only" | tr ',' ' '); do k=$((k + 1)); printf '%s\t-\t%s\n' "$k" "$id"; done
EOF
  chmod +x "$T/bin/bundle" "$T/bin/bundle-bad" "$T/bin/gate" "$T/bin/make" "$T/bin/gh" "$T/bin/shard"
  export CC_CHECK_PUSH_MAKE="$T/bin/bundle" CC_TEST_TREE_GATE="$T/bin/gate" CC_TEST_TREE_MAKE="$T/bin/make" CC_TEST_TREE_GH="$T/bin/gh"
  # Every case but F41 checks a run that neither judges nor records, so reuse
  # is off unless a case turns it on.
  export CHECK_PUSH_REUSE=0

  # History. master: A - B1, later moved to M2 (adds section s2 in front of s1)
  # with M3 (adds a file that breaks check-cheap) on branch m3. Branches from A:
  # h (the work), hx (conflicts with B1), and review-base/x at B1.
  W="$T/work"
  sgit init -q --bare "$T/origin.git"
  mkdir -p "$T/seed/scripts" "$T/seed/sections"
  (
    cd "$T/seed" || exit 1
    sgit init -q
    sgit remote add origin "$T/origin.git"
    printf '#!/usr/bin/env bash\n# fixture\n# --- section: s1 | group: g | covers: x | anchors: y ---\n# f1\n# f2\n# f3\n# f4\n# end\n' > scripts/test-gate.sh
    printf '[ ! -e rows.txt ]\n' > sections/s1.sh
    printf 'g1\ng2\n' > goals.txt
    printf 'readme\n' > README.md
    sgit add -A && sgit commit -q -m A
    sgit branch -q a
    sgit checkout -q -b h
    printf 'h\n' > h.txt
    sgit add -A && sgit commit -q -m H
    sgit checkout -q -b hx a
    printf 'other\n' > base-only.txt
    sgit add -A && sgit commit -q -m HX
    sgit checkout -q master
    printf 'base\n' > base-only.txt
    sgit add -A && sgit commit -q -m B1
    sgit branch -q review-base/x
    sgit push -q origin master h hx review-base/x
  ) > /dev/null 2>&1 || { bad "픽스처 준비" "git 실패"; rm -rf "$T"; return 1; }
  sgit clone -q -b h "$T/origin.git" "$W" > /dev/null 2>&1
  (
    cd "$T/seed" || exit 1
    printf '#!/usr/bin/env bash\n# fixture\n# --- section: s2 | group: g | covers: x | anchors: y ---\n# --- section: s1 | group: g | covers: x | anchors: y ---\n# f1\n# f2\n# f3\n# f4\n# end\n' > scripts/test-gate.sh
    printf 'printf "r\\n" >> rows.txt\n' > sections/s2.sh
    sgit add -A && sgit commit -q -m M2
    sgit checkout -q -b m3
    printf 'x\n' > breaker.txt
    sgit add -A && sgit commit -q -m M3
    sgit push -q origin master m3
  ) > /dev/null 2>&1 || { bad "픽스처 준비" "git 실패"; rm -rf "$T"; return 1; }
  (cd "$W" && sgit fetch -q origin refs/heads/m3:refs/remotes/origin/m3 refs/heads/hx:refs/heads/hx) > /dev/null 2>&1
  sa=$(cd "$T/seed" && git rev-parse a)
  sb1=$(cd "$T/seed" && git rev-parse review-base/x)
  sm2=$(cd "$T/seed" && git rev-parse master)
  sm3=$(cd "$T/seed" && git rev-parse m3)
  sh=$(cd "$W" && git rev-parse HEAD)
  shx=$(cd "$W" && git rev-parse hx)
  th=$(cd "$W" && git rev-parse 'HEAD^{tree}')
  thx=$(cd "$W" && git rev-parse 'hx^{tree}')
  tm=$(cd "$W" && git merge-tree --write-tree "$sm2" "$sh")
  stamp="$W/.git/cc-cmds-check-push/$th"

  cprun() { (cd "$W" && env "$@" bash "$self" run 2>&1); }
  cvrun() { (cd "$W" && env "$@" bash "$self" verify 2>&1); }
  stamp_count() { find "$W/.git/cc-cmds-check-push" -type f ! -name '.stamp.*' 2>/dev/null | wc -l | tr -d ' '; }
  fh_line() { printf '%s\t\tbranch '"'"'%s'"'"' of %s\n' "$1" "${2:-master}" "$T/origin.git" > "$W/.git/FETCH_HEAD"; }
  hand_stamp() {  # <합침> <base출처> <대역>
    mkdir -p "$W/.git/cc-cmds-check-push"
    printf 'v=2\ncommit=%s\nat=t\nbash=x\n합침=%s\nbase=%s\nbase출처=%s\nfetch=t\ntested_tree=%s\nsections=없음\ngoals=없음\n절+베이스=없음\n충돌경로=없음\n대역=%s\n' \
      "$sh" "$1" "$sm2" "$2" "$tm" "$3" > "$stamp"
  }

  # --- the five head-mode cases of v1, kept --------------------------------------
  out=$(cvrun); rc=$?
  check "(1) 도장이 없으면 verify 는 1" "$rc" "1"
  out=$(cprun CC_CHECK_PUSH_MAKE="$T/bin/bundle-bad"); rc=$?
  if [ "$rc" != "0" ] && [ "$(stamp_count)" = "0" ]; then ok "(2) 대역이 실패하면 run 은 0 아닌 값이고 도장이 없다"; else bad "(2) 대역이 실패하면 run 은 0 아닌 값이고 도장이 없다" "rc=$rc stamps=$(stamp_count)"; fi
  : > "$T/order.log"
  out=$(cprun); rc=$?
  if [ "$rc" = "0" ] && [ "$(stamp_count)" = "1" ]; then ok "(3) 통과하면 도장이 하나 생긴다"; else bad "(3) 통과하면 도장이 하나 생긴다" "rc=$rc stamps=$(stamp_count) $out"; fi
  out=$(cvrun); rc=$?
  check "(3) 도장 뒤 verify 는 0" "$rc" "0"
  check "(3) 임시 복제본에서 lint, readme, check-cheap 을 차례로 부른다" "$(sed -n 's/^bundle:\([^|]*\)|.*$/\1/p' "$T/order.log" | tr '\n' ' ')" "lint readme check-cheap "
  check "F13 무인 런이 아니면 합침=안함 이고 head 트리를 시험한다" "$(check_push_field "$stamp" 합침) $(check_push_field "$stamp" tested_tree) $(check_push_field "$stamp" base출처)" "안함 $th 없음"
  (cd "$W" && sgit commit -q --amend -m 'H, reworded')
  out=$(cvrun); rc=$?
  check "(4) 메시지만 고친 같은 트리 커밋은 verify 통과" "$rc" "0"
  sh=$(cd "$W" && git rev-parse HEAD)
  rm -f "$stamp"

  # --- F12 무인 런, 신선한 FETCH_HEAD, 움직인 base ---------------------------------
  (cd "$W" && sgit fetch -q --no-tags --refmap= origin refs/heads/master) > /dev/null 2>&1
  check "F12 픽스처: 추적 ref 는 그대로 B1 이다" "$(cd "$W" && git rev-parse refs/remotes/origin/master)" "$sb1"
  : > "$T/order.log"
  : > "$T/seen.log"
  : > "$T/held.log"
  out=$(cprun CC_PIPELINE_RUN_ID=t CC_TEST_SLOTS=auto); rc=$?
  check "F12 통과" "$rc" "0"
  check "F12 base 는 FETCH_HEAD 의 sha" "$(check_push_field "$stamp" base) $(check_push_field "$stamp" base출처)" "$sm2 FETCH_HEAD"
  check "F12 tested_tree 가 따로 만든 merge-tree 와 같다" "$(check_push_field "$stamp" tested_tree)" "$tm"
  has "F12 make 대역이 base 에만 있는 파일을 본다" "$(cat "$T/seen.log")" "saw-base-only"
  case "$out" in "check-push: 시험 트리 — 합침=합침 base=$sm2 base출처=FETCH_HEAD head=$sh tree=$tm 절=없음 목표=없음 절+베이스=s2 fetch=20"*"BUNDLE lint"*) ok "F12 기록 줄이 검사보다 먼저 나온다" ;; *) bad "F12 기록 줄이 검사보다 먼저 나온다" "$out" ;; esac
  has "F12 묶음 단계마다 자리를 잡는다" "$out" "check-push: 자리 잡음 단계 lint (0초 대기)"
  has "F12 마지막 묶음 단계도 자리를 잡는다" "$out" "check-push: 자리 잡음 단계 check-cheap (0초 대기)"
  out=$(sed -n 's/=.*$//p' "$stamp" | tr '\n' ' ')
  check "F12 도장 v2 필드" "$out" "v commit at bash 합침 base base출처 fetch tested_tree sections goals 절+베이스 충돌경로 대역 병렬 자리대기 재사용 재사용절 시간예산 시도 CI몫 fetch베이스 유도목표 유도없음 유도릴리스 "
  check "F12 재사용을 끈 실행의 도장은 재사용=꺼짐" "$(check_push_field "$stamp" 재사용)" "꺼짐"
  check "F12 재사용을 끈 실행의 도장은 재사용절=꺼짐" "$(check_push_field "$stamp" 재사용절)" "꺼짐"
  check "F12 사적 저장소에서는 자리를 기다리지 않는다" "$(check_push_field "$stamp" 자리대기)" "0"
  check "F12 자리를 잡은 묶음 단계는 CC_TEST_SLOT_HELD=1 을 받는다" "$(tr '\n' ' ' < "$T/held.log")" "lint:1 readme:1 check-cheap:1 "
  before=$(cksum < "$stamp")

  # --- F39 CC_TEST_SLOTS=0 -------------------------------------------------------
  stamp_keep="$T/stamp.keep"
  cp "$stamp" "$stamp_keep"
  rm -f "$stamp"
  : > "$T/held.log"
  out=$(cprun CC_PIPELINE_RUN_ID=t CC_TEST_SLOTS=0); rc=$?
  check "F39 자리를 끄면 통과하고 자리대기=0" "$rc $(check_push_field "$stamp" 자리대기)" "0 0"
  hasnt "F39 자리를 끄면 자리 잡음 줄이 없다" "$out" "자리 잡음"
  check "F39 자리를 끄면 묶음 단계에 CC_TEST_SLOT_HELD 가 없다" "$(tr '\n' ' ' < "$T/held.log")" "lint:unset readme:unset check-cheap:unset "
  rm -f "$stamp"
  : > "$T/held.log"
  # The run is unattended and CC_TEST_SLOTS is unset, so it follows the default
  # constant of scripts/test-slots.sh: the expected outcome is derived from it.
  v=$(CC_PIPELINE_RUN_ID=t && unset CC_TEST_SLOTS && ts_set_count 2>/dev/null && printf '%s' "$TS_N")
  out=$(cprun CC_PIPELINE_RUN_ID=t CC_TEST_SLOTS_DIR="$T/dflt-slots"); rc=$?
  check "F39 CC_TEST_SLOTS 가 없는 기본 실행은 통과하고 자리대기=0" "$rc $(check_push_field "$stamp" 자리대기)" "0 0"
  if [ "${v:-0}" -gt 0 ]; then
    has "F39 무인 기본값이 켜졌으면 기본 실행도 자리를 잡는다" "$out" "자리 잡음 단계 lint"
    check "F39 무인 기본값이 켜졌으면 묶음 단계가 CC_TEST_SLOT_HELD=1 을 받는다" "$(tr '\n' ' ' < "$T/held.log")" "lint:1 readme:1 check-cheap:1 "
    check "F39 무인 기본값이 켜졌으면 준 저장소를 쓴다" "$([ -e "$T/dflt-slots" ] && echo 있음 || echo 없음)" "있음"
  else
    hasnt "F39 기본 실행은 자리 잡음 줄이 없다" "$out" "자리 잡음"
    check "F39 기본 실행은 묶음 단계에 CC_TEST_SLOT_HELD 가 없다" "$(tr '\n' ' ' < "$T/held.log")" "lint:unset readme:unset check-cheap:unset "
    check "F39 기본 실행은 준 저장소를 만들지 않는다" "$([ -e "$T/dflt-slots" ] && echo 있음 || echo 없음)" "없음"
  fi
  # A step started without a slot at the wait cap passes CC_TEST_SLOT_HELD=1
  # on too: the only slot is held by a live process that is not this run.
  rm -f "$stamp"
  : > "$T/held.log"
  rm -rf "$T/free-slots"
  mkdir -p "$T/free-slots/slot-1"
  printf 'pool %s %s\n' "$$" "$(ts_fp "$$")" > "$T/free-slots/slot-1/owner"
  out=$(cprun CC_PIPELINE_RUN_ID=t CC_TEST_SLOTS=1 CC_TEST_SLOTS_DIR="$T/free-slots" CC_TEST_SLOTS_WAIT_MAX=0); rc=$?
  check "F39 상한에 닿아 자리 없이 띄운 묶음 단계는 통과한다" "$rc" "0"
  has "F39 자리 없이 띄운 묶음 단계는 상한 경고를 남긴다" "$out" "상한 0초에 닿았다, 자리 없이 띄운다 — 단계 lint"
  check "F39 자리 없이 띄운 묶음 단계도 CC_TEST_SLOT_HELD=1 을 받는다" "$(tr '\n' ' ' < "$T/held.log")" "lint:1 readme:1 check-cheap:1 "
  rm -rf "$T/free-slots"
  mv -f "$stamp_keep" "$stamp"

  # --- F19 head 모드는 합친 도장을 바꾸지 않는다 ------------------------------------
  out=$(cprun); rc=$?
  check "F19 head 모드 실행이 같은 트리의 합친 도장을 그대로 둔다" "$rc $(cksum < "$stamp")" "0 $before"
  has "F19 그 사실을 안내한다" "$out" "head 모드 도장으로 바꾸지 않는다"

  # --- F14 합친 트리 실패 -------------------------------------------------------
  : > "$T/gh.log"
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_SECTIONS=s1,s2); rc=$?
  check "F14 종료 1, 도장 없음" "$rc $(stamp_count)" "1 0"
  case "$out" in
    *"check-push: 합친 트리 실패 — base=$sm2 단계=절=s2,s1"*"head 만 다시 돌리기 (워크트리에서) — bash scripts/test-gate.sh --sections s1 헤드에 없는 항목=s2"*"bash scripts/test-tree.sh base-verdict --base $sm2 --head $sh --expect $tm --sections s2,s1 --jobs 4"*"gh run list --repo Nharu/cc-cmds --commit $sm2 --json workflowName,conclusion,databaseId — 워크플로마다, 런 없음 또는 진행 중이면 그 워크플로의 베이스 상태는 모름이다 (초록이 아니다)"*)
      ok "F14 메시지 넷이 차례로 나온다" ;;
    *) bad "F14 메시지 넷이 차례로 나온다" "$out" ;;
  esac
  hasnt "F14 원인 판정 줄은 repro 가 아니다" "$out" "test-tree.sh repro"
  hasnt "F14 기본 병렬에는 목록 전체 주의 줄이 없다" "$out" "CHECK_PUSH_JOBS=1 의 실패 단계는"
  hasnt "F14 gh run list 에 --workflow 가 없다" "$out" "--workflow"
  check "F14 gh 대역은 불리지 않았다" "$(cat "$T/gh.log")" ""

  # --- F35 원인 판정 줄은 실패한 항목만 base-verdict 에 넘긴다 ---------------------
  # An ancestor base with two goals of which only g1 fails: the line names g1
  # alone, and nothing of the sections or the passing goal.
  : > "$T/fail-g1"
  out=$(cprun CHECK_PUSH_BASE="$sa" CHECK_PUSH_GOALS=g1,g2); rc=$?
  rm -f "$T/fail-g1"
  check "F35 조상 목표 실패: 종료 1, 도장 없음" "$rc $(stamp_count)" "1 0"
  has "F35 조상 목표 실패: 단계는 실패한 목표 하나" "$out" "check-push: 합친 트리 실패 — base=$sa 단계=목표=g1"
  has "F35 조상 목표 실패: 원인 판정 줄이 실패한 목표만 넘긴다" "$out" "bash scripts/test-tree.sh base-verdict --base $sa --head $sh --expect $th --goals g1 --jobs 4"
  hasnt "F35 조상 목표 실패: 통과한 목표는 넘기지 않는다" "$out" "--goals g1,g2"
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_JOBS=1 CHECK_PUSH_SECTIONS=s1,s2); rc=$?
  check "F35 직렬 실패: 종료 1" "$rc" "1"
  has "F35 직렬 실패: 원인 판정 줄이 --jobs 1 을 넘긴다" "$out" "bash scripts/test-tree.sh base-verdict --base $sm2 --head $sh --expect $tm --sections s2,s1 --jobs 1"
  has "F35 직렬 실패: 목록 전체 주의 줄이 원인 판정 줄 다음에 나온다" "$out" "--jobs 1
check-push: CHECK_PUSH_JOBS=1 의 실패 단계는 목록 전체를 이름 댄다 — 원인 판정의 브랜치 결함 항목에는 이 트리에서 통과한 항목이 섞일 수 있다"

  # --- F20 순서 ----------------------------------------------------------------
  : > "$T/order.log"
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_JOBS=1 CHECK_PUSH_SECTIONS=s1 CHECK_PUSH_GOALS=g2,g1); rc=$?
  check "F20 통과" "$rc" "0"
  check "F20 묶음, 이어 절 한 번, 이어 목표 make 한 번" "$(grep -v -e 'gate:--list' -e 'print-rest-goals' "$T/order.log" | sed 's/|.*$//' | tr '\n' ' ')" "bundle:lint bundle:readme bundle:check-cheap gate:--sections s1 make:--no-print-directory g2 g1 "
  check "F20 CHECK_PUSH_JOBS=1 의 도장은 병렬=1" "$(check_push_field "$stamp" 병렬)" "1"

  # --- F30 잡 풀: 호출 모양, 순서, 격리, 기록 ----------------------------------------
  # g1 has no estimate, so it counts as the heaviest and starts with the lane;
  # g2 is the lightest and waits for a free slot of the two.
  : > "$T/order.log"; : > "$T/env.log"; : > "$T/recadd.log"
  printf 'test-gate: 예상 — 요청한 절 1개, needs 로 함께 도는 절 0개\ns1\t5\t실측\n@head\t1\t실측\nmake:g2\t1\t실측\nmake:g1\t-\t없음\n' > "$T/estimate.txt"
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_JOBS=2 CHECK_PUSH_SECTIONS=s1 CHECK_PUSH_GOALS=g2,g1); rc=$?
  check "F30 통과하고 도장은 병렬=2" "$rc $(check_push_field "$stamp" 병렬)" "0 2"
  has "F30 대역 gate 면 레인 분할 불가를 알린다" "$out" "check-push: 레인 분할 불가 — 한 레인으로 돈다"
  check "F30 절은 한 레인으로 한 번, 목표는 목표마다 make 한 번" "$(grep -e '^gate:--sections' -e '^make:--no-print-directory' "$T/order.log" | sort | tr '\n' ' ')" "gate:--sections s1 make:--no-print-directory g1 make:--no-print-directory g2 "
  check "F30 가장 가벼운 g2 가 마지막에 시작한다" "$(grep -e '^gate:--sections' -e '^make:--no-print-directory' "$T/order.log" | tail -n 1)" "make:--no-print-directory g2"
  has "F30 예상은 시험 트리의 test-gate 에 절과 목표를 함께 묻는다" "$(cat "$T/order.log")" "gate:--estimate --sections s1 --goals g2,g1 --timing-table "
  check "F30 잡 출력은 풀에 넣은 순서대로 찍힌다" "$(printf '%s\n' "$out" | sed -n 's/^=== check-push: 잡 \(.*\) ===$/\1/p' | tr '\n' '|')" "레인 1(s1)|목표 g2|목표 g1|"
  check "F30 잡이 끝날 때마다 끝 줄" "$(printf '%s\n' "$out" | grep -c '^check-push: 끝 — .* rc=0 [0-9]*초$')" "3"
  case "$(cat "$T/env.log")" in
    *"env:TMPDIR=$T/tmp/cc-test-tree."*"/pool/job-0/tmp|OUT=$T/tmp/cc-test-tree."*"/pool/job-0/marks.tsv|REC=$W/.git/cc-cmds-gate-timing.tsv"*)
      ok "F30 레인은 자기 TMPDIR·표지 파일과 메인 레포의 기록 경로를 받는다" ;;
    *) bad "F30 레인은 자기 TMPDIR·표지 파일과 메인 레포의 기록 경로를 받는다" "$(cat "$T/env.log")" ;;
  esac
  check "F30 목표 잡은 기록을 끈다" "$(grep -c '^menv:--no-print-directory g[12]|REC=off$' "$T/env.log")" "2"
  check "F30 끝난 목표의 소요를 메인 레포 기록에 한 번 넘긴다" "$(grep -c '^REC=' "$T/recadd.log") $(grep '^REC=' "$T/recadd.log") $(grep '^make:' "$T/recadd.log" | cut -f1 | sort | tr '\n' ' ')" "1 REC=$W/.git/cc-cmds-gate-timing.tsv make:g1 make:g2 "

  # --- F31 절과 목표가 함께 실패한다 ------------------------------------------------
  # s2 leaves the row file s1 refuses, so the lane fails and names s1 alone in
  # its rerun line; g1's make fails too, and every job still runs to its end.
  : > "$T/order.log"
  : > "$T/gate-rerun-line"; : > "$T/fail-g1"
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_FAIL_FAST=0 CHECK_PUSH_JOBS=4 CHECK_PUSH_SECTIONS=s1,s2 CHECK_PUSH_GOALS=g1,g2); rc=$?
  rm -f "$T/gate-rerun-line" "$T/fail-g1"
  check "F31 종료 1, 도장 없음" "$rc $(stamp_count)" "1 0"
  has "F31 단계가 실패한 절과 목표를 함께 든다" "$out" "check-push: 합친 트리 실패 — base=$sm2 단계=절=s1 목표=g1"
  has "F31 다시 돌리기 줄이 절과 목표를 한 줄에 싣는다" "$out" "head 만 다시 돌리기 (워크트리에서) — bash scripts/test-gate.sh --sections s1 && make --no-print-directory g1 헤드에 없는 항목=없음"
  check "F31 한 잡이 실패해도 모든 잡이 끝까지 돈다" "$(printf '%s\n' "$out" | grep -c '^check-push: 끝 — ')" "3"
  has "F31 실패한 목표를 이름 댄다" "$out" "check-push: 목표 g1 가 종료 코드 1 로 끝났다"

  # --- F32 합계 줄 없는 레인 ---------------------------------------------------------
  : > "$T/gate-no-total"
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_JOBS=2 CHECK_PUSH_SECTIONS=s1); rc=$?
  rm -f "$T/gate-no-total"
  check "F32 종료 코드 0 이어도 합계 줄이 없는 레인은 실패다" "$rc $(stamp_count)" "1 0"
  has "F32 합계 줄이 없다고 알린다" "$out" "check-push: 레인 1(s1) 의 출력에 합계 줄(test-gate: <n> passed, <n> failed)이 없다"

  # --- F33 CHECK_PUSH_JOBS 검증 -------------------------------------------------------
  : > "$T/order.log"
  for v in abc 0 -1 2x 04; do
    out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_JOBS="$v"); rc=$?
    check "F33 CHECK_PUSH_JOBS=$v → 2" "$rc" "2"
  done
  has "F33 거부가 변수를 이름 댄다" "$out" "check-push: CHECK_PUSH_JOBS=04 는 양의 정수가 아니다"
  check "F33 거부는 검사 전에 끝난다" "$(grep -c '^bundle:' "$T/order.log")" "0"
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_JOBS= CHECK_PUSH_GOALS=g2,g1); rc=$?
  check "F33 빈 값은 기본 4 이고 잡 수 2 로 줄인다" "$rc $(check_push_field "$stamp" 병렬)" "0 2"

  # --- F34 진행 줄 -------------------------------------------------------------------
  : > "$T/gate-slow"
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_JOBS=2 CC_CHECK_PUSH_PROGRESS_SECS=1 CHECK_PUSH_SECTIONS=s1 CHECK_PUSH_GOALS=g1); rc=$?
  rm -f "$T/gate-slow"
  rc=$(printf '%s\n' "$out" | grep -c '^check-push: 진행 — 끝난 잡 [0-9]/2 · 가장 오래 도는 잡 레인 1(s1) [0-9]*초째(예상 [^)]*) · 전체 [0-9]*초$')
  if [ "$rc" -ge 1 ]; then ok "F34 도는 동안 진행 줄이 정해진 모양으로 찍힌다 (${rc}줄)"; else bad "F34 도는 동안 진행 줄이 정해진 모양으로 찍힌다" "$out"; fi
  rm -f "$T/estimate.txt"
  : > "$T/order.log"
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_SECTIONS=s9); rc=$?
  check "F20 모르는 항목은 lint 전에 실패한다" "$rc $(grep -c '^bundle:' "$T/order.log")" "1 0"
  has "F20 모르는 항목을 이름 댄다" "$out" "check-push: 모르는 절 s9"
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_GOALS=s1); rc=$?
  has "F20 절을 목표로 주면 CHECK_PUSH_SECTIONS 를 이름 댄다" "$rc $out" "CHECK_PUSH_SECTIONS 로 준다"

  # --- F16 FETCH_HEAD 없음·오래됨 -------------------------------------------------
  rm -f "$W/.git/FETCH_HEAD"
  out=$(cprun CC_PIPELINE_RUN_ID=t); rc=$?
  check "F16 FETCH_HEAD 없음 → 4, 도장 없음" "$rc $(stamp_count)" "4 0"
  has "F16 --refmap= fetch 를 이름 댄다" "$out" "git fetch --no-tags --refmap= origin refs/heads/master (게이트 --surface 읽기 --reach 협업)"
  hasnt "F16 복제 전에 끝난다" "$out" "시험 트리 —"
  fh_line "$sm2"
  touch -t 202001010000 "$W/.git/FETCH_HEAD"
  out=$(cprun CC_PIPELINE_RUN_ID=t); rc=$?
  check "F16 오래된 FETCH_HEAD → 4, 도장 없음" "$rc $(stamp_count)" "4 0"

  # --- F26 새 base 에서 실패한 트리에는 도장이 없다 ---------------------------------
  fh_line "$sb1"
  out=$(cprun CC_PIPELINE_RUN_ID=t); rc=$?
  check "F26 base B1 과 합쳐 통과해 도장을 받는다" "$rc $(stamp_count) $(check_push_field "$stamp" base)" "0 1 $sb1"
  fh_line "$sm3"
  out=$(cprun CC_PIPELINE_RUN_ID=t); rc=$?
  check "F26 새 base 와 합쳐 실패하면 1 이고 그 열쇠의 도장이 없다" "$rc $(stamp_count)" "1 0"
  out=$(cvrun CC_PIPELINE_RUN_ID=t); rc=$?
  check "F26 그 뒤 verify 1" "$rc" "1"
  fh_line "$sb1"
  out=$(cprun CC_PIPELINE_RUN_ID=t); rc=$?
  touch -t 202001010000 "$W/.git/FETCH_HEAD"
  out=$(cprun CC_PIPELINE_RUN_ID=t); rc=$?
  check "F26 도장을 둔 뒤 FETCH_HEAD 를 묵히면 4 이고 도장이 없다" "$rc $(stamp_count)" "4 0"

  # --- F21 다른 base 브랜치 ---------------------------------------------------------
  (cd "$W" && sgit fetch -q --no-tags --refmap= origin refs/heads/review-base/x) > /dev/null 2>&1
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_BASE_BRANCH=review-base/x); rc=$?
  check "F21 CHECK_PUSH_BASE_BRANCH 의 FETCH_HEAD 줄이 base 다" "$rc $(check_push_field "$stamp" base)" "0 $sb1"
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_BASE_BRANCH='a..b'); rc=$?
  check "F21 형식이 틀린 브랜치 이름 → 2" "$rc" "2"

  # --- F17 지정 base ----------------------------------------------------------------
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_BASE="$sa"); rc=$?
  check "F17 더 오래된 조상을 지정하면 도장 base출처=지정, 합침=조상" "$rc $(check_push_field "$stamp" base출처) $(check_push_field "$stamp" 합침)" "0 지정 조상"
  hand_stamp 조상 지정 없음
  out=$(cvrun CC_PIPELINE_RUN_ID=t); rc=$?
  check "F17 base출처=지정 도장에 무인 verify 1" "$rc" "1"
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_BASE=no-such-ref); rc=$?
  check "F17 커밋으로 풀리지 않는 CHECK_PUSH_BASE → 2, 도장 없음" "$rc $(stamp_count)" "2 0"

  # --- F18 / F27 verify ---------------------------------------------------------
  mkdir -p "$W/.git/cc-cmds-check-push"
  printf 'commit=%s\nat=t\n' "$sh" > "$stamp"
  out=$(cvrun CC_PIPELINE_RUN_ID=t); rc=$?
  check "F18 무인 런의 v1 → 1" "$rc" "1"
  out=$(cvrun); rc=$?
  check "F18 인터랙티브 v1 → 0" "$rc" "0"
  has "F18 인터랙티브 v1 은 기록 없음을 찍는다" "$out" "check-push: 기록 없음(v1 도장)"
  hand_stamp 안함 없음 없음
  out=$(cvrun CC_PIPELINE_RUN_ID=t); rc=$?
  check "F18 무인 런의 안함 → 1" "$rc" "1"
  out=$(cvrun); rc=$?
  check "F18 인터랙티브 안함 → 0" "$rc" "0"
  has "F18 v2 도장이면 기록 줄을 찍는다" "$out" "check-push: 시험 트리 — 합침=안함 base=$sm2 base출처=없음 head=$sh tree=$tm"
  hand_stamp 합침 FETCH_HEAD 없음
  out=$(cvrun CC_PIPELINE_RUN_ID=t); rc=$?
  check "F18 무인 런의 합침·FETCH_HEAD·대역=없음 → 0" "$rc" "0"
  fh_line "$sm2"
  out=$(cprun CC_PIPELINE_RUN_ID=t CC_TEST_TREE_SHARD="$T/bin/shard"); rc=$?
  has "F27 기록 줄에 대역 이름들" "$out" "대역=CC_CHECK_PUSH_MAKE,CC_TEST_TREE_GATE,CC_TEST_TREE_SHARD,CC_TEST_TREE_MAKE,CC_TEST_TREE_GH"
  check "F27 도장에 대역 이름들" "$(check_push_field "$stamp" 대역)" "CC_CHECK_PUSH_MAKE,CC_TEST_TREE_GATE,CC_TEST_TREE_SHARD,CC_TEST_TREE_MAKE,CC_TEST_TREE_GH"
  out=$(cvrun CC_PIPELINE_RUN_ID=t); rc=$?
  check "F27 무인 verify 는 대역 도장에 1" "$rc" "1"
  out=$(cvrun); rc=$?
  check "F27 인터랙티브 verify 는 대역 도장에 0" "$rc" "0"
  sed 's/^대역=.*$/대역=없음/' "$stamp" > "$T/stamp.tmp" && mv -f "$T/stamp.tmp" "$stamp"
  out=$(cvrun CC_PIPELINE_RUN_ID=t); rc=$?
  check "F27 그 줄만 대역=없음 으로 바꾸면 무인 verify 0" "$rc" "0"
  out=$(cvrun); rc=$?
  check "F27 인터랙티브 verify 도 0" "$rc" "0"

  # --- F15 충돌 ------------------------------------------------------------------
  (cd "$W" && sgit checkout -q hx) > /dev/null 2>&1
  out=$(cprun CC_PIPELINE_RUN_ID=t); rc=$?
  check "F15 충돌이면 head 를 시험하고 통과한다" "$rc" "0"
  has "F15 head 만 시험했고 CI 런이 없다는 줄" "$out" "check-push: 합침=충돌 base-only.txt — 합친 트리는 시험하지 않았다, CI 런 없음"
  hasnt "F15 합침=합침 줄이 없다" "$out" "합침=합침"
  check "F15 도장 합침=충돌, 경로, 시험한 트리는 head" "$(check_push_field "$W/.git/cc-cmds-check-push/$thx" 합침) $(check_push_field "$W/.git/cc-cmds-check-push/$thx" 충돌경로) $(check_push_field "$W/.git/cc-cmds-check-push/$thx" tested_tree)" "충돌 base-only.txt $thx"
  sed 's/^대역=.*$/대역=없음/' "$W/.git/cc-cmds-check-push/$thx" > "$T/stamp.tmp" && mv -f "$T/stamp.tmp" "$W/.git/cc-cmds-check-push/$thx"
  out=$(cvrun CC_PIPELINE_RUN_ID=t); rc=$?
  check "F15 같은 필드에 대역=없음 인 v2 도장에 무인 verify 0" "$rc" "0"
  (cd "$W" && sgit checkout -q h) > /dev/null 2>&1

  # --- F29 무인 런에서 gate.sh 를 바꾼 head 는 절을 지명한다 -------------------------
  # The seed history has no gate.sh, so the head that changes it is one more
  # commit on top of h rather than an edit of the seed: the fixed shas the cases
  # above read stay where they are. The unattended cases above name no section
  # and still end as before, because their heads leave gate.sh absent.
  (
    cd "$W" || exit 1
    sgit checkout -q -b hg h && mkdir -p plugins/cc-cmds/orchestrator \
      && printf 'g\n' > plugins/cc-cmds/orchestrator/gate.sh && sgit add -A && sgit commit -q -m G
  ) > /dev/null 2>&1 || bad "F29 픽스처" "gate.sh 커밋 실패"
  tg=$(cd "$W" && git rev-parse 'HEAD^{tree}')
  fh_line "$sm2"
  : > "$T/order.log"
  out=$(cprun CC_PIPELINE_RUN_ID=t); rc=$?
  check "F29 무인, gate.sh 를 바꾼 head, 절 없음 → 2" "$rc" "2"
  has "F29 거부가 CHECK_PUSH_SECTIONS 로 절을 지명하라고 알린다" "$out" "CHECK_PUSH_SECTIONS=<id,...> 로 바꾼 축의 test-gate 절을 지명해 다시 부른다"
  hasnt "F29 거부는 복제 전에 끝난다" "$out" "시험 트리 —"
  check "F29 검사를 부르지 않았고 그 트리에 도장이 없다" "$(grep -c '^bundle:' "$T/order.log") $([ -f "$W/.git/cc-cmds-check-push/$tg" ] && echo 있음 || echo 없음)" "0 없음"
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_GOALS=g1); rc=$?
  check "F29 목표만 준 무인 실행도 → 2" "$rc" "2"
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_SECTIONS=s1); rc=$?
  hasnt "F29 절을 주면 거부 문면이 없다" "$out" "시험할 절을 지명해야 한다"
  has "F29 절을 주면 검사로 나아간다" "$out" "시험 트리 —"
  out=$(cprun); rc=$?
  hasnt "F29 대화형 실행은 거부하지 않는다" "$out" "시험할 절을 지명해야 한다"
  (cd "$W" && sgit checkout -q h) > /dev/null 2>&1
  fh_line "$sm2"
  out=$(cprun CC_PIPELINE_RUN_ID=t); rc=$?
  check "F29 gate.sh 를 바꾸지 않은 head 는 절 없이도 통과한다" "$rc" "0"
  hasnt "F29 그때 거부 문면이 없다" "$out" "시험할 절을 지명해야 한다"
  (cd "$W" && sgit checkout -q hg) > /dev/null 2>&1
  fh_line 0123456789abcdef0123456789abcdef01234567
  out=$(cprun CC_PIPELINE_RUN_ID=t); rc=$?
  check "F29 base 커밋 객체가 없으면 → 4" "$rc" "4"
  hasnt "F29 그때 거부 문면이 없다 (객체 없음 갈래를 가리지 않는다)" "$out" "시험할 절을 지명해야 한다"
  has "F29 그때 fetch 를 안내한다" "$out" "객체 없음 — 0123456789abcdef0123456789abcdef01234567"
  (cd "$W" && sgit checkout -q h) > /dev/null 2>&1

  # --- F41 통과 재사용 -------------------------------------------------------------
  # Through the doubles check-cheap reads h.txt and goal g1 reads goals.txt;
  # git-cc makes check-cheap run git, which counts as reading the whole tree.
  # Each case commits on branch hr, so the trees are new to the stamp cases
  # around it. A volume where reads do not move the access time records
  # nothing, so every case checks the same thing on both and only the
  # expected reuse differs.
  local items_dir v crec
  items_dir="$W/.git/cc-cmds-check-push-items"
  rm -rf "$items_dir"
  v=0
  if tr_canary "$T/probe"; then v=1; fi
  rm -rf "$T/probe" "$T/probe".*
  ve() { if [ "$v" = 1 ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
  cur_tree() { (cd "$W" && git rev-parse 'HEAD^{tree}'); }
  cur_reuse() { check_push_field "$W/.git/cc-cmds-check-push/$(cur_tree)" 재사용; }
  cur_field() { check_push_field "$W/.git/cc-cmds-check-push/$(cur_tree)" "$1"; }
  rw() { (cd "$W" && printf '%b' "$2" > "$1" && sgit add -A && sgit commit -q -m r) > /dev/null 2>&1; }
  crr() { cprun "$@" CHECK_PUSH_REUSE=1 CHECK_PUSH_JOBS=2 CHECK_PUSH_GOALS=g1; }
  cirun() { (cd "$W" && env "$@" bash "$self" items 2>&1); }
  printf 'h.txt\n' > "$T/reads-cc"
  printf 'goals.txt\n' > "$T/reads-g1"
  (cd "$W" && sgit checkout -q -b hr h) > /dev/null 2>&1
  rw r.txt 'r\n'
  : > "$T/cwd.log"
  out=$(crr); rc=$?
  check "F41 첫 실행은 통과하고 재사용이 없다" "$rc $(cur_reuse)" "0 없음"
  check "F41 재사용을 켠 실행의 도장은 다시 쓴 절이 없으면 재사용절=없음" "$(cur_field 재사용절)" "없음"
  has "F41 check-cheap 은 자기 항목 체크아웃에서 돈다" "$(cat "$T/cwd.log")" "/items/cc git="
  has "F41 check-cheap 환경의 PATH 맨 앞에 git 감시 꼴" "$(cat "$T/cwd.log")" "/items/cc.shim/git"
  check "F41 통과한 두 항목의 기록" "$(ls "$items_dir" 2>/dev/null | tr '\n' ' ')" "$(ve 'make:check-cheap make:g1 ' '')"
  : > "$T/cwd.log"
  out=$(crr); rc=$?
  check "F41 같은 트리의 다음 실행은 두 항목을 재사용한다" "$rc $(cur_reuse)" "0 $(ve make:check-cheap,make:g1 없음)"
  check "F41 재사용한 check-cheap 은 돌지 않는다" "$(grep -c '^cc ' "$T/cwd.log")" "$(ve 0 1)"
  check "F41 재사용한 항목마다 재사용 줄" "$(printf '%s\n' "$out" | grep -c '^check-push: 재사용 make:.* ← ')" "$(ve 2 0)"
  rw sections/s1.sh '[ ! -e rows.txt ] # longer\n'
  out=$(crr); rc=$?
  check "F41 읽지 않은 파일의 내용과 크기만 바뀐 트리는 두 항목을 재사용한다" "$rc $(cur_reuse)" "0 $(ve make:check-cheap,make:g1 없음)"
  rw h.txt 'h2\n'
  : > "$T/cwd.log"
  out=$(crr); rc=$?
  check "F41 읽은 파일이 바뀌면 그 항목만 다시 돈다" "$rc $(cur_reuse) $(grep -c '^cc ' "$T/cwd.log")" "0 $(ve make:g1 없음) 1"
  rw new.txt 'n\n'
  out=$(crr); rc=$?
  check "F41 경로가 늘면 두 항목 모두 다시 돈다" "$rc $(cur_reuse)" "0 없음"
  rw sections/s1.sh ''
  out=$(crr); rc=$?
  check "F41 읽지 않은 파일이 비면 두 항목 모두 다시 돈다" "$rc $(cur_reuse)" "0 없음"
  out=$(crr -u CC_TEST_TREE_GH); rc=$?
  check "F41 대역이 다르면 다시 돈다" "$rc $(cur_reuse)" "0 없음"
  # One record per item and tree: the pass under the other doubles replaced it.
  out=$(crr); rc=$?
  check "F41 대역이 다른 통과가 그 트리의 기록을 바꿔 원래 대역의 실행도 다시 돈다" "$rc $(cur_reuse)" "0 없음"
  for crec in "$items_dir"/*/*; do
    [ -f "$crec" ] || continue
    awk -F'\t' 'BEGIN { OFS = "\t" } $1 == "시각" { $2 = 1000 } { print }' "$crec" > "$T/rec.tmp" && mv -f "$T/rec.tmp" "$crec"
  done
  out=$(crr); rc=$?
  check "F41 24시간보다 오래된 기록은 쓰지 않는다" "$rc $(cur_reuse)" "0 없음"
  : > "$T/git-cc"
  rw h.txt 'h3\n'
  out=$(crr); rc=$?
  check "F41 git 을 부른 check-cheap 은 트리 전체를 읽은 것으로 기록된다" "$rc $(awk -F'\t' '$1 == "트리전체" { print $2 }' "$items_dir/make:check-cheap/$(cur_tree)" 2>/dev/null)" "0 $(ve 예 '')"
  out=$(crr); rc=$?
  check "F41 트리 전체 기록은 같은 트리·커밋·base 에서 재사용한다" "$rc $(cur_reuse)" "0 $(ve make:check-cheap,make:g1 없음)"
  rw r.txt 'r2\n'
  out=$(crr); rc=$?
  check "F41 트리 전체 기록은 읽지 않은 파일만 바뀌어도 다시 돈다" "$rc $(cur_reuse)" "0 $(ve make:g1 없음)"
  rm -f "$T/git-cc"
  # Goal g1 runs the commands of $T/run-g1 in its item checkout, and each case
  # reads the 트리전체 field of the record that run leaves. The record of the
  # tree is removed first, so g1 runs again on the same tree.
  sgit init -q "$T/fx" > /dev/null 2>&1
  (cd "$T/fx" && printf 'f\n' > f && sgit add f && sgit commit -q -m f) > /dev/null 2>&1
  printf 'outside\n' > "$T/outside.txt"
  gw() {  # <case> <commands run by g1 in its checkout> <트리전체 expected>
    printf 'ck=$(pwd -P)\n%s\n' "$2" > "$T/run-g1"
    rm -rf "$items_dir/make:g1" "$T/fxc" "$T/cpo"
    out=$(crr); rc=$?
    rm -f "$T/run-g1"
    check "F41 $1" "$rc $(awk -F'\t' '$1 == "트리전체" { print $2 }' "$items_dir/make:g1/$(cur_tree)" 2>/dev/null)" "0 $(ve "$3" '')"
  }
  gw "-C 로 체크아웃을 향한 git 은 트리 전체" "cd \"$T/fx\" && git -C \"\$ck\" status > /dev/null 2>&1" 예
  gw "GIT_DIR 로 체크아웃을 향한 git 은 트리 전체" "cd \"$T/fx\" && GIT_DIR=\"\$ck/.git\" git status > /dev/null 2>&1" 예
  gw "체크아웃을 경로 인자로 받은 git 은 트리 전체" "cd \"$T\" && git clone -q \"\$ck\" \"$T/fxc\" > /dev/null 2>&1" 예
  gw "픽스처 저장소만 향한 git 은 트리 전체가 아니다" "git -C \"$T/fx\" status > /dev/null 2>&1" 아니오
  gw "작업 디렉터리만 체크아웃 안이고 밖을 밖으로 복제한 git 은 트리 전체가 아니다" "git clone -q \"$T/fx\" \"$T/fxc\" > /dev/null 2>&1" 아니오
  gw "작업 디렉터리에서 저장소를 찾은 git 은 .git 의 atime 으로 트리 전체" "git rev-parse HEAD > /dev/null 2>&1" 예
  tr_os_init
  if [ "$TR_OS" = bsd ]; then
    gw "체크아웃 파일을 이 OS 의 복제 선택지(-c)로 복사한 cp 는 트리 전체" "cp -c h.txt \"$T/cpo\"" 예
    gw "체크아웃 밖 파일만 복제 선택지(-c)로 복사한 cp 는 트리 전체가 아니다" "cp -c \"$T/outside.txt\" \"$T/cpo\"" 아니오
  else
    gw "체크아웃 파일을 이 OS 의 복제 선택지(--reflink=auto)로 복사한 cp 는 트리 전체" "cp --reflink=auto h.txt \"$T/cpo\"" 예
    gw "체크아웃 밖 파일만 복제 선택지(--reflink=auto)로 복사한 cp 는 트리 전체가 아니다" "cp --reflink=auto \"$T/outside.txt\" \"$T/cpo\"" 아니오
  fi
  gw "복제 선택지 없이 체크아웃 파일을 복사한 cp 는 트리 전체가 아니다" "cp h.txt \"$T/cpo\"" 아니오
  rm -rf "$T/fx" "$T/fxc" "$T/cpo" "$T/outside.txt"
  fh_line "$sm2"
  out=$(crr CC_PIPELINE_RUN_ID=t); rc=$?
  check "F41 합친 트리의 첫 실행은 head 트리의 기록을 쓰지 않는다" "$rc $(cur_reuse)" "0 없음"
  out=$(crr CC_PIPELINE_RUN_ID=t); rc=$?
  check "F41 같은 HEAD 와 base 의 합친 트리는 다음 실행이 재사용한다" "$rc $(cur_reuse) $(check_push_field "$W/.git/cc-cmds-check-push/$(cur_tree)" 합침)" "0 $(ve make:check-cheap,make:g1 없음) 합침"
  : > "$T/fail-g2"
  out=$(cprun CHECK_PUSH_REUSE=1 CHECK_PUSH_JOBS=2 CHECK_PUSH_GOALS=g1,g2); rc=$?
  rm -f "$T/fail-g2"
  check "F41 실패한 목표는 기록을 남기지 않는다" "$rc $([ -e "$items_dir/make:g2" ] && echo 있음 || echo 없음)" "1 없음"
  before=$(cksum < "$W/.git/cc-cmds-check-push/$(cur_tree)")
  rm -rf "$items_dir"
  : > "$T/order.log"
  out=$(cirun CC_PIPELINE_RUN_ID=t CHECK_PUSH_REUSE=1 CHECK_PUSH_JOBS=2 CHECK_PUSH_GOALS=g1 CHECK_PUSH_SECTIONS=s1); rc=$?
  check "F41 items 는 통과하고 합친 도장을 그대로 둔다" "$rc $(cksum < "$W/.git/cc-cmds-check-push/$(cur_tree)")" "0 $before"
  check "F41 items 는 묶음에서 check-cheap 을 부르고 절을 컷 다이제스트 뒤 레인으로 돌린다" "$(grep -e '^bundle:' -e '^gate:--sections' "$T/order.log" | sed 's/|.*$//' | tr '\n' ' ')" "bundle:check-cheap gate:--sections s1 --cut-digest gate:--sections s1 "
  has "F41 items 통과 줄은 다시 쓴 절이 없으면 재사용절=없음" "$out" "재사용절=없음). 도장은 건드리지 않는다"
  has "F41 items 통과 줄" "$out" "check-push: items 통과 — 커밋 "
  check "F41 items 의 통과 기록에 레인 기록이 더해진다" "$(ls "$items_dir" 2>/dev/null | tr '\n' ' ')|$(ls "$items_dir/lane" 2>/dev/null | wc -l | tr -d ' ')" "$(ve 'lane make:check-cheap make:g1 |1' '|0')"
  : > "$T/order.log"
  out=$(cirun CC_PIPELINE_RUN_ID=t CHECK_PUSH_REUSE=1 CHECK_PUSH_JOBS=2 CHECK_PUSH_GOALS=g1 CHECK_PUSH_SECTIONS=s1); rc=$?
  check "F41 다음 items 는 레인 기록으로 절을 다시 쓰고 돌리지 않는다" "$rc|$(grep -c '^gate:--sections s1$' "$T/order.log")" "0|$(ve 0 1)"
  has "F41 다음 items 의 통과 줄에 다시 쓴 절" "$out" "$(ve '재사용절=s1)' '재사용절=없음)')"
  has "F41 다시 쓴 절마다 재사용 절 줄" "$out" "$(ve 'check-push: 재사용 절 s1 ← ' 'check-push: items 통과')"
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_REUSE=1 CHECK_PUSH_JOBS=2 CHECK_PUSH_GOALS=g1 CHECK_PUSH_SECTIONS=s1); rc=$?
  check "F41 items 가 남긴 레인 기록을 run 이 다시 쓰고 도장에 재사용절=<ids>" "$rc $(cur_field 재사용절)" "0 $(ve s1 없음)"
  out=$(cirun CHECK_PUSH_REUSE=0); rc=$?
  check "F41 CHECK_PUSH_REUSE=0 의 items → 2" "$rc" "2"
  out=$(cirun CHECK_PUSH_REUSE=1 CHECK_PUSH_JOBS=1 CHECK_PUSH_GOALS=g1); rc=$?
  check "F41 CHECK_PUSH_JOBS=1 로 목표를 준 items → 2" "$rc" "2"
  out=$(cirun CHECK_PUSH_REUSE=1 CHECK_PUSH_JOBS=1 CHECK_PUSH_SECTIONS=s1); rc=$?
  check "F41 CHECK_PUSH_JOBS=1 로 절만 준 items → 2" "$rc|$(printf '%s' "$out" | grep -c '절은 한 test-gate 호출로 돌아 기록되지 않는다')" "2|1"
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_REUSE=0 CHECK_PUSH_JOBS=2 CHECK_PUSH_GOALS=g1); rc=$?
  check "F41 CHECK_PUSH_REUSE=0 은 기록이 있어도 재사용하지 않고 도장에 꺼짐" "$rc $(cur_reuse) $(cur_field 재사용절)" "0 꺼짐 꺼짐"
  # A release commit after items: g1 calls git in its checkout, so items
  # records it as a whole-tree record, and the release commit on top changes
  # only the version line and the top of CHANGELOG.md; the last run reuses g1
  # through the release relation. A release commit that also changes r.txt
  # runs g1 again.
  rel_commit() {  # <version> <CHANGELOG top block> [<file> <content>]
    (
      cd "$W" || exit 1
      mkdir -p plugins/cc-cmds/.claude-plugin
      printf '{\n  "name": "cc-cmds",\n  "version": "%s"\n}\n' "$1" > plugins/cc-cmds/.claude-plugin/plugin.json
      printf '# Changelog\n\n%b## [0.1.0] - 2026-01-01\n- a\n' "$2" > CHANGELOG.md
      [ -z "${3:-}" ] || printf '%b' "$4" > "$3"
      sgit add -A && sgit commit -q -m "release $1"
    ) > /dev/null 2>&1
  }
  rel_commit 0.1.0 ''
  printf 'git rev-parse HEAD > /dev/null 2>&1\n' > "$T/run-g1"
  rm -rf "$items_dir"
  fh_line "$sm2"
  out=$(cirun CC_PIPELINE_RUN_ID=t CHECK_PUSH_REUSE=1 CHECK_PUSH_JOBS=2 CHECK_PUSH_GOALS=g1); rc=$?
  check "F41 릴리스 앞 items 는 git 을 부른 g1 을 트리 전체로 기록한다" \
    "$rc $(cat "$items_dir"/make:g1/* 2>/dev/null | awk -F'\t' '$1 == "트리전체" { print $2; exit }')" "0 $(ve 예 '')"
  rel_commit 0.1.1 '## [0.1.1] - 2026-01-02\n- b\n\n'
  out=$(crr CC_PIPELINE_RUN_ID=t); rc=$?
  check "F41 릴리스 커밋 뒤 마지막 run 은 g1 을 다시 쓰고 도장 재사용= 에 넣는다" "$rc $(cur_reuse)" "0 $(ve make:check-cheap,make:g1 없음)"
  check "F41 릴리스 관계로 다시 쓴 항목만 재사용 줄 꼬리가 릴리스 차이" \
    "$(printf '%s\n' "$out" | grep -c '^check-push: 재사용 make:g1 ← .* (.*, 릴리스 차이)$') $(printf '%s\n' "$out" | grep -c '릴리스 차이')" "$(ve '1 1' '0 0')"
  rel_commit 0.1.2 '## [0.1.2] - 2026-01-03\n- c\n\n## [0.1.1] - 2026-01-02\n- b\n\n' r.txt 'r3\n'
  out=$(crr CC_PIPELINE_RUN_ID=t); rc=$?
  check "F41 릴리스 밖 파일도 바꾼 릴리스 커밋 뒤에는 g1 이 다시 돈다" "$rc $(cur_reuse)" "0 $(ve make:check-cheap 없음)"
  # Location queries leave a `git읽기` record, reused across a new HEAD and a
  # merged base. Goal g1 and section s9 ask where the repository is; goal g2
  # and section s8, the control, read HEAD. The cases commit on branch hq; the
  # base cases merge branch qb into it with --no-ff and name qb in FETCH_HEAD,
  # so qb is an ancestor of HEAD. The git watch shim sorts a call with a
  # GIT_CONFIG_GLOBAL or GIT_CONFIG_NOSYSTEM in its environment as strict, so
  # these runs drop the two the self-test exports and keep the user's git
  # configuration out with a HOME of their own.
  reuse_has() { case ",$(cur_reuse)," in *",$1,"*) echo 예 ;; *) echo 아니오 ;; esac; }
  sec_has() { case ",$(cur_field 재사용절)," in *",$1,"*) echo 예 ;; *) echo 아니오 ;; esac; }
  whole_of() { awk -F'\t' '$1 == "트리전체" { print $2 }' "$items_dir/make:$1/$(cur_tree)" 2>/dev/null; }
  mkdir -p "$T/home/.config"
  cpq() { cprun -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_NOSYSTEM HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" "$@"; }
  crq() { cpq "$@" CHECK_PUSH_REUSE=1 CHECK_PUSH_JOBS=2 CHECK_PUSH_GOALS=g1 CHECK_PUSH_SECTIONS=s9; }
  crc() { cpq "$@" CHECK_PUSH_REUSE=1 CHECK_PUSH_JOBS=2 CHECK_PUSH_GOALS=g2 CHECK_PUSH_SECTIONS=s8; }
  printf 'git rev-parse --show-toplevel > /dev/null\n' > "$T/run-g1"
  printf 'git rev-parse HEAD > /dev/null\n' > "$T/run-g2"
  printf 'goals.txt\n' > "$T/reads-g2"
  rm -rf "$items_dir"
  (
    cd "$W" || exit 1
    sgit checkout -q -b hq h
    printf '#!/usr/bin/env bash\n# fixture\n# --- section: s1 | group: g | covers: x | anchors: y ---\n# --- section: s8 | group: g | covers: x | anchors: y ---\n# --- section: s9 | group: g | covers: x | anchors: y ---\n# f1\n# end\n' > scripts/test-gate.sh
    printf 'git rev-parse HEAD > /dev/null\n' > sections/s8.sh
    printf 'git rev-parse --show-toplevel > /dev/null\n' > sections/s9.sh
    sgit add -A && sgit commit -q -m Q1
  ) > /dev/null 2>&1
  out=$(crq); rc=$?
  check "F41 git읽기: 위치 질의만 한 g1 은 git읽기로 기록된다" "$rc $(whole_of g1)" "0 $(ve git읽기 '')"
  out=$(crc); rc=$?
  check "F41 git읽기 대조군: rev-parse HEAD 를 부른 g2 는 트리 전체로 기록된다" "$rc $(whole_of g2)" "0 $(ve 예 '')"
  rw README.md 'readme 2\n'
  out=$(crq); rc=$?
  check "F41 git읽기: 읽지 않은 파일만 바꾼 다음 커밋에서 g1 과 레인 s9 를 재사용한다" "$rc $(reuse_has make:g1) $(sec_has s9)" "0 $(ve '예 예' '아니오 아니오')"
  out=$(crc); rc=$?
  check "F41 git읽기 대조군: g2 와 레인 s8 은 다음 커밋에서 다시 돈다" "$rc $(reuse_has make:g2) $(sec_has s8)" "0 아니오 아니오"
  rw goals.txt 'g2\ng1\n'
  out=$(crq); rc=$?
  check "F41 git읽기: g1 이 읽는 파일을 바꾼 커밋에서 g1 은 다시 돌고 레인 s9 는 재사용한다" "$rc $(reuse_has make:g1) $(sec_has s9)" "0 아니오 $(ve 예 아니오)"
  (cd "$W" && sgit branch -q qb hq && sgit checkout -q qb && printf 'readme 3\n' > README.md && sgit commit -q -am QB1 \
    && sgit checkout -q hq && sgit merge -q --no-ff --no-edit qb) > /dev/null 2>&1
  fh_line "$(cd "$W" && git rev-parse qb)"
  out=$(crq CC_PIPELINE_RUN_ID=t); rc=$?
  check "F41 git읽기: 읽지 않은 파일의 내용만 바꾼 베이스를 합친 뒤 g1 과 레인 s9 를 재사용한다" \
    "$rc $(cur_field 합침) $(reuse_has make:g1) $(sec_has s9)" "0 조상 $(ve '예 예' '아니오 아니오')"
  (cd "$W" && sgit checkout -q qb && printf 'q\n' > qnew.txt && sgit add -A && sgit commit -q -m QB2 \
    && sgit checkout -q hq && sgit merge -q --no-ff --no-edit qb) > /dev/null 2>&1
  fh_line "$(cd "$W" && git rev-parse qb)"
  out=$(crq CC_PIPELINE_RUN_ID=t); rc=$?
  check "F41 git읽기: 추적 경로를 하나 더한 베이스를 합친 뒤 g1 과 레인 s9 는 다시 돈다" \
    "$rc $(cur_field 합침) $(reuse_has make:g1) $(sec_has s9)" "0 조상 아니오 아니오"
  rm -f "$T/run-g2" "$T/reads-g2"
  rm -f "$T/run-g1"
  rm -f "$T/reads-cc" "$T/reads-g1"
  (cd "$W" && sgit checkout -q h) > /dev/null 2>&1

  # --- F43 유도: 바꾼 파일을 읽는 목표가 지명한 목표 뒤에 붙어 돈다 -------------------
  # Branch d adds a run/ goal whose entry script reads data/in.txt, so the
  # change derives it; h.txt, goals.txt and notes.txt are read by no goal.
  (
    cd "$W" || exit 1
    sgit checkout -q -b d h
    mkdir -p tools data
    printf 'g1\ng2\nrun/tools/r.sh\n' > goals.txt
    printf 'cat data/in.txt\n' > tools/r.sh
    printf 'in\n' > data/in.txt
    printf 'n\n' > notes.txt
    sgit add -A && sgit commit -q -m D
    sgit branch -q lb "$sa"
  ) > /dev/null 2>&1
  td=$(cd "$W" && git rev-parse 'HEAD^{tree}')
  dstamp="$W/.git/cc-cmds-check-push/$td"
  dgoals() { grep -e '^make:--no-print-directory' "$T/order.log" | tr '\n' ' '; }
  : > "$T/order.log"
  out=$(cprun CHECK_PUSH_BASE="$sa" CHECK_PUSH_JOBS=1 CHECK_PUSH_GOALS=g2); rc=$?
  check "F43 통과" "$rc" "0"
  has "F43 시험 트리 줄의 목표= 는 지명한 목표 그대로다" "$out" " 절=없음 목표=g2 "
  has "F43 유도 목표 줄" "$out" "check-push: 유도 목표 — 변경 파일 5개, 유도 1개: run/tools/r.sh"
  has "F43 유도 근거 없는 변경 파일 줄" "$out" "check-push: 유도 근거 없는 변경 파일 3개 — goals.txt h.txt notes.txt"
  check "F43 지명한 목표 뒤에 유도 목표가 붙어 돈다" "$(dgoals)" "make:--no-print-directory g2 run/tools/r.sh "
  check "F43 도장의 goals 는 합집합이고 유도목표·유도없음이 있다" \
    "$(check_push_field "$dstamp" goals) $(check_push_field "$dstamp" 유도목표) $(check_push_field "$dstamp" 유도없음)" "g2,run/tools/r.sh run/tools/r.sh 3"
  : > "$T/order.log"
  out=$(cprun CHECK_PUSH_BASE="$sa" CHECK_PUSH_JOBS=1 CHECK_PUSH_GOALS=run/tools/r.sh,g1); rc=$?
  check "F43 지명한 목표가 유도되면 지명 순서대로 한 번만 돈다" "$rc $(dgoals)" "0 make:--no-print-directory run/tools/r.sh g1 "
  # A goal other than run/ is entered through what `make -n` prints for it.
  printf 'bash tools/r.sh --self-test\n' > "$T/n-g1"
  : > "$T/order.log"
  out=$(cprun CHECK_PUSH_BASE="$sa" CHECK_PUSH_JOBS=1 CHECK_PUSH_GOALS=g2); rc=$?
  rm -f "$T/n-g1"
  check "F43 make -n 이 이름 댄 진입 파일로 유도한 목표는 print-rest-goals 순서로 붙는다" "$rc $(dgoals)" "0 make:--no-print-directory g2 g1 run/tools/r.sh "
  # Head mode: the base branch's remote-tracking ref, else the local branch.
  rm -f "$dstamp"
  : > "$T/order.log"
  out=$(cprun CHECK_PUSH_BASE_BRANCH=lb CHECK_PUSH_JOBS=1 CHECK_PUSH_GOALS=g2); rc=$?
  check "F43 head 모드는 원격 추적 ref 가 없으면 로컬 브랜치와의 merge-base 부터 본다" "$rc $(dgoals)" "0 make:--no-print-directory g2 run/tools/r.sh "
  rm -f "$dstamp"
  : > "$T/order.log"
  out=$(cprun CHECK_PUSH_BASE_BRANCH=nosuch CHECK_PUSH_JOBS=1 CHECK_PUSH_GOALS=g2); rc=$?
  check "F43 head 모드에 베이스 ref 가 없으면 지명한 목표만 돌고 통과한다" "$rc $(dgoals)" "0 make:--no-print-directory g2 "
  has "F43 판정불가 줄" "$out" "check-push: 유도 판정불가 — 베이스 브랜치 nosuch 의 refs/remotes/origin/nosuch 도 refs/heads/nosuch 도 없다"
  check "F43 판정불가 도장" "$(check_push_field "$dstamp" 유도목표) $(check_push_field "$dstamp" 유도없음)" "판정불가 0"
  # A derivation that cannot be computed ends 1 before any item, with no stamp.
  rm -f "$dstamp"
  : > "$T/derive-n-fail"
  : > "$T/order.log"
  out=$(cprun CHECK_PUSH_BASE="$sa" CHECK_PUSH_GOALS=g2); rc=$?
  rm -f "$T/derive-n-fail"
  check "F43 유도 실패는 종료 1, 도장 없음" "$rc $([ -f "$dstamp" ] && echo 있음 || echo 없음)" "1 없음"
  has "F43 유도 실패 줄이 단계를 이름 댄다" "$out" "check-push: 유도 실패 — make -n g1"
  check "F43 유도 실패면 항목을 하나도 돌리지 않는다" "$(grep -c -e '^bundle:' -e '^make:--no-print-directory' -e '^gate:--sections' "$T/order.log")" "0"
  # items derives too, and runs the derived goal with nothing named.
  : > "$T/order.log"
  out=$(cd "$W" && env CHECK_PUSH_REUSE=1 CHECK_PUSH_BASE="$sa" CHECK_PUSH_JOBS=2 bash "$self" items 2>&1); rc=$?
  check "F43 items 통과" "$rc" "0"
  has "F43 items 도 유도 목표 줄을 찍는다" "$out" "check-push: 유도 목표 — 변경 파일 5개, 유도 1개: run/tools/r.sh"
  has "F43 items 가 지명 없이 유도 목표를 돌린다" "$(grep -e '^make:' "$T/order.log" | grep -v print-rest-goals)" "run/tools/r.sh"
  (cd "$W" && sgit checkout -q h) > /dev/null 2>&1

  # --- F44 릴리스 차이는 유도 입력에서 빠진다 ------------------------------------------
  # Branch e carries CHANGELOG.md and plugin.json, a run/ goal whose entry
  # script only names those two paths and a run/ goal whose entry script reads
  # data/feat.txt. Each case commits on a new branch from e and runs with e as
  # the base.
  local se fa fb F44_BUMP rpjf="plugins/cc-cmds/.claude-plugin/plugin.json"
  rpj() { printf '{\n  "name": "%s",\n  "version": "%s",\n  "description": "d"\n}\n' "${2:-x}" "$1" > "$rpjf"; }
  rlog() { printf '# Changelog\n\nintro\n\n%b## [1.0.0] - 2026-01-01\n- %s\n' "$1" "${2:-a}" > CHANGELOG.md; }
  (
    cd "$W" || exit 1
    sgit checkout -q -b e h
    mkdir -p tools data plugins/cc-cmds/.claude-plugin
    printf 'g1\ng2\nrun/tools/rel.sh\nrun/tools/feat.sh\n' > goals.txt
    printf 'cat CHANGELOG.md plugins/cc-cmds/.claude-plugin/plugin.json\n' > tools/rel.sh
    printf 'cat data/feat.txt\n' > tools/feat.sh
    printf 'f\n' > data/feat.txt
    rpj 1.0.0 && rlog ''
    sgit add -A && sgit commit -q -m E
  ) > /dev/null 2>&1
  se=$(cd "$W" && git rev-parse HEAD)
  F44_BUMP="rpj 1.0.1 && rlog '## [1.0.1] - 2026-01-02\n- b\n\n'"
  # Commits the commands of $2 on branch $1 (made from e when it is new) and
  # runs check-push against e on it, with a fresh order log and no stamp of
  # that tree; prints the run's output and leaves its status in $T/f44-rc.
  f44_run() {
    (cd "$W" && { sgit checkout -q "$1" 2> /dev/null || sgit checkout -q -b "$1" "$se"; } && eval "$2" && sgit add -A && sgit commit -q -m "$1") > /dev/null 2>&1
    rm -f "$(f44_stamp)"
    : > "$T/order.log"
    cprun CHECK_PUSH_BASE="$se" CHECK_PUSH_JOBS=1
    printf '%s' "$?" > "$T/f44-rc"
  }
  f44_stamp() { printf '%s/.git/cc-cmds-check-push/%s' "$W" "$(cd "$W" && git rev-parse 'HEAD^{tree}')"; }
  f44_field() { check_push_field "$(f44_stamp)" "$1"; }
  out=$(f44_run er "$F44_BUMP")
  check "F44 C1 릴리스 커밋만 더한 head 는 통과" "$(cat "$T/f44-rc")" "0"
  has "F44 C1 유도 목표 줄은 변경 파일 2개, 유도 0개" "$out" "check-push: 유도 목표 — 변경 파일 2개, 유도 0개: 없음"
  has "F44 C1 릴리스 줄이 두 경로를 찍는다" "$out" "check-push: 릴리스 차이로 유도에서 뺀 변경 파일 2개 — CHANGELOG.md $rpjf"
  hasnt "F44 C1 유도 근거 없음 줄이 없다" "$out" "유도 근거 없는 변경 파일"
  check "F44 C1 두 파일을 담은 목표가 돌지 않는다" "$(dgoals)" ""
  check "F44 C1 도장의 유도목표·유도없음·유도릴리스" "$(f44_field 유도목표) $(f44_field 유도없음) $(f44_field 유도릴리스)" "없음 0 CHANGELOG.md,$rpjf"
  out=$(f44_run ef "printf 'f2\n' > data/feat.txt")
  fa="$(cat "$T/f44-rc") $(f44_field 유도목표)"
  out=$(f44_run ef "$F44_BUMP")
  fb="$(cat "$T/f44-rc") $(f44_field 유도목표)"
  check "F44 C2 기능 커밋 위에 릴리스 커밋을 더해도 유도목표가 같다" "$fb" "$fa"
  check "F44 C2 그 유도목표는 기능 파일을 읽는 목표 하나다" "$fa" "0 run/tools/feat.sh"
  out=$(f44_run ep "rpj 1.0.1 y && rlog '## [1.0.1] - 2026-01-02\n- b\n\n'")
  has "F44 plugin.json 의 다른 줄도 바꾸면 릴리스 줄은 CHANGELOG.md 만 찍는다" "$out" "check-push: 릴리스 차이로 유도에서 뺀 변경 파일 1개 — CHANGELOG.md"
  check "F44 plugin.json 의 다른 줄도 바꾸면 plugin.json 이 남아 두 파일을 담은 목표가 돈다" \
    "$(cat "$T/f44-rc") $(f44_field 유도목표) $(f44_field 유도릴리스) $(dgoals)" "0 run/tools/rel.sh CHANGELOG.md make:--no-print-directory run/tools/rel.sh "
  out=$(f44_run el "rpj 1.0.1 && rlog '' 'a fixed'")
  check "F44 CHANGELOG 기존 항목 본문을 고치면 CHANGELOG.md 는 빠지지 않는다" \
    "$(cat "$T/f44-rc") $(f44_field 유도목표) $(f44_field 유도릴리스)" "0 run/tools/rel.sh $rpjf"
  # items derives the same way on the head of C1.
  (cd "$W" && sgit checkout -q er) > /dev/null 2>&1
  : > "$T/order.log"
  out=$(cd "$W" && env CHECK_PUSH_REUSE=1 CHECK_PUSH_BASE="$se" CHECK_PUSH_JOBS=2 bash "$self" items 2>&1); rc=$?
  check "F44 items 통과" "$rc" "0"
  has "F44 items 도 릴리스 줄을 찍는다" "$out" "check-push: 릴리스 차이로 유도에서 뺀 변경 파일 2개 — CHANGELOG.md $rpjf"
  hasnt "F44 items 는 두 파일을 담은 목표를 돌리지 않는다" "$(grep -e '^make:' "$T/order.log" | grep -v print-rest-goals)" "run/tools/rel.sh"
  (cd "$W" && sgit checkout -q h) > /dev/null 2>&1

  # --- F42 시간 예산, 이어 돌리기, CI 몫, 조기 종료 ------------------------------------
  # Each section gets a lane of its own (the shard double) and reuse is on, so
  # a lane that ended before the budget ran out leaves its record. The cases
  # commit on branch hb, so their trees are new to everything above. M4 on
  # master descends from M2 and stands for the base a later fetch brings.
  local sm4 hb0 rsf p t0 el
  (
    cd "$T/seed" || exit 1
    sgit checkout -q master && printf 'm4\n' > m4.txt && sgit add -A && sgit commit -q -m M4 && sgit push -q origin master
  ) > /dev/null 2>&1 || bad "F42 픽스처" "M4 커밋 실패"
  sm4=$(cd "$T/seed" && git rev-parse master)
  (cd "$W" && sgit fetch -q --no-tags --refmap= origin refs/heads/master) > /dev/null 2>&1
  rm -rf "$items_dir"
  (cd "$W" && sgit checkout -q -b hb h) > /dev/null 2>&1
  rw b.txt 'b\n'
  hb0=$(cd "$W" && git rev-parse HEAD)
  rsf="$W/.git/cc-cmds-check-push-resume/$hb0"
  cb() { cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_REUSE=1 CHECK_PUSH_JOBS=2 CC_TEST_TREE_SHARD="$T/bin/shard" CC_CHECK_PUSH_STOP_GRACE=2 "$@"; }
  # 0 while the pid in file $1 still runs.
  pid_alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

  # Budget stop: s1 ends at once, s2 sleeps past the budget.
  fh_line "$sm2"
  printf '60\n' > "$T/slow-s2"
  rm -f "$T/slowpid-s2"
  out=$(cb CHECK_PUSH_SECTIONS=s1,s2 CHECK_PUSH_BUDGET_SECS=20); rc=$?
  rm -f "$T/slow-s2"
  check "F42 예산 멈춤: 종료 코드 5, 도장 없음" "$rc $([ -f "$W/.git/cc-cmds-check-push/$(cur_tree)" ] && echo 있음 || echo 없음)" "5 없음"
  has "F42 예산 멈춤: 미완 판정 줄이 끝난 항목과 남은 항목을 이름 댄다" "$out" "check-push: 판정 — 미완(시간 예산 20초) · 끝난 항목 lint,readme,check-cheap,s1 · 남은 항목 s2 · 시도 1"
  has "F42 예산 멈춤: 다시 띄우라는 줄이 베이스를 이름 댄다" "$out" "check-push: 같은 명령으로 다시 띄우면 끝난 항목은 기록으로 건너뛴다 (베이스 $sm2 유지)"
  has "F42 예산 멈춤: 풀이 마감을 까닭으로 멈춘다" "$out" "check-push: 멈춤 — 시간 예산 마감"
  check "F42 예산 멈춤: 시도 기록에 베이스와 시도 1" "$(check_push_field "$rsf" base) $(check_push_field "$rsf" 시도)" "$sm2 1"
  check "F42 예산 멈춤: 빠른 레인의 기록이 남는다" "$(ls "$items_dir/lane" 2>/dev/null | wc -l | tr -d ' ')" "$(ve 1 0)"
  if pid_alive "$T/slowpid-s2"; then bad "F42 예산 멈춤: 느린 레인의 프로세스가 남지 않는다" "$(cat "$T/slowpid-s2")"; else ok "F42 예산 멈춤: 느린 레인의 프로세스가 남지 않는다"; fi

  # Resume to the end: the next fetch moved the base on to M4, a descendant of
  # the recorded base, so the run keeps M2 and runs only what is left.
  fh_line "$sm4"
  : > "$T/order.log"
  out=$(cb CHECK_PUSH_SECTIONS=s1,s2 CHECK_PUSH_BUDGET_SECS=0); rc=$?
  check "F42 이어 끝내기: 통과" "$rc" "0"
  check "F42 이어 끝내기: 도장의 base·base출처·fetch베이스·시도" "$(cur_field base) $(cur_field base출처) $(cur_field fetch베이스) $(cur_field 시도)" "$sm2 이어감 $sm4 2"
  has "F42 이어 끝내기: 시험 트리 줄이 이어감과 fetch 한 베이스를 보인다" "$out" "base=$sm2 base출처=이어감 head=$hb0"
  has "F42 이어 끝내기: 시험 트리 줄 끝의 fetch베이스와 시도" "$out" "fetch베이스=$sm4 시도=2"
  has "F42 이어 끝내기: 빠른 레인은 기록으로 건너뛴다" "$out" "$(ve 'check-push: 재사용 절 s1 ← ' 'check-push: 통과')"
  check "F42 이어 끝내기: 게이트 대역은 느린 레인만 받는다" "$(grep -c '^gate:--sections s1$' "$T/order.log") $(grep -c '^gate:--sections s2$' "$T/order.log")" "$(ve '0 1' '1 1')"
  check "F42 이어 끝내기: 도장의 시간예산" "$(cur_field 시간예산)" "꺼짐"
  check "F42 이어 끝내기: 통과 뒤 시도 기록이 없다" "$([ -e "$rsf" ] && echo 있음 || echo 없음)" "없음"

  # Cut from outside, as the harness limit would: TERM once the fast lane
  # ended (and left its record), then the same command again. The commit
  # changes the file lane s1 runs, so its earlier record does not hold.
  rw sections/s1.sh '[ ! -e rows.txt ] # term\n'
  fh_line "$sm4"
  printf '60\n' > "$T/slow-s2"
  rm -f "$T/slowpid-s2"
  crec=$(ls "$items_dir/lane" 2>/dev/null | wc -l | tr -d ' ')
  (cd "$W" && exec env CC_PIPELINE_RUN_ID=t CHECK_PUSH_REUSE=1 CHECK_PUSH_JOBS=2 CC_TEST_TREE_SHARD="$T/bin/shard" CC_CHECK_PUSH_STOP_GRACE=2 \
    CHECK_PUSH_SECTIONS=s1,s2 bash "$self" run > "$T/term.out" 2>&1) &
  p=$!
  t0=0
  while [ "$t0" -lt 60 ]; do
    if [ "$v" = 1 ]; then
      [ "$(ls "$items_dir/lane" 2>/dev/null | wc -l | tr -d ' ')" -gt "$crec" ] && [ -f "$T/slowpid-s2" ] && break
    else
      grep -q '끝 — 레인 [0-9](s1) rc=0' "$T/term.out" 2>/dev/null && [ -f "$T/slowpid-s2" ] && break
    fi
    sleep 1
    t0=$((t0 + 1))
  done
  sleep 1
  kill -TERM "$p" 2>/dev/null
  wait "$p"
  rc=$?
  rm -f "$T/slow-s2"
  check "F42 밖에서 끊긴 실행: 종료 코드 143" "$rc" "143"
  if pid_alive "$T/slowpid-s2"; then bad "F42 밖에서 끊긴 실행: 잡 프로세스가 남지 않는다" "$(cat "$T/slowpid-s2")"; else ok "F42 밖에서 끊긴 실행: 잡 프로세스가 남지 않는다"; fi
  : > "$T/order.log"
  out=$(cb CHECK_PUSH_SECTIONS=s1,s2); rc=$?
  check "F42 밖에서 끊긴 뒤 같은 명령: 도장에 닿는다" "$rc $(cur_field 시도)" "0 2"
  check "F42 밖에서 끊긴 뒤 같은 명령: 빠른 레인은 다시 돌지 않는다" "$(grep -c '^gate:--sections s1$' "$T/order.log")" "$(ve 0 1)"

  # A goal the budget cut twice is left to CI when the tested tree's lint.yml
  # runs rest-tests for a path this head changed (h.txt, an exact pattern).
  (cd "$W" && mkdir -p .github/workflows) && rw .github/workflows/lint.yml \
    "on:\n  pull_request:\n    paths:\n      - 'scripts/**'\n      - '**.md'\n      - 'h.txt'\njobs:\n  rest-tests:\n    runs-on: x\n"
  hb0=$(cd "$W" && git rev-parse HEAD)
  rsf="$W/.git/cc-cmds-check-push-resume/$hb0"
  printf 'sleep 60\n' > "$T/run-g2"
  fh_line "$sm4"
  out=$(cb CHECK_PUSH_GOALS=g2 CHECK_PUSH_BUDGET_SECS=20); rc=$?
  check "F42 목표 잘림 1: 종료 코드 5, 잘린목표 g2:1" "$rc $(check_push_field "$rsf" 잘린목표)" "5 g2:1"
  fh_line "$sm4"
  out=$(cb CHECK_PUSH_GOALS=g2 CHECK_PUSH_BUDGET_SECS=20); rc=$?
  check "F42 목표 잘림 2: 종료 코드 5, 잘린목표 g2:2, 시도 2" "$rc $(check_push_field "$rsf" 잘린목표) $(check_push_field "$rsf" 시도)" "5 g2:2 2"
  fh_line "$sm4"
  : > "$T/order.log"
  out=$(cb CHECK_PUSH_GOALS=g2); rc=$?
  check "F42 두 번 잘린 목표: 통과하고 도장 CI몫=g2" "$rc $(cur_field CI몫)" "0 g2"
  has "F42 두 번 잘린 목표: CI 몫 줄" "$out" "check-push: CI 몫 — g2 (이 커밋의 시도에서 시간 예산에 두 번 잘림, PR 의 rest-tests 가 돌린다)"
  check "F42 두 번 잘린 목표: 로컬에서 돌리지 않는다" "$(grep -c '^make:--no-print-directory g2$' "$T/order.log")" "0"
  out=$(cvrun); rc=$?
  check "F42 두 번 잘린 목표: verify 는 받는다" "$rc" "0"
  has "F42 두 번 잘린 목표: verify 가 CI 몫 줄을 찍는다" "$out" "check-push: CI 몫 — g2 (로컬에서 돌리지 않았다)"
  sed 's/^대역=.*$/대역=없음/' "$W/.git/cc-cmds-check-push/$(cur_tree)" > "$T/stamp.tmp" && mv -f "$T/stamp.tmp" "$W/.git/cc-cmds-check-push/$(cur_tree)"
  out=$(cvrun CC_PIPELINE_RUN_ID=t); rc=$?
  check "F42 두 번 잘린 목표: 대역=없음 이면 무인 verify 도 이어감 도장을 받는다" "$rc" "0"
  rm -f "$T/run-g2"

  # The same count where lint.yml's paths miss every changed path: the goal
  # runs here again.
  rw .github/workflows/lint.yml "on:\n  pull_request:\n    paths:\n      - 'docs/**'\n      - 'zzz.txt'\njobs:\n  rest-tests:\n    runs-on: x\n"
  hb0=$(cd "$W" && git rev-parse HEAD)
  rsf="$W/.git/cc-cmds-check-push-resume/$hb0"
  mkdir -p "${rsf%/*}"
  printf 'v=1\ncommit=%s\nbase=%s\n처음=%s\n시도=2\n잘린목표=g2:2\n' "$hb0" "$sm4" "$(date +%s)" > "$rsf"
  fh_line "$sm4"
  : > "$T/order.log"
  out=$(cb CHECK_PUSH_GOALS=g2); rc=$?
  check "F42 경로가 맞지 않으면: 통과하고 CI몫=없음" "$rc $(cur_field CI몫)" "0 없음"
  has "F42 경로가 맞지 않으면: 이유 한 줄" "$out" "check-push: CI 몫 아님 — g2 (시간 예산에 2번 잘렸지만 시험 트리의 lint.yml 의 pull_request 경로가 head 가 바꾼 경로에 맞지 않는다) · 로컬에서 다시 돈다"
  check "F42 경로가 맞지 않으면: 로컬에서 돈다" "$(grep -c '^make:--no-print-directory g2$' "$T/order.log")" "1"

  # Base pinning refused: a record older than six hours, and a record whose
  # base is not an ancestor of the fetched base.
  printf 'v=1\ncommit=%s\nbase=%s\n처음=%s\n시도=1\n잘린목표=\n' "$hb0" "$sm2" "$(( $(date +%s) - 30000 ))" > "$rsf"
  fh_line "$sm4"
  out=$(cb CHECK_PUSH_GOALS=g1); rc=$?
  check "F42 오래된 기록: 새 베이스, base출처=FETCH_HEAD, 시도 1" "$rc $(cur_field base) $(cur_field base출처) $(cur_field 시도)" "0 $sm4 FETCH_HEAD 1"
  has "F42 오래된 기록: 잇지 않는 까닭" "$out" "check-push: 시도 기록을 잇지 않는다 — 기록의 처음이 21600초 안이 아니다"
  printf 'v=1\ncommit=%s\nbase=%s\n처음=%s\n시도=1\n잘린목표=\n' "$hb0" "$sm3" "$(date +%s)" > "$rsf"
  fh_line "$sm4"
  out=$(cb CHECK_PUSH_GOALS=g1); rc=$?
  check "F42 조상이 아닌 기록 베이스: 새 베이스, base출처=FETCH_HEAD, 시도 1" "$rc $(cur_field base) $(cur_field base출처) $(cur_field 시도)" "0 $sm4 FETCH_HEAD 1"
  has "F42 조상이 아닌 기록 베이스: 잇지 않는 까닭" "$out" "가 방금 fetch 한 베이스 $sm4 의 조상이 아니다"

  # Unattended early stop: g1 fails at once while g2 sleeps; the run ends 1
  # long before g2 would, names g1 alone and g2 as unfinished.
  : > "$T/fail-g1"
  printf 'sleep 30\n' > "$T/run-g2"
  fh_line "$sm4"
  t0=$(date +%s)
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_JOBS=2 CC_CHECK_PUSH_STOP_GRACE=2 CHECK_PUSH_GOALS=g1,g2); rc=$?
  el=$(( $(date +%s) - t0 ))
  check "F42 무인 조기 종료: 종료 코드 1" "$rc" "1"
  if [ "$el" -lt 25 ]; then ok "F42 무인 조기 종료: 느린 목표를 기다리지 않는다"; else bad "F42 무인 조기 종료: 느린 목표를 기다리지 않는다" "${el}초"; fi
  has "F42 무인 조기 종료: 끝나지 않은 항목 줄" "$out" "check-push: 끝나지 않은 항목 — g2"
  has "F42 무인 조기 종료: 실패한 항목만 단계에 든다" "$out" "check-push: 합친 트리 실패 — base=$sm4 단계=목표=g1"
  case "$out" in
    *"check-push: 실패 확정 — 목표 g1 rc=1"*"검사 실패 — 도장을 찍지 않는다"*) ok "F42 무인 조기 종료: 실패 확정 줄이 마지막 판정 줄보다 앞" ;;
    *) bad "F42 무인 조기 종료: 실패 확정 줄이 마지막 판정 줄보다 앞" "$out" ;;
  esac
  # Interactive runs every job to its end, and says the failure first.
  printf 'sleep 3\n' > "$T/run-g2"
  out=$(cprun CHECK_PUSH_JOBS=2 CHECK_PUSH_GOALS=g1,g2); rc=$?
  check "F42 대화형: 종료 코드 1" "$rc" "1"
  hasnt "F42 대화형: 끝나지 않은 항목이 없다" "$out" "끝나지 않은 항목"
  case "$out" in
    *"check-push: 실패 확정 — 목표 g1 rc=1"*"check-push: 끝 — 목표 g2 rc=0"*) ok "F42 대화형: 실패 확정 줄이 느린 목표의 끝 줄보다 앞" ;;
    *) bad "F42 대화형: 실패 확정 줄이 느린 목표의 끝 줄보다 앞" "$out" ;;
  esac
  rm -f "$T/fail-g1" "$T/run-g2"

  # A deadline that passes during the serial bundle leaves the next step and
  # every item after it.
  : > "$T/bundle-slow"
  rw b.txt 'b3\n'
  fh_line "$sm4"
  out=$(cb CHECK_PUSH_GOALS=g1 CHECK_PUSH_BUDGET_SECS=1); rc=$?
  rm -f "$T/bundle-slow"
  check "F42 직렬 묶음에서 마감: 종료 코드 5" "$rc" "5"
  has "F42 직렬 묶음에서 마감: 남은 항목이 뒤 단계와 목표를 든다" "$out" "check-cheap,g1 · 시도 1"

  # Usage: wrong values end 2 before any check runs.
  : > "$T/order.log"
  for p in abc -1 07 1.5; do
    out=$(cprun CHECK_PUSH_BUDGET_SECS="$p"); rc=$?
    check "F42 CHECK_PUSH_BUDGET_SECS=$p → 2" "$rc" "2"
  done
  has "F42 예산 거부가 변수를 이름 댄다" "$out" "check-push: CHECK_PUSH_BUDGET_SECS=1.5 는 0 이나 양의 정수가 아니다"
  for p in 2 yes; do
    out=$(cprun CHECK_PUSH_FAIL_FAST="$p"); rc=$?
    check "F42 CHECK_PUSH_FAIL_FAST=$p → 2" "$rc" "2"
  done
  check "F42 거부는 검사 전에 끝난다" "$(grep -c '^bundle:' "$T/order.log")" "0"
  (cd "$W" && sgit checkout -q h) > /dev/null 2>&1

  # --- F45 유도로만 든 무거운 목표는 처음부터 CI 몫 ---------------------------------------
  # Branch v carries two run/ goals: r.sh, which the tree's list names with the
  # direct targets data/direct.txt and data/dir/, and u.sh, which it does not.
  # Both read data/in.txt. Each case commits on a new branch from v and runs
  # with v as the base.
  local sv R45=run/tools/r.sh L45="유도로만 들어왔고 직접 대상이 바뀌지 않음, PR 의 rest-tests 가 돌린다" W45
  (
    cd "$W" || exit 1
    sgit checkout -q -b v h
    mkdir -p tools data/dir scripts .github/workflows
    printf 'g1\ng2\nrun/tools/r.sh\nrun/tools/u.sh\n' > goals.txt
    printf 'cat data/in.txt data/direct.txt data/dir/a.txt data/dirx.txt\n' > tools/r.sh
    printf 'cat data/in.txt\n' > tools/u.sh
    printf 'in\n' > data/in.txt
    printf 'd\n' > data/direct.txt
    printf 'a\n' > data/dir/a.txt
    printf 'x\n' > data/dirx.txt
    printf '# c\n\nrun/tools/r.sh\tdata/direct.txt data/dir/\n' > scripts/check-push-ci.tsv
    printf "on:\n  pull_request:\n    paths:\n      - 'data/**'\n      - 'tools/**'\njobs:\n  rest-tests:\n    runs-on: x\n" > .github/workflows/lint.yml
    sgit add -A && sgit commit -q -m V
  ) > /dev/null 2>&1 || bad "F45 픽스처" "v 커밋 실패"
  sv=$(cd "$W" && git rev-parse v)
  W45=0
  # Commits the commands $1 on a new branch from v and leaves it checked out.
  v45_at() {
    W45=$((W45 + 1))
    (cd "$W" && sgit checkout -q -b "v$W45" v && eval "$1" && sgit add -A && sgit commit -q -m "v$W45") > /dev/null 2>&1
    fh_line "$sv"
    : > "$T/order.log"
  }
  v45() { cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_JOBS=1 "$@"; }
  V45_IN="printf 'in2\n' > data/in.txt"

  v45_at "$V45_IN"
  out=$(cprun CC_PIPELINE_RUN_ID=t CHECK_PUSH_JOBS=2); rc=$?
  check "F45 첫 시도에서 이연: 통과하고 도장 CI몫 은 그 목표다" "$rc $(cur_field CI몫) $(cur_field 시도)" "0 $R45 1"
  has "F45 이연 줄" "$out" "check-push: CI 몫 — $R45 ($L45)"
  check "F45 이연 줄은 이연한 목표에만 나온다" "$(printf '%s\n' "$out" | grep -c 'CI 몫')" "1"
  check "F45 이연한 목표는 돌지 않고 목록에 없는 유도 목표는 돈다" "$(dgoals)" "make:--no-print-directory run/tools/u.sh "
  check "F45 도장의 goals 에서 빠지고 유도목표에는 남는다" "$(cur_field goals) $(cur_field 유도목표)" "run/tools/u.sh run/tools/r.sh,run/tools/u.sh"
  out=$(cvrun)
  has "F45 verify 가 CI 몫 줄을 목표 이름만으로 찍는다" "$out" "check-push: CI 몫 — $R45 (로컬에서 돌리지 않았다)"
  fh_line "$sv"
  out=$(v45 CHECK_PUSH_JOBS=1 CHECK_PUSH_GOALS=g2); rc=$?
  check "F45 다른 목표를 지명해도 유도로만 든 목표는 이연한다" "$rc $(cur_field CI몫)" "0 $R45"

  v45_at "$V45_IN"
  hb0=$(cd "$W" && git rev-parse HEAD)
  rsf="$W/.git/cc-cmds-check-push-resume/$hb0"
  mkdir -p "${rsf%/*}"
  printf 'v=1\ncommit=%s\nbase=%s\n처음=%s\n시도=2\n잘린목표=g2:2\n' "$hb0" "$sv" "$(date +%s)" > "$rsf"
  out=$(v45 CHECK_PUSH_GOALS=g2); rc=$?
  check "F45 두 번 잘린 목표와 이연 목표가 함께: 통과하고 둘 다 CI몫" "$rc $(cur_field CI몫)" "0 g2,$R45"
  has "F45 함께: 두 번 잘린 목표의 줄" "$out" "check-push: CI 몫 — g2 (이 커밋의 시도에서 시간 예산에 두 번 잘림, PR 의 rest-tests 가 돌린다)"
  has "F45 함께: 이연 목표의 줄" "$out" "check-push: CI 몫 — $R45 ($L45)"
  check "F45 함께: 남은 유도 목표만 돈다" "$(dgoals)" "make:--no-print-directory run/tools/u.sh "

  # Every case where it runs here: the goal runs and no line names it CI's.
  v45_local() {
    local ran=아니오
    case "$(dgoals)" in *"$R45 "*) ran=예 ;; esac
    check "$1" "rc=$rc CI몫=$(cur_field CI몫) 돎=$ran 줄=$(printf '%s\n' "$out" | grep -c 'CI 몫')" "rc=0 CI몫=없음 돎=예 줄=0"
  }
  v45_at "$V45_IN"
  out=$(cprun CHECK_PUSH_BASE="$sv" CHECK_PUSH_JOBS=1); rc=$?
  v45_local "F45 무인 런이 아니면 로컬에서 돈다"
  v45_at "$V45_IN"
  out=$(v45 CHECK_PUSH_GOALS="$R45"); rc=$?
  v45_local "F45 지명하고 유도에도 든 목표는 로컬에서 돈다"
  v45_at "printf 'h2\n' > h.txt; printf 'd2\n' > data/zz.txt"
  out=$(v45 CHECK_PUSH_GOALS="$R45"); rc=$?
  v45_local "F45 지명만 하고 유도에 들지 않은 목표도 로컬에서 돈다"
  v45_at "$V45_IN; printf 'd2\n' > data/direct.txt"
  out=$(v45); rc=$?
  v45_local "F45 직접 대상이 바뀌면 로컬에서 돈다"
  v45_at "$V45_IN; printf 'a2\n' > data/dir/a.txt"
  out=$(v45); rc=$?
  v45_local "F45 접두 직접 대상 아래가 바뀌면 로컬에서 돈다"
  v45_at "printf 'x2\n' > data/dirx.txt"
  out=$(v45); rc=$?
  check "F45 접두는 이름이 이어지는 다른 파일에 맞지 않는다" "$rc $(cur_field CI몫)" "0 $R45"
  v45_at "$V45_IN; printf '# e\n' >> tools/r.sh"
  out=$(v45); rc=$?
  v45_local "F45 진입 파일이 바뀌면 로컬에서 돈다"
  v45_at "$V45_IN; printf '# more\n' >> scripts/check-push-ci.tsv"
  out=$(v45); rc=$?
  v45_local "F45 목록이 바뀌면 로컬에서 돈다"
  v45_at "$V45_IN; sgit rm -q scripts/check-push-ci.tsv"
  out=$(v45); rc=$?
  v45_local "F45 head 가 목록을 지우면 로컬에서 돈다"
  v45_at "$V45_IN; printf 'on:\n  pull_request:\n    paths:\n      - docs/x.md\njobs:\n  rest-tests:\n    runs-on: x\n' > .github/workflows/lint.yml"
  out=$(v45); rc=$?
  v45_local "F45 CI 가 돌리지 않는 커밋이면 로컬에서 돈다"
  # The base carries no list at all, and one whose row has no direct target.
  (cd "$W" && sgit checkout -q -b vn v && sgit rm -q scripts/check-push-ci.tsv && sgit commit -q -m VN \
    && sgit checkout -q -b vb v && printf 'run/tools/r.sh\n' > scripts/check-push-ci.tsv && sgit commit -q -am VB) > /dev/null 2>&1
  for p in vn vb; do
    (cd "$W" && sgit checkout -q -b "$p-w" "$p" && printf 'in2\n' > data/in.txt && sgit commit -q -am "$p-w") > /dev/null 2>&1
    fh_line "$(cd "$W" && git rev-parse "$p")"
    : > "$T/order.log"
    out=$(v45); rc=$?
    v45_local "F45 목록이 없거나 줄에 직접 대상이 없으면 로컬에서 돈다($p)"
  done
  v45_at "$V45_IN"
  out=$(cd "$W" && env CC_PIPELINE_RUN_ID=t CHECK_PUSH_REUSE=1 CHECK_PUSH_JOBS=2 bash "$self" items 2>&1); rc=$?
  check "F45 items 는 이연하지 않는다" "$rc $(grep -c "^make:--no-print-directory $R45\$" "$T/order.log")" "0 1"
  hasnt "F45 items 는 CI 몫 줄을 내지 않는다" "$out" "CI 몫"
  # An undecided derivation leaves no change list, and without one nothing is
  # left to CI. The first answer shows the same call defers with the list.
  out=$(
    cd "$W" || exit 1
    TT_DIR="$T" TT_WORK="$W" CC_PIPELINE_RUN_ID=t CP_DERIVED="$R45" CP_CHANGED_LIST="data/in.txt"
    check_push_ci_defers "$R45" "" "$sv" HEAD && printf '이연 '
    CHECK_PUSH_BASE_BRANCH=nosuch
    check_push_derive head "" HEAD
    printf '%s[%s] ' "$CP_DERIVED" "$CP_CHANGED_LIST"
    CP_DERIVED="$R45"
    check_push_ci_defers "$R45" "" "$sv" HEAD || printf '로컬'
  )
  check "F45 유도가 판정불가면 변경 목록이 비고 로컬에서 돈다" "$out" "이연 판정불가[] 로컬"
  (cd "$W" && sgit checkout -q h) > /dev/null 2>&1

  # The list this repository carries: every goal is a REST goal and every
  # direct target is in the tree.
  local root45 rg45 rows45=0 miss45="" k45 v45t t45
  root45=$(cd "$(dirname "$self")/.." && pwd)
  rg45=$(cd "$root45" && MAKEFLAGS='' MFLAGS='' MAKELEVEL='' make -s --no-print-directory print-rest-goals 2>/dev/null)
  while IFS=$'\t' read -r k45 v45t; do
    case "$k45" in ''|'#'*) continue ;; esac
    rows45=$((rows45 + 1))
    printf '%s\n' "$rg45" | grep -Fxq -- "$k45" || miss45="$miss45 목표:$k45"
    [ -n "$v45t" ] || miss45="$miss45 대상없음:$k45"
    for t45 in $v45t; do
      case "$t45" in
        */) [ -d "$root45/$t45" ] || miss45="$miss45 $t45" ;;
        *) [ -f "$root45/$t45" ] || miss45="$miss45 $t45" ;;
      esac
    done
  done < "$root45/$CP_CI_LIST"
  check "F45 이 저장소의 목록: 목표가 모두 REST 목표이고 직접 대상이 트리에 있다" "$([ "$rows45" -gt 0 ] && echo 있음)|$miss45" "있음|"

  # --- F46 지난 실패 기록은 부른 워크트리의 것이다 ------------------------------------------
  local lf46="$W/.git/cc-cmds-last-failed.tsv" wt46="$T/wt46" lw46
  lf46n() { cut -f 2,3 "$1" 2>/dev/null | tr '\t\n' ': '; }
  (cd "$W" && sgit worktree add -q --detach "$wt46" h) > /dev/null 2>&1 || bad "F46 픽스처" "워크트리 실패"
  lw46=$(cd "$wt46" && git rev-parse --absolute-git-dir)/cc-cmds-last-failed.tsv
  rm -f "$lf46"
  : > "$T/fail-g1"
  out=$(cprun CHECK_PUSH_JOBS=1 CHECK_PUSH_GOALS=g1); rc=$?
  check "F46 CHECK_PUSH_JOBS=1 의 실패는 적지 않는다" "$rc $([ -e "$lf46" ] && echo 있음 || echo 없음)" "1 없음"
  out=$(cprun CHECK_PUSH_JOBS=2 CHECK_PUSH_GOALS=g1,g2); rc=$?
  check "F46 run 이 실패한 목표를 부른 워크트리의 git 디렉터리에 적는다" "$rc $(lf46n "$lf46")" "1 목표:g1 "
  rm -f "$T/fail-g1"
  : > "$T/fail-g2"
  out=$(cd "$wt46" && env CHECK_PUSH_JOBS=2 CHECK_PUSH_REUSE=1 CHECK_PUSH_GOALS=g1,g2 bash "$self" items 2>&1); rc=$?
  rm -f "$T/fail-g2"
  check "F46 items 도 적고, 다른 워크트리의 기록은 건드리지 않는다" "$rc $(lf46n "$lw46")|$(lf46n "$lf46")" "1 목표:g2 |목표:g1 "
  out=$(cprun CHECK_PUSH_JOBS=2 CHECK_PUSH_GOALS=g1,g2); rc=$?
  check "F46 통과하면 자기 기록만 지운다" "$rc $(lf46n "$lf46")|$(lf46n "$lw46")" "0 |목표:g2 "
  (cd "$W" && sgit worktree remove --force "$wt46") > /dev/null 2>&1

  # --- (5) a commit that changes the tree has no stamp ------------------------------
  (cd "$W" && printf 'two\n' > h.txt && sgit commit -q -am second)
  out=$(cvrun); rc=$?
  check "(5) 트리를 바꾼 새 커밋은 verify 실패" "$rc" "1"

  # --- F28 임시 디렉터리 ---------------------------------------------------------------
  out=$(find "$T/tmp" -maxdepth 1 \( -name 'cc-test-tree.*' -o -name 'cc-check-push.*' \) | wc -l | tr -d ' ')
  check "F28 run(통과, 실패, 종료 4) 뒤 TMPDIR 에 cc-test-tree.* 와 cc-check-push.* 가 없다" "$out" "0"
  out=$(find "$W/.git/cc-cmds-check-push" -name '.stamp.*' | wc -l | tr -d ' ')
  check "F28 도장 임시 파일이 남지 않는다" "$out" "0"

  rm -rf "$T"
  printf 'check-push self-test: %d passed, %d failed\n' "$passed" "$failed"
  # A floor on the count, so a refactor that silently skips cases cannot pass.
  if [ "$passed" -lt 293 ]; then
    printf 'check-push self-test: 통과 수 %d 가 하한 293 에 못 미칩니다\n' "$passed" >&2
    return 1
  fi
  [ "$failed" = "0" ]
}

# --- main --------------------------------------------------------------------

[ "$#" -eq 1 ] || check_push_usage
case "$1" in
  run)         check_push_run run ;;
  items)       check_push_run items ;;
  verify)     check_push_verify ;;
  --self-test) check_push_self_test ;;
  *)           check_push_usage ;;
esac
