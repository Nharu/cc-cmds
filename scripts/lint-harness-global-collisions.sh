#!/usr/bin/env bash
#
# lint-harness-global-collisions.sh — the gate harness and the gate must not
# share a top-level variable name.
#
# The harness reaches the gate by forking it today, and the in-process seam
# that replaces the fork sources `gate.sh` — which sources `run.sh` — into the
# harness's own shell. Sourcing runs every top-level assignment of both files
# in the caller's process, so any name the harness holds at top level and the
# gate also assigns at top level is silently overwritten under the harness's
# feet: its fixture manifest becomes the gate's empty default, its ledger path
# becomes whatever the driver computed, and every assertion after that reads a
# different world than the one it set up. Measured at the pin: exactly four
# names collided (`MANIFEST`, `LEDGER`, `GRANT`, `CC_PIPELINE_STAGE_ID`), and
# nothing would have said so when a fifth arrived. This lint is what says so.
#
# Both populations are derived from the files' bytes; nothing is listed here.
#
#   harness side H  — the NAME of every column-zero `NAME=`, `export NAME=` or
#                     `export NAME` line, where NAME is upper-case letters,
#                     digits and underscores and starts with a letter. A line
#                     is EXCLUDED when it is a command-prefix environment
#                     (`NAME=val some-command …`): once the leading assignment
#                     tokens are removed either a command or a continuation
#                     backslash (the command is on the next line) remains,
#                     rather than nothing, a comment or a statement separator.
#                     Such an assignment reaches only the child, never the
#                     sourcing shell. Indented assignments
#                     are excluded too — a name assigned inside a function or a
#                     block is not a top-level variable a sourced file would
#                     clobber on entry, and the seam's own guard is what covers
#                     function-local state.
#
#   gate side G     — every NAME assigned at the START OF A STATEMENT anywhere
#                     in the gate files, at any indentation: `NAME=`,
#                     `export NAME=`, `readonly NAME=`, `declare NAME=` and
#                     `export NAME` (which makes a caller's value the gate's).
#                     A statement starts at the line's first token or after
#                     `;`, `&&`, `||`, `(`, `{`, `then`, `do` or `else`.
#                     Excluded: `local NAME=` and `declare` spelled with a
#                     scope flag (the name dies with the function), `for NAME
#                     in` (a loop variable), comment lines (first non-blank
#                     byte is `#`), and command-prefix environments, for the
#                     same reason as on the harness side — `CC_CLAUDE_BIN=
#                     "$CLI_BIN" \` in front of a launch cannot overwrite the
#                     sourcing shell's `CC_CLAUDE_BIN`, and counting it would
#                     make the `export CC_CLAUDE_BIN` the harness legitimately
#                     needs a permanent violation.
#
#   verdict         — H ∩ G non-empty is a violation. Every colliding name is
#                     reported with the first harness line and the first gate
#                     line that assign it, so the reader lands on both sides.
#
# The exclusions are the whole precision of this check. A collision that is
# not one — a prefix on a child command — reported as one would train readers
# to override the lint; a real collision hidden behind an over-wide exclusion is
# the clobber this lint exists to catch. Both lists above are therefore closed
# and stated, and the self-test holds each of them to a case.
#
# Usage: bash scripts/lint-harness-global-collisions.sh
#
# Env override:
#   ROOT        repo root (default: this script's repo root)
#   HARNESS     harness file, root-relative (default scripts/test-gate.sh)
#   GATE_FILES  space-separated gate files, root-relative
#               (default plugins/cc-cmds/orchestrator/gate.sh plugins/cc-cmds/orchestrator/run.sh)
#
# Exit codes:
#   0  compared, no collision
#   1  compared, at least one collision
#   2  the comparison could not be carried out: the harness file or a gate
#      file is missing, or either derivation is empty
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
default_root=$(cd "$script_dir/.." && pwd)
root="${ROOT:-$default_root}"
harness_rel="${HARNESS:-scripts/test-gate.sh}"
gate_files_rel="${GATE_FILES:-plugins/cc-cmds/orchestrator/gate.sh plugins/cc-cmds/orchestrator/run.sh}"

fail=0

viol() {
  # $1 rule id, $2 target, $3 message
  printf 'FAIL: [%s] %s — %s\n' "$1" "$2" "$3" >&2
  fail=1
}

die2() {
  printf 'ERR: %s\n' "$1" >&2
  exit 2
}

# --- prerequisites ----------------------------------------------------------

harness="$root/$harness_rel"
[ -f "$harness" ] || die2 "하니스 파일이 없다: ${harness_rel}"
for g in $gate_files_rel; do
  [ -f "$root/$g" ] || die2 "게이트 파일이 없다: ${g}"
done

# --- the shared exclusion: command-prefix environments ----------------------
# `$1` is a statement whose first token is `NAME=…`. Every leading `NAME=value`
# token is stripped — a value being a single- or double-quoted string or a run
# of non-blank bytes — and the statement is a command-prefix environment when
# what remains is a command: not empty, not a comment, not a continuation
# backslash and not a statement separator.

