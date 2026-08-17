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
# rather than the consequence, so it covers all 13 identically and covers every
# call site added after it, which is the half fixtures can never do.
#
# THE POPULATION IS PINNED, not merely printed. Three sentences of this header
# used to say "eleven" while the runtime said 12, and a reader cannot tell that
# apart from "one site is uncovered" — which is the one thing this header exists
# to settle. `EXPECTED_SITES` below is the count, and it is asserted, so the next
# drift fails instead of persisting. Adding or removing a call site is therefore
# a two-line change on purpose.
#
# EVERY OCCURRENCE IS CLASSIFIED, and the fourth bucket is the point. Matching
# only one spelling of the call is what let two forms escape: `=$( extract_between`
# with a space, and `r="$(extract_between …)"` with quotes around the
# substitution — the second was measured to PASS while not being counted as a
# call site at all, so an unguarded call was neither flagged nor tallied. Notation
# is not forbidden here, because all three spellings are identical to the shell
# and a lint that bans one says "unprotected" about code that is fine. What is
# forbidden is silence: every non-comment occurrence lands in exactly one of
# guarded / unguarded / deliberately-excluded / UNRECOGNIZED, and the last one
# fails loudly. A silent fourth category is the real defect.
#
# THE GUARD PREDICATE ASKS WHETHER THE SUBSTITUTION IS THE `if`'s CONDITION, not
# whether the line starts with `if`. A prefix test certified
# `if true; then v=$(extract_between …); fi` as guarded and raised the count —
# an active false assertion about a line it had read, which is worse than the
# escapes above: those hide a site, this one vouches for it.
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

# The live call-site count. Asserted only for the real tree: a fixture root holds
# whatever its case needs, and its own EXPECT pins that number.
EXPECTED_SITES=13

# An assignment from a command substitution, in any of the three spellings the
# shell treats alike. `var=`, `local var=`, `declare var=`, `readonly var=`.
ASSIGN='((local|declare|readonly|typeset)[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*='
SUBST='("?\$\([[:space:]]*|`[[:space:]]*)extract_between'
CALL="${ASSIGN}${SUBST}"

fail=0
sites=0
guarded=0
files=0

while IFS= read -r f; do
  case "$(basename "$f")" in
    "$HELPER"|"$SELF") continue ;;
  esac
  files=$((files + 1))
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

    if [[ "$body" =~ ^$CALL ]]; then
      # A bare call site: an assignment that is not the condition of anything.
      sites=$((sites + 1))
      case "$body" in
        local\ *|declare\ *|readonly\ *)
          echo "FAIL: ${f#"$scripts_root/"}:$n — extract_between call site is not guarded; the declaration builtin supplies the assignment's exit status, so a failing extraction is swallowed silently and the region variable holds the empty string" >&2 ;;
        *)
          echo "FAIL: ${f#"$scripts_root/"}:$n — extract_between call site is not guarded by \`if\`; a bare assignment aborts the script at that line under \`set -euo pipefail\` and loses every later diagnostic" >&2 ;;
      esac
      fail=1
      continue
    fi

    if [[ "$body" =~ ^if[[:space:]]+$CALL ]]; then
      # Guarded only if the substitution is the `if`'s CONDITION. `if true; then
      # v=$(…)` matches the prefix and guards nothing.
      prefix="${body%%=*}"
      case "$prefix" in
        *';'*|*'&&'*|*'||'*)
          sites=$((sites + 1)); fail=1
          echo "FAIL: ${f#"$scripts_root/"}:$n — extract_between call site sits inside an \`if\` but is not its condition, so a non-zero return is not caught; the substitution must be what the \`if\` tests" >&2 ;;
        *)
          sites=$((sites + 1)); guarded=$((guarded + 1)) ;;
      esac
      continue
    fi

    # Anything else that mentions the helper outside a comment is a form this
    # lint does not recognize. Reporting it is the whole point: silence here is
    # indistinguishable from coverage.
    sites=$((sites + 1)); fail=1
    echo "FAIL: ${f#"$scripts_root/"}:$n — unrecognized \`extract_between\` form; this lint could not classify it as guarded, unguarded, or prose, and an unclassified occurrence is not a covered one" >&2
  done < <(grep -nF -- 'extract_between' "$f" || true)
done < <(find "$scripts_root" -type f \( -name '*.sh' -o -name '*.bash' \) | sort)

if [[ -z "${SCRIPTS_ROOT:-}" ]] && (( sites != EXPECTED_SITES )); then
  echo "FAIL: extractor call contract — found $sites call site(s), the pinned population is $EXPECTED_SITES; update EXPECTED_SITES together with this header's prose, which is the only place the contract's coverage claim is stated" >&2
  fail=1
fi

if (( fail == 0 )); then
  if (( sites == 0 )); then
    echo "SKIP: no extract_between call sites under $scripts_root"
    exit 0
  fi
  echo "OK:   extractor call contract — $sites call site(s) across $files file(s), $guarded guarded by \`if\` as the tested condition, 0 unrecognized (item (1) only; the sentinel assignment of item (2) is prose-enforced)"
fi

exit "$fail"
