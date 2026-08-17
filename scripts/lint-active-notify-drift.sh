#!/usr/bin/env bash
# Lint the active-notify contract surfaces for the two drift classes that
# shipped green in PR #88.
#
#   (A) Phrase drift — the always-loaded surfaces must not keep a contract the
#       body has retired. Scans the owning SKILL.md's YAML frontmatter and the
#       shared procedure file for banned phrases, and requires the surviving
#       termination contract to be named.
#   (B) Citation drift — every `SKILL.md §N[.M]` citation in a shared file must
#       resolve to a real heading in its owning SKILL.md, matching on the
#       heading TITLE, not merely on the section number existing.
#
# Why (B) checks the title and not just existence: the drift this lint was
# written for was a uniform +1 shift, and a shifted number always lands on some
# neighbouring real heading. An existence-only check catches none of it. The
# title anchor is what makes the citation falsifiable.
#
# Rules the implementation depends on (each was a live failure while
# prototyping — do not "simplify" any of them away):
#   1. Newlines are flattened before citations are detected. A citation wrapped
#      across a line break (`(SKILL.md\n  §4.4 …)`) is invisible to a line-wise
#      scan, and one of the two originally-drifted citations is wrapped.
#   2. The heading regex accepts both shapes: top-level headings carry a period
#      after the number (`## 7. Permission test bypass`), subsection headings do
#      not (`### 4.4 Fire-now ordering …`).
#   3. Anchor comparison is case-insensitive and substring-based. Heading titles
#      carry trailing parentheticals (`(when an ARM may be live)`) that a
#      citation must not be forced to reproduce.
#   4. The shared-file → owning-SKILL.md mapping is an explicit table. Only one
#      shared file currently carries qualifying citations; leaving ownership
#      implicit would make the rule vacuous for the other shared files. A
#      qualifying citation found in an unmapped shared file is a failure, so the
#      table cannot silently fall behind.
#   5. `turn-end auto-fire` is banned only outside a negation. The shared file
#      states the correct contract using that exact phrase inside a negative
#      sentence; a blanket ban would fail the very text this lint exists to
#      protect.
#   6. Both rules judge blank-line-separated BLOCKS with newlines flattened, not
#      lines. Re-wrapping a paragraph was enough to carry a banned phrase and a
#      conditional phrase past a line-wise scan in both directions — the phrase
#      split across the wrap became invisible, and a negator wrapped onto the
#      previous line turned legitimate prose into a false positive.
#   7. The negation test is ASYMMETRIC and windowed. English negators precede
#      the phrase; Korean is verb-final, so its negative endings follow it. A
#      before-only window — which is what the review proposed — false-positives
#      on legitimate Korean negation, measured. An unwindowed test lets a
#      negation belonging to an unrelated clause license the assertion.
#
# Known ceiling — the `self-cancel` requirement is an EXISTENCE check. A file
# that keeps the token while inverting the contract around it ("there is no
# model self-cancel") satisfies it. That is inherent to a presence test; the
# check guarantees the term is named, not that it is named truthfully. The same
# ceiling applies to the banned-phrase rule more broadly: it bans NOTATIONS that
# point at a retired contract, not the contract itself. A restatement in other
# words passes — `턴이 끝날 때마다` does, measured.
#
# Usage:
#   bash scripts/lint-active-notify-drift.sh          # lint the real surfaces
#
# Env override:
#   SKILLS_ROOT=<dir> bash scripts/lint-active-notify-drift.sh   # fixture tests
#
# Exit codes:
#   0 — all checks passed (a non-fatal WARN may still be printed)
#   1 — at least one violation found
#   2 — no scannable files found (checked only when there are no violations)

set -euo pipefail

# Shared-file → owning-SKILL.md table (rule 4). One `<shared>|<owner>` pair per
# line, both paths relative to the skills root. Add a row when a shared file
# starts citing a SKILL.md section; an unmapped citation fails the lint.
OWNER_TABLE='_common/notify.md|active-notify/SKILL.md'

