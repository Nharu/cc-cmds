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
#   elapsed-compare
#                  an upper bound, or an equality, on an elapsed value, judged
#                  over a logical line (physical lines joined at a trailing
#                  backslash). An elapsed value is `$SECONDS`, an arithmetic
#                  difference of a clock value (an anchor, an inline
#                  `$(date [-u] +%s)` or `$EPOCHSECONDS`) and a non-constant
#                  operand, or an elapsed variable: one assigned such a value,
#                  or another elapsed variable, within the same scope. A scope
#                  is the stretch between two section banners or function
#                  boundaries, so a name reused elsewhere in a large file is not
#                  taken along; a clock minus a constant is a point in time, not
#                  an elapsed value. Upper bounds are `x -lt N`, `x -le N`,
#                  `N -gt x`, `N -ge x`, `x < N`, `x <= N`, `N > x`, `N >= x`;
#                  `-eq`, `-ne`, `==` and `!=` cannot tell an upper bound from a
#                  lower one and are taken too. A lower bound alone is not
#                  flagged. A logical line where `elapsed-bound` hits on any of
#                  its physical lines (accepted or not) takes no
#                  `elapsed-compare`; the hit is reported on the logical line's
#                  first physical line.
#
# Comment-only lines are not checked.
#
# Load marker (scripts/test-gate.sh only, told by the file name). A judgement
# line — a line that calls `check` or `bad`, the first physical line of a
# multi-line `check` — may carry `# gate-load: <reason>` at its end; when it ends
# with a backslash the marker sits alone on the comment-only line right above
# it. In a file named test-gate.sh an `elapsed-bound` or `elapsed-compare` hit
# is accepted when the judgement line it connects to carries the marker: the
# first physical line of its logical line when that line calls `check`/`bad`,
# every `bad` line of the block when the hit is the condition of an `if`, and
# otherwise only the escape comment (naming the `check` that judges the value).
# Such a hit is never taken into the baseline, and a baseline entry for one
# fails. The marker does not accept `clock-margin`. A marker fails on its own
# (`gate-load-reason`, `gate-load-orphan`, `gate-load-outside`,
# `gate-load-order`) when its reason is empty or holds ` — `, when its line
# calls neither `check` nor `bad` (a comment-only marker line passes only right
# above a backslash-ended judgement line), when it is outside test-gate.sh, or
# when it follows `# gate-isolation: 변동` on the same line.
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

