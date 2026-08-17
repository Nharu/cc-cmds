#!/usr/bin/env bash
# Schema check for a mutation-corpus row directory. Corpus-invariant, so it
# lives here rather than in either corpus's fixture tree, and both harnesses
# call it instead of each carrying its own copy.
#
# The clauses this serves, the reading rules, and what is deliberately not
# caught are in README.md beside this file. Do not restate them here — a second
# copy is how the three-document divergence this harness family already suffered
# gets made again.
#
# Usage:  mutation_row_schema_check <row-dir>
#   Exit 0 — the row is well formed.
#   Exit 2 — schema violation (a CONFIGURATION error, deliberately distinct from
#            a pin failure; a caller that collapses it to 1 loses the ability to
#            tell "this corpus is malformed" from "this mutation escaped").
#
# Sourced, not executed: callers `source` this file and call the function.

# Parse a row's declared vector: one fixture name per line, comments and blanks
# stripped. EVERY reader of that file goes through this — a second reader with
# its own line rule is not a style problem, it is a silent disagreement. The
# measured instance: a sole-kill counter that counted raw non-blank lines while
# the comparator stripped `#` comments, so one documented comment line in a row
# dropped that row out of the published coverage figure while both the row and
# the run still passed.
mutation_row_declared_vector() {
  grep -v '^#' "$1/expected-red" 2>/dev/null | grep -v '^$' || true
}

# Content hash of a fixture set: names AND bytes, order-stable. Names alone are
# not enough — editing a fixture's CONTENT leaves a name-list hash unchanged
# while a row's vector collapses, and that case is measured, not hypothetical.
mutation_fixture_set_hash() {
  local root="$1" prefix="${2:-}"
  # LC_ALL=C on every sort in this function, and the reason is not style. `sort`
  # collates by locale: C compares bytes, so `SKILL.md` precedes `scripts/…`
  # because `S` is 0x53 and `s` is 0x73, while a UTF-8 locale folds case and
  # orders them the other way. Fixture trees hold both, so the same tree hashes
  # to two values depending on who runs it, and the check then reports a
  # fixture-set change that did not happen.
  #
  # This was found by CI on the first run of the job that calls these harnesses,
  # and the shape of the near-miss is worth keeping: three of the four corpora
  # agreed across locales anyway, because their names happen to collate the same
  # either way. An instrument that agrees by coincidence on most of its inputs
  # reads exactly like one that is correct.
  LC_ALL=C
  find "$root" -mindepth 1 -maxdepth 1 -type d -name "${prefix}*" -exec basename {} \; \
    | LC_ALL=C sort \
    | while IFS= read -r d; do
        printf '%s\n' "$d"
        find "$root/$d" -type f | LC_ALL=C sort | while IFS= read -r f; do
          printf '%s  ' "${f#"$root/"}"; shasum -a 256 "$f" | cut -d' ' -f1
        done
      done \
    | shasum -a 256 | cut -d' ' -f1
}

# Compare the corpus's recorded pre-measurement block against the tree. The
# recorded value is a CONTENT hash rather than a revision on purpose: the
# documented trigger for re-running this harness is "the target changed", which
# means a dirty tree, and a revision check passes in exactly that case — it
# would certify the table precisely when the table is invalid.
mutation_pre_measurement_check() {   # $1 = manifest dir, $2 = fixture root, $3 = prefix
  local manifest="$1" fixture_root="$2" prefix="${3:-}" block declared observed
  block="$manifest/PRE-MEASUREMENT"

  if [[ ! -f "$block" ]]; then
    echo "SCHEMA: $(basename "$manifest") — PRE-MEASUREMENT block is missing" >&2
    return 2
  fi

  declared=$(sed -n 's/^fixture-set-content-sha256: *//p' "$block" | head -1)
  if [[ -z "$declared" ]]; then
    echo "SCHEMA: PRE-MEASUREMENT declares no fixture-set-content-sha256" >&2
    return 2
  fi

  observed=$(mutation_fixture_set_hash "$fixture_root" "$prefix")
  if [[ "$declared" != "$observed" ]]; then
    {
      echo "SCHEMA: the fixture set changed since the vectors were recorded — stopping before the first row."
      echo "  declared: $declared"
      echo "  observed: $observed"
      echo "  Every declared vector was derived against the recorded set. Re-derive them"
      echo "  against the current set and update the block; do not edit vectors to match."
    } >&2
    return 2
  fi
  return 0
}

# True when the row declares that it reddens NOTHING. The declaration is
# out-of-band — a separate FILE, not a value inside the vector file — because an
# in-band sentinel would put a new value in the same namespace as fixture names:
# every reader would have to special-case it, and a reader that forgot would read
# it AS a fixture name. That is a live defect in this tree, reproduced on purpose.
#
# Out-of-band, the two claims are not expressible in one file: no string a typo
# can produce inside a vector file means "reddens nothing".
mutation_row_is_degenerate() { [[ -f "$1/reddens-nothing" ]]; }

mutation_row_schema_check() {
  local dir="$1" id
  id=$(basename "$dir")

  local f
  for f in anchor replacement; do
    if [[ ! -f "$dir/$f" ]]; then
      echo "SCHEMA: $id — required file '$f' is missing" >&2
      return 2
    fi
  done

  # Three-phase: exactly one of the two declaration files must be present.
  #
  # All three failure branches exit 2 — a CONFIGURATION error, not a pin failure.
  # This is a BEHAVIOUR CHANGE, not preservation: the path it replaces counted a
  # row with a missing or empty declaration as a failing row and ended at 1. That
  # collapse is what a later job must not inherit, because 2 is what separates
  # "this corpus is malformed" from "a mutation escaped".
  local has_red=0 has_none=0
  [[ -f "$dir/expected-red"    ]] && has_red=1
  [[ -f "$dir/reddens-nothing" ]] && has_none=1

  if (( has_red == 1 && has_none == 1 )); then
    echo "SCHEMA: $id — declares both an expected-red set and reddens-nothing; a row cannot claim both" >&2
    return 2
  fi
  if (( has_red == 0 && has_none == 0 )); then
    echo "SCHEMA: $id — declares neither an expected-red set nor reddens-nothing" >&2
    return 2
  fi

  if (( has_none == 1 )); then
    # A degenerate row stays FALSIFIABLE: it is still applied and run, and its
    # observed red set must come back empty. The file must carry the measurement
    # and the reasoning — an empty one collapses "declares nothing" back into
    # "declares that it reddens nothing", which is the very distinction this
    # policy exists to create.
    if [[ ! -s "$dir/reddens-nothing" ]]; then
      echo "SCHEMA: $id — 'reddens-nothing' is empty; it must carry the measurement and the reason" >&2
      return 2
    fi
    return 0
  fi

  # `expected-red` carries the declared per-fixture vector. Comment lines are a
  # documented feature of the format, so anything that reads this file must
  # strip them with the same rule the vector parser uses — a reader that counts
  # raw lines instead reports a different number than the parser and the
  # disagreement is silent.
  local declared
  declared=$(mutation_row_declared_vector "$dir")
  if [[ -z "$declared" ]]; then
    echo "SCHEMA: $id — 'expected-red' declares nothing; a row that pins no fixture is not a pin" >&2
    return 2
  fi

  return 0
}
