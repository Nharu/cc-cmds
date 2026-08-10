#!/usr/bin/env bash
# Shared region extractor for the region-scoped pin linters.
#
# Prints the lines between the first line matching <start_ere> and the first
# subsequent line matching <end_ere>. The start line is excluded unless the
# fifth argument is `include-start`, which a single-line region needs.
#
# BOTH ANCHORS ARE PINNED. A missing start, or an end that never occurs after
# the start, is a failure rather than a region that silently widens to end of
# file. A widened region still contains every pinned literal, so a check over it
# would keep reporting success while no longer checking anything about position.
#
# Usage:
#   source scripts/_extract-between.sh
#   extract_between <start_ere> <end_ere> <file> <label> [include-start]
#
# CALL CONTRACT — the two halves are separate obligations and a caller owes both.
#
#   (1) Guard the call with an `if`, never with `|| fail=1` and never bare.
#
#         if region=$(extract_between "$start" "$end" "$f" "label"); then :
#         else fail=1
#         fi
#
#       Every caller runs under `set -euo pipefail`, where a bare
#       `region=$(extract_between …)` that returns non-zero aborts the script at
#       that assignment and throws away every diagnostic after it — measured,
#       not argued: one unguarded call site cut a five-line report to one line.
#       The `if` form is immune to that omission class by syntax, because an
#       `if` cannot be written with its guard left out.
#
#       This function does NOT set the caller's `fail` variable, and must not be
#       changed to. Every call site is a command substitution, so an assignment
#       made here happens in a subshell and never reaches the parent — the
#       status is the only channel that crosses that boundary.
#
#   (2) Run the downstream assertions in BOTH branches. Skipping them when the
#       region is unavailable is short-circuiting, and those assertions are what
#       currently re-establishes `fail=1` in the parent shell. Removing them
#       leaves a linter that prints `FAIL:` lines and exits 0.
#
# This body replaced two same-named copies that had drifted into different
# semantics (one included its heading and kept scanning, the other did neither),
# and were then re-synchronized by hand under a comment claiming they were
# byte-identical — which they were not, by three lines and two prefixes. One
# definition removes the claim along with the thing it was claiming about.

# Sentinel a caller assigns to its region variable on the failure path:
#
#   if region=$(extract_between …); then :
#   else fail=1; region="$REGION_UNAVAILABLE"
#   fi
#
# The downstream assertions still run — see call contract (2) — but a caller that
# left the region as the empty string made every one of them report "literal
# missing", naming innocent literals that are sitting in the file untouched. The
# reader then goes looking for a deletion that never happened while the real
# defect, one broken anchor, scrolls past in the first line. The sentinel lets
# those assertions say what is actually true: the region could not be read, so
# the pin was not evaluated. The diagnostic COUNT is unchanged — one line per
# pin either way — which is what keeps each pin's fixture attribution intact.
# The control bytes make the value unforgeable by any real region content.
REGION_UNAVAILABLE=$'\001cc-region-unavailable\001'

extract_between() {
  local start_ere="$1" end_ere="$2" file="$3" label="$4" mode="${5:-exclude-start}"
  if [[ ! -f "$file" ]]; then
    echo "FAIL: $label — file not found: $file" >&2
    return 1
  fi
  if ! grep -Eq -- "$start_ere" "$file"; then
    echo "FAIL: $label — region start anchor missing: /$start_ere/" >&2
    return 1
  fi
  # The regexes travel through the environment, not through `awk -v`: `-v`
  # processes escape sequences in the value, so a `\(` in the pattern would
  # reach awk as a bare `(` and open an unterminated group.
  if ! EB_START="$start_ere" EB_END="$end_ere" awk '
        BEGIN { s = ENVIRON["EB_START"]; e = ENVIRON["EB_END"] }
        !started && $0 ~ s { started = 1; next }
        started && $0 ~ e  { found = 1; exit }
        END { exit(found ? 0 : 1) }
      ' "$file"; then
    echo "FAIL: $label — region terminator literal missing after the start anchor: /$end_ere/" >&2
    return 1
  fi
  EB_START="$start_ere" EB_END="$end_ere" EB_MODE="$mode" awk '
    BEGIN { s = ENVIRON["EB_START"]; e = ENVIRON["EB_END"]
            inc = (ENVIRON["EB_MODE"] == "include-start") }
    started && $0 ~ e { exit }
    !started && $0 ~ s { started = 1; if (inc) print; next }
    started { print }
  ' "$file"
}
