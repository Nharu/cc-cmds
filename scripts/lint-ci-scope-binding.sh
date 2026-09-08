#!/usr/bin/env bash
#
# lint-ci-scope-binding.sh — a workflow's `paths` filter and the execution set
# of the job it gates must each be DERIVED from their own source of truth, and
# the two derivations must agree.
#
# The defect this closes was observed: a leg's filter named six of the thirteen
# suites the leg actually ran, so editing one of the other seven woke nothing
# and the suite existed without ever being run by the change that broke it. A
# filter and an execution set maintained by hand in two files drift, and the
# drift is invisible because the build stays green.
#
# The two derivations:
#
#   filter side     — `explode(.) | .["on"].<event>.paths[]` of the target
#                     workflow. The anchor MUST be exploded first: on an
#                     aliased `paths: *anchor`, `.paths | length` reports 0
#                     while `.paths[]` yields every glob, so a non-empty guard
#                     written with `length` reads a populated filter as empty.
#                     `.["on"]` rather than `.on` because YAML 1.1 resolves a
#                     top-level `on` key to a boolean.
#
#   execution side  — the single `run: make <target>` line of that workflow
#                     (I1), the recipe lines of that Makefile target (I3), and
#                     the `# ci-deps:` declarations of the scripts those lines
#                     name. When there is more than one such line I1 reports the
#                     ambiguity and the execution set is the UNION of every named
#                     target: taking one of them would compute every other rule
#                     against an arbitrary half of the leg, which both invents
#                     violations against the half that runs and hides the real
#                     ones of the half that was dropped.
#
# Two markers, and they do not fold into one. `# ci-deps:` is what a suite
# READS: it joins the execution set, so rule 1 pushes it into the filter, and it
# carries no radius cap because declaring what you read is not a claim about
# breadth. `# ci-subject:` is a claim that the filter may cover files the job
# does NOT read: it does not join the execution set, and it is the only one the
# boundaries B1-B5 apply to. Folding them makes the billing line of B5
# identically zero for every declared tree, or else strands the declared paths
# outside the filter — one of the two mechanisms goes silently dead either way.
#
# Usage: bash scripts/lint-ci-scope-binding.sh
#
# Env override:
#   CI_SCOPE_ROOT      repo root to analyze (default: this script's repo root)
#   CI_SCOPE_WORKFLOW  target workflow, root-relative
#                      (default .github/workflows/notify-macos.yml)
#
# Exit codes:
#   0  the comparison ran and found no violation
#   1  the comparison ran and found at least one violation — I1-I4, rules 1-10
#   2  the comparison COULD NOT BE CARRIED OUT. That is a different statement
#      from "compared and clean", and conflating them is how a lint reports
#      success for a tree it never read: yq absent, unparsable workflow, an
#      event of the target workflow declaring no `paths` at all (rule 6-strict),
#      no `run: make` line, or an empty derivation on either side.
#
#      An abort reached AFTER a violation has already been recorded exits 1, not
#      2. Once something has been found, "could not be carried out" is no longer
#      true of the run, and a caller that treats exit 2 as "precondition unmet,
#      skip" would drop the findings that were already printed.
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.
# Glob matching runs under bash and never under zsh: `case "$p" in $glob)` lets
# `*` cross a `/` in zsh but not in bash, and a matcher that silently matches
# less manufactures false violations.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
default_root=$(cd "$script_dir/.." && pwd)
root="${CI_SCOPE_ROOT:-$default_root}"
workflow_rel="${CI_SCOPE_WORKFLOW:-.github/workflows/notify-macos.yml}"
workflow="$root/$workflow_rel"
makefile="$root/Makefile"

self_lint_base=$(basename "$0")

fail=0

viol() {
  # $1 rule id, $2 target, $3 message
  printf 'FAIL: [%s] %s — %s\n' "$1" "$2" "$3" >&2
  fail=1
}

die2() {
  # Exit 2 says the comparison was never carried out. Once a violation has been
  # recorded that statement is false about this run, and a wrapper that reads
  # exit 2 as "precondition unmet, skip" throws away what the lint already
  # found — the FAIL lines are printed and then discarded by the exit code that
  # follows them. A violation already on the record outranks the abort: the
  # abort keeps its diagnostic and the run exits 1.
  if [ "$fail" -ne 0 ]; then
    printf 'FAIL: %s\n' "$1" >&2
    printf 'FAIL: ci-scope-binding — 비교를 끝까지 수행하지 못했으나 이미 기록된 위반이 있다 — exit 1\n' >&2
    exit 1
  fi
  printf 'ERR: %s\n' "$1" >&2
  exit 2
}

# --- prerequisites ----------------------------------------------------------

command -v yq >/dev/null 2>&1 || die2 "yq (mikefarah v4) 를 찾지 못했다 — 비교를 수행할 수 없다"
[ -f "$workflow" ] || die2 "대상 워크플로가 없다: $workflow_rel"
[ -f "$makefile" ] || die2 "Makefile 이 없다: $root/Makefile"

