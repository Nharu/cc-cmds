#!/usr/bin/env bash
# Pin the boundary-gate capture format to ONE spelling.
#
# WHAT THIS EXISTS FOR. The gate's capture command was respelled at fifteen
# places across six files. Adding `--untracked-files=all` — which is what makes
# the §6.3 (v) bracket's path assertion satisfiable at all — is therefore not one
# edit but fifteen, and a partial application leaves the tree in a state where
# some gates see files and others see folded directories. Before this pin, the
# number of the nine lint scripts that could detect such a partial application
# was **zero**: eight do not read these files at all and the ninth scans shell
# scripts, so it cannot see markdown structure.
#
# HOW IT WORKS. One site spells the format; every other site refers to it by
# name. That is the property being pinned, and it is what makes partial
# application detectable — a second spelling is a second thing to update, and
# with only one spelling on disk there is nothing to fall out of step with.
#
# THE ONE ADMITTED EXCEPTION is a sentence discussing the retired spelling, which
# necessarily contains it. Such an occurrence must be marked by the word `bare`
# immediately before it, so the exception is self-declaring rather than inferred
# from context. A reader who removes the word to tidy the prose turns the
# sentence into a violation, which is the correct direction to fail.
#
# THE MARKER IS ALSO COUNTED AND GATED, because only one direction of it had been
# reasoned about. Removing the word makes a sentence fail — safe. ADDING it makes
# any sentence legal, including one that *instructs* the reader to run the retired
# form, and the marker is purely lexical so it cannot tell discussion from
# instruction. Left ungated the bypass accumulates without a ceiling, so the count
# is pinned: a new marked occurrence is a deliberate edit to this file rather than
# a silent one.
#
# EVERY DISCOVERED VALUE IS BOUND TO THE VERDICT. `refs` and `marked` used to be
# computed, printed on the success line, and asserted against nothing — the
# population was fenced in the toy fixture and free in the real tree, which is the
# exact shape this repo keeps finding: a fence that counts its own population and
# gates on none of it.
#
# MATCHING IS FLAG-ORDER INDEPENDENT AND COUNTS OCCURRENCES. Three escapes were
# measured against the substring form. `git status --untracked-files=all
# --porcelain` is semantically identical and was neither a definition, nor a
# reference, nor a violation — it was nothing at all, while the short variant
# `-uall` was caught, so the coverage boundary was a by-product of substring
# choice rather than a decision. A canonical spelling and a retired one on the
# SAME line let the definition branch `continue` past the bare check, so one line
# carried both. And counting lines rather than occurrences reported two canonical
# spellings on one line as a single definition site.
#
# COMMENTS ARE NOT CONTENT, AND THIS LINT HAS TO STRIP FOR ITSELF. Every file is
# read through a comment-blanked copy. The shared fix that gave the region-scoped
# pin linters their pre-stripped input does not reach here, because this lint
# never calls the region extractor — it reads whole files — so nothing about that
# fix changes a byte of what this script sees. Landing the extractor fix and
# reporting the elision class closed would therefore have been wrong, and green.
# Line count is preserved by the blanker, so the line numbers in the diagnostics
# below still point into the original file.
#
# Usage:
#   bash scripts/lint-capture-format.sh
#   SKILLS_ROOT=<dir> bash scripts/lint-capture-format.sh   # fixture test
#
# Exit codes:
#   0 — exactly one definition and no unmarked respelling (or no skills → skip)
#   1 — the definition count is not 1, or a respelling is unmarked

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
# shellcheck source=./_strip-html-comments.sh
source "$script_dir/_strip-html-comments.sh"
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"
skills_root="${skills_root%/}"

# A `git status` invocation carrying `--porcelain`, in any flag order. The
# untracked flag is then looked for separately, so an equivalent respelling is
# classified rather than invisible.
# The whole invocation, flags included, so classification reads the flags it
# actually carries. Anchoring on `--porcelain` alone matched only up to that flag
# and left everything after it out of the match, which is how the canonical
# spelling read as the retired one.
STATUS_RE='git status([[:space:]]+-{1,2}[A-Za-z][^[:space:]|;&`]*)+'
PORCELAIN_RE='--porcelain'
UNTRACKED_RE='(--untracked-files=all|-uall)'

