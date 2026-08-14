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
  find "$root" -mindepth 1 -maxdepth 1 -type d -name "${prefix}*" -exec basename {} \; \
    | sort \
    | while IFS= read -r d; do
        printf '%s\n' "$d"
        find "$root/$d" -type f | sort | while IFS= read -r f; do
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

  # `expected-red` carries the declared per-fixture vector. Comment lines are a
  # documented feature of the format, so anything that reads this file must
  # strip them with the same rule the vector parser uses — a reader that counts
  # raw lines instead reports a different number than the parser and the
  # disagreement is silent.
  if [[ ! -f "$dir/expected-red" ]]; then
    echo "SCHEMA: $id — required file 'expected-red' is missing" >&2
    return 2
  fi

  local declared
  declared=$(mutation_row_declared_vector "$dir")
  if [[ -z "$declared" ]]; then
    echo "SCHEMA: $id — 'expected-red' declares nothing; a row that pins no fixture is not a pin" >&2
    return 2
  fi

  return 0
}