# --- tracked corpus ---------------------------------------------------------
# The enumerator's name goes on the OK line every run. A silent fall back to
# `find` would put untracked files into rule 2's corpus and manufacture
# violations, so the transition has to be readable from the log.

#
# `-z` is not a nicety. With the default `core.quotePath`, `git ls-files` wraps a
# non-ASCII path in double quotes and octal-escapes every byte of it, so the
# corpus element is a string no matcher is ever handed — the file drops out of
# `in_corpus`, `tracked_under`, rules 2 and 3 at once, and the line COUNT is
# unchanged, so nothing in the summary reports the loss. `-z` sidesteps the
# quoting entirely rather than turning it off after the fact.
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

# --- glob -> ERE ------------------------------------------------------------
# GitHub `paths` semantics: `*` does not cross a separator, `**` does. `!`
# negation is NOT implemented; it is left as a literal character, so a negated
# glob matches no tracked file and rule 3 names it and fires. That is a loud
# refusal, not a false pass.

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

# Rule 6-strict, opted in for the target workflow: EVERY event it declares must
# carry `paths`. Without it, deleting the `push` filter of a x10 leg is not a
# violation — the event simply leaves the conditional rule's scope — and every
# master push runs the expensive leg unconditionally. I1-I4 govern the target
# and the execution set and never look at event coverage, so nothing else
# catches it.
first_event=""
first_globs=""
all_globs=""
for ev in $events; do
  tag=$(yq -r "explode(.) | .[\"on\"].\"$ev\".paths | tag" "$workflow" 2>/dev/null)
  if [ "$tag" != "!!seq" ]; then
    die2 "규칙 6-strict: 이벤트 '$ev' 가 paths 를 아예 갖지 않는다 — 비교가 수행되지 못했다"
  fi
  globs=$(yq -r "explode(.) | .[\"on\"].\"$ev\".paths[]" "$workflow" 2>/dev/null | sort)
  [ -n "$globs" ] || die2 "이벤트 '$ev' 의 paths 유도가 비었다"
  if [ -z "$first_event" ]; then
    first_event="$ev"
    first_globs="$globs"
  elif [ "$globs" != "$first_globs" ]; then
    viol "규칙 6" "$workflow_rel" "이벤트 '$ev' 의 paths 가 '$first_event' 와 일치하지 않는다"
  fi
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

# Matching goes through bash's own `=~` rather than through a pipe into
# `grep -q`. Under `pipefail` an early-exiting right side leaves SIGPIPE on the
# left and the whole pipeline reports failure — so the condition reads false at
# exactly the moment the answer is yes. It is also one fork per path avoided,
# over a corpus of hundreds.
matches_filter() {
  local re="^($filter_ere)$"
  [[ $1 =~ $re ]]
}

# --- execution side: I1 -----------------------------------------------------

run_lines=$(yq -r 'explode(.) | .jobs[].steps[] | select(has("run")) | .run' "$workflow" 2>/dev/null) \
  || die2 "워크플로의 steps 를 파싱하지 못했다: $workflow_rel"

