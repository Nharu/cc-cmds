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
#
# Usage:
#   bash scripts/lint-active-notify-drift.sh          # lint the real surfaces
#
# Env override:
#   SKILLS_ROOT=<dir> bash scripts/lint-active-notify-drift.sh   # fixture tests
#
# Exit codes:
#   0 — all checks passed
#   1 — at least one violation found
#   2 — no scannable files found

set -euo pipefail

# Shared-file → owning-SKILL.md table (rule 4). One `<shared>|<owner>` pair per
# line, both paths relative to the skills root. Add a row when a shared file
# starts citing a SKILL.md section; an unmapped citation fails the lint.
OWNER_TABLE='_common/notify.md|active-notify/SKILL.md'

# Rule (A) banned phrases. `turn-end auto-fire` is handled separately because it
# is legitimate inside a negation (rule 5).
BANNED_RE='매 turn|per-turn'
CONDITIONAL_RE='turn-end auto-fire'
# A line stating the phrase negatively. Covers the English and Korean forms the
# surfaces actually use.
NEGATION_RE='([Nn]o|[Nn]ot|[Nn]ever|없|않)'
# Rule (A) required phrase — the termination contract that replaced the retired
# one must be named on each scanned surface.
REQUIRED_PHRASE='self-cancel'

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"

violations=0
checks=0

fail() {
  echo "FAIL: $*" >&2
  violations=$((violations + 1))
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
    echo "lint-active-notify-drift: shared file not found: $shared_path" >&2
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
    line_no=0
    while IFS= read -r line; do
      line_no=$((line_no + 1))
      if printf '%s\n' "$line" | grep -qE "$BANNED_RE"; then
        fail "$scan_label — line $line_no carries a retired contract phrase: $line"
      fi
      if printf '%s\n' "$line" | grep -qE "$CONDITIONAL_RE" \
         && ! printf '%s\n' "$line" | grep -qE "$NEGATION_RE"; then
        fail "$scan_label — line $line_no states 'turn-end auto-fire' without negating it: $line"
      fi
    done < "$scan_file"

    if ! grep -qF "$REQUIRED_PHRASE" "$scan_file"; then
      fail "$scan_label — required phrase '$REQUIRED_PHRASE' is absent; the termination contract is unnamed"
    fi
  done
  rm -f "$fm_tmp"

  # ---- (B) citation drift ----
  headings_tmp=$(mktemp)
  headings_of "$owner_path" > "$headings_tmp"

  # Flatten newlines (rule 1) before extracting citations.
  citations=$(tr '\n' ' ' < "$shared_path" \
    | tr -s ' ' \
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
        | sed -E 's/[[:space:]]*[.,;:]*$//')

      title=$(awk -F'\t' -v n="$num" '$1==n { print $2; exit }' "$headings_tmp")
      if [[ -z "$title" ]]; then
        fail "$shared — citation '§$num' names no heading in $owner"
        continue
      fi
      if [[ -z "$anchor" ]]; then
        fail "$shared — citation '§$num' carries no title anchor (expected '§$num $title'); an unanchored citation cannot detect a renumbering"
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

  # Rule 4: a qualifying citation in a shared file with no declared owner.
  for other in "$skills_root"/_common/*.md; do
    [[ -f "$other" ]] || continue
    other_rel="_common/$(basename "$other")"
    printf '%s\n' "$OWNER_TABLE" | grep -qF "$other_rel|" && continue
    if tr '\n' ' ' < "$other" | tr -s ' ' | grep -qE 'SKILL\.md[[:space:]]+§[0-9]'; then
      fail "$other_rel — carries a 'SKILL.md §N' citation but declares no owning SKILL.md; add a row to OWNER_TABLE"
    fi
  done

  rm -f "$headings_tmp"
done <<TABLE
$OWNER_TABLE
TABLE

if (( scanned == 0 )); then
  echo "lint-active-notify-drift: no scannable files found" >&2
  exit 2
fi

if (( violations == 0 )); then
  echo "lint-active-notify-drift: ${checks} check(s) passed across ${scanned} surface pair(s)"
  exit 0
fi

echo "lint-active-notify-drift: ${violations} violation(s)" >&2
exit 1