is_prefix_env() {
  local rest="$1" tok name
  while :; do
    tok=${rest%%[[:space:]]*}
    case "$tok" in
      *=*) ;;
      *) break ;;
    esac
    name=${tok%%=*}
    case "$name" in
      [A-Za-z_]*) ;;
      *) break ;;
    esac
    case "$name" in
      *[!A-Za-z0-9_]*) break ;;
    esac
    rest=${rest#*=}
    case "$rest" in
      \"*)
        rest=${rest#\"}
        rest=${rest#*\"} ;;
      \'*)
        rest=${rest#\'}
        rest=${rest#*\'} ;;
      *)
        rest=${rest#"${rest%%[[:space:]]*}"} ;;
    esac
    rest=${rest#"${rest%%[![:space:]]*}"}
  done
  # A trailing continuation backslash means the command is on the NEXT line —
  # the launch in `gate.sh` spells ten prefix assignments one per line before
  # the `bash` they belong to — so it counts as a prefix, not as a statement.
  case "$rest" in
    '\') return 0 ;;
    ''|'#'*|';'*|'&&'*|'||'*|')'*|'}'*|'|'*|'&'*) return 1 ;;
    *) return 0 ;;
  esac
}

# --- harness side H ---------------------------------------------------------
# Column-zero lines only. Records are `NAME<TAB>line[<TAB>statement]`; the
# statement is present only for bare assignments, which are the lines that
# can be a command prefix.

harness_names=$(
  awk '
    /^export[ \t]+[A-Z][A-Z0-9_]*(=|[ \t]|$)/ {
      n = $0; sub(/^export[ \t]+/, "", n); sub(/[^A-Z0-9_].*$/, "", n)
      print n "\t" NR; next
    }
    /^[A-Z][A-Z0-9_]*=/ {
      n = $0; sub(/=.*$/, "", n)
      print n "\t" NR "\t" $0
    }
  ' "$harness"
)

H=""
while IFS=$'\t' read -r name line text; do
  [ -n "$name" ] || continue
  if [ -n "${text:-}" ] && is_prefix_env "$text"; then
    continue
  fi
  H=$(printf '%s\n%s\t%s' "$H" "$name" "$line")
done <<EOF
$harness_names
EOF
H=$(printf '%s\n' "$H" | grep -v '^$' | awk -F'\t' '!seen[$1]++')
[ -n "$H" ] || die2 "하니스 쪽 전역 유도가 비었다: ${harness_rel}"

# --- gate side G ------------------------------------------------------------
# Every statement start on every non-comment line. The awk walks a line
# statement by statement; `local` and scoped `declare` never match because the
# assignment has to be the statement's first token or follow one of the three
# bare keywords; `for NAME in` has no `=` and never matches at all.

gate_names=""
for g in $gate_files_rel; do
  part=$(
    awk -v f="$g" '
      function emit_stmt(s,   n, t) {
        sub(/^[ \t]+/, "", s)
        if (s ~ /^(export|readonly|declare)[ \t]+[A-Z][A-Z0-9_]*(=|[ \t]|$)/) {
          n = s; sub(/^(export|readonly|declare)[ \t]+/, "", n); sub(/[^A-Z0-9_].*$/, "", n)
          print n "\t" f ":" NR
          return
        }
        if (s ~ /^[A-Z][A-Z0-9_]*=/) {
          n = s; sub(/=.*$/, "", n)
          print n "\t" f ":" NR "\t" s
        }
      }
      /^[ \t]*#/ { next }
      {
        line = $0
        # Split into statements at `;`, `&&`, `||`, `(`, `{`, and after the
        # keywords then/do/else when they end a token.
        while (match(line, /(;|&&|[|][|]|[(]|[{]|[ \t](then|do|else)[ \t])/)) {
          emit_stmt(substr(line, 1, RSTART - 1))
          line = substr(line, RSTART + RLENGTH)
        }
        emit_stmt(line)
      }
    ' "$root/$g"
  )
  gate_names=$(printf '%s\n%s' "$gate_names" "$part")
done

G=""
while IFS=$'\t' read -r name where text; do
  [ -n "$name" ] || continue
  if [ -n "${text:-}" ] && is_prefix_env "$text"; then
    continue
  fi
  G=$(printf '%s\n%s\t%s' "$G" "$name" "$where")
done <<EOF
$gate_names
EOF
G=$(printf '%s\n' "$G" | grep -v '^$' | awk -F'\t' '!seen[$1]++')
[ -n "$G" ] || die2 "게이트 쪽 전역 유도가 비었다: ${gate_files_rel}"

# --- intersection -----------------------------------------------------------

h_only=$(printf '%s\n' "$H" | cut -f1 | sort -u)
g_only=$(printf '%s\n' "$G" | cut -f1 | sort -u)
both=$(comm -12 <(printf '%s\n' "$h_only") <(printf '%s\n' "$g_only"))

while IFS= read -r name; do
  [ -n "$name" ] || continue
  hl=$(printf '%s\n' "$H" | awk -F'\t' -v n="$name" '$1 == n { print $2; exit }')
  gl=$(printf '%s\n' "$G" | awk -F'\t' -v n="$name" '$1 == n { print $2; exit }')
  viol "충돌" "$name" "하니스 ${harness_rel}:${hl} 의 최상위 전역을 게이트 ${gl} 가 대입한다 — 소싱하는 순간 하니스의 값이 덮인다"
done <<EOF
$both
EOF

# --- summary ----------------------------------------------------------------

count_lines() { printf '%s\n' "$1" | grep -c '[^[:space:]]' || true; }

h_count=$(count_lines "$h_only")
g_count=$(count_lines "$g_only")
b_count=$(count_lines "$both")

if [ "$fail" -ne 0 ]; then
  printf 'FAIL: harness-global-collisions — |H|=%d |G|=%d 교집합 %d (하니스 %s, 게이트 %s)\n' \
    "$h_count" "$g_count" "$b_count" "$harness_rel" "$gate_files_rel" >&2
  exit 1
fi

printf 'OK: harness-global-collisions — |H|=%d |G|=%d 교집합 0 (하니스 %s, 게이트 %s)\n' \
  "$h_count" "$g_count" "$harness_rel" "$gate_files_rel"
exit 0
