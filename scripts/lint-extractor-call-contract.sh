#!/usr/bin/env bash
# Assert the SHAPE of every `extract_between` call site.
#
# WHY A LINT AND NOT FIXTURES. The call contract in `_extract-between.sh` binds
# each call site individually, but the fixtures that were supposed to enforce it
# only reach some of them: removing the guard from ONE call site was measured to
# turn a fixture red at 5 of the 11 sites that existed at the time (2026-08-11),
# and the four call sites added most recently had coverage 0/4 — the count of
# call sites grew 57% and guard-regression coverage did not grow at all.
#
# A shape lint is uniform where fixtures are incidental. It reads the call site
# rather than the consequence, so it covers every occurrence identically and
# covers every call site added after it,
# which is the half fixtures can never do.
#
# THE POPULATION IS PINNED, not merely printed. Three sentences of this header
# used to say "eleven" while the runtime said 12, and a reader cannot tell that
# apart from "one site is uncovered" — which is the one thing this header exists
# to settle. `EXPECTED_SITES` below is the count, and it is asserted, so the next
# drift fails instead of persisting. Adding or removing a call site is therefore
# a two-line change on purpose.
#
# EVERY OCCURRENCE IS CLASSIFIED, and the unit is the OCCURRENCE, not the line.
# The enumerator used to emit one record per line and every classifier was
# anchored at the line start, so only the FIRST `extract_between` on a line was
# ever classified. The control group is decisive: the same two calls on TWO
# lines fail, on ONE line pass with `1 call site(s), 1 guarded, 0 unrecognized`,
# and the difference is a single newline. Appending an unguarded call to the end
# of an already-guarded line left the count unmoved and the run at exit 0 — the
# fifteenth call site did not appear in the tally at all, and `0 unrecognized`
# was an active false claim about a line this lint had read. `…; fi; b=$(…)` is
# ordinary shell, not self-sabotage, which is why this was a merge blocker.
#
# Notation is not forbidden here, because all three spellings are identical to
# the shell and a lint that bans one says "unprotected" about code that is fine.
# What is forbidden is silence: every non-comment occurrence lands in exactly one
# of guarded / unguarded / deliberately-excluded / UNRECOGNIZED, and the last one
# fails loudly. A silent fourth category is the real defect.
#
# THE GUARD PREDICATE IS RE-EXPRESSED OVER THE TEXT BEFORE EACH OCCURRENCE, and
# over the text after it where the shell puts the deciding token there. Three
# certifications were false:
#   * a prefix test called `if true; then v=$(extract_between …); fi` guarded;
#   * `if local v=$(extract_between …); then` was called guarded although the
#     declaration builtin supplies the assignment's exit status and swallows the
#     substitution's, so the `if` tests the builtin and not the extraction;
#   * `if v=$(extract_between …) || true; then` was called guarded because the
#     predicate stopped at the first `=` and never saw the `|| true`.
# The last one needs the text AFTER the occurrence, so this lint reads both
# sides. **Declared limit**: the after-side rule looks for `||` or `&&` before
# the condition's `then`, and an anchor argument containing `||` would trip it.
# There are none in this tree (measured 0), and a false positive here is a loud
# FAIL rather than a silent pass.
#
# WHAT IT DOES NOT COVER, stated because the gap is load-bearing.
#   * Contract item (2), the sentinel assignment on the failure path, has no
#     mechanical check: a call site that is guarded but omits the sentinel passes
#     this lint and then reports untouched literals as missing. That is exactly
#     the shape a caller would copy out of the helper's own canonical example,
#     which is why that example carries the sentinel and why keeping it correct
#     is not cosmetic.
#   * The sweep is `scripts/` only, and that is a DECLARED boundary rather than a
#     measurement. A consumer placed outside that directory — under a skill, say —
#     would source the helper by path and never be seen here. Nothing today
#     constrains where a consumer lives, so this is a forward risk, not a current
#     hole. Two narrower limits that were NOT declared have been removed instead:
#     the sweep now descends into subdirectories and accepts `.bash` as well as
#     `.sh`, each of which was measured to hide an unguarded call while the run
#     stayed green.
#
# Usage:
#   bash scripts/lint-extractor-call-contract.sh
#   SCRIPTS_ROOT=<dir> bash scripts/lint-extractor-call-contract.sh   # fixture test
#
# Exit codes:
#   0 — every call site is guarded and the population matches (or none → skip)
#   1 — an unguarded call site, an unrecognized form, or a population drift

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
scripts_root="${SCRIPTS_ROOT:-$script_dir}"
# Normalize: a caller passing a fixture path with a trailing slash would
# otherwise defeat the prefix strip below and emit an absolute path, which no
# fixture declaration can reproduce across machines.
scripts_root="${scripts_root%/}"

