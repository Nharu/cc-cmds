#!/usr/bin/env bash
# Lint the structural invariant that every payload schema section of
# `_common/sidecar.md` declares its OWN kind's file terminator.
#
# Why this pin exists. The shared write loop (§1.3) reads `$SC_TERM`, the file
# terminator the payload schema fixes. While a schema fixed none, the empty
# value was contract-conforming — and an empty terminator short-circuits the
# truncation check and the completeness check at the same time, after which the
# carry-forward rule strips a required field line instead of a sentinel. The
# diff gate cannot see that removal: `diff` is content-based, so it aligns the
# deleted line against the byte-identical line the newly appended block
# re-emits. No `gate_write_form` predicate closes it; the fix has to be the
# terminator, and this script is what keeps the terminator from being dropped
# again by a schema added later.
#
# Three token classes, handled ASYMMETRICALLY — this is the load-bearing part:
#   * section heading    — must be OUTSIDE a fence (a fenced heading is an
#                          example, not a declaration)
#   * terminator literal — must be OUTSIDE a fence, for the same reason. A
#                          section that merely SHOWS its sentinel inside an
#                          example block has declared nothing, and a pin that
#                          ignored fences would pass that forgery.
#   * machine header     — fence-AGNOSTIC. The headers in this file are shown
#                          inside fenced blocks, so a naive fence-aware rule
#                          that applied uniformly would break on the real file.
#
# Counting rule. Never compare with `grep -c`: the re-convergence sentinel
# legitimately occurs on more than one line, so a count comparison passes
# vacuously. Compare the DISTINCT set (`grep -oE … | sort -u`).
#
# SCOPE LIMIT — read before trusting a green run. This script scans
# `_common/sidecar.md` and nothing else. `design-audit`'s report schema is a
# payload schema that lives in its own SKILL.md rather than in this file, so it
# is OUTSIDE this pin's reach: its terminator declaration is enforced by prose
# only. A green result here does NOT mean every payload schema in the repo
# declares a terminator — it means every payload schema IN THIS FILE does.
#
# Usage:
#   bash scripts/lint-sidecar-schema.sh                 # lint real plugin skills
#   SKILLS_ROOT=<dir> bash scripts/lint-sidecar-schema.sh   # fixture test
#
# Exit codes:
#   0 — every payload schema section declares its own kind-bound terminator
#       (or the SOT is absent → skip)
#   1 — at least one section is uncovered, crosswired, or forged

set -euo pipefail

# Resolve skills root (allow SKILLS_ROOT env override for tests).
script_dir=$(cd "$(dirname "$0")" && pwd)
# COMMENTS ARE NOT CONTENT. Every markdown file this lint reads is read through a
# comment-blanked copy. Wrapping a section in OUT-OF-LINE comment markers leaves
# the heading bytes intact, so a matcher anchored on the heading fires exactly as
# before while a reader sees nothing there — measured on this lint at exit 0 with
# a success line byte-identical to the unwrapped run. Commenting the heading line
# ITSELF turns the run red, but that is a parse failure rather than detection and
# it is not the shape an editor produces when removing a section.
#
# The strip is not sufficient on its own and is not offered as such: a roster
# built over a comment-blind derivation is defeated exactly as a count is,
# because an elided member still contributes itself to the observed set. The
# declaration and the derivation are two obligations, not one.
# shellcheck source=./_strip-html-comments.sh
source "$script_dir/_strip-html-comments.sh"
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"

SOT="$skills_root/_common/sidecar.md"

# SOT absent → mechanism not present in this tree → silent skip.
if [[ ! -f "$SOT" ]]; then
  echo "SKIP: _common/sidecar.md not found under $skills_root — sidecar contract not present"
  exit 0
fi