# Rule (A) banned phrases. Spelling variants of the same retired contract, not
# the two literals that happened to ship — those two caught 3 of 10 restatements.
# Classes are spelled out per letter rather than folding only the first letter:
# the first-letter form still misses an all-caps restatement, and per-letter
# classes are the technique `normalize_citations` below already uses, for the
# reason it already gives (a case-insensitive flag is GNU-only in sed).
BANNED_RE='매[[:space:]]*([Tt][Uu][Rr][Nn]|턴)|([Pp][Ee][Rr]|[Ee][Vv][Ee][Rr][Yy]|[Ee][Aa][Cc][Hh])[[:space:]-]+[Tt][Uu][Rr][Nn]|([Tt][Uu][Rr][Nn]|턴)[[:space:]]*마다'
# What a green run on this rule does and does not mean. The frontmatter states
# SIX contracts in the negative, enumerated here so the number has a referent
# that travels with this header:
#
#   1. no invocation without the request lexicon;
#   2. never ARM or bypass on the model's own judgement;
#   3. wall-clock requests are not ARMed;
#   4. there is no turn-end auto-fire;
#   5. a turn opened by an external scheduler is not an instance;
#   6. there is no slash-command surface.
#
# THIS CHECK COVERS NUMBER 4, AND ONLY NUMBER 4. Its green does not mean the
# always-loaded contract is pinned — it means the tracked phrasings were not
# asserted without being negated. A reader who concludes anything wider is wrong
# about five of the six.
#
# Handled separately because it is legitimate inside a negation (rule 5).
#
# A FAMILY, and bilingual. The single English literal covered none of the actual
# contract: the surfaces state it in Korean too, and that spelling appeared in
# neither this list nor the banned family, so no window setting could ever reach
# it — the gap was structural, not a tuning problem. Spacing and hyphenation vary
# across the surfaces, so the family matches on those rather than on one spelling.
CONDITIONAL_PHRASE='turn-end auto-fire'
CONDITIONAL_RE='turn[- ]?end[[:space:]]*auto[- ]?fire|턴[[:space:]]*종료[[:space:]]*자동[[:space:]]*발화'
# POSIX-portable word boundaries rather than `\b`, which is unreliable in BSD
# grep ERE and is a lint-bash-portability hazard. Whole words matter here: the
# unanchored `[Nn]o` this replaces matched `now`, `notes`, `nothing`, `notified`
# and `fire-now` — and `fire-now` is this file's central term.
# The hyphen is excluded from the TRAILING boundary only, so `no-op` and
# `no-brainer` stop counting as negators while `no longer` still does. The
# leading boundary keeps it.
NEGATION_RE_BEFORE='(^|[^[:alnum:]])([Nn]o|[Nn]ot|[Nn]ever|[Nn]either|[Nn]or)([^[:alnum:]-]|$)|없|않|아니|못'
# Defined by reference, not by copying the literal, so the two cannot drift
# apart — which is the class of defect this lint exists for. The Korean-only
# form rejected correct English denials that put the phrase after the negator.
# What stops an unrelated clause from licensing an assertion is the WINDOW, not
# the language split.
NEGATION_RE_AFTER="$NEGATION_RE_BEFORE"
# BYTES, not characters — the window is measured under `local LC_ALL=C` so the
# two CI runners cannot disagree. The two sides differ because the languages do:
# an English negator precedes the phrase and is ASCII (1 byte per character),
# while a Korean negative ending follows it at three bytes per syllable. 144
# bytes is the same ~48 syllables of reach the leading side gets in characters.
NEGATION_WINDOW_BEFORE=48
NEGATION_WINDOW_AFTER=144
# Shortest anchor that can falsify a renumbering. A one- or two-character anchor
# matches almost any title by substring.
ANCHOR_MIN_LEN=4
# Rule (A) required phrase — the termination contract that replaced the retired
# one must be named on each scanned surface.
REQUIRED_PHRASE='self-cancel'
# Judged as a regex on flattened text. Flattening alone is not enough: blocks are
# joined with a space, so a token broken at its hyphen across a wrap flattens to
# `self- cancel`, which still does not contain the literal. The optional
# whitespace is what closes that, and the folded classes keep a sentence-cased
# spelling from counting as absent. The literal above stays as the name printed
# in the failure, so the message still says which token to add.
REQUIRED_PHRASE_RE='[Ss]elf-[[:space:]]*[Cc]ancel'
tab=$(printf '\t')

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"

