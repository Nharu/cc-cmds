#!/usr/bin/env bash
# lint-notify-title-render: self-skip
# Refuse a banner title or body LITERAL that the notifier would swallow.
#
# terminal-notifier drops an argument whose first character is one of six —
# `[ ( { < " -` — and nothing looks broken when it does: the notice still
# appears, with the application's own name where the title was. That is how a
# bracketed source marker erased every title this tree ever raised. Closing
# brackets pass and a leading space is no shield, because the tool strips
# whitespace before judging.
#
# THE SCOPE IS THE WHOLE TREE, not one file. The defect was never a property of
# a single emitter — it was a repo-wide bracketed-prefix convention, and two
# separate dispatchers followed it. A lint scoped to one of them would leave the
# other outside the fence permanently.
#
# Rules:
#   1  a `-title`/`-message` argument written as a quoted LITERAL must not begin
#      with one of the six                                              [fail]
#   2  the shared emitter's own title table must not either              [fail]
#
# ONLY LITERALS ARE JUDGED, and that limit is stated here because it is not
# obvious from the output. `-message "${summary}"` opens with a variable whose
# value cannot be known from the source, so it is skipped rather than guessed
# at; the dynamic argv assertions in the banner suites cover that half, and the
# oracle covers the case where the tool itself changes which characters it
# swallows. Do not read a green run as "the variables were checked too".
#
# A literal is judged up to its first `$`, so `-title "cc-cmds ${workflow}"` is
# decided by `cc-cmds ` — which is all that can ever bear on a FIRST character.
#
# A `-title` written INSIDE a quoted string is not an argument, it is an
# assertion about somebody else's argv, and that is exactly how the test suites
# spell their expectations. Requiring the next token to OPEN WITH A QUOTE is
# what separates the two; without it this lint would fail on every suite that
# pins the arguments it is protecting.
#
# Comments are stripped first, so prose naming the six characters is not a
# violation — the same idiom the kill-switch name lint uses. A file may exempt
# itself with `lint-notify-title-render: self-skip` in its first five lines,
# exactly as the portability lint allows.
#
# Usage:
#   bash scripts/lint-notify-title-render.sh
#
# Env overrides (fixture runner):
#   ROOT=<dir>       # tree to scan (default: the repository root)
#   EMITTER=<file>   # shared emitter for rule 2 (default: derived from ROOT)
#
# Posture: a tree with nothing to scan is a silent pass, so the script stays
# green during an incremental rollout.
#
# Exit codes:
#   0 — pass (or nothing scannable)
#   1 — at least one violation
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
root="${ROOT:-$repo_root}"
emitter="${EMITTER:-$root/plugins/cc-cmds/orchestrator/notify-run.sh}"

fail=0

# The six — but they divide into two mechanisms, and a leading space tells them
# apart. Measured against the real binary by the oracle in this tree:
#
#   `[ ( { < "` are swallowed by the value parser, which strips whitespace before
#   it judges, so ` [x` is swallowed exactly as `[x` is.
#   `-` is swallowed for the other reason — the word looks like an option — and a
#   space in front stops it being a word at all, so ` -x` survives.
#
# Collapsing the two would be wrong in both directions at once: judging only the
# very first character lets ` [x` through, and judging the stripped string flags
# ` -x`, which the tool renders perfectly well.
banned_first() {
  local s="$1" stripped
  stripped="$s"
  while :; do
    case "$stripped" in
      [[:space:]]*) stripped="${stripped#?}" ;;
      *) break ;;
    esac
  done
  case "$stripped" in
    '['*|'('*|'{'*|'<'*|'"'*) return 0 ;;
  esac
  case "$s" in
    '-'*) return 0 ;;
  esac
  return 1
}

