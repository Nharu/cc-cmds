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
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"
skills_root="${skills_root%/}"

FORMAT='git status --porcelain --untracked-files=all'
BARE='git status --porcelain'

if [[ ! -d "$skills_root" ]]; then
  echo "SKIP: no skills tree under $skills_root"
  exit 0
fi

fail=0
defs=0
refs=0
marked=0

while IFS= read -r f; do
  rel="${f#"$skills_root/"}"
  while IFS=: read -r n line; do
    if [[ "$line" == *"$FORMAT"* ]]; then
      defs=$((defs + 1))
      continue
    fi
    # A bare spelling: permitted only when the sentence marks it as the retired
    # form with the word `bare` immediately before it.
    if [[ "$line" == *"bare \`$BARE\`"* || "$line" == *"bare $BARE"* ]]; then
      marked=$((marked + 1))
      continue
    fi
    echo "FAIL: $rel:$n — the capture format is respelled here instead of referred to by name; one site defines it and every other site says \"the capture format\" (a discussion of the retired spelling must mark it with the word \`bare\`)" >&2
    fail=1
  done < <(grep -nF -- "$BARE" "$f" || true)
  refs=$((refs + $(grep -cF -- 'capture format' "$f" 2>/dev/null || true)))
done < <(find "$skills_root" -type f -name '*.md' | sort)

if (( defs != 1 )); then
  echo "FAIL: the capture format must be spelled at exactly 1 site, found $defs — a second spelling is a second thing to update, which is the state this pin exists to forbid" >&2
  fail=1
fi

if (( fail == 0 )); then
  echo "OK:   capture format — 1 definition site, $refs by-name reference(s), $marked marked discussion(s) of the retired spelling"
fi

exit "$fail"