HELPER='_extract-between.sh'
# This script's own occurrences of the name are match patterns and a `grep`
# argument, not calls. It is exempted for the same reason the helper is: a file
# that talks ABOUT the contract is not a consumer of it. The exemption is by
# basename and is stated here rather than left as a special case in the loop,
# because a self-exemption that is not declared is how a lint stops covering
# itself without anyone noticing.
SELF='lint-extractor-call-contract.sh'

# The live populations, asserted rather than printed.
#
# THE `SCRIPTS_ROOT` GUARD WAS THE HOLE. Gating the assertion on "is this the
# real tree" meant every fixture invocation — which sets `SCRIPTS_ROOT` by
# definition — skipped it, so deleting the assertion outright left six fixtures
# and the real tree green. A fence nothing can exercise is not a fence. A fixture
# root declares its own populations in a file beside the tree it lints, exactly
# as the capture-format lint already does, and the override is fenced in the
# other direction too: a declaration file next to the REAL tree would be a way
# to relax these pins from outside this script, so its presence there fails.
#
# TWO NUMBERS ARE PINNED AND TWO ARE NOT, deliberately. `sites` and the count of
# files that actually CONTAIN a call site are gated, because both were measured
# to move without any gate noticing — adding a file with no call sites at all
# moved the reported file count while the run stayed at exit 0. `guarded` and the
# unrecognized count are printed and not gated, because the judgment path already
# implies them: a non-zero unrecognized count sets `fail`, and `guarded` differs
# from `sites` only when something already failed. An equivalence check over a
# number the verdict already forces cannot fail, and a check that cannot fail is
# the same defect class this file exists to remove.
EXPECTED_SITES=14
EXPECTED_SITE_FILES=2
POPULATION_DECL="$scripts_root/POPULATION"

# An assignment from a command substitution, in any of the three spellings the
# shell treats alike. `var=`, `local var=`, `declare var=`, `readonly var=`.
# An assignment from a command substitution, in any of the three spellings the
# shell treats alike, anchored at the END of the text preceding an occurrence.
DECL='(local|declare|readonly|typeset)'
OPENER="(${DECL}[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=(\"?\\$\\([[:space:]]*|\`[[:space:]]*)$"
# What may sit between the line start and that opener for the substitution to be
# the `if`'s own condition: the `if` keyword and nothing else.
# The `if` must be the statement this assignment belongs to, which means the
# text before the assignment ENDS with `if ` and what precedes that `if` is a
# statement boundary. Anchoring the whole head to `^ *if +$` was too strict in
# one direction — a second guarded call after a completed `fi;` on the same line
# read as unguarded — and the boundary class is what separates that legitimate
# shape from `if true; then v=$(…)`, which ends with `then` and never matches.
IFHEAD='(^[[:space:]]*|[;&|{}][[:space:]]*)if[[:space:]]+$'

if [[ -f "$POPULATION_DECL" ]]; then
  if [[ -z "${SCRIPTS_ROOT:-}" ]]; then
    echo "FAIL: a population declaration sits beside the real scripts tree; these pins are meant to be changed in this script, not overridden from the tree they measure" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$POPULATION_DECL"
fi

fail=0
sites=0
guarded=0
files=0
site_files=0