violations=0
checks=0

fail() {
  echo "FAIL: $*" >&2
  violations=$((violations + 1))
}

# Non-fatal. Used where the real tree already violates the property and making
# the rule fatal would ship a red tree; `lint-skill-options.sh` sets the
# precedent for a warn tier in this repo.
warn() {
  echo "WARN: $*" >&2
}

# True when every occurrence of $2 in $1 carries a negator close enough to be
# negating THAT phrase. English negators usually precede it; Korean is
# verb-final, so its negative endings follow it. An unwindowed test lets a
# negation belonging to an unrelated clause license the assertion.
#
# Takes the phrase as an argument because the banned family needs the same
# exception: stating the retired contract in order to deny it is the correct
# thing to write on these surfaces, and the family is six times larger than the
# one literal, so without the exception the gate degrades the text it protects.
#
# The reach is the CLAUSE BOUNDARY INTERSECTED WITH THE WINDOW, not one or the
# other. Replacing the window with clause boundaries alone breaks a long
# single-clause block — everything in it stays in reach of everything else, which
# is the saturation this rule exists to stop. Keeping only the window lets a
# negator from the neighbouring sentence license the assertion. Taking the
# smaller of the two is what closes both directions at once.
# Clause terminators, as an ALTERNATION rather than a bracket class: this runs
# under `LC_ALL=C`, where `[,—]` would enrol each of the em dash's three bytes as
# an independent member and could cut at a stray byte inside other multibyte text.
#
# The set is CLAUSE terminators, not sentence terminators. A comma is the one
# that matters most here — the surfaces state the contract as
# "... turn-end auto-fire, and the dispatcher owns no timer", so a sentence-level
# cut leaves the neighbouring clause's negator in reach and licenses the very
# assertion this rule exists to catch.
_CLAUSE_SEP='(\.|;|!|\?|,|—)'

_clause_before() {   # text after the LAST clause terminator (whole string if none)
  printf '%s' "$1" | sed -E "s/^.*${_CLAUSE_SEP}//"
}
_clause_after() {    # text up to the FIRST clause terminator (whole string if none)
  printf '%s' "$1" | sed -E "s/${_CLAUSE_SEP}.*\$/\1/"
}


