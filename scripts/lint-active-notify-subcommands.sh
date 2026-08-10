#!/usr/bin/env bash
# Lint every surface that enumerates active-notify's dispatcher subcommands
# against the dispatcher itself.
#
# THE SOURCE OF TRUTH IS THE RUNNING CODE — the `case "$subcommand" in` block in
# notify.sh. Deriving the reference list from a document instead would make this
# a document-to-document comparison, which cannot see the drift the check exists
# for: a subcommand the dispatcher accepts but no document enumerates. That is
# also the direction that bites. When a name is missing from the hook's regex the
# call stops being auto-approved and drops to a permission dialog that an absent
# user cannot answer, so the banner never arrives and nothing reports why.
#
# Rules:
#   1. Coverage        — every dispatcher subcommand is named at least once on
#                        every scanned surface.
#   2. Alternation     — any `(a|b|c)` / `{a|b|c}` group that mentions at least
#                        one subcommand must equal the dispatcher set, IN
#                        DISPATCHER ORDER.
#   3. Cardinality     — an `N subcommand(s)` claim must equal the dispatcher
#                        count, whether N is a digit or an English number word.
#
# Rule 1 is satisfied by body text. It is NOT an instruction to add names to the
# SKILL.md frontmatter: that surface is always loaded into the model's context
# and is governed by a separate description-budget lint, so growing it to satisfy
# this check trades a documentation gap for a context-budget one. The L0 barrier
# is stated here because the natural response to a rule-1 violation is to edit
# the nearest editable place, and on that file the nearest place is the wrong one.
#
# Surfaces deliberately NOT scanned, each for a stated reason: the SKILL.md
# frontmatter (above); README.md (no enumeration, and it sits in no load state);
# hooks.json (matcher is "Bash", nothing to enumerate); Makefile (none); frozen
# CHANGELOG sections (a released section is the accurate record of that release —
# syncing an old list forward would document a contract that never existed);
# docs/ and tests/ (frozen artifacts, and drivers that discover fixtures by
# directory, so there is no list to drift).
#
# A FOURTH RULE WAS BUILT, MEASURED AND REJECTED — "prose cluster completeness",
# i.e. a run of two or more distinct subcommand names within N characters must
# name all of them. On the current tree it produced ten findings, all false
# positives: ordinary sentences that mention two subcommands (`fire-now 후 사용자
# CANCEL`, `cancel fire-now`, …). The list signal is not separable from mere
# co-occurrence at any gap value that could be justified. Consequence, stated as
# a limitation rather than hidden: the two comma-list sites in `_common/notify.md`
# are protected by rule 1 against a name vanishing from the file, but not against
# a name that is present elsewhere in the file and missing from that one list.
#
# CLOSURE CLAIMS ("X is the only dispatch surface") ARE ALSO OUT, and that
# rejection is measured too — it is recorded here so the two rejections carry
# equal weight, because a maintainer who finds one reasoned rejection and one
# bare assertion will re-propose the bare one. In the body the exception clause
# of such a claim sits outside a 400-character window (windows of 100, 240 and
# 400 all score 2/1; only 600 reaches 2/2, and at that width the window spans
# three paragraphs). In the shared document the trigger phrase carries markdown
# emphasis inside it (`the **only** dispatch surface`), so the match count is
# zero. Their disposition belongs to an issue, not to a rule here.
#
# Usage:
#   bash scripts/lint-active-notify-subcommands.sh
#
# Env override:
#   PLUGIN_ROOT=<dir> bash scripts/lint-active-notify-subcommands.sh   # fixtures
#
# The eight checks are not two per surface. Measured per surface: rule 1 runs
# once per file (4), rule 2 fires on `notify.sh` twice and on the hook once (3),
# rule 3 fires on `SKILL.md` once (1). `_common/notify.md` contributes zero
# enumeration sites and is protected by rule 1 alone. One of the eight cannot
# fail — `notify.sh`'s own rule-1 check, since the file is both a scanned surface
# and the source the names come from. The tidy-up that would make the count
# honest is to drop `notify.sh` from the allowlist, and it is refused here: that
# would take its two real rule-2 checks with it.
#
# Exit codes:
#   0 — all checks passed
#   1 — at least one violation found
#   2 — the dispatcher or a declared surface was not found, or the case block
#       stopped being readable. The second half is decided by SHAPE, not by the
#       extracted set being empty — see the guard below for why emptiness is the
#       wrong test.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
plugin_root="${PLUGIN_ROOT:-$repo_root/plugins/cc-cmds}"