# classify <relpath> <lineno> <before> <after>
#   before — the line's text from its start up to this occurrence, exclusive
#   after  — the line's text following this occurrence
classify() {
  local rel="$1" n="$2" before="$3" after="$4" head opener

  if [[ ! "$before" =~ $OPENER ]]; then
    sites=$((sites + 1)); fail=1
    echo "FAIL: $rel:$n — unrecognized \`extract_between\` form; this lint could not classify it as guarded, unguarded, or prose, and an unclassified occurrence is not a covered one" >&2
    return
  fi

  sites=$((sites + 1))
  opener="${BASH_REMATCH[0]}"
  head="${before%"$opener"}"

  if [[ ! "$head" =~ $IFHEAD ]]; then
    # An `if` earlier on the line does not make this occurrence its condition,
    # and the two cases read differently to a contributor: `if true; then v=$(…)`
    # is a substitution in the wrong position, while `…; fi; v=$(…)` is an
    # ordinary bare assignment that merely shares a line with a finished `if`.
    # `then` is what separates them.
    case "$head" in
      *then*)
        echo "FAIL: $rel:$n — extract_between call site is a bare assignment inside a compound statement's body; a bare assignment aborts the script at that line under \`set -euo pipefail\` and loses every later diagnostic, and sharing a line with a guarded call does not guard it" >&2 ;;
      *if*)
        echo "FAIL: $rel:$n — extract_between call site sits inside an \`if\` but is not its condition, so a non-zero return is not caught; the substitution must be what the \`if\` tests" >&2 ;;
      *)
        case "$opener" in
          local\ *|declare\ *|readonly\ *|typeset\ *)
            echo "FAIL: $rel:$n — extract_between call site is not guarded; the declaration builtin supplies the assignment's exit status, so a failing extraction is swallowed silently and the region variable holds the empty string" >&2 ;;
          *)
            echo "FAIL: $rel:$n — extract_between call site is not guarded by \`if\`; a bare assignment aborts the script at that line under \`set -euo pipefail\` and loses every later diagnostic" >&2 ;;
        esac ;;
    esac
    fail=1
    return
  fi

  # Inside the `if`'s condition position. Two things still disqualify it.
  case "$opener" in
    local\ *|declare\ *|readonly\ *|typeset\ *)
      fail=1
      echo "FAIL: $rel:$n — extract_between call site is the \`if\` condition in form only; the declaration builtin supplies the exit status the \`if\` tests, so a failing extraction takes the THEN branch with the region variable empty" >&2
      return ;;
  esac
  case "${after%%then*}" in
    *'||'*|*'&&'*)
      fail=1
      echo "FAIL: $rel:$n — extract_between call site is joined to the \`if\` condition by \`||\` or \`&&\`, so the condition can hold when the extraction failed; the substitution must be the whole condition" >&2
      return ;;
  esac
  guarded=$((guarded + 1))
}

while IFS= read -r f; do
  case "$(basename "$f")" in
    "$HELPER"|"$SELF") continue ;;
  esac
  files=$((files + 1))
  rel="${f#"$scripts_root/"}"
  sites_before=$sites
  while IFS=: read -r n line; do
    body="${line#"${line%%[![:space:]]*}"}"
    # Comment lines are prose about the contract, not uses of it — otherwise the
    # contract's own documentation would be its first violation.
    case "$body" in
      '#'*) continue ;;
    esac
    # The helper's own definition and the `source` that pulls it in are uses of
    # the name, not call sites. Named explicitly so they cannot fall into the
    # unrecognized bucket.
    case "$body" in
      extract_between'('*|source*|.[[:space:]]*) continue ;;
    esac

    # Occurrence-wise. `consumed` carries everything already walked past, so
    # `before` is always measured from the start of the line rather than from
    # the previous occurrence.
    consumed=""
    rest="$body"
    while [[ "$rest" == *extract_between* ]]; do
      before="$consumed${rest%%extract_between*}"
      rest="${rest#*extract_between}"
      consumed="${before}extract_between"
      classify "$rel" "$n" "$before" "$rest"
    done
  done < <(grep -nF -- 'extract_between' "$f" || true)
  if (( sites > sites_before )); then
    site_files=$((site_files + 1))
  fi
done < <(find "$scripts_root" -type f \( -name '*.sh' -o -name '*.bash' \) | sort)

if (( sites != EXPECTED_SITES )); then
  echo "FAIL: extractor call contract — found $sites call site(s), the pinned population is $EXPECTED_SITES; update EXPECTED_SITES together with this header's prose, which is the only place the contract's coverage claim is stated" >&2
  fail=1
fi
if (( site_files != EXPECTED_SITE_FILES )); then
  echo "FAIL: extractor call contract — call sites live in $site_files file(s), the pinned population is $EXPECTED_SITE_FILES; a file that carries no call site must not move a reported number" >&2
  fail=1
fi

if (( fail == 0 )); then
  if (( sites == 0 )); then
    echo "SKIP: no extract_between call sites under $scripts_root"
    exit 0
  fi
  echo "OK:   extractor call contract — $sites call site(s) in $site_files of $files file(s), $guarded guarded by \`if\` as the tested condition, 0 unrecognized (item (1) only; the sentinel assignment of item (2) is prose-enforced)"
fi

exit "$fail"