phrase_is_negated() {
  # `local LC_ALL=C` pins ${#s} and ${s:0:n} to BYTES. Without it the window is
  # characters in a UTF-8 locale and bytes in C/POSIX, so the same text is
  # judged differently on two CI runners — and the side that moves is Korean,
  # three bytes per syllable, which is the text this window exists to protect.
  # The assignment is scoped to this function; the caller's locale is untouched.
  local LC_ALL=C
  local rest="$1" phrase="$2" head tail
  while [[ "$rest" == *"$phrase"* ]]; do
    head="${rest%%"$phrase"*}"
    tail="${rest#*"$phrase"}"
    head=$(_clause_before "$head")
    tail=$(_clause_after "$tail")
    if (( ${#head} > NEGATION_WINDOW_BEFORE )); then
      head="${head: -NEGATION_WINDOW_BEFORE}"
    fi
    tail="${tail:0:NEGATION_WINDOW_AFTER}"
    if ! printf '%s\n' "$head" | grep -qE "$NEGATION_RE_BEFORE" \
       && ! printf '%s\n' "$tail" | grep -qE "$NEGATION_RE_AFTER"; then
      return 1
    fi
    rest="${rest#*"$phrase"}"
  done
  return 0
}

# Emit `<first-line-number>\t<flattened text>` for each blank-line-separated block.
blocks_of() {
  awk '
    /^[[:space:]]*$/ { if (buf != "") { print start "\t" buf; buf = "" } ; next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (buf == "") { start = NR; buf = line } else { buf = buf " " line }
    }
    END { if (buf != "") print start "\t" buf }
  ' "$1"
}

# Flatten newlines and fold every recognized citation notation onto the canonical
# `SKILL.md §N` shape. Three substitutions: reversed word order; the connectives
# that sit between the filename and the section mark; and the §-less `section N`
# spelling. Character classes are spelled out rather than using a case-insensitive
# flag, which is GNU-only in sed.
normalize_citations() {
  tr '\n' ' ' < "$1" \
    | tr -s ' ' \
    | sed -E 's/§([0-9]+(\.[0-9]+)?)[[:space:]]*(of|의)[[:space:]]+[Ss][Kk][Ii][Ll][Ll]\.[Mm][Dd]/SKILL.md §\1/g' \
    | sed -E 's/[Ss][Kk][Ii][Ll][Ll]\.[Mm][Dd][[:space:]]*(의|,)?[[:space:]]*(body|본문|section|절)?[[:space:]]*§/SKILL.md §/g' \
    | sed -E 's/[Ss][Kk][Ii][Ll][Ll]\.[Mm][Dd][[:space:]]*(body|본문)?[[:space:]]*(section|절)[[:space:]]+([0-9])/SKILL.md §\3/g'
}

# Emit the frontmatter of $1 (the lines between the opening `---` and the next
# `---`, inclusive) so `usage:` — which the description-budget lint does not
# read — is still covered here.
frontmatter_of() {
  awk 'NR==1 && $0!="---" { exit } NR==1 { print; next } { print } $0=="---" && NR>1 { exit }' "$1"
}

# Emit `<num>\t<title>` for every numbered heading in $1 (rule 2).
headings_of() {
  sed -nE 's/^#{2,4} ([0-9]+(\.[0-9]+)?)\.? +(.*)$/\1\t\3/p' "$1"
}

# --- driver -------------------------------------------------------------
scanned=0

while IFS='|' read -r shared owner; do
  [[ -n "$shared" ]] || continue
  shared_path="$skills_root/$shared"
  owner_path="$skills_root/$owner"

  if [[ ! -f "$shared_path" ]]; then
    fail "$shared — declared in OWNER_TABLE but not found at $shared_path"
    continue
  fi
  if [[ ! -f "$owner_path" ]]; then
    fail "$shared — declared owner not found: $owner"
    continue
  fi
  scanned=$((scanned + 1))

  # ---- (A) phrase drift on both surfaces ----
  fm_tmp=$(mktemp)
  frontmatter_of "$owner_path" > "$fm_tmp"

  for pair in "$fm_tmp|$owner frontmatter" "$shared_path|$shared"; do
    scan_file="${pair%%|*}"
    scan_label="${pair#*|}"
    checks=$((checks + 1))
    while IFS="$tab" read -r block_start block_text; do
      [[ -n "$block_text" ]] || continue
      if printf '%s\n' "$block_text" | grep -qE "$BANNED_RE"; then
        hit=$(printf '%s\n' "$block_text" | grep -oE "$BANNED_RE" | head -1)
        # Judged on the unfolded text so `$hit` keeps its original case in the
        # message; it came from this same string, so the split is exact.
        if ! phrase_is_negated "$block_text" "$hit"; then
          fail "$scan_label — block at line $block_start carries a retired contract phrase ('$hit')"
        fi
      fi
      # Case-folded copy: the conditional test is a bash glob, which cannot be
      # made case-insensitive the way the regexes above are. ASCII-only fold, so
      # Korean bytes (all >= 0x80) pass through untouched; `tr '[:upper:]'
      # '[:lower:]'` is rejected because its multibyte behaviour on macOS is not
      # dependable.
      block_lc=$(printf '%s' "$block_text" | LC_ALL=C tr 'A-Z' 'a-z')
      while IFS= read -r cond_hit; do
        [[ -n "$cond_hit" ]] || continue
        if ! phrase_is_negated "$block_lc" "$cond_hit"; then
          evidence=$(printf '%s\n' "$block_text" \
            | grep -oiE ".{0,40}$cond_hit.{0,40}" | head -1)
          fail "$scan_label — block at line $block_start states '$cond_hit' without negating it: ...$evidence..."
          break
        fi
      done < <(printf '%s\n' "$block_lc" | grep -oE "$CONDITIONAL_RE" | sort -u)
    done < <(blocks_of "$scan_file")

    if ! blocks_of "$scan_file" | grep -qE "$REQUIRED_PHRASE_RE"; then
      fail "$scan_label — required phrase '$REQUIRED_PHRASE' is absent; the termination contract is unnamed"
    fi
  done
  rm -f "$fm_tmp"

  # ---- (B) citation drift ----
  headings_tmp=$(mktemp)
  headings_of "$owner_path" > "$headings_tmp"

  # Warn where the title anchor cannot falsify anything, because two headings
  # share a title. Not fatal: the real SKILL.md has such a pair today (§4.6 and
  # §6.4), which is precisely the transposition the anchor is meant to catch.
  dup_titles=$(cut -f2 "$headings_tmp" | sort | uniq -d)
  if [[ -n "$dup_titles" ]]; then
    while IFS= read -r dup; do
      [[ -n "$dup" ]] || continue
      warn "$owner — two or more headings share the title '$dup'; citations to them cannot be falsified by the title anchor"
    done <<DUPS
$dup_titles
DUPS
  fi

  # Flatten newlines and fold notation variants (rules 1 and 2) before
  # extracting citations.
  citations=$(normalize_citations "$shared_path" \
    | grep -oE 'SKILL\.md[[:space:]]+§[0-9]+(\.[0-9]+)?[^);]*' || true)

  if [[ -n "$citations" ]]; then
    while IFS= read -r citation; do
      [[ -n "$citation" ]] || continue
      checks=$((checks + 1))
      num=$(printf '%s\n' "$citation" | sed -E 's/^SKILL\.md[[:space:]]+§([0-9]+(\.[0-9]+)?).*$/\1/')
      # The anchor runs from the section number to the end of the citation.
      # `)` and `;` already bounded the grep above; a citation that ends at a
      # sentence instead has to be cut at the first `. ` here, otherwise the
      # rest of the paragraph is swallowed into the anchor and never matches.
      anchor=$(printf '%s\n' "$citation" \
        | sed -E 's/^SKILL\.md[[:space:]]+§[0-9]+(\.[0-9]+)?[[:space:]]*//' \
        | sed -E 's/\. .*$//' \
        | sed -E 's/(,|—|`|\|).*$//' \
        | sed -E 's/[[:space:]]*[.,;:]*$//')

      title=$(awk -F'\t' -v n="$num" '$1==n { print $2; exit }' "$headings_tmp")
      if [[ -z "$title" ]]; then
        fail "$shared — citation '§$num' names no heading in $owner"
        continue
      fi
      if (( ${#anchor} < ANCHOR_MIN_LEN )); then
        fail "$shared — citation '§$num' carries no usable title anchor (expected '§$num $title'); an unanchored citation cannot detect a renumbering"
        continue
      fi
      # Rule 3: case-insensitive substring.
      if ! printf '%s\n' "$title" | grep -qiF "$anchor"; then
        fail "$shared — citation '§$num $anchor' does not match $owner heading '§$num $title'"
      fi
    done <<CITATIONS
$citations
CITATIONS
  fi

  rm -f "$headings_tmp"
done <<TABLE
$OWNER_TABLE
TABLE

# Rule 4: a qualifying citation in a shared file with no declared owner. Hoisted
# out of the table loop — nested, it re-reported every unmapped file once per
# row. It uses the SAME recognizer as the citation rule above, or a file with no
# table row could evade the sweep just by writing prose word order.
for other in "$skills_root"/_common/*.md; do
  [[ -f "$other" ]] || continue
  other_rel="_common/$(basename "$other")"
  printf '%s\n' "$OWNER_TABLE" | grep -qF "$other_rel|" && continue
  if normalize_citations "$other" | grep -qE 'SKILL\.md[[:space:]]+§[0-9]'; then
    fail "$other_rel — carries a 'SKILL.md §N' citation but declares no owning SKILL.md; add a row to OWNER_TABLE"
  fi
done

# Violations outrank the empty-collection exit. A declared-but-absent shared file
# is now a violation, and it also leaves `scanned` at zero — reporting that as
# "nothing to scan" would turn the finding into exit 2 and hide it.
if (( violations > 0 )); then
  echo "lint-active-notify-drift: ${violations} violation(s)" >&2
  exit 1
fi

if (( scanned == 0 )); then
  echo "lint-active-notify-drift: no scannable files found" >&2
  exit 2
fi

echo "lint-active-notify-drift: ${checks} check(s) passed across ${scanned} surface pair(s)"
exit 0
