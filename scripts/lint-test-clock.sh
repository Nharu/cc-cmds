#!/usr/bin/env bash
# Lint test scripts for assertions that lean on how fast the suite runs.
#
# An assertion that pins a wall-clock reading a few seconds inside a window, or
# that a step finished within N seconds, passes on a quick machine and fails on
# a slow CI runner — the suite did nothing wrong, the runner was busy. The rule
# for new code is: inject the time, read the clock at the very call that judges
# it, or keep the value well clear of the boundary; never lengthen a deadline to
# make room. This lint finds the two shapes that break it.
#
# Anchors. A variable is an anchor when the same file assigns it from the wall
# clock: `name=$(date +%s)`, `name=$(date -u +%s)`, `name=$EPOCHSECONDS` (a
# `local` or `export` in front is fine), or `printf -v name '%(%s)T'`.
#
# Rules.
#   clock-margin   inside `$(( ))`, an anchor together with an integer constant
#                  from 1 to 59 that is added or subtracted (not an operand of
#                  `*`, `/` or `%`) — `$((w_now - w_stall + 5))`. A margin of
#                  60 or more is not flagged.
#   elapsed-bound  an upper bound on the difference of two anchors —
#                  `[ $((t1 - t0)) -le 1 ]`, or `<` / `<=` inside arithmetic.
#
# Comment-only lines are not checked.
#
# Escape. `# lint-test-clock: disable=<rule> <reason>` at the end of the line,
# or on the comment-only line right above it, suppresses <rule> there. It is
# meant for places with no race against the clock, such as a fixture that
# injects the time. A disable with no reason suppresses nothing and is itself a
# failure (`disable-no-reason`).
#
# Baseline. scripts/lint-test-clock.baseline holds the hits that were already in
# the tree, one per line as `<path>|<rule>|<line text, trimmed>`; a text that
# occurs on several lines is listed that many times. No line number is part of
# the key, so editing other lines does not age it. A hit beyond the baseline
# fails, and so does a baseline entry that no longer hits: the baseline only
# shrinks, and fixing an old hit means deleting its entry. `--write-baseline`
# rewrites the file from the current hits.
#
# Usage:
#   bash scripts/lint-test-clock.sh                    # lint the test scripts
#   bash scripts/lint-test-clock.sh --write-baseline   # regenerate the baseline
#
# Env override:
#   SCAN_ROOT=<dir>   scan *.sh in <dir>; keys are relative to <dir>
#   BASELINE=<file>   baseline to compare with or write (a missing file is empty)
#
# Exit codes:
#   0 — no hit outside the baseline, no stale entry, no reasonless disable
#   1 — at least one violation
#   2 — the scan could not be carried out (bad argument, no file to scan, an
#       unreadable baseline, or the matcher failing)
#
# Matching runs under LC_ALL=C on both hosts so the byte-wise view of a line,
# and the sort order of a written baseline, do not move with the locale.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

write_baseline=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --write-baseline) write_baseline=1; shift ;;
    *) echo "lint-test-clock: unknown argument: $1" >&2; exit 2 ;;
  esac
done

baseline=${BASELINE:-$repo_root/scripts/lint-test-clock.baseline}
if [[ -e "$baseline" && ! -r "$baseline" ]]; then
  echo "lint-test-clock: baseline is not readable: $baseline" >&2
  exit 2
fi

FILES=()
if [[ -n "${SCAN_ROOT:-}" ]]; then
  root=$(cd "$SCAN_ROOT" && pwd)
  while IFS= read -r f; do FILES+=("$f"); done < <(find "$root" -maxdepth 1 -name '*.sh' | LC_ALL=C sort)
else
  root=$repo_root
  while IFS= read -r f; do FILES+=("$f"); done < <(
    {
      find "$repo_root/scripts" -maxdepth 1 -name 'test-*.sh'
      [[ -d "$repo_root/plugins/cc-cmds/orchestrator" ]] \
        && find "$repo_root/plugins/cc-cmds/orchestrator" -maxdepth 1 -name 'test-*.sh'
    } | LC_ALL=C sort
  )
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "lint-test-clock: no scannable files found" >&2
  exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/lint-test-clock.XXXXXX")
