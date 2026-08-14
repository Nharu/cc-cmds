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
  declared=$(grep -v '^#' "$dir/expected-red" | grep -v '^$' || true)
  if [[ -z "$declared" ]]; then
    echo "SCHEMA: $id — 'expected-red' declares nothing; a row that pins no fixture is not a pin" >&2
    return 2
  fi

  return 0
}