dispatcher_path="$plugin_root/skills/active-notify/scripts/notify.sh"

# Scanned surfaces, relative to the plugin root. Enumeration SITES outnumber
# these — one file can carry several — but a site cannot be named in config
# without a line number, and line numbers are exactly what this repo's anchor
# discipline forbids. So the allowlist is files; the sites are found by content.
SCAN_TARGETS='skills/active-notify/scripts/notify.sh
skills/active-notify/SKILL.md
skills/_common/notify.md
hooks/active-notify-pretool.sh'

violations=0
checks=0

fail() {
  echo "FAIL: $*" >&2
  violations=$((violations + 1))
}

if [[ ! -f "$dispatcher_path" ]]; then
  echo "lint-active-notify-subcommands: dispatcher not found: $dispatcher_path" >&2
  exit 2
fi

# --- SOT extraction -----------------------------------------------------
# The `*)` catch-all is excluded by the `[a-z]` anchor: it is the unknown-input
# branch, not a subcommand.
subcommands=$(awk '
  /^case "\$subcommand" in$/ { inblock = 1; next }
  inblock && /^esac$/        { closed = 1; exit }
  inblock && /^  [a-z][a-z-]*\)$/ {
    line = $0
    sub(/^  /, "", line); sub(/\)$/, "", line)
    print line
    next
  }
  inblock && /^[[:space:]]*[a-z][a-z0-9|_-]*\)/ { print "@@UNRECOGNIZED-ARM " $0 }
  END { if (inblock && !closed) print "@@UNTERMINATED" }
' "$dispatcher_path")

if [[ -z "$subcommands" ]]; then
  echo "lint-active-notify-subcommands: the case block shape changed — no subcommands read from $dispatcher_path" >&2
  exit 2
fi

# The empty set is not the shape check. A `case` block whose arms the strict
# reader above does not recognize — a new arm at four-space indent, a
# multi-pattern arm, an `esac` the reader never reaches — still yields a
# non-empty list, so an emptiness test reports success while having seen part of
# its input. Worse, a multi-pattern arm produces a list the RULES then act on,
# and the resulting message blames the surfaces: following it literally deletes
# a live subcommand from the hook's regex.
if printf '%s\n' "$subcommands" | grep -q '^@@'; then
  printf '%s\n' "$subcommands" | grep '^@@' >&2
  echo "lint-active-notify-subcommands: the case block shape changed — read only part of it in $dispatcher_path" >&2
  exit 2
fi

sot_ordered=$(printf '%s' "$subcommands" | tr '\n' ' ' | sed -E 's/ +$//')
sot_count=$(printf '%s\n' "$subcommands" | wc -l | tr -d ' ')
echo "lint-active-notify-subcommands: dispatcher declares ${sot_count} subcommand(s): ${sot_ordered}"

# Longest-first so `fire-now` cannot shadow `fire-oneshot`.
token_re=$(printf '%s\n' "$subcommands" | awk '{ print length, $0 }' | sort -rn -k1 \
  | cut -d' ' -f2- | tr '\n' '|' | sed -E 's/\|$//')