trap 'rm -rf "$work"' EXIT
hits="$work/hits"
: > "$hits"

# One awk per file, reading it twice: the first pass collects the anchors, the
# second judges each line against them, so an anchor assigned below its use
# still counts. Output lines:
#   H <TAB> <line no> <TAB> <path>|<rule>|<trimmed line>
#   D <TAB> <line no> <TAB> <path>
# shellcheck disable=SC2016
AWK_PROG='
function strip_comment(s,    i, c, p) {
  # A comment opens at a "#" that starts the line or follows a blank, so
  # ${#arr[@]} and $# stay code.
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "#") {
      p = (i == 1) ? " " : substr(s, i - 1, 1)
      if (p == " " || p == "\t") return substr(s, 1, i - 1)
    }
  }
  return s
}
function tokenize(s,    n, i, c, c2, j, len, depth) {
  n = 0; len = length(s); i = 1
  while (i <= len) {
    c = substr(s, i, 1)
    if (c == " " || c == "\t") { i++; continue }
    if (c == "$") {
      c2 = substr(s, i + 1, 1)
      if (c2 == "{") {
        j = index(substr(s, i + 2), "}")
        if (j == 0) { T[++n] = "?"; break }
        T[++n] = substr(s, i + 2, j - 1)
        i = i + 2 + j
        continue
      }
      if (c2 == "(") {
        depth = 0
        for (j = i + 1; j <= len; j++) {
          c = substr(s, j, 1)
          if (c == "(") depth++
          else if (c == ")") { depth--; if (depth == 0) break }
        }
        T[++n] = "?"; i = j + 1
        continue
      }
      # A positional or special parameter ($2, $#) is no constant.
      if (c2 ~ /[0-9@*#?$!-]/) { T[++n] = "?"; i += 2; continue }
      i++
      continue
    }
    if (c ~ /[A-Za-z_]/) {
      j = i; while (j <= len && substr(s, j, 1) ~ /[A-Za-z0-9_]/) j++
      T[++n] = substr(s, i, j - i); i = j
      continue
    }
    if (c ~ /[0-9]/) {
      j = i; while (j <= len && substr(s, j, 1) ~ /[0-9A-Za-z#_]/) j++
      T[++n] = substr(s, i, j - i); i = j
      continue
    }
    c2 = substr(s, i, 2)
    if (c2 == "<=" || c2 == ">=" || c2 == "<<" || c2 == ">>" || c2 == "==" || c2 == "!=" || c2 == "**" || c2 == "&&" || c2 == "||" || c2 == "++" || c2 == "--" || c2 == "+=" || c2 == "-=") {
      T[++n] = c2; i += 2
      continue
    }
    T[++n] = c; i++
  }
  T[0] = ""; T[n + 1] = ""
  return n
}
function margin_hit(n,    k, has, p, x) {
  has = 0
  for (k = 1; k <= n; k++) if (T[k] in A) { has = 1; break }
  if (!has) return 0
  for (k = 1; k <= n; k++) {
    if (T[k] !~ /^[0-9]+$/ || T[k] + 0 < 1 || T[k] + 0 >= 60) continue
    p = T[k - 1]; x = T[k + 1]
    if (p == "*" || p == "/" || p == "%" || p == "**" || x == "*" || x == "/" || x == "%" || x == "**") continue
    if (p == "+" || p == "-" || x == "+" || x == "-") return 1
  }
  return 0
}
function diff_at(k) {
  return (T[k] in A) && T[k + 1] == "-" && (T[k + 2] in A) && T[k] != T[k + 2]
}
function arith_bound(n,    k, j) {
  for (k = 1; k + 2 <= n; k++) {
    if (!diff_at(k)) continue
    j = k + 3; while (j <= n && T[j] == ")") j++
    if (T[j] == "<" || T[j] == "<=") return 1
    j = k - 1; while (j >= 1 && T[j] == "(") j--
    if (j >= 1 && (T[j] == ">" || T[j] == ">=")) return 1
  }
  return 0
}
function pure_diff(n,    k, m, u1, u2, u3) {
  m = 0
  for (k = 1; k <= n; k++) {
    if (T[k] == "(" || T[k] == ")") continue
    m++
    if (m == 1) u1 = T[k]; else if (m == 2) u2 = T[k]; else if (m == 3) u3 = T[k]
  }
  return m == 3 && (u1 in A) && u2 == "-" && (u3 in A) && u1 != u3
}
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function parse_disable(cmt,    i, rest, rule, reason) {
  i = index(cmt, "lint-test-clock:")
  if (i == 0) return
  rest = substr(cmt, i + length("lint-test-clock:"))
  sub(/^[ \t]*/, "", rest)
  if (substr(rest, 1, 8) != "disable=") return
  rest = substr(rest, 9)
  rule = rest; sub(/[^A-Za-z0-9_-].*$/, "", rule)
  reason = trim(substr(rest, length(rule) + 1))
  if (reason == "") { printf "D\t%d\t%s\n", FNR, path; return }
  DIS[rule] = 1
}
BEGIN {
  DATE_RE = "[A-Za-z_][A-Za-z0-9_]*=\"?(\\$\\(date[ \t]+(-u[ \t]+)?[\"'"'"']?\\+%s[\"'"'"']?\\)|\\$\\{?EPOCHSECONDS\\}?)"
  PRINTF_RE = "printf[ \t]+-v[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+[\"'"'"']?%\\(%s\\)T"
}
FNR == NR {
  if ($0 ~ /^[ \t]*#/) next
  code = index($0, "#") ? strip_comment($0) : $0
  if (index(code, "date") || index(code, "EPOCHSECONDS")) {
    s = code
    while (match(s, DATE_RE)) {
      m = substr(s, RSTART, RLENGTH)
      A[substr(m, 1, index(m, "=") - 1)] = 1
      s = substr(s, RSTART + RLENGTH)
    }
  }
  if (index(code, "printf")) {
    s = code
    while (match(s, PRINTF_RE)) {
      m = substr(s, RSTART, RLENGTH)
      split(m, w, /[ \t]+/)
      A[w[3]] = 1
      s = substr(s, RSTART + RLENGTH)
    }
  }
  next
}
{
  line = $0
  comment_only = (line ~ /^[ \t]*#/)
  if (comment_only) { code = ""; cmt = line }
  else if (index(line, "#")) { code = strip_comment(line); cmt = substr(line, length(code) + 1) }
  else { code = line; cmt = "" }
  for (r in DIS) delete DIS[r]
  if (index(cmt, "lint-test-clock:")) parse_disable(cmt)
  if (comment_only) {
    for (r in PREV) delete PREV[r]
    for (r in DIS) PREV[r] = 1
    prev_no = FNR
    next
  }
  if (prev_no == FNR - 1) for (r in PREV) DIS[r] = 1
  for (r in PREV) delete PREV[r]
  if (!index(code, "((")) next

  margin = 0; bound = 0
  s = code
  while ((i = index(s, "((")) > 0) {
    dollar = (i > 1 && substr(s, i - 1, 1) == "$")
    depth = 0; end = 0
    for (j = i; j <= length(s); j++) {
      c = substr(s, j, 1)
      if (c == "(") depth++
      else if (c == ")") { depth--; if (depth == 0) { end = j; break } }
    }
    if (!end) break
    inner = substr(s, i + 2, end - i - 3)
    n = tokenize(inner)
    if (dollar && margin_hit(n)) margin = 1
    if (arith_bound(n)) bound = 1
    if (dollar && pure_diff(n)) {
      before = substr(s, 1, i - 2); after = substr(s, end + 1)
      if (after ~ /^"?[ \t]+-(lt|le)([ \t]|$)/ || before ~ /-(gt|ge)[ \t]+"?$/) bound = 1
    }
    s = substr(s, end + 1)
  }
  if (margin && !("clock-margin" in DIS)) printf "H\t%d\t%s|clock-margin|%s\n", FNR, path, trim(line)
  if (bound && !("elapsed-bound" in DIS)) printf "H\t%d\t%s|elapsed-bound|%s\n", FNR, path, trim(line)
}
'

scan_failed=0
unreadable=0
for f in "${FILES[@]}"; do
  if [[ ! -r "$f" ]]; then
    echo "FAIL: $f — unreadable" >&2
    unreadable=$((unreadable + 1))
    continue
  fi
  rel=${f#"$root"/}
  if ! LC_ALL=C awk -v path="$rel" "$AWK_PROG" "$f" "$f" >> "$hits"; then
    echo "lint-test-clock: the matcher failed on $rel" >&2
    scan_failed=1
  fi
done
if (( scan_failed )); then
  exit 2
fi

reasonless=$(LC_ALL=C awk -F '\t' '$1 == "D" { print $3 ":" $2 }' "$hits")
verdicts=""

if (( write_baseline )); then
  tmp="$work/baseline"
  {
    echo "# lint-test-clock baseline — wall-clock assertions already in the tree."
    echo "# One hit per line as <path>|<rule>|<trimmed line text>. It only shrinks:"
    echo "# delete an entry when its line is fixed. Regenerate with"
    echo "# bash scripts/lint-test-clock.sh --write-baseline"
    LC_ALL=C awk '/^H\t/ { sub(/^H\t[^\t]*\t/, ""); print }' "$hits" | LC_ALL=C sort
  } > "$tmp"
  mv "$tmp" "$baseline"
  echo "lint-test-clock: wrote $(grep -cv '^#' "$baseline" || true) entr(y/ies) to $baseline"
else
  # Each hit takes one matching baseline entry; what is left on either side is a
  # violation. The baseline is read with getline so a missing file reads as an
  # empty one.
  verdicts=$(LC_ALL=C awk -F '\t' -v bf="$baseline" '
    BEGIN { while ((getline l < bf) > 0) { if (l ~ /^#/ || l ~ /^[ \t]*$/) continue; b[l]++ } }
    $1 == "H" { k = $0; sub(/^H\t[^\t]*\t/, "", k); if (b[k] > 0) { b[k]--; next } print "NEW\t" $2 "\t" k }
    END { for (k in b) for (i = 0; i < b[k]; i++) print "STALE\t-\t" k }
  ' "$hits")
fi

violations=0
if [[ -n "$reasonless" ]]; then
  while IFS= read -r v; do
    echo "FAIL: $v — disable-no-reason: a lint-test-clock disable comment with no reason suppresses nothing" >&2
    violations=$((violations + 1))
  done <<< "$reasonless"
fi
if (( ! write_baseline )) && [[ -n "$verdicts" ]]; then
  while IFS=$'\t' read -r kind no key; do
    path=${key%%|*}; rest=${key#*|}; rule=${rest%%|*}
    if [[ "$kind" == NEW ]]; then
      echo "FAIL: $path:$no — $rule: a wall-clock assertion that is not in the baseline" >&2
      echo "       advice: inject the time, read the clock at the call that judges it, or keep the value well clear of the boundary; do not lengthen the deadline" >&2
    else
      echo "FAIL: baseline entry no longer hits — $key" >&2
      echo "       advice: the baseline only shrinks; delete the entry (or rerun with --write-baseline)" >&2
    fi
    violations=$((violations + 1))
  done <<< "$verdicts"
fi
violations=$((violations + unreadable))

if (( violations == 0 )); then
  echo "lint-test-clock: all ${#FILES[@]} file(s) passed"
  exit 0
fi
echo "lint-test-clock: ${violations} violation(s)" >&2
exit 1