# Strip the option word, the opening quote and everything from the first `$`.
# Returns the empty string when the argument begins with a variable, which is
# the signal to skip.
literal_of() {
  local m="$1" q rest
  rest="${m#-title}"
  rest="${rest#-message}"
  while :; do
    case "$rest" in
      [[:space:]]*) rest="${rest#?}" ;;
      *) break ;;
    esac
  done
  q="${rest:0:1}"
  rest="${rest:1}"
  case "$q" in
    '"') rest="${rest%%\"*}" ;;
    "'") rest="${rest%%\'*}" ;;
    *) printf ''; return 0 ;;
  esac
  printf '%s' "${rest%%\$*}"
}

report() {
  # report <file> <line> <what> <literal>
  echo "FAIL: ${1}:${2} — ${3} 리터럴이 삼킴 문자로 시작한다: 「${4}」" >&2
  echo "       삼킴 문자 여섯: [ ( { < \" -   (닫는 괄호는 통과하고, 앞선 공백은 방패가 아니다)" >&2
  fail=1
}

judge_matches() {
  # judge_matches <file> <what> — reads `<line>:<match>` pairs on stdin
  local f="$1" what="$2" hit line lit
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    line="${hit%%:*}"
    lit=$(literal_of "${hit#*:}")
    [ -n "$lit" ] || continue
    if banned_first "$lit"; then
      report "$f" "$line" "$what" "$lit"
    fi
  done
}

scanned=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # Fixture trees are excluded RELATIVE TO THE ROOT BEING SCANNED, not by the
  # substring `tests/fixtures` anywhere in the path. A blanket substring match
  # also swallows the case where the root IS a fixture directory, which is how
  # the paired test drives this script — every deliberate violation would then be
  # skipped and the test would report a clean tree.
  case "$f" in
    "$root"/tests/fixtures/*) continue ;;
  esac
  if { head -5 "$f" 2>/dev/null || true; } | grep -qF 'lint-notify-title-render: self-skip'; then
    continue
  fi
  scanned=$((scanned + 1))
  # Comments are stripped before the scan. A `#` inside a string truncates the
  # line here, which can only hide a candidate — never invent one.
  stripped=$(sed 's/#.*//' "$f" 2>/dev/null || true)
  judge_matches "$f" "인자" <<EOF
$(printf '%s\n' "$stripped" | grep -nEo -- '-(title|message)[[:space:]]+"[^"]*"' || true)
EOF
  judge_matches "$f" "인자" <<EOF
$(printf '%s\n' "$stripped" | grep -nEo -- "-(title|message)[[:space:]]+'[^']*'" || true)
EOF
done <<EOF
$(find "$root" -type f -name '*.sh' 2>/dev/null | sort || true)
EOF

# --- Rule 2: the emitter's own title table ---------------------------------
#
# The five arms are literals that never pass through a `-title` argument in this
# file — the fire path hands them over in a variable — so rule 1 cannot see them
# and they are read at their source instead.
if [ -f "$emitter" ]; then
  table=$(sed -n '/^cc_notify_title() {/,/^}/p' "$emitter" 2>/dev/null | sed 's/#.*//' || true)
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    lit="${hit#*:}"
    lit="${lit#printf }"
    lit="${lit#\'}"
    lit="${lit%\'}"
    [ -n "$lit" ] || continue
    if banned_first "$lit"; then
      echo "FAIL: $(basename "$emitter") — 제목 표의 리터럴이 삼킴 문자로 시작한다: 「${lit}」" >&2
      fail=1
    fi
  done <<EOF
$(printf '%s\n' "$table" | grep -nEo -- "printf '[^']*'" || true)
EOF
fi

if [ "$fail" != "0" ]; then
  echo "lint-notify-title-render: violations found" >&2
  exit 1
fi

if [ "$scanned" = "0" ]; then
  echo "SKIP: 스캔할 셸 파일이 없다: $root"
  exit 0
fi

echo "OK:   notify title render — 셸 파일 ${scanned}개의 제목·본문 리터럴이 삼킴 문자로 시작하지 않는다"
exit 0
