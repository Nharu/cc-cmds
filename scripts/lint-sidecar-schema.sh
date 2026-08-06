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
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"

SOT="$skills_root/_common/sidecar.md"

# SOT absent → mechanism not present in this tree → silent skip.
if [[ ! -f "$SOT" ]]; then
  echo "SKIP: _common/sidecar.md not found under $skills_root — sidecar contract not present"
  exit 0
fi

rel="${SOT#"$skills_root/"}"

# (1) Per-section structural check, fence-aware.
#
# A payload schema section is an H2 whose heading names its own artifact path,
# `docs/<kind>/{slug}.md`. `## 1` (generic mechanics) names no path and is
# therefore not a payload schema — the pin must not demand a terminator of it.
if ! nsec=$(awk -v rel="$rel" '
  {
    line = $0
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
    if (outside && line ~ /^## [0-9]+\. /) {
      cur = 0
      if (match(line, /`docs\/[a-z][a-z-]*\/\{slug\}\.md`/)) {
        path = substr(line, RSTART + 1, RLENGTH - 2)
        split(path, parts, "/")
        nsec++
        kind[nsec] = parts[2]
        atline[nsec] = NR
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
      # Machine header — fence-AGNOSTIC.
      if (index(line, "cc-" kind[cur] " v") > 0) hashdr[cur] = 1
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
    printf("%d\n", nsec)
    exit 0
  }
' "$SOT"); then
  exit 1
fi

# (2) Distinct-literal cross-check. Catches the mirror defect (1) cannot see:
# a terminator literal for a kind that has no payload schema section — the
# residue a removed schema leaves behind. DISTINCT set, never a count.
declared_kinds=$(grep -oE '^## [0-9]+\. .*`docs/[a-z][a-z-]*/\{slug\}\.md`' "$SOT" \
  | grep -oE 'docs/[a-z][a-z-]*/' | sed -E 's|^docs/||; s|/$||' | sort -u)
expected=$(printf '%s\n' "$declared_kinds" | sed -E 's|^|<!-- cc-|; s|$|: end -->|' | sort -u)
actual=$(grep -oE '<!-- cc-[a-z][a-z-]*: end -->' "$SOT" | sort -u)

if [[ "$expected" != "$actual" ]]; then
  echo "FAIL: $rel — the set of terminator literals present does not equal the set of payload schema kinds" >&2
  echo "  expected (one per payload schema section):" >&2
  printf '%s\n' "$expected" | sed -E 's|^|    |' >&2
  echo "  present in file:" >&2
  printf '%s\n' "$actual" | sed -E 's|^|    |' >&2
  exit 1
fi

echo "OK:   sidecar payload schemas — $nsec of $nsec sections declare their own kind-bound terminator (scope: $rel only; design-audit's schema is out of reach)"