# The live populations, asserted rather than printed. A fixture root holds a
# different population by construction, so it declares its own in a file beside
# the tree it lints; the real tree has no such file and uses the pins below. The
# override is fenced in the other direction too — a declaration file next to the
# REAL tree would be a way to relax these pins from outside this script, so its
# presence there is itself a failure.
EXPECTED_REFS=18
EXPECTED_MARKED=2
POPULATION_DECL="$skills_root/POPULATION"

if [[ ! -d "$skills_root" ]]; then
  echo "SKIP: no skills tree under $skills_root"
  exit 0
fi

if [[ -f "$POPULATION_DECL" ]]; then
  if [[ -z "${SKILLS_ROOT:-}" ]]; then
    echo "FAIL: a population declaration sits beside the real skills tree; these pins are meant to be changed in this script, not overridden from the tree they measure" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$POPULATION_DECL"
fi

fail=0
defs=0
refs=0
marked=0

while IFS= read -r f; do
  rel="${f#"$skills_root/"}"
  if [[ ! -r "$f" ]]; then
    echo "FAIL: $rel — file is not readable, so this sweep cannot say anything about it; an unreadable file is an unknown, not an absence" >&2
    fail=1
    continue
  fi
  visible=$(stripped_copy "$f")
  while IFS=: read -r n line; do
    # Occurrences, not lines. Two canonical spellings on one physical line are
    # two definition sites, and reporting them as one is how a second spelling
    # hides inside the first one's line.
    rest="$line"
    while [[ "$rest" =~ $STATUS_RE ]]; do
      hit="${BASH_REMATCH[0]}"
      rest="${rest#*"$hit"}"
      # A `git status` without `--porcelain` is not the boundary-gate capture and
      # is none of this lint's business.
      [[ "$hit" =~ $PORCELAIN_RE ]] || continue
      if [[ "$hit" =~ $UNTRACKED_RE ]]; then
        defs=$((defs + 1))
        continue
      fi
      # A retired spelling. Permitted only where the sentence marks it as retired
      # with the word `bare` immediately before it. The check runs against the
      # occurrence rather than the line, so a canonical spelling elsewhere on the
      # same line grants no amnesty.
      if [[ "$line" == *"bare \`$hit\`"* || "$line" == *"bare $hit"* ]]; then
        marked=$((marked + 1))
        continue
      fi
      echo "FAIL: $rel:$n — the capture format is respelled here instead of referred to by name; one site defines it and every other site says \"the capture format\" (a discussion of the retired spelling must mark it with the word \`bare\`)" >&2
      fail=1
    done
  done < <(grep -nE -- "git status[[:space:]]+-" "$visible" || true)
  # `grep -c` prints 0 and exits 1 on no match, so the exit status is absorbed
  # rather than replaced — an `|| echo 0` appends a second line and the addition
  # below then fails with a syntax error the success line never mentions.
  count=$(grep -cF -- 'capture format' "$visible" 2>/dev/null || true)
  refs=$((refs + ${count:-0}))
done < <(find "$skills_root" -type f -name '*.md' | sort)

if (( defs != 1 )); then
  echo "FAIL: the capture format must be spelled at exactly 1 site, found $defs — a second spelling is a second thing to update, which is the state this pin exists to forbid" >&2
  fail=1
fi

if true; then
  if (( refs != EXPECTED_REFS )); then
    echo "FAIL: capture format — found $refs by-name reference(s), the pinned population is $EXPECTED_REFS; this count was printed and asserted against nothing, so the by-name references could be destroyed wholesale with the run still green" >&2
    fail=1
  fi
  if (( marked != EXPECTED_MARKED )); then
    echo "FAIL: capture format — found $marked marked discussion(s) of the retired spelling, the pinned population is $EXPECTED_MARKED; the marker is a one-word bypass and adding one has to be a deliberate edit to this file" >&2
    fail=1
  fi
fi

if (( fail == 0 )); then
  echo "OK:   capture format — $defs definition site, $refs by-name reference(s), $marked marked discussion(s) of the retired spelling"
fi

exit "$fail"
