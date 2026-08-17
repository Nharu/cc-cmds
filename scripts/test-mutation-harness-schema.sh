#!/usr/bin/env bash
# Test the shared mutation-harness helpers in tests/mutation-harness/schema-check.sh.
#
# These helpers have no fixture corpus of their own — they are the thing every
# corpus depends on — so the assertions here build their inputs in a temp tree.
#
# The locale case is the reason this file exists. `mutation_fixture_set_hash`
# sorted without pinning the collation, so the same tree hashed to two different
# values depending on the caller's locale, and the pre-measurement check reported
# a fixture-set change that had not happened. Three of the four corpora agreed
# across locales anyway because their names collate the same either way; only one
# disagreed, and it disagreed only on CI. An instrument that is right by
# coincidence on most of its inputs is indistinguishable from a correct one, so
# the assertion below is written against a path set that is KNOWN to collate
# differently rather than against any real corpus. The pair that reproduces it is
# `…/active-notify/SKILL.md` against `…/active-notify/scripts/notify.sh`, and the
# axis is CASE — not punctuation, which was the first guess and was wrong. The
# fixture tree below is shaped like the real ones for that reason: the difference
# does not reproduce on short names.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

# shellcheck source=../tests/mutation-harness/schema-check.sh
. "$repo_root/tests/mutation-harness/schema-check.sh"

passed=0
failures=0

ok()   { passed=$((passed + 1)); echo "PASS: $1"; }
bad()  { failures=$((failures + 1)); echo "FAIL: $1" >&2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# PLUGIN_ROOT-shaped fixtures, because that shape is what carries the collating
# pair: a file and a subdirectory that differ only in the case of their first
# letter, under a long shared prefix.
fx="$work/fixtures"
mkdir -p "$fx"
for n in "T-X-ERR-2" "T-X-FAIL-1" "T-X-OK-2"; do
  base="$fx/$n/plugins/cc-cmds/skills"
  mkdir -p "$base/active-notify/scripts" "$base/_common"
  printf 'skill doc for %s\n' "$n" > "$base/active-notify/SKILL.md"
  printf 'dispatcher for %s\n' "$n" > "$base/active-notify/scripts/notify.sh"
  printf 'shared doc for %s\n' "$n" > "$base/_common/notify.md"
done

# 1 — the hash does not depend on the caller's locale.
h_c=$(LC_ALL=C mutation_fixture_set_hash "$fx" "T-X")
h_u=$(LC_ALL=en_US.UTF-8 mutation_fixture_set_hash "$fx" "T-X")
if [[ "$h_c" == "$h_u" ]]; then
  ok "fixture-set hash is locale-independent"
else
  bad "fixture-set hash differs by locale (C=$h_c en_US.UTF-8=$h_u)"
fi

# 2 — and the ordering it pins is genuinely locale-sensitive, so assertion 1 is
# testing something. Without this, a tree that collates identically in both
# locales would let assertion 1 pass against an unpinned implementation — which
# is exactly how the defect survived: three of four corpora were that tree.
paths=$(find "$fx" -type f)
o_c=$(printf '%s\n' "$paths" | LC_ALL=C sort)
o_u=$(printf '%s\n' "$paths" | LC_ALL=en_US.UTF-8 sort)
if [[ "$o_c" != "$o_u" ]]; then
  ok "the tree used above really does collate differently in the two locales"
else
  bad "the tree collates identically — assertion 1 cannot fail and proves nothing"
fi

# 3 — content, not just names. A fixture edited without being renamed must move
# the hash; a name-list hash would not see it, and that case was measured on a
# real corpus (names byte-identical, suite still green, one row's vector
# collapsed to the empty set).
before=$(mutation_fixture_set_hash "$fx" "T-X")
printf 'edited\n' >> "$fx/T-X-OK-2/plugins/cc-cmds/skills/_common/notify.md"
after=$(mutation_fixture_set_hash "$fx" "T-X")
if [[ "$before" != "$after" ]]; then
  ok "editing a fixture's content moves the hash"
else
  bad "content edit did not move the hash — a name-list hash would not see it"
fi

# 4 — the prefix filter excludes non-fixture siblings.
mkdir -p "$fx/NOT-A-FIXTURE"
printf 'x\n' > "$fx/NOT-A-FIXTURE/f"
if [[ "$(mutation_fixture_set_hash "$fx" "T-X")" == "$after" ]]; then
  ok "a directory outside the prefix does not enter the hash"
else
  bad "a non-fixture sibling changed the hash"
fi

# 5 — degenerate rows are recognized by the out-of-band file, not by an empty
# expected-red, so that "declares nothing" and "file is empty" stay different.
row="$work/row"
mkdir -p "$row"
printf 'a\n' > "$row/anchor"; printf 'b\n' > "$row/replacement"
printf 'd\n' > "$row/description"; printf 'fx-1\n' > "$row/expected-red"
if ! mutation_row_is_degenerate "$row"; then
  ok "a row with a vector is not degenerate"
else
  bad "a row with a vector was read as degenerate"
fi
rm "$row/expected-red"; printf 'measured: nothing reddens\n' > "$row/reddens-nothing"
if mutation_row_is_degenerate "$row" && mutation_row_schema_check "$row" 2>/dev/null; then
  ok "a row with only reddens-nothing is degenerate and passes the schema"
else
  bad "a well-formed degenerate row was rejected"
fi

# 6 — all three malformed shapes are configuration errors (exit 2), not pin
# failures (exit 1). A pin failure says "the code changed"; these say "the row
# is not a row", and collapsing them teaches the reader to look at the wrong file.
set +e
printf 'fx-1\n' > "$row/expected-red"           # both present
mutation_row_schema_check "$row" >/dev/null 2>&1; rc_both=$?
rm "$row/expected-red" "$row/reddens-nothing"   # neither present
mutation_row_schema_check "$row" >/dev/null 2>&1; rc_neither=$?
: > "$row/reddens-nothing"                      # present but empty
mutation_row_schema_check "$row" >/dev/null 2>&1; rc_empty=$?
set -e
if [[ "$rc_both" == 2 && "$rc_neither" == 2 && "$rc_empty" == 2 ]]; then
  ok "all three malformed row shapes exit 2 (configuration error)"
else
  bad "malformed row shapes gave rc both=$rc_both neither=$rc_neither empty=$rc_empty, wanted 2/2/2"
fi

echo "test-mutation-harness-schema: $passed passed, $failures failed"
(( failures > 0 )) && exit 1
exit 0