# A step carrying an `if:` of its own, or sitting in a job that carries one, must
# not contribute to the execution set: the closure of a target named by a step
# that may never run joins the union and makes the header's claim above false, in
# the false direction (the filter is told to widen for a script nothing runs) and
# in the quiet one (a script the filter does name stops being reported because the
# closure absorbed it). Evaluating a GitHub expression is not this lint's job, so
# the honest answer is neither to include it nor to drop it quietly — it is that
# the comparison could not be carried out.
#
# The predicate is KEY PRESENCE, and the value under the key is deliberately not
# read. A value test folds `if: false` and an empty `if:` into the same `null` an
# absent key produces, so it waves through precisely the job that certainly never
# runs while rejecting the `if: true` that certainly does — the disposition comes
# out exactly inverted. Asking whether the author attached a condition at all is
# also the only question a file that has declared it does not evaluate GitHub
# expressions is entitled to ask.
#
# Two shapes stay outside this guard, and they are named here rather than left to
# be rediscovered. A conditional step whose verb is not `make` contributes nothing
# to the execution set and passes quietly, as the setup steps do. And a job
# disabled TRANSITIVELY — one whose `needs:` names a job that itself never runs —
# carries no `if:` key of its own, so its `make` lines still join the union;
# measured, such a tree is byte-identical in output to the same tree with the
# `needs:` removed. Only self-disabling by `if:` is what the guard sees.
cond_rows=$(yq -r '
  explode(.) | .jobs | to_entries[]
  | .key as $job | (.value | has("if")) as $jobif
  | ((.value.steps // []) | to_entries[])
  | select(.value | has("run"))
  | select($jobif or (.value | has("if")))
  | .key as $idx | .value.run as $run
  | ($run | split("\n"))[] | [$job, ($idx|tostring), .] | @tsv
' "$workflow" 2>/dev/null || true)

cond_make=$(printf '%s\n' "$cond_rows" | awk -F'\t' '
  NF >= 3 && $3 ~ /^[[:space:]]*make([[:space:]]|$)/ {
    printf "  잡 %s 스텝 %s: %s\n", $1, $2, $3
  }
')
if [ -n "$cond_make" ]; then
  die2 "조건부 make 스텝이 있다 — 이 린트는 GitHub 표현식을 평가하지 않으므로 그 스텝이 도는지 알 수 없고, 실행 집합을 유도할 수 없다:
$cond_make"
fi

make_lines=$(printf '%s\n' "$run_lines" | grep -E '^[[:space:]]*make[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]*$' || true)
make_count=$(printf '%s\n' "$make_lines" | grep -c '[^[:space:]]' || true)

if [ "$make_count" -eq 0 ]; then
  die2 "I1: 'run: make <타깃>' 줄이 0 개다 — 실행 집합을 유도할 수 없다"
fi

# The strict regex above is what yields a target name. A `run:` line that starts
# with `make` but does not match it — `make -C dir t`, `make t VAR=1`, `make a b`,
# `make ${{ matrix.t }}`, `make t && echo done` — would otherwise drop out with no
# trace at all. When it is the only `make` line the check above is already loud,
# but when a well-formed line accompanies it the union is silently incomplete:
# the header's claim is false and nothing says so. Same defect shape as the
# conditional step, so it gets the same disposition, and the rejected lines are
# quoted verbatim so the reader sees which form was not understood.
loose_make=$(printf '%s\n' "$run_lines" | grep -E '^[[:space:]]*make([[:space:]]|$)' || true)
loose_count=$(printf '%s\n' "$loose_make" | grep -c '[^[:space:]]' || true)
if [ "$loose_count" -ne "$make_count" ]; then
  unparsable=$(printf '%s\n' "$loose_make" \
    | grep -vE '^[[:space:]]*make[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]*$' \
    | grep '[^[:space:]]' | sed -E 's/^/  /' || true)
  die2 "'run: make …' 줄 중 타깃을 유도할 수 없는 형태가 있다 — 합집합이 조용히 불완전해진다:
$unparsable"
fi
# `awk` reads every line without exiting early, for the same reason the matcher
# above avoids `grep -q`: a right side that stops reading turns the pipeline into
# a failure under `pipefail`.
make_targets=$(printf '%s\n' "$make_lines" | awk '
  NF { sub(/^[ \t]*make[ \t]+/, ""); sub(/[ \t]*$/, ""); print }
' | sort -u)
make_targets_flat=$(printf '%s\n' "$make_targets" | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')

if [ "$make_count" -gt 1 ]; then
  # Two `make` lines is a violation the lint DETECTED, not a comparison it could
  # not carry out, so it is exit 1. Making it exit 2 would turn "this tree is
  # red today" into "this tree could not be compared" and erase what the
  # measurement behind this lint is measuring.
  #
  # Reporting the ambiguity is not the same as resolving it, and taking one of
  # the lines would compute every downstream rule against an arbitrary half of
  # the leg. Both directions are wrong and the quiet one is worse: the suites the
  # OTHER target runs get charged with "the filter wakes them but nothing runs
  # them", which prescribes the reverse repair of dropping them from the filter,
  # while the true violations of the half that was dropped are not reported at
  # all. So the execution set is the UNION of every named target's expansion —
  # I1 still names the ambiguity and the targets it is derived from, and rules 1,
  # 2 and I4 still answer about the leg that actually runs.
  viol "I1" "$workflow_rel" "'run: make <타깃>' 줄이 $make_count 개다 — 레그의 타깃이 모호하다. 실행 집합은 그 전부의 합집합으로 유도한다: $make_targets_flat"
fi

# Any other `run:` verb — `brew install …`, `jq --version` — contributes nothing
# to the execution set and passes quietly. Failing on an unrecognized verb would
# kill the lint on the job's own setup steps; I1 already forces "exactly one
# step does the work".

# --- Makefile: prerequisites and recipe lines -------------------------------

make_field() {
  # $1 = target, $2 = PREREQ|RECIPE
  awk -v t="$1" -v want="$2" '
    BEGIN { intgt = 0 }
    {
      if ($0 ~ "^" t ":") {
        intgt = 1
        p = $0
        sub(/^[^:]*:[ \t]*/, "", p)
        if (want == "PREREQ") print p
        next
      }
      if (intgt == 1) {
        if ($0 ~ /^\t/) {
          if (want == "RECIPE") { line = $0; sub(/^\t/, "", line); print line }
          next
        }
        if ($0 ~ /^[ \t]*$/) next
        if ($0 ~ /^#/) next
        intgt = 0
      }
    }
  ' "$makefile"
}

# I2 and I3 bind EACH named target's own prerequisites and recipe lines, and the
# violations they report name the target they came from, so a tree with more than
# one `make` line can be read without guessing which half a message is about.
# Extraction has to be a total function rather than a best effort, which is what
# these invariants buy.
prereqs=""
scripts_rel=""
bash_recipe_re='^bash [^[:space:]]+$'

# The same question asked of the same text must get the same answer wherever it
# is asked. This body used to be inline in the per-target loop while the
# prerequisite walker carried a prefix-match copy that checked neither the field
# count nor a line continuation, so every recipe line reached THROUGH a
# prerequisite bypassed I3 — and that is the route the union derivation feeds
# most of the execution set through. Lifting it makes the check total over every
# recipe line the leg reaches by any route, and keys each violation to the target
# it actually came from.
collect_recipe_scripts() {
  local t="$1" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *'\') viol "I3" "Makefile:$t" "줄이음이 있다: $line" ; continue ;;
    esac
    if [[ $line =~ $bash_recipe_re ]]; then
      scripts_rel=$(printf '%s\n%s\n' "$scripts_rel" "${line#bash }")
    else
      viol "I3" "Makefile:$t" "레시피 줄이 'bash <경로>' 두 필드가 아니다: $line"
    fi
  done <<EOF
$(make_field "$t" RECIPE)
EOF
}

for t in $make_targets; do
  t_prereqs=$(make_field "$t" PREREQ)
  t_recipe=$(make_field "$t" RECIPE)
  # A target the Makefile does not resolve yields empty for both fields. The loop
  # then contributes nothing while `scripts_rel` stays non-empty thanks to some
  # OTHER target, so the emptiness check further down never fires — and the I1
  # line above goes on claiming the execution set was derived from this name.
  # Existence has to be its own invariant rather than a side effect of that
  # check. One predicate covers all three shapes: undefined, defined-but-empty,
  # and defined in an `include`d file the root-Makefile reader never sees.
  if [ -z "$(printf '%s' "$t_prereqs" | tr -d '[:space:]')" ] &&
     [ -z "$(printf '%s' "$t_recipe" | tr -d '[:space:]')" ]; then
    viol "I1" "Makefile:$t" "워크플로가 이름을 댄 타깃을 Makefile 이 해소하지 못한다 — 선행도 레시피도 없다(정의되지 않았거나, 비었거나, include 로 정의됐다)"
  fi
  if [ -n "$(printf '%s' "$t_prereqs" | tr -d '[:space:]')" ]; then
    viol "I2" "Makefile:$t" "선행 타깃이 있다: $t_prereqs — ubuntu 를 겨냥한 편집이 이 레그를 함께 움직인다"
    prereqs="$prereqs $t_prereqs"
  fi
  collect_recipe_scripts "$t"
done

# Prerequisites are expanded anyway so rule 1 still has both sides to compare;
# I2 has already recorded that they should not be there.
expand_prereqs() {
  local t sub
  for t in $1; do
    collect_recipe_scripts "$t"
    sub=$(make_field "$t" PREREQ)
    if [ -n "$(printf '%s' "$sub" | tr -d '[:space:]')" ]; then
      expand_prereqs "$sub"
    fi
  done
}
expand_prereqs "$prereqs"

scripts_rel=$(printf '%s\n' "$scripts_rel" | grep -v '^$' | sort -u)
[ -n "$scripts_rel" ] || die2 "실행 집합 변의 유도가 비었다 — '$make_targets_flat' 에서 'bash <경로>' 줄을 얻지 못했다"

# I4: every extracted path is a real regular file and is named by the filter.
while IFS= read -r s; do
  [ -n "$s" ] || continue
  if [ ! -f "$root/$s" ]; then
    viol "I4" "$s" "추출된 경로가 실재하는 정규 파일이 아니다"
    continue
  fi
  matches_filter "$s" || viol "I4" "$s" "실행되는 스크립트가 어떤 필터 글로브에도 매치되지 않는다"
done <<EOF
$scripts_rel
EOF

# --- markers ----------------------------------------------------------------

marker_items() {
  # $1 = file, $2 = deps|subject
  grep -E "^[[:space:]]*#[[:space:]]*ci-$2:" "$1" 2>/dev/null \
    | sed -E "s|^[[:space:]]*#[[:space:]]*ci-$2:[[:space:]]*||" \
    | tr ' ' '\n' | grep -v '^$' || true
}

tracked_under() {
  # $1 = directory, without trailing slash
  printf '%s\n' "$corpus" | grep -E "^$(glob_body "$1")/" || true
}

dir_has_wildcard() {
  # The directory part of `<디렉터리>/**` must be a literal. Both markers ask the
  # same question of the same shape, so they ask it in one place: when the two
  # asked separately, `# ci-subject:` rejected `pkg*/mod/**` while `# ci-deps:`
  # accepted `*/**` — the same text refused by one marker and admitted by the
  # other. An admitted `*/**` is not a narrow declaration either: `tracked_under`
  # then greps `^[^/]*/` and absorbs every path with a slash into the execution
  # set, so one comment line turns the whole detector off.
  case "$1" in
    *'*'*|*'?'*) return 0 ;;
  esac
  return 1
}

exec_set="$scripts_rel"
subject_lines=""

while IFS= read -r s; do
  [ -n "$s" ] || continue
  [ -f "$root/$s" ] || continue

  deps=$(marker_items "$root/$s" deps)
  if [ -z "$deps" ]; then
    # `# ci-deps: none` is mandatory rather than optional precisely so that its
    # absence shows up as a missing line in a diff instead of as nothing.
    #
    # Reporting it must NOT skip the rest of this body. The `# ci-subject:`
    # collection below feeds `subject_trees`, and an empty `subject_trees`
    # removes rule 2's exemption, so one missing line charges every tracked file
    # under a declared tree with "not in the execution set and not in a declared
    # subject tree" — while the declaration sits in the file the lint refused to
    # finish reading. The amplification is the size of the tree, and the wording
    # points the reader away from the one-line cause. The item loop below runs
    # zero times on an empty `deps`, so no guard is needed here.
    viol "규칙 4" "$s" "'# ci-deps:' 선언이 없다 ('# ci-deps: none' 도 선언이다)"
  fi

  while IFS= read -r item; do
    [ -n "$item" ] || continue
    [ "$item" = "none" ] && continue
    case "$item" in
      */\*\*)
        d=${item%/\*\*}
        if dir_has_wildcard "$d"; then
          viol "규칙 4" "$s" "디렉터리 부분에 와일드카드가 있다 — '<디렉터리>/**' 의 디렉터리는 리터럴이어야 한다: $item"
          continue
        fi
        under=$(tracked_under "$d")
        if [ -z "$under" ]; then
          viol "규칙 4" "$s" "선언이 죽었다 — '$item' 가 tracked 파일을 하나도 담지 않는다"
        else
          exec_set=$(printf '%s\n%s\n' "$exec_set" "$under")
        fi
        ;;
      */)
        viol "규칙 4" "$s" "디렉터리 선언의 형태가 아니다 — '$item' 대신 '${item%/}/**' 로 적는다 (후행 슬래시만으로는 재귀 여부가 정해지지 않는다)"
        ;;
      *\**)
        viol "규칙 4" "$s" "선언에 와일드카드가 있다 — 파일이거나 '<디렉터리>/**' 여야 한다: $item"
        ;;
      *)
        if in_corpus "$item"; then
          exec_set=$(printf '%s\n%s\n' "$exec_set" "$item")
        else
          viol "규칙 4" "$s" "선언이 죽었다 — '$item' 가 tracked 파일이 아니다"
        fi
        ;;
    esac
  done <<EOF
$deps
EOF

  subs=$(marker_items "$root/$s" subject)
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    subject_lines=$(printf '%s\n%s\t%s\n' "$subject_lines" "$s" "$item")
  done <<EOF
$subs
EOF
done <<EOF
$scripts_rel
EOF

exec_set=$(printf '%s\n' "$exec_set" | grep -v '^$' | sort -u)
nl_exec="
$exec_set
"

in_exec() {
  case "$nl_exec" in
    *"
$1
"*) return 0 ;;
  esac
  return 1
}

# --- probe: rules 5 and 9 ---------------------------------------------------
# The probe reads path literals out of a script's own bytes. It is deliberately
# not the whole truth — a path assembled from a variable defined in a file the
# script only sources is invisible to it, which is exactly why `# ci-deps:` is
# an authored declaration rather than something derived. What the probe does buy
# is that a read it CAN see must be declared.
#
# The alternation matters. A `$VAR/` prefix has to be able to stand on its own
# with no intervening directory, or `"$orch_root/gate.sh"` matches only from
# `orch_root/` onward and rule 9 then reports a literal that does not appear in
# the source at all — pointing the reader at a directory named `orch_root` that
# never existed.

probe_literals() {
  grep -vE '^[[:space:]]*#[[:space:]]*ci-(deps|subject):' "$1" 2>/dev/null \
    | grep -vE 'https?://' \
    | grep -oE '(\$\{?[A-Za-z_][A-Za-z_0-9]*\}?/([A-Za-z0-9_.+-]+/)*|([A-Za-z0-9_.+-]+/)+)[A-Za-z0-9_.+-]+\.(sh|md|json|ya?ml|txt|tsv)' \
    | sort -u || true
}

resolve_literal() {
  # Echoes the corpus-relative path when the literal resolves, nothing when it
  # does not. Resolution is tried against the repo root and against the
  # declaring script's own directory, which is where a `"$DIR/name"` fragment
  # points once the variable is stripped.
  local raw=$1 owner_dir=$2 rel cand
  rel=$(printf '%s\n' "$raw" | sed -E 's|^\$\{?[A-Za-z_][A-Za-z_0-9]*\}?/||; s|^\./||')
  while :; do
    case "$rel" in
      */../*) rel=$(printf '%s\n' "$rel" | sed -E 's|[^/]+/\.\./||') ;;
      *) break ;;
    esac
  done
  if in_corpus "$rel"; then printf '%s\n' "$rel"; return 0; fi
  if [ -n "$owner_dir" ] && [ "$owner_dir" != "." ]; then
    cand="$owner_dir/$rel"
    if in_corpus "$cand"; then printf '%s\n' "$cand"; return 0; fi
  fi
  return 1
}

probe_evidence=""
while IFS= read -r s; do
  [ -n "$s" ] || continue
  [ -f "$root/$s" ] || continue
  owner_dir=$(dirname "$s")
  own_deps=$(marker_items "$root/$s" deps)

  while IFS= read -r raw; do
    [ -n "$raw" ] || continue
    [ "$raw" = "$s" ] && continue
    if resolved=$(resolve_literal "$raw" "$owner_dir"); then
      [ "$resolved" = "$s" ] && continue
      probe_evidence=$(printf '%s\n%s\t%s\n' "$probe_evidence" "$s" "$resolved")
      # Rule 5 is discharged by `# ci-deps:` ALONE. Letting `# ci-subject:`
      # discharge it reopens the hole this whole mechanism exists to close:
      # `# ci-deps: none` plus `# ci-subject: D/**` with `D` left out of the
      # filter would pass, because rule 1 only ever looks at the execution set
      # and a subject tree never joins it. And it is not a corner case — B2
      # requires two probe-visible reads under the tree, so every lawful use of
      # the marker builds exactly that shape.
      # Items are compared whole, never as substrings: a declared
      # `lib/helper.sh.bak` must not be read as covering `lib/helper.sh`, which
      # is a miss the substring form silently passes.
      covered=1
      while IFS= read -r item; do
        [ -n "$item" ] || continue
        if [ "$item" = "$resolved" ]; then covered=0; break; fi
        case "$item" in
          */\*\*)
            d=${item%/\*\*}
            case "$resolved" in "$d"/*) covered=0; break ;; esac
            ;;
        esac
      done <<EOF
$own_deps
EOF
      if [ "$covered" -ne 0 ]; then
        viol "규칙 5" "$s" "프로브된 경로 '$resolved' 가 그 스크립트 자신의 '# ci-deps:' 로 덮이지 않는다"
      fi
    else
      # What rule 9 separates is the BLAME, not the verdict. A literal that
      # resolves to nothing cannot be declared (rule 4 would call the
      # declaration dead) and cannot be filtered (rule 3 would call the glob
      # dead), so charging it to rule 5 puts the reader on a repair that both
      # other rules then refuse. It is reported as its own thing, and it still
      # fails — otherwise "do nothing" stays the quiet option, which is the
      # shape of the original defect.
      viol "규칙 9" "$s" "죽은 읽기 — 프로브된 경로 리터럴 '$raw' 가 tracked 파일로 해소되지 않는다"
    fi
  done <<EOF
$(probe_literals "$root/$s")
EOF
done <<EOF
$scripts_rel
EOF

# --- rule 1 -----------------------------------------------------------------

while IFS= read -r p; do
  [ -n "$p" ] || continue
  matches_filter "$p" || viol "규칙 1" "$p" "실행 집합의 원소가 어떤 필터 글로브에도 매치되지 않는다"
done <<EOF
$exec_set
EOF

# --- rule 2 -----------------------------------------------------------------
# The two truth-source files are a NAMED, enumerated exception, not a pattern.
# Refusing them makes the sources of truth uneditable: a PR that fixes the
# Makefile target or the workflow filter would not wake the leg, and changing
# the execution set would require breaking the filter first. A pattern here
# would be a door back out of rule 2, so the exception is two literal paths.
named_exceptions="Makefile
$workflow_rel"

subject_trees=$(printf '%s\n' "$subject_lines" | grep -v '^$' | cut -f2 | sort -u)

in_subject_tree() {
  local p=$1 t d
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    d=${t%/\*\*}
    case "$p" in "$d"/*) return 0 ;; esac
  done <<EOF
$subject_trees
EOF
  return 1
}

woken=$(printf '%s\n' "$corpus" | grep -E "^($filter_ere)\$" || true)
while IFS= read -r p; do
  [ -n "$p" ] || continue
  in_exec "$p" && continue
  case "
$named_exceptions
" in
    *"
$p
"*) continue ;;
  esac
  in_subject_tree "$p" && continue
  viol "규칙 2" "$p" "필터가 깨우지만 실행 집합에도 선언된 주제 트리에도 없다"
done <<EOF
$woken
EOF

# --- rule 3 -----------------------------------------------------------------
# Without this, rule 2 is vacuously satisfied by a glob that matches nothing,
# and rule 1 is vacuously satisfied by `- '**'`. The three rules only mean
# something together.
while IFS= read -r g; do
  [ -n "$g" ] || continue
  b=$(glob_body "$g")
  if [ -z "$(printf '%s\n' "$corpus" | grep -E "^($b)\$")" ]; then
    viol "규칙 3" "$g" "죽은 글로브 — tracked 파일을 하나도 매치하지 않는다"
  fi
done <<EOF
$filter_globs
EOF

# --- rule 7: the five boundaries on a `# ci-subject:` tree ------------------

common_ancestor() {
  # Longest directory prefix shared by every line of $1.
  local acc="" p d
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    d=$(dirname "$p")
    if [ -z "$acc" ]; then acc="$d"; continue; fi
    while [ "$acc" != "." ]; do
      case "$d/" in "$acc"/*) break ;; esac
      acc=$(dirname "$acc")
    done
  done <<EOF
$1
EOF
  printf '%s\n' "$acc"
}

while IFS=$'\t' read -r owner tree; do
  [ -n "$owner" ] || continue
  [ -n "$tree" ] || continue

  # B1 vocabulary. A repo's top-level directories are categories, not subjects.
  case "$tree" in
    */\*\*) : ;;
    *) viol "규칙 7/B1" "$owner" "주제 트리의 형태가 '<디렉터리>/**' 가 아니다: $tree" ; continue ;;
  esac
  d=${tree%/\*\*}
  if dir_has_wildcard "$d"; then
    viol "규칙 7/B1" "$owner" "디렉터리 부분에 와일드카드가 있다: $tree"
    continue
  fi
  seg_count=$(printf '%s\n' "$d" | tr '/' '\n' | grep -c '[^[:space:]]')
  if [ "$seg_count" -lt 2 ]; then
    viol "규칙 7/B1" "$owner" "경로 세그먼트가 둘 미만이다 — 최상위 디렉터리는 주제가 아니라 범주다: $tree"
    continue
  fi

  # B2 evidence. One read is a file, not a tree, so it is declared as a file.
  evidence=$(printf '%s\n' "$probe_evidence" | grep -v '^$' \
    | awk -F'\t' -v o="$owner" '$1 == o { print $2 }' \
    | grep -E "^$(glob_body "$d")/" | sort -u || true)
  ev_count=$(printf '%s\n' "$evidence" | grep -c '[^[:space:]]' || true)
  if [ "$ev_count" -lt 2 ]; then
    viol "규칙 7/B2" "$owner" "그 트리 아래 프로브 가시 읽기가 $ev_count 개다 — 둘 미만이면 트리가 아니라 파일로 적는다: $tree"
    continue
  fi

  # B3 minimality is the boundary that carries the load. B1 is a denylist and
  # denylists rot; B3 makes the breadth a DERIVED quantity, so a declaration can
  # never claim wider than where its own observed reads already reach.
  anc=$(common_ancestor "$evidence")
  if [ "$anc" != "$d" ]; then
    case "$anc/" in
      "$d"/*)
        viol "규칙 7/B3" "$owner" "증거보다 넓다 — 증거 전부를 담는 최소 디렉터리는 '$anc' 다: $tree"
        continue
        ;;
    esac
  fi

  # B4 radius cap.
  matched=$(tracked_under "$d")
  m_count=$(printf '%s\n' "$matched" | grep -c '[^[:space:]]' || true)
  if [ "$m_count" -gt 40 ]; then
    viol "규칙 7/B4" "$owner" "반경 상한 초과 — '$tree' 가 tracked 파일 $m_count 개를 매치한다(상한 40). 대안은 파일과 하위 디렉터리로 쪼갠 열거다"
    continue
  fi

  # B5 visibility. The billing number belongs in a green build log, not in a
  # quota warning.
  outside=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    in_exec "$p" || outside=$((outside + 1))
  done <<EOF
$matched
EOF
  printf '청구: %s — 주제 트리 %s 가 실행 집합 밖에서 깨우는 파일 %d 개\n' "$owner" "$tree" "$outside"
done <<EOF
$(printf '%s\n' "$subject_lines" | grep -v '^$')
EOF

# --- rule 8 -----------------------------------------------------------------
# Selected by `runs-on`, never by job name: a renamed job must not be able to
# drop out of this check. On the reduced leg a skip becomes the whole job, and
# without the flag the skip reports green.

#
# Every `.jobs` query explodes first, exactly as the `on:`/`paths` queries above
# do. Without it an aliased `runs-on: *ro` comes back as the literal string
# `*ro`, which holds no `macos`, so the job falls out of this check entirely —
# rule 8, whose whole subject is the silent green skip, skipping silently. The
# same omission on the `env` query makes `keys` fail on an alias, `|| true`
# swallows the error, and the empty key list is then read as "the variable is
# absent" — a false violation from the same missing word.
job_names=$(yq -r 'explode(.) | .jobs | keys | .[]' "$workflow" 2>/dev/null || true)
for job in $job_names; do
  # `runs-on` is read on its own rather than folded into one row per job, so a
  # sequence-valued `runs-on` still yields its entries instead of collapsing the
  # whole check into a parse failure.
  runs_on=$(yq -r "explode(.) | .jobs.\"$job\".\"runs-on\"" "$workflow" 2>/dev/null || true)
  case "$runs_on" in
    *macos*) : ;;
    *) continue ;;
  esac
  env_keys=$(yq -r "explode(.) | .jobs.\"$job\".env | keys | .[]" "$workflow" 2>/dev/null || true)
  case "
$env_keys
" in
    *"
CC_CMDS_REQUIRE_NATIVE
"*) : ;;
    *) viol "규칙 8" "$workflow_rel:$job" "macOS 러너에서 도는 잡이 CC_CMDS_REQUIRE_NATIVE 를 설정하지 않는다 — 침묵 초록 스킵이 열려 있다" ;;
  esac
done

# --- rule 10: self-application ---------------------------------------------
# Items 10, 11, 13 and R11 point at four different places and say one thing: the
# binding lint has to satisfy, for its own target and trigger and rules, the
# invariant it imposes. Standing this as a rule rather than as a separate meta
# check is deliberate — a meta check is itself a place nothing binds, so the
# recursion would move up a level instead of closing.

runner_workflow=""
for wf in "$root"/.github/workflows/*.yml "$root"/.github/workflows/*.yaml; do
  [ -f "$wf" ] || continue
  wf_runs=$(yq -r 'explode(.) | .jobs[].steps[] | select(has("run")) | .run' "$wf" 2>/dev/null || true)
  if [ -n "$(printf '%s\n' "$wf_runs" | grep -E '^[[:space:]]*make[[:space:]]+lint[[:space:]]*$')" ]; then
    runner_workflow=${wf#"$root"/}
    break
  fi
done

if [ -n "$runner_workflow" ]; then
  lint_rel=$(make_field lint RECIPE | awk -v b="$self_lint_base" '
    !seen && $0 ~ ("^bash [^ \t]*" b "$") { sub(/^bash /, ""); print; seen = 1 }
  ')
  if [ -z "$lint_rel" ]; then
    lint_rel="scripts/$self_lint_base"
  fi
  lint_dir=$(dirname "$lint_rel")
  test_rel="$lint_dir/test-$self_lint_base"
  fixture_root="tests/fixtures/$(printf '%s\n' "$self_lint_base" | sed -E 's/\.sh$//')"

  surface="$workflow_rel
Makefile
$lint_rel
$test_rel"
  fixture_files=$(tracked_under "$fixture_root")
  if [ -n "$fixture_files" ]; then
    surface=$(printf '%s\n%s\n' "$surface" "$fixture_files")
  fi

  runner_events=$(yq -r 'explode(.) | .["on"] | keys | .[]' "$root/$runner_workflow" 2>/dev/null || true)
  for ev in $runner_events; do
    tag=$(yq -r "explode(.) | .[\"on\"].\"$ev\".paths | tag" "$root/$runner_workflow" 2>/dev/null)
    [ "$tag" = "!!seq" ] || continue
    r_globs=$(yq -r "explode(.) | .[\"on\"].\"$ev\".paths[]" "$root/$runner_workflow" 2>/dev/null | sort -u)
    r_ere=""
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      b=$(glob_body "$g")
      if [ -z "$r_ere" ]; then r_ere="$b"; else r_ere="$r_ere|$b"; fi
    done <<EOF
$r_globs
EOF
    [ -n "$r_ere" ] || continue
    r_anchored="^($r_ere)$"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      in_corpus "$p" || continue
      if ! [[ $p =~ $r_anchored ]]; then
        viol "규칙 10" "$runner_workflow:$ev" "이 린트를 돌리는 워크플로의 필터가 결속면 '$p' 를 이름으로 담지 않는다 — 그 파일만 고치는 PR 에서 결속 린트가 침묵한다"
      fi
    done <<EOF
$surface
EOF
  done
fi

# --- summary ----------------------------------------------------------------

exec_count=$(printf '%s\n' "$exec_set" | grep -c '[^[:space:]]' || true)
glob_count=$(printf '%s\n' "$filter_globs" | grep -c '[^[:space:]]' || true)
corpus_count=$(printf '%s\n' "$corpus" | grep -c '[^[:space:]]' || true)

printf '유도: 실행 집합 %d 개\n' "$exec_count"
printf '%s\n' "$exec_set" | sed -E 's/^/  /'

if [ "$fail" -ne 0 ]; then
  printf 'FAIL: ci-scope-binding — 필터 글로브 %d 개 대 실행 집합 %d 개, tracked 코퍼스 %d 파일 (%s)\n' \
    "$glob_count" "$exec_count" "$corpus_count" "$enumerator" >&2
  exit 1
fi

printf 'OK: ci-scope-binding — 필터 글로브 %d 개, 실행 집합 %d 개, tracked 코퍼스 %d 파일 (%s)\n' \
  "$glob_count" "$exec_count" "$corpus_count" "$enumerator"
exit 0