rel="${SOT#"$skills_root/"}"
# THE STRIP HERE IS SELECTIVE, and it has to be. The literals this lint pins —
# the file terminator and the machine header — ARE HTML comments by
# construction, so a blanket blanking erases the very bytes being asserted and
# turns a clean tree red. What must become comment-aware is SECTION RECOGNITION:
# wrapping a payload schema section in out-of-line comment markers leaves the
# heading bytes intact, the heading matcher fires as before, and the run was
# measured at exit 0 with a success line byte-identical to the unwrapped one.
#
# So both files are handed to awk: the blanked copy first, read into `vis` by
# line number, then the raw file. A heading whose blanked counterpart is empty
# is a heading a reader cannot see, and it opens no section. Everything else
# keeps reading the raw bytes.
#
# This alone does not close the class and is not offered as if it did. With the
# section gone, `nsec` falls with `covered` and the self-relative coverage
# comparison still holds — the absolute population floor that closes that is a
# separate obligation, and it can only be observed once this strip exists.
SOT_VISIBLE=$(stripped_copy "$SOT")

# (1) Per-section structural check, fence-aware.
#
# A payload schema section is an H2 whose heading names its own artifact path,
# `docs/<kind>/{slug}.md`. `## 1` (generic mechanics) names no path and is
# therefore not a payload schema — the pin must not demand a terminator of it.
if ! nsec=$(awk -v rel="$rel" '
  NR == FNR { vis[FNR] = $0; next }
  {
    line = $0
    # A line whose blanked counterpart holds nothing is inside a comment.
    hidden = (vis[FNR] !~ /[^ \t]/ && line ~ /[^ \t]/)
    # Fence state machine. Fences are variable-length (§2.5): an opener is 3+
    # backticks, and a closer is at least as long as the opener it closes.
    stripped = line
    sub(/^[ \t]+/, "", stripped)
    nb = 0
    while (substr(stripped, nb + 1, 1) == "`") nb++
    fenceline = 0
    if (nb >= 3) {
      if (infence == 0) { infence = 1; fencelen = nb; fenceline = 1 }
      else if (nb >= fencelen) { infence = 0; fencelen = 0; fenceline = 1 }
    }
    outside = (infence == 0 && fenceline == 0)

    # Section boundaries — outside fences only.
    if (outside && !hidden && line ~ /^## [0-9]+\. /) {
      cur = 0
      if (match(line, /`(<base>\/)?docs\/[a-z][a-z-]*\/\{slug\}\.md`/)) {
        path = substr(line, RSTART + 1, RLENGTH - 2)
        # The kind is the LAST-BUT-ONE segment, so an optional `<base>/` prefix
        # does not shift it. A fixed index would: the same heading with and
        # without the prefix would name two different kinds, and the section
        # would silently stop matching its own terminator.
        np = split(path, parts, "/")
        nsec++
        kind[nsec] = parts[np - 1]
        # FNR, not NR: two files are handed to this awk (the blanked copy, then
        # the raw one), so NR is cumulative across both and would report every
        # line number offset by the length of the first file.
        atline[nsec] = FNR
        hasterm[nsec] = 0
        hashdr[nsec] = 0
        cross[nsec] = ""
        cur = nsec
      }
    }

    if (cur > 0) {
      want = "<!-- cc-" kind[cur] ": end -->"
      # Terminator declaration — OUTSIDE a fence only.
      if (outside) {
        if (index(line, want) > 0) hasterm[cur] = 1
        if (match(line, /<!-- cc-[a-z][a-z-]*: end -->/)) {
          tok = substr(line, RSTART, RLENGTH)
          if (tok != want) cross[cur] = cross[cur] " " tok
        }
      }
      # Machine header — fence-AGNOSTIC (the headers are shown inside example
      # fences), but ANCHORED TO THE LINE START. A substring test accepted any
      # prose that merely mentions `cc-<kind> v2` — including a sentence saying
      # the header is absent, or a counterexample — so the check could not
      # distinguish a declared header from a discussion of one.
      if (line ~ ("^<!-- cc-" kind[cur] " v[0-9]")) hashdr[cur] = 1
    }
  }
  END {
    if (nsec == 0) {
      printf("FAIL: %s — no payload schema section found (expected an H2 naming `docs/<kind>/{slug}.md`)\n", rel) > "/dev/stderr"
      exit 1
    }
    covered = 0
    for (i = 1; i <= nsec; i++) {
      ok = 1
      if (hasterm[i] == 0) {
        printf("FAIL: %s:%d — payload schema `%s` declares no file terminator; expected the literal `<!-- cc-%s: end -->` outside a fence\n", rel, atline[i], kind[i], kind[i]) > "/dev/stderr"
        ok = 0
      }
      if (cross[i] != "") {
        printf("FAIL: %s:%d — payload schema `%s` declares a foreign terminator outside a fence:%s\n", rel, atline[i], kind[i], cross[i]) > "/dev/stderr"
        ok = 0
      }
      if (hashdr[i] == 0) {
        printf("FAIL: %s:%d — payload schema `%s` declares no machine header carrying `cc-%s v<N>`\n", rel, atline[i], kind[i], kind[i]) > "/dev/stderr"
        ok = 0
      }
      if (ok == 1) covered++
    }
    if (covered != nsec) {
      printf("FAIL: %s — %d of %d payload schema sections covered\n", rel, covered, nsec) > "/dev/stderr"
      exit 1
    }
    # The kind set is emitted, not just the count, so step (2) can CONSUME it
    # instead of re-deriving one. Line 1 is the count; every later line is a kind.
    printf("%d\n", nsec)
    for (i = 1; i <= nsec; i++) printf("%s\n", kind[i])
    exit 0
  }
' "$SOT_VISIBLE" "$SOT"); then
  exit 1
fi
stage1_kinds=$(printf '%s\n' "$nsec" | tail -n +2 | sort -u)

# THE ABSOLUTE POPULATION, declared here and nowhere else.
#
# The coverage comparison below asks whether every section it found is covered,
# and both operands are derived from the same variable input: delete a payload
# schema section and `covered` falls with `nsec`, so `OK: 1 of 1 sections` comes
# out at exit 0 for a document that lost half its schemas. The only absolute
# floor was `nsec == 0`. Demonstrated with the comment-strip fix already applied,
# which is why this is a separate obligation rather than part of that one — it is
# the residual that SURVIVES the class fix.
#
# The set is asserted, not the count: a count admits a rename and a swap, and the
# set does not. It is a hand-written literal, because deriving it from the file
# this lint measures is the dependence that makes every one of these fences
# defeatable.
EXPECTED_KINDS='design-drift design-reconverge'
observed_kinds=$(printf '%s\n' "$stage1_kinds" | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')
if [[ "$observed_kinds" != "$EXPECTED_KINDS" ]]; then
  echo "FAIL: $rel — the payload schema kinds present are not the declared set" >&2
  echo "  declared: $EXPECTED_KINDS" >&2
  echo "  present:  $observed_kinds" >&2
  exit 1
fi
nsec=$(printf '%s\n' "$nsec" | head -1)

# (2) Distinct-literal cross-check. Catches the mirror defect (1) cannot see:
# a terminator literal for a kind that has no payload schema section — the
# residue a removed schema leaves behind. DISTINCT set, never a count.
#
# BOTH STEPS USE ONE NOTION OF "A KIND". They do NOT share one notion of "a
# section", and an earlier form of this comment claimed both. What is shared is
# the kind half — step (2) consumes step (1)'s set rather than deriving its own.
# The fence state machine is still two byte-different copies, one per step, and
# saying otherwise names a property this file does not have. Step (1) runs a fence state machine
# and treats a heading inside a fence as example text; step (2) grepped the raw
# file and treated the same line as a real declaration. One lint, two answers to
# "what is a section" — and the asymmetry was not merely untidy: a legitimate
# fenced example heading in the contract produced a **hard failure** naming a
# payload schema that does not exist, and the same blindness masked a mutant that
# step (1) would otherwise have caught. `unfenced` below is the shared answer for
# fence state.
#
# KIND EXTRACTION WAS THE HALF THIS COMMENT OVERCLAIMED. Step (1) takes one kind
# per heading — the last-but-one segment of the `{slug}.md` path it matched —
# while step (2) took EVERY `docs/<kind>/` occurrence on the same heading. A
# heading that names a second path, a previous location in parentheses say, made
# step (2) demand a terminator for a kind step (1) never opened a section for,
# and the run hard-failed naming a payload schema that does not exist. Step (2)
# now consumes step (1)'s set rather than deriving its own; step (1) is the
# authority because it is the half that actually builds the sections.
unfenced=$(awk '
  NR == FNR { vis[FNR] = $0; next }
  {
    stripped = $0
    hidden = (vis[FNR] !~ /[^ \t]/ && $0 ~ /[^ \t]/)
    sub(/^[ \t]+/, "", stripped)
    nb = 0
    while (substr(stripped, nb + 1, 1) == "`") nb++
    fenceline = 0
    if (nb >= 3) {
      if (infence == 0) { infence = 1; fencelen = nb; fenceline = 1 }
      else if (nb >= fencelen) { infence = 0; fencelen = 0; fenceline = 1 }
    }
    if (infence == 0 && fenceline == 0 && !hidden) print; else print ""
  }
' "$SOT_VISIBLE" "$SOT")

expected=$(printf '%s\n' "$stage1_kinds" | sed -E 's|^|<!-- cc-|; s|$|: end -->|' | sort -u)
# The terminator side reads unfenced text too, for the same reason: a sentinel
# shown inside an example block is a picture of a terminator, not one.
actual=$(printf '%s\n' "$unfenced" | grep -oE '<!-- cc-[a-z][a-z-]*: end -->' | sort -u)

if [[ "$expected" != "$actual" ]]; then
  echo "FAIL: $rel — the set of terminator literals present does not equal the set of payload schema kinds" >&2
  echo "  expected (one per payload schema section):" >&2
  printf '%s\n' "$expected" | sed -E 's|^|    |' >&2
  echo "  present in file:" >&2
  printf '%s\n' "$actual" | sed -E 's|^|    |' >&2
  exit 1
fi

# (3) Guard-order pin. §1.3 evaluates the version guard BEFORE the truncation
# check, and that order is load-bearing: hoisting the truncation judgment ahead
# of it misdiagnoses an intact foreign-version file as truncated, a disposition
# §1.5 forbids. Nothing else in this repo reads that ordering, so before this pin
# existed a "simplification" back to truncation-first was a free edit. Absence of
# either anchor is a failure, not a skip — a pin that vanishes with its target
# reports success while guarding nothing.
# `|| true` is load-bearing, not defensive noise: under `set -euo pipefail` a
# no-match `grep` fails the whole pipeline and kills the script AT THE
# ASSIGNMENT, so the absent-anchor arm below could never run and the missing pin
# reported itself as a silent exit 1 with no diagnostic at all. The fixture that
# deletes both anchors is what surfaced it.
gv_line=$(grep -nE '^[[:space:]]*\[ ! -e "\$SNAP" \] \|\| guard_version' "$SOT" | head -1 | cut -d: -f1 || true)
tc_line=$(grep -nE '^[[:space:]]*# Truncation check' "$SOT" | head -1 | cut -d: -f1 || true)

if [[ -z "$gv_line" || -z "$tc_line" ]]; then
  echo "FAIL: $rel — guard-order anchors not found (version-guard call: ${gv_line:-missing}, truncation-check comment: ${tc_line:-missing})" >&2
  exit 1
fi
if (( gv_line >= tc_line )); then
  echo "FAIL: $rel — guard order inverted: the version guard (line $gv_line) must precede the truncation check (line $tc_line)" >&2
  exit 1
fi

echo "OK:   sidecar payload schemas — $nsec of $nsec sections declare their own kind-bound terminator + guard order pinned (version $gv_line < truncation $tc_line) (scope: $rel only; design-audit's schema is out of reach)"