# One awk per file, reading it twice: the first pass collects the anchors and
# the assignments elapsed variables are derived from, the second judges each
# line against them, so an anchor assigned below its use still counts. Output
# lines:
#   H <TAB> <line no> <TAB> <path>|<rule>|<trimmed line>
#   D <TAB> <line no> <TAB> <path>
#   M <TAB> <line no> <TAB> <path> <TAB> <marker rule>
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
# Scopes for elapsed variables: a new one opens at a section banner, at a
# function definition, and on the line after a function body closes.
function scope_step(l) {
  if (bump_next) { SC++; bump_next = 0 }
  if (l ~ /^# --- / || (prevraw ~ /^# -+$/ && l ~ /^# [0-9]+[a-z]*(-[0-9]+[a-z]*)?\. /)) SC++
  else if (l ~ /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)[ \t]*(\{|$)/) {
    SC++
    if (l ~ /\}[ \t;]*$/) bump_next = 1
  }
  else if (l ~ /^\}/) bump_next = 1
  prevraw = l
}
function nowsub(s) {
  gsub(/\$\(date[ \t]+(-u[ \t]+)?["'"'"']?\+%s["'"'"']?\)/, " __NOW__ ", s)
  return s
}
# The arithmetic expansion opening at s[i] ("$(("): its inner text, with the
# index of its closing parenthesis left in ARE (0 when it does not close).
function arith_inner(s, i,    d, k, ch) {
  ARE = 0; d = 0
  for (k = i + 1; k <= length(s); k++) {
    ch = substr(s, k, 1)
    if (ch == "(") d++
    else if (ch == ")") { d--; if (d == 0) { ARE = k; return substr(s, i + 3, k - i - 4) } }
  }
  return ""
}
function timeish(t) { return (t in A) || t == "__NOW__" || t == "EPOCHSECONDS" }
function operand(t) { return t == "?" || t ~ /^[A-Za-z_][A-Za-z0-9_]*$/ }
# T[k] is a "-" between a clock value and a non-constant operand.
function tdiff_at(k,    a, b) {
  if (T[k] != "-") return 0
  a = T[k - 1]; b = T[k + 1]
  if (a == b) return 0
  return (timeish(a) && operand(b)) || (timeish(b) && operand(a))
}
function elapsed_name(t, sc) { return t == "SECONDS" || ((sc SUBSEP t) in E) }
function arith_elapsed(n, sc,    k) {
  for (k = 1; k <= n; k++) if (elapsed_name(T[k], sc) || tdiff_at(k)) return 1
  return 0
}
function arith_cmp(n, sc,    k, j, op, le, re) {
  for (k = 1; k <= n; k++) {
    op = T[k]
    if (op != "<" && op != "<=" && op != ">" && op != ">=" && op != "==" && op != "!=") continue
    j = k - 1; while (j >= 1 && T[j] == ")") j--
    le = (j >= 1) && (elapsed_name(T[j], sc) || (j >= 3 && tdiff_at(j - 1)))
    j = k + 1; while (j <= n && T[j] == "(") j++
    re = (j <= n) && (elapsed_name(T[j], sc) || tdiff_at(j + 1))
    if ((op == "<" || op == "<=") && le) return 1
    if ((op == ">" || op == ">=") && re) return 1
    if ((op == "==" || op == "!=") && (le || re)) return 1
  }
  return 0
}
function word_el(w, sc,    nm) {
  gsub(/["'"'"']/, "", w)
  if (w == "__PHE__") return 1
  if (w !~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/) return 0
  nm = w; gsub(/[${}]/, "", nm)
  return elapsed_name(nm, sc)
}
function cmp_hit(s, sc,    out, i, inner, n, t, op, lw, rw) {
  out = ""
  while ((i = index(s, "$((")) > 0) {
    inner = arith_inner(s, i)
    if (!ARE) break
    n = tokenize(nowsub(inner))
    if (arith_cmp(n, sc)) return 1
    out = out substr(s, 1, i - 1) (arith_elapsed(n, sc) ? "__PHE__" : "__PHN__")
    s = substr(s, ARE + 1)
  }
  out = out s
  t = out
  while ((i = index(t, "((")) > 0) {
    inner = arith_inner(t, i - 1)
    if (!ARE) break
    n = tokenize(nowsub(inner))
    if (arith_cmp(n, sc)) return 1
    t = substr(t, ARE + 1)
  }
  t = out
  while (match(t, /[ \t]-(lt|le|gt|ge|eq|ne)[ \t]/)) {
    op = substr(t, RSTART + 2, 2)
    lw = substr(t, 1, RSTART); sub(/[ \t]+$/, "", lw); sub(/^.*[ \t[]/, "", lw)
    rw = substr(t, RSTART + RLENGTH); sub(/^[ \t]+/, "", rw); sub(/[] \t].*$/, "", rw)
    if (word_el(lw, sc) && (op == "lt" || op == "le" || op == "eq" || op == "ne")) return 1
    if (word_el(rw, sc) && (op == "gt" || op == "ge" || op == "eq" || op == "ne")) return 1
    t = substr(t, RSTART + RLENGTH - 1)
  }
  return 0
}
# The right-hand side of an assignment, as the elapsed closure reads it.
function rhs_of(r,    i, inner, nm) {
  sub(/^"/, "", r)
  if (substr(r, 1, 3) == "$((") {
    inner = arith_inner(r, 1)
    return ARE ? "A:" inner : ""
  }
  if (match(r, /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)) {
    nm = substr(r, 1, RLENGTH); gsub(/[${}]/, "", nm)
    return nm == "SECONDS" ? "S" : "V:" nm
  }
  return ""
}
function close_elapsed(    k, n, t, key, ch) {
  for (k = 1; k <= NASG; k++) {
    key = ASC[k] SUBSEP ANM[k]
    if (ARHS[k] == "S") { E[key] = 1; continue }
    if (substr(ARHS[k], 1, 2) != "A:") continue
    n = tokenize(nowsub(substr(ARHS[k], 3)))
    for (t = 1; t <= n; t++) if (T[t] == "SECONDS" || tdiff_at(t)) { E[key] = 1; break }
  }
  do {
    ch = 0
    for (k = 1; k <= NASG; k++) {
      key = ASC[k] SUBSEP ANM[k]
      if (key in E) continue
      if (substr(ARHS[k], 1, 2) == "V:") {
        if ((ASC[k] SUBSEP substr(ARHS[k], 3)) in E) { E[key] = 1; ch = 1 }
      } else if (substr(ARHS[k], 1, 2) == "A:") {
        n = tokenize(substr(ARHS[k], 3))
        for (t = 1; t <= n; t++) if ((ASC[k] SUBSEP T[t]) in E) { E[key] = 1; ch = 1; break }
      }
    }
  } while (ch)
}
function is_call(c) { return c ~ /(^|[;&|({]|(^|[ \t])(then|else|do))[ \t]*(check|bad)[ \t]/ }
function is_bad(c) { return c ~ /(^|[;&|({]|(^|[ \t])(then|else|do))[ \t]*bad[ \t]/ }
function count_re(c, re,    n) {
  n = 0
  while (match(c, re)) { n++; c = substr(c, RSTART + RLENGTH) }
  return n
}
# A judgement line carries the marker: at its end, or, when it ends with a
# backslash, on the comment-only line right above it.
function marked(no) { return ENDBS[no] ? ((no - 1) in MKC) : (no in MK) }
function emit_hit(no, rule) { printf "H\t%d\t%s|%s|%s\n", no, path, rule, LTXT[no] }
# A hit in test-gate.sh is accepted by the marker on the judgement line it
# connects to; elsewhere it goes to the baseline comparison.
function report(no, rule) {
  if (!is_tg) { emit_hit(no, rule); return }
  if (is_call(LLCODE)) { if (!marked(LLF)) emit_hit(no, rule); return }
  if (LLCODE ~ /^[ \t]*if[ \t]/) {
    NP++; PNO[NP] = no; PRULE[NP] = rule; PBASE[NP] = LLD0; PBAD[NP] = ""; POPEN[NP] = 1
    return
  }
  emit_hit(no, rule)
}
function resolve(p,    nb, k, b, ok) {
  POPEN[p] = 0
  nb = split(PBAD[p], b, " ")
  ok = (nb > 0)
  for (k = 1; k <= nb; k++) if (!marked(b[k] + 0)) ok = 0
  if (!ok) emit_hit(PNO[p], PRULE[p])
}
function flush_ll(    k, rawb) {
  if (!LLF) return
  rawb = 0
  for (k = LLF; k <= LLL; k++) if (k in BRAW) rawb = 1
  for (k = LLF; k <= LLL; k++) if ((k in BRAW) && !(k in BDIS)) report(k, "elapsed-bound")
  if (!rawb && !LLCDIS && cmp_hit(LLCODE, LLSC)) report(LLF, "elapsed-compare")
  LLF = 0
}
function marker_check(l, comment_only, c,    mi, rest, gi) {
  mi = index(l, "# gate-load:")
  if (!mi) return
  rest = substr(l, mi + length("# gate-load:"))
  gi = index(rest, " #"); if (gi) rest = substr(rest, 1, gi - 1)
  rest = trim(rest)
  if (rest == "" || index(rest, " — ")) printf "M\t%d\t%s\tgate-load-reason\n", FNR, path
  if (!is_tg) printf "M\t%d\t%s\tgate-load-outside\n", FNR, path
  gi = index(l, "# gate-isolation:")
  if (gi && gi < mi) printf "M\t%d\t%s\tgate-load-order\n", FNR, path
  if (comment_only) { pend_mk = FNR; MKC[FNR] = 1; return }
  if (!is_call(c)) printf "M\t%d\t%s\tgate-load-orphan\n", FNR, path
  MK[FNR] = 1
}
BEGIN {
  DATE_RE = "[A-Za-z_][A-Za-z0-9_]*=\"?(\\$\\(date[ \t]+(-u[ \t]+)?[\"'"'"']?\\+%s[\"'"'"']?\\)|\\$\\{?EPOCHSECONDS\\}?)"
  PRINTF_RE = "printf[ \t]+-v[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+[\"'"'"']?%\\(%s\\)T"
}
FNR == NR {
  if (FNR == 1) { is_tg = (path ~ /(^|\/)test-gate\.sh$/); SC = 0; prevraw = ""; bump_next = 0 }
  scope_step($0)
  if ($0 ~ /^[ \t]*#/) next
  code = index($0, "#") ? strip_comment($0) : $0
  if (index(code, "=")) {
    s = code
    while (match(s, /(^|[ \t;&|(`])[A-Za-z_][A-Za-z0-9_]*=/)) {
      m = substr(s, RSTART, RLENGTH); sub(/^[^A-Za-z_]/, "", m); sub(/=$/, "", m)
      s = substr(s, RSTART + RLENGTH)
      r = rhs_of(s)
      if (r != "" && m != "SECONDS") { NASG++; ASC[NASG] = SC; ANM[NASG] = m; ARHS[NASG] = r }
    }
  }
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
FNR == 1 { close_elapsed(); SC = 0; prevraw = ""; bump_next = 0 }
{
  line = $0
  scope_step(line)
  comment_only = (line ~ /^[ \t]*#/)
  if (comment_only) { code = ""; cmt = line }
  else if (index(line, "#")) { code = strip_comment(line); cmt = substr(line, length(code) + 1) }
  else { code = line; cmt = "" }
  if (pend_mk) {
    if (comment_only || !is_call(code) || line !~ /\\$/) printf "M\t%d\t%s\tgate-load-orphan\n", pend_mk, path
    pend_mk = 0
  }
  if (index(line, "gate-load:")) marker_check(line, comment_only, code)
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

  if (line ~ /\\$/) ENDBS[FNR] = 1
  LTXT[FNR] = trim(line)
  if (!LLF) { LLF = FNR; LLCODE = ""; LLSC = SC; LLCDIS = 0; LLD0 = ifdepth }
  LLL = FNR
  c2 = code; sub(/\\$/, "", c2)
  LLCODE = LLCODE " " c2
  if ("elapsed-compare" in DIS) LLCDIS = 1
  if ("elapsed-bound" in DIS) BDIS[FNR] = 1
  if (index(code, "((")) arith_rules()
  if (NP && is_bad(code)) for (p = 1; p <= NP; p++) if (POPEN[p]) PBAD[p] = PBAD[p] " " FNR
  ifdepth += count_re(code, "(^|[;&|({ \t])if[ \t]") - count_re(code, "(^|[;&| \t])fi([ \t;)&|]|$)")
  if (ifdepth < 0) ifdepth = 0
  if (!(FNR in ENDBS)) flush_ll()
  for (p = 1; p <= NP; p++) if (POPEN[p] && ifdepth <= PBASE[p]) resolve(p)
}
END {
  flush_ll()
  for (p = 1; p <= NP; p++) if (POPEN[p]) resolve(p)
  if (pend_mk) printf "M\t%d\t%s\tgate-load-orphan\n", pend_mk, path
}
function arith_rules(    s, i, j, c, dollar, d, end, inner, n, margin, bound, before, after) {
  margin = 0; bound = 0
  s = code
  while ((i = index(s, "((")) > 0) {
    dollar = (i > 1 && substr(s, i - 1, 1) == "$")
    d = 0; end = 0
    for (j = i; j <= length(s); j++) {
      c = substr(s, j, 1)
      if (c == "(") d++
      else if (c == ")") { d--; if (d == 0) { end = j; break } }
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
  if (bound) BRAW[FNR] = 1
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
markers=$(LC_ALL=C awk -F '\t' '$1 == "M" { print $3 ":" $2 "\t" $4 }' "$hits")
verdicts=""

# An elapsed-time hit in test-gate.sh is answered by the load marker or the
# escape comment, never by the baseline: it is not written into it, and an
# entry naming one is refused.
TG_KEY_RE='^([^|]*/)?test-gate[.]sh[|]elapsed-(bound|compare)[|]'

if (( write_baseline )); then
  tmp="$work/baseline"
  {
    echo "# lint-test-clock baseline — wall-clock assertions already in the tree."
    echo "# One hit per line as <path>|<rule>|<trimmed line text>. It only shrinks:"
    echo "# delete an entry when its line is fixed. Regenerate with"
    echo "# bash scripts/lint-test-clock.sh --write-baseline"
    LC_ALL=C awk -v tg="$TG_KEY_RE" '/^H\t/ { sub(/^H\t[^\t]*\t/, ""); if ($0 !~ tg) print }' "$hits" | LC_ALL=C sort
  } > "$tmp"
  mv "$tmp" "$baseline"
  echo "lint-test-clock: wrote $(grep -cv '^#' "$baseline" || true) entr(y/ies) to $baseline"
  verdicts=$(LC_ALL=C awk -F '\t' -v tg="$TG_KEY_RE" '
    $1 == "H" { k = $0; sub(/^H\t[^\t]*\t/, "", k); if (k ~ tg) print "NEW\t" $2 "\t" k }
  ' "$hits")
else
  # Each hit takes one matching baseline entry; what is left on either side is a
  # violation. The baseline is read with getline so a missing file reads as an
  # empty one.
  verdicts=$(LC_ALL=C awk -F '\t' -v bf="$baseline" -v tg="$TG_KEY_RE" '
    BEGIN { while ((getline l < bf) > 0) { if (l ~ /^#/ || l ~ /^[ \t]*$/) continue; if (l ~ tg) { print "REFUSED\t-\t" l; continue } b[l]++ } }
    $1 == "H" { k = $0; sub(/^H\t[^\t]*\t/, "", k); if (k !~ tg && b[k] > 0) { b[k]--; next } print "NEW\t" $2 "\t" k }
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
if [[ -n "$markers" ]]; then
  while IFS=$'\t' read -r at rule; do
    case "$rule" in
      gate-load-reason)  why="the load marker needs a reason that holds no ' — '" ;;
      gate-load-orphan)  why="the load marker sits on a line that calls neither check nor bad (alone on a comment line, it belongs right above a judgement line ending with a backslash)" ;;
      gate-load-outside) why="the load marker belongs to scripts/test-gate.sh only" ;;
      *)                 why="the load marker goes in front of '# gate-isolation: 변동', not after it" ;;
    esac
    echo "FAIL: $at — $rule: $why" >&2
    violations=$((violations + 1))
  done <<< "$markers"
fi
if [[ -n "$verdicts" ]]; then
  while IFS=$'\t' read -r kind no key; do
    path=${key%%|*}; rest=${key#*|}; rule=${rest%%|*}
    if [[ "$kind" == NEW && "$key" =~ $TG_KEY_RE ]]; then
      echo "FAIL: $path:$no — $rule: a wall-clock assertion whose judgement line carries no gate-load marker" >&2
      echo "       advice: mark the judgement line with the load marker, or name the check that judges the value in a disable comment" >&2
    elif [[ "$kind" == NEW ]]; then
      echo "FAIL: $path:$no — $rule: a wall-clock assertion that is not in the baseline" >&2
      echo "       advice: inject the time, read the clock at the call that judges it, or keep the value well clear of the boundary; do not lengthen the deadline" >&2
    elif [[ "$kind" == REFUSED ]]; then
      echo "FAIL: baseline entry refused — $key" >&2
      echo "       advice: an elapsed-time hit in test-gate.sh is not baselined; delete the entry and mark the judgement line" >&2
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