# --- scan ---------------------------------------------------------------
while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  target="$plugin_root/$rel"
  if [[ ! -f "$target" ]]; then
    echo "lint-active-notify-subcommands: declared surface not found: $target" >&2
    exit 2
  fi

  # Rule 1 — coverage. Case-insensitive: an all-uppercase spelling names the
  # lifecycle phase rather than the subcommand, and several sites legitimately
  # write `ARM / FIRE-NOW / CANCEL` while omitting `fire-oneshot`, which belongs
  # to no ARM cycle. Those are not enumerations of the dispatcher and must not
  # be flagged; requiring the lowercase form somewhere in the file is what keeps
  # rule 1 off them.
  #
  # The name must appear as a WHOLE WORD. A substring test judges a surface to
  # cover `arm` on the strength of the word `alarm` and `cancel` on the strength
  # of `cancellation`, which is not a hypothetical: the shared document carries
  # no enumeration site at all, so rule 1 is the whole of its protection. The
  # boundary is written as `[^a-z-]` rather than `\b` for two independent
  # reasons — `\b` is not portable between BSD and GNU grep, and `\b` treats the
  # hyphen as a boundary, which would let `fire-now` be satisfied from inside
  # `fire-oneshot`. The class excludes digits from the boundary, so `arm2` would
  # count; no such spelling exists and the widening is accepted knowingly.
  checks=$((checks + 1))
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if ! grep -qiE -- "(^|[^a-z-])${name}([^a-z-]|\$)" "$target"; then
      fail "$rel — subcommand '$name' is never named; the dispatcher declares it"
    fi
  done <<NAMES
$subcommands
NAMES

  # Rule 2 — alternation exactness. The extractor is deliberately non-greedy and
  # character-restricted. The hook's path class contains literal parentheses, so
  # a looser extractor (`\((.*)\)` above all) captures a span that happens to
  # contain the subcommand names, compares it to the dispatcher set and fails
  # forever — and the obvious way to "fix" that is to loosen the hook regex,
  # which is the exact opposite of what the security fix in this release did.
  #
  # So the extractor stays strict and the INPUT is normalized instead, on a
  # scratch stream that is never written back: backticks and asterisks are
  # stripped because this repo writes alternations as `` (`cancel`|`arm`) `` by
  # convention, and spaces around `|` are closed up because `(cancel | arm)` is
  # the same claim. `_` is deliberately NOT stripped — it is an emphasis marker
  # but also appears mid-identifier throughout the scanned shell files, and
  # stripping it manufactures tokens that never existed. Cost worth knowing: a
  # finding below prints the NORMALIZED group, so a reader debugging one is
  # looking at a string that does not appear verbatim in the file.
  while IFS= read -r group; do
    [[ -n "$group" ]] || continue
    inner="${group:1:${#group}-2}"
    printf '%s\n' "$inner" | tr '|' '\n' | grep -qxE "$token_re" || continue
    checks=$((checks + 1))
    if [[ "$(printf '%s' "$inner" | tr '|' ' ')" != "$sot_ordered" ]]; then
      fail "$rel — alternation '$group' does not equal the dispatcher set '($(printf '%s' "$sot_ordered" | tr ' ' '|'))'"
    fi
  done < <(sed -e 's/[`*]//g' -e 's/[[:space:]]*|[[:space:]]*/|/g' "$target" \
             | grep -oE '[({][a-z][a-z|-]*[)}]' | sort -u)

  # Rule 3 — cardinality.
  while IFS= read -r claim; do
    [[ -n "$claim" ]] || continue
    checks=$((checks + 1))
    word=$(printf '%s' "$claim" | awk '{print tolower($1)}')
    case "$word" in
      one) n=1 ;; two) n=2 ;; three) n=3 ;; four) n=4 ;; five) n=5 ;;
      six) n=6 ;; seven) n=7 ;; eight) n=8 ;; nine) n=9 ;; ten) n=10 ;;
      *) n="$word" ;;
    esac
    if [[ "$n" != "$sot_count" ]]; then
      fail "$rel — '$claim' claims $n but the dispatcher declares $sot_count"
    fi
  done < <(grep -oiE '(one|two|three|four|five|six|seven|eight|nine|ten|[0-9]+) subcommands?' "$target" | sort -u)
done <<TARGETS
$SCAN_TARGETS
TARGETS

if (( violations > 0 )); then
  echo "lint-active-notify-subcommands: ${violations} violation(s)" >&2
  exit 1
fi

echo "lint-active-notify-subcommands: ${checks} check(s) passed"
exit 0
