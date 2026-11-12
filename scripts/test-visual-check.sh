#!/usr/bin/env bash
# Executable specification of plugins/cc-cmds/orchestrator/visual-check.sh.
#
# Cases:
#   scan V11   the 55-line labelled colour/spacing sample: every V line is a
#              token-color finding, no C line is, every S line is a
#              token-space finding, no s line is. The CSS lines sit inside
#              <style> blocks and the markup lines (and the body sentence) sit
#              outside, so the comment line and the body sentence are no
#              longer findings.
#   scan V32   the 20-line script sample: 10 V lines found, 8 C lines not
#   scan refs  external-ref: http:, https:, //, an IP literal and a relative
#              path are found; ./support.js, a data: URI, a fragment, mailto:
#              and a body sentence are not; a commented-out reference is not
#   scan bans  the seed's 마크업 items and a 스크립트 item are found under their
#              own ids; a **금지 해제** id is skipped and named in the header;
#              a malformed ban line is a usage error. Its N lines are read
#              apart from token-undefined, which the fixture's undefined
#              custom properties draw
#   scan tokens  the token block and undefined custom properties:
#              1 a screen with no block draws token-undefined once per name,
#                without --tokens (the undefined.txt sample: every U line,
#                no D line), exit 1
#              2 a screen whose block equals tokens.css is clean with
#                --tokens (exit 0) and draws token-color on its block lines
#                without it
#              3 one byte changed in the block → token-block on the opening
#                line and the block lines' token-color back
#              4 two blocks, no block, and an opening line whose `</style>`
#                is glued to text → one token-block each; with two blocks no
#                block line is exempt
#              5 a tokens file with `url(https://…)` → external-ref stays
#                although the block matches
#              6 a tokens file holding `</style`, a missing tokens file, and a
#                screen whose opening line is never followed by `</style` →
#                exit 2 with the reason
#              7 a name defined only through setProperty('--x', …) is not
#                found; an undefined `var(--y, #fff)` draws token-undefined
#                and token-color together
#              8 the third header line in both forms
#   scan leak  a `/*` inside a script or CSS string, a template string whose
#              `${…}` holds another template, a script regex literal or
#              a `//` comment glued to the token before it, a `</script>`
#              inside a `//` comment, and an apostrophe inside an unquoted
#              attribute value leave every later line scanned; a screen that
#              ends inside a comment, a tag, a template string or an unclosed
#              <style>/<script>, or whose block comment or template string is
#              still open at its closing tag or attribute quote, is exit 2 with
#              the reason, for scan and size
#   scan hangul  Hangul in script and CSS strings and comments, a style
#              attribute and body text, under a UTF-8 locale: scan is exit 1
#              with an empty stderr, every later line is scanned and the
#              finding text keeps its bytes; size is exit 0
#   size      the start-tag count leaves comments and script out
#   approval   no sidecar, state not 발행됨, no approval line, one screen byte
#              changed, valid — and bundle --lines prints the bundle text; the
#              `**문서 반영**` line in each of its values with and without the
#              tail, repeated, misplaced or malformed
#   drift      count and digest of the block up to the next `### ` heading and
#              up to the end of the file, `없음`, no block (1), and lines whose
#              title or document text is not found (2); the sidecar placed by
#              hand through `대기` → `완료` and `대기` → `실패`
#   binding    equal to the driver's binding_digest on a document without a
#              `## 시각 정합 기준` section, blind to that section where it is
#   reuse      a 검토 통과 and a 발행됨 sidecar where every condition holds
#              are reusable, each condition broken once is not, a published
#              artifact line and an older sidecar's whole-file hash still are,
#              a changed tokens line, tokens.css, ban lift or source line is
#              not, argument errors are 2, and no sidecar, record, screen,
#              system.md or tokens.css byte moves
#   system     the normalized digest of a file without a final newline equals
#              a fixed constant, the artifact line is put back to unpublished,
#              a file without one hashes whole, no system.md prints (없음);
#              --owner is 0 for this document's sidecar whatever its record
#              and 1 for each reason, and argument errors are 2
#   grammar   the sidecar and ban-lift grammar examples of
#              plugins/cc-cmds/skills/visual/references/ read as the helpers
#              expect; the references must exist
#
# The fixtures store `label|content` lines: the content becomes the screen
# file and the label is the expectation for that same line number. A `-` label
# is a structural line with no expectation.
#
# Usage:
#   bash scripts/test-visual-check.sh
#
# Exit codes:
#   0 — every case passed
#   1 — at least one case failed
#   2 — the suite could not run (missing helper or fixtures)
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`; BSD
# and GNU userland alike.

set -euo pipefail

# THE RUN NOTIFIER IS OFF FOR THIS WHOLE PROCESS. The binding case sources the
# driver to compare against its own digest, so the census counts this file as
# a gate-family caller and demands these exports of it.
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
# The dashboard server is off for the same reason.
CC_CMDS_DASHBOARD=off
export CC_CMDS_DASHBOARD
# And it clears the inherited pipeline names, for the same reason.
for v in $(compgen -e | grep '^CC_PIPELINE_' || true); do unset "$v"; done

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
CHECK="$repo_root/plugins/cc-cmds/orchestrator/visual-check.sh"
CONFIG="$repo_root/plugins/cc-cmds/orchestrator/visual-config.sh"
SEED="$repo_root/plugins/cc-cmds/orchestrator/visual-bans.seed"
fixtures="$repo_root/tests/fixtures/visual-check"
REFS="$repo_root/plugins/cc-cmds/skills/visual/references/sidecar.md"

for need in "$CHECK" "$CONFIG" "$SEED" "$fixtures/v11.txt" "$fixtures/v32.txt" "$fixtures/refs.txt" "$fixtures/bans.txt" "$fixtures/leak.txt" "$fixtures/hangul.txt" "$fixtures/tokens.css" "$fixtures/undefined.txt"; do
  if [[ ! -f "$need" ]]; then
    echo "test-visual-check: missing $need" >&2
    exit 2
  fi
done

passed=0
failures=0
pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }

T=$(mktemp -d "${TMPDIR:-/tmp}/test-visual-check.XXXXXX")
trap 'rm -rf "$T"' EXIT

# materialize <fixture> <html out> <labels out>
materialize() {
  local line
  : > "$2"; : > "$3"
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "${line#*|}" >> "$2"
    printf '%s\n' "${line%%|*}" >> "$3"
  done < "$1"
}

# lines_of <rule> <scan output> — the line numbers carrying that rule.
lines_of() {
  { grep -E "^$1 " "$2" || true; } | sed -E 's/^[^ ]+ [^ ]*:([0-9]+) .*$/\1/' | sort -n -u
}

# tally <labels> <hit lines file> <label> — "<total> <hit>" for that label.
tally() {
  awk -v want="$3" -v hits="$2" '
    BEGIN { while ((getline l < hits) > 0) h[l] = 1 }
    $0 == want { t++; if (NR in h) n++ }
    END { printf "%d %d\n", t, n }
  ' "$1"
}

run_scan() { # <out> <args...> — prints rc
  local out=$1 rc=0
  shift
  bash "$CHECK" scan "$@" > "$out" 2> "$out.err" || rc=$?
  echo "$rc"
}

# --- scan V11 -----------------------------------------------------------------
materialize "$fixtures/v11.txt" "$T/v11.html" "$T/v11.labels"
rc=$(run_scan "$T/v11.out" "$T/v11.html")
[ "$rc" = 1 ] && pass "V11 scan 은 발견이 있어 종료 1" || fail "V11 scan 종료 ${rc} (기대 1)"
lines_of token-color "$T/v11.out" > "$T/v11.color"
lines_of token-space "$T/v11.out" > "$T/v11.space"
got=$(tally "$T/v11.labels" "$T/v11.color" V)
[ "$got" = "22 22" ] && pass "V11 V=22 hit=22" || fail "V11 V 줄 (전체 적중) = ${got}, 기대 22 22"
got=$(tally "$T/v11.labels" "$T/v11.color" C)
[ "$got" = "19 0" ] && pass "V11 C=19 false-positive=0" || fail "V11 C 줄 (전체 오탐) = ${got}, 기대 19 0"
got=$(tally "$T/v11.labels" "$T/v11.space" S)
[ "$got" = "3 3" ] && pass "V11 S=3 hit=3" || fail "V11 S 줄 (전체 적중) = ${got}, 기대 3 3"
got=$(tally "$T/v11.labels" "$T/v11.space" s)
[ "$got" = "4 0" ] && pass "V11 s=4 false-positive=0" || fail "V11 s 줄 (전체 오탐) = ${got}, 기대 4 0"
for pat in '/\* old: #fff \*/' 'Use #fff for white text'; do
  if grep -qE "^token-color .*${pat}" "$T/v11.out"; then
    fail "V11 주석·본문 문장 줄이 잡혔다: ${pat}"
  else
    pass "V11 주석·본문 문장 줄은 잡히지 않는다: ${pat}"
  fi
done
if grep -qE '^token-color .*var\(--color-surface, #fff\)' "$T/v11.out"; then
  pass "V11 var() 대체값의 리터럴은 위반으로 잡힌다"
else
  fail "V11 var() 대체값의 리터럴이 잡히지 않았다"
fi
grep -qxF '# 검사 밖: 계산된 색(스크립트가 실행 중에 값을 이어 만드는 색)은 이 검사가 보지 못한다' "$T/v11.out" \
  && pass "보고 머리에 계산된 색이 검사 밖이라고 적는다" || fail "보고 머리에 계산된 색 줄이 없다"
grep -qxF '# 금지 해제: 없음' "$T/v11.out" \
  && pass "해제가 없으면 머리에 '없음' 을 적는다" || fail "보고 머리에 '# 금지 해제: 없음' 이 없다"
v11_rows=$(grep -vE '^# ' "$T/v11.out" || true)
if [ -n "$v11_rows" ] && grep -qvE '^[a-z0-9-]+ [^ ]+:[0-9]+ ' <<EOF
$v11_rows
EOF
then
  fail "발견 줄이 '<규칙 id> <파일>:<줄> <문면>' 꼴이 아니다"
else
  pass "발견 줄은 '<규칙 id> <파일>:<줄> <문면>' 꼴이다"
fi

# --- scan V32 -----------------------------------------------------------------
materialize "$fixtures/v32.txt" "$T/v32.html" "$T/v32.labels"
rc=$(run_scan "$T/v32.out" "$T/v32.html")
lines_of token-color "$T/v32.out" > "$T/v32.color"
got=$(tally "$T/v32.labels" "$T/v32.color" V)
[ "$got" = "10 10" ] && pass "V32 스크립트 묶음 적중 10" || fail "V32 V 줄 (전체 적중) = ${got}, 기대 10 10"
got=$(tally "$T/v32.labels" "$T/v32.color" C)
[ "$got" = "8 0" ] && pass "V32 스크립트 묶음 오탐 0" || fail "V32 C 줄 (전체 오탐) = ${got}, 기대 8 0"

# --- scan refs ----------------------------------------------------------------
materialize "$fixtures/refs.txt" "$T/refs.html" "$T/refs.labels"
rc=$(run_scan "$T/refs.out" "$T/refs.html")
lines_of external-ref "$T/refs.out" > "$T/refs.hit"
got=$(tally "$T/refs.labels" "$T/refs.hit" R)
[ "$got" = "8 8" ] && pass "external-ref 적중 8 (http·https·//·IP·상대 경로·url()·@import·스크립트 URL)" \
  || fail "external-ref R 줄 (전체 적중) = ${got}, 기대 8 8"
got=$(tally "$T/refs.labels" "$T/refs.hit" N)
[ "$got" = "7 0" ] && pass "external-ref 비적중 7 (./support.js·data:·조각·mailto:·본문 문장·스크립트 조각)" \
  || fail "external-ref N 줄 (전체 오탐) = ${got}, 기대 7 0"
if grep -q 'comment.example.com' "$T/refs.out"; then
  fail "주석 안의 참조가 잡혔다"
else
  pass "주석 안의 참조는 잡히지 않는다"
fi

# --- scan bans ----------------------------------------------------------------
materialize "$fixtures/bans.txt" "$T/bans.html" "$T/bans.labels"
cp "$SEED" "$T/bans.list"
printf '%s\n' 'local-storage | 스크립트 | 브라우저 저장소에 상태를 둔다 | localStorage\.' >> "$T/bans.list"
rc=$(run_scan "$T/bans.out" "$T/bans.html" --bans "$T/bans.list")
[ "$rc" = 1 ] && pass "금지 목록 적중이 있으면 종료 1" || fail "금지 목록 scan 종료 ${rc} (기대 1)"
# The fixture's N lines reference custom properties it never defines; that
# rule is the scan tokens case's to judge, so the N lines are read without it.
{ grep -vE '^token-undefined ' "$T/bans.out" || true; } > "$T/bans.nontu"
n=0
while IFS= read -r label; do
  n=$((n + 1))
  case "$label" in
    -) ;;
    N)
      if grep -qE "^[^ ]+ [^ ]*:${n} " "$T/bans.nontu"; then fail "금지 목록 비적중 줄 ${n} 이 잡혔다"; else pass "금지 목록 비적중 줄 ${n}"; fi
      ;;
    *)
      if grep -qE "^${label} [^ ]*:${n} " "$T/bans.out"; then pass "금지 항목 ${label} 이 줄 ${n} 에서 잡힌다"; else fail "금지 항목 ${label} 이 줄 ${n} 에서 잡히지 않았다"; fi
      ;;
  esac
done < "$T/bans.labels"
printf '%s\n' '# 디자인 시스템' '' '**금지 해제**: glassmorphism — 이 제품의 유리 카드는 정체성이다' > "$T/system.md"
rc=$(run_scan "$T/lift.out" "$T/bans.html" --bans "$T/bans.list" --lifts "$T/system.md")
if grep -qE '^glassmorphism ' "$T/lift.out"; then fail "해제된 id 가 잡혔다"; else pass "해제된 id 는 건너뛴다"; fi
grep -qE '^pill-button ' "$T/lift.out" && pass "해제되지 않은 id 는 그대로 잡힌다" || fail "해제와 무관한 id 가 사라졌다"
grep -qxF '# 금지 해제: glassmorphism' "$T/lift.out" && pass "건너뛴 id 를 보고 머리에 적는다" || fail "보고 머리에 해제 id 가 없다"
printf '%s\n' 'bad line without separators' > "$T/bad.list"
rc=$(run_scan "$T/bad.out" "$T/bans.html" --bans "$T/bad.list")
[ "$rc" = 2 ] && pass "꼴이 틀린 금지 목록은 종료 2" || fail "꼴이 틀린 금지 목록 종료 ${rc} (기대 2)"
printf '%s\n' 'broken | 마크업 | 깨진 패턴 | (unclosed' > "$T/bad2.list"
rc=$(run_scan "$T/bad2.out" "$T/bans.html" --bans "$T/bad2.list")
[ "$rc" = 2 ] && pass "grep -E 로 읽히지 않는 패턴은 종료 2" || fail "깨진 패턴 종료 ${rc} (기대 2)"
rc=0; bash "$CHECK" scan >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && pass "화면 없는 scan 은 사용 오류 2" || fail "인자 없는 scan 종료 ${rc} (기대 2)"
printf '%s\n' '<!doctype html>' '<p>plain</p>' > "$T/clean.html"
rc=$(run_scan "$T/clean.out" "$T/clean.html")
[ "$rc" = 0 ] && pass "발견이 없으면 종료 0" || fail "발견 없는 화면 종료 ${rc} (기대 0)"

# --- scan tokens --------------------------------------------------------------
TOK="$fixtures/tokens.css"
# line_set <rule> <scan output> — the rule's line numbers on one line.
line_set() { lines_of "$1" "$2" | tr '\n' ' ' | sed 's/ $//'; }
rows_of() { { grep -E "^$1 " "$2" || true; } | grep -c . || true; }
# tok_screen <out> <tokens file> <mode> — a screen whose head holds the token
# block as <mode> says (one, two, changed, glued, noclose, none), then the
# screen's own style that only uses var(--…). With the fixture tokens file a
# one-block screen has the block on lines 3–16.
tok_screen() {
  local out=$1 tok=$2 mode=$3
  {
    echo '<!doctype html>'
    echo '<html><head>'
    case "$mode" in
      one|two) echo '<style data-cc-tokens>'; cat "$tok"; echo '</style>' ;;
      changed) echo '<style data-cc-tokens>'; sed 's/#123456/#123457/' "$tok"; echo '</style>' ;;
      glued) echo '<style data-cc-tokens>'; echo ':root { --color-bg: #123456; --color-fg: #f5f7fa; }</style>' ;;
      noclose) echo '<style data-cc-tokens>'; cat "$tok" ;;
    esac
    if [ "$mode" = two ]; then echo '<style data-cc-tokens>'; cat "$tok"; echo '</style>'; fi
    if [ "$mode" = glued ]; then
      echo '<style>body { margin: 0; background: var(--color-bg); } p { color: var(--color-fg); }</style>'
    elif [ "$mode" != noclose ]; then
      echo '<style>'
      echo 'body { margin: 0; background: var(--color-bg); }'
      echo 'p { color: var(--color-fg); }'
      echo '.x { background: var(--color-bg); }'
      echo '</style>'
    fi
    echo '</head><body><p>x</p></body></html>'
  } > "$out"
}
# 1 — the observed defect: no block, only var(--…) uses.
materialize "$fixtures/undefined.txt" "$T/undef.html" "$T/undef.labels"
rc=$(run_scan "$T/undef.out" "$T/undef.html")
[ "$rc" = 1 ] && pass "tokens 1: 정의 없는 변수가 있으면 --tokens 없이도 종료 1" || fail "tokens 1: undefined.txt scan 종료 ${rc} (기대 1)"
lines_of token-undefined "$T/undef.out" > "$T/undef.hit"
got=$(tally "$T/undef.labels" "$T/undef.hit" U)
[ "$got" = "5 5" ] && pass "tokens 1: 정의 없는 이름을 처음 참조한 줄마다 token-undefined (5)" || fail "tokens 1: U 줄 (전체 적중) = ${got}, 기대 5 5"
got=$(tally "$T/undef.labels" "$T/undef.hit" D)
[ "$got" = "7 0" ] && pass "tokens 1: 정의된 이름·둘째 이후 참조·마크업 속성·setProperty 정의는 지적하지 않는다 (7)" || fail "tokens 1: D 줄 (전체 오탐) = ${got}, 기대 7 0"
tok_screen "$T/tk-none.html" "$TOK" none
rc=$(run_scan "$T/tk-none.out" "$T/tk-none.html")
got=$(line_set token-undefined "$T/tk-none.out")
[ "$rc:$got" = "1:4 5" ] && pass "tokens 1: 블록 없는 화면은 이름마다 한 건 (줄 4·5, 종료 1)" || fail "tokens 1: 블록 없는 화면 = ${rc}:${got} (기대 1:4 5)"
# 2 — the block filled from tokens.css.
tok_screen "$T/tk-one.html" "$TOK" one
rc=$(run_scan "$T/tk-one.out" "$T/tk-one.html" --tokens "$TOK")
rows=$(grep -cvE '^# ' "$T/tk-one.out" || true)
[ "$rc:$rows" = "0:0" ] && pass "tokens 2: 일치하는 블록을 담은 화면은 --tokens 로 발견 0, 종료 0" || fail "tokens 2: --tokens = ${rc}, 발견 ${rows}: $(grep -vE '^# ' "$T/tk-one.out" | head -n 3)"
rc=$(run_scan "$T/tk-one.bare" "$T/tk-one.html")
got=$(line_set token-color "$T/tk-one.bare")
[ "$rc:$got" = "1:5 6 7 13 14" ] && pass "tokens 2: --tokens 없으면 블록 줄이 token-color 로 지적된다" || fail "tokens 2: --tokens 없음 = ${rc}:${got} (기대 1:5 6 7 13 14)"
[ "$(rows_of token-undefined "$T/tk-one.bare")" = 0 ] && pass "tokens 2: 블록이 정의하므로 token-undefined 는 없다" || fail "tokens 2: 블록 있는 화면에 token-undefined"
# 3 — one byte changed in the block.
tok_screen "$T/tk-chg.html" "$TOK" changed
rc=$(run_scan "$T/tk-chg.out" "$T/tk-chg.html" --tokens "$TOK")
[ "$rc:$(line_set token-block "$T/tk-chg.out")" = "1:3" ] && pass "tokens 3: 한 바이트 다른 블록은 여는 줄에 token-block" || fail "tokens 3: token-block = ${rc}:$(line_set token-block "$T/tk-chg.out") (기대 1:3)"
[ "$(line_set token-color "$T/tk-chg.out")" = "5 6 7 13 14" ] && pass "tokens 3: 다른 블록의 줄은 면제되지 않는다" || fail "tokens 3: token-color = $(line_set token-color "$T/tk-chg.out")"
# 4 — two blocks, no block, an opening line with no closing line.
tok_screen "$T/tk-two.html" "$TOK" two
rc=$(run_scan "$T/tk-two.out" "$T/tk-two.html" --tokens "$TOK")
[ "$(rows_of token-block "$T/tk-two.out"):$(line_set token-block "$T/tk-two.out")" = "1:17" ] && pass "tokens 4: 블록 둘은 둘째 여는 줄에 token-block 한 건" || fail "tokens 4: 블록 둘 = $(line_set token-block "$T/tk-two.out") (기대 17)"
[ "$(line_set token-color "$T/tk-two.out")" = "5 6 7 13 14 19 20 21 27 28" ] && pass "tokens 4: 블록이 둘이면 어느 블록 줄도 면제되지 않는다" || fail "tokens 4: 블록 둘 token-color = $(line_set token-color "$T/tk-two.out")"
rc=$(run_scan "$T/tk-none.tok" "$T/tk-none.html" --tokens "$TOK")
[ "$(rows_of token-block "$T/tk-none.tok"):$(line_set token-block "$T/tk-none.tok")" = "1:1" ] && pass "tokens 4: 블록 없는 화면은 1행에 token-block 한 건" || fail "tokens 4: 블록 없음 = $(line_set token-block "$T/tk-none.tok") (기대 1)"
tok_screen "$T/tk-glued.html" "$TOK" glued
rc=$(run_scan "$T/tk-glued.out" "$T/tk-glued.html" --tokens "$TOK")
[ "$(rows_of token-block "$T/tk-glued.out"):$(line_set token-block "$T/tk-glued.out")" = "1:1" ] && pass "tokens 4: 닫는 줄 없는 여는 줄은 블록이 아니다 (1행에 token-block 한 건)" || fail "tokens 4: 붙은 닫는 태그 = $(line_set token-block "$T/tk-glued.out") (기대 1)"
# 5 — an outside reference in the tokens file stays a finding.
{ cat "$TOK"; echo ':root { --img-hero: url(https://cdn.example.com/a.png); }'; } > "$T/tok-url.css"
tok_screen "$T/tk-url.html" "$T/tok-url.css" one
rc=$(run_scan "$T/tk-url.out" "$T/tk-url.html" --tokens "$T/tok-url.css")
[ "$rc:$(rows_of token-block "$T/tk-url.out"):$(line_set external-ref "$T/tk-url.out")" = "1:0:16" ] && pass "tokens 5: 블록이 일치해도 토큰 파일의 url() 은 external-ref" || fail "tokens 5: = ${rc}:$(rows_of token-block "$T/tk-url.out"):$(line_set external-ref "$T/tk-url.out") (기대 1:0:16)"
# 6 — input errors are exit 2 with the reason.
{ cat "$TOK"; echo '/* </STYLE> */'; } > "$T/tok-bad.css"
rc=$(run_scan "$T/tk-bad.out" "$T/tk-one.html" --tokens "$T/tok-bad.css")
[ "$rc" = 2 ] && grep -qF '</style 를 담아' "$T/tk-bad.out.err" && pass "tokens 6: </style 를 담은 토큰 파일은 종료 2 와 사유" || fail "tokens 6: </style 토큰 파일 = ${rc} $(cat "$T/tk-bad.out.err")"
rc=$(run_scan "$T/tk-miss.out" "$T/tk-one.html" --tokens "$T/no-such-tokens.css")
[ "$rc" = 2 ] && grep -qF '토큰 파일이 없다' "$T/tk-miss.out.err" && pass "tokens 6: 없는 토큰 파일은 종료 2 와 사유" || fail "tokens 6: 없는 토큰 파일 = ${rc} $(cat "$T/tk-miss.out.err")"
tok_screen "$T/tk-open.html" "$TOK" noclose
rc=$(run_scan "$T/tk-open.out" "$T/tk-open.html" --tokens "$TOK")
[ "$rc" = 2 ] && grep -qF '<style> 이 닫히지 않았다' "$T/tk-open.out.err" && pass "tokens 6: 여는 줄 뒤에 </style 이 없는 화면은 종료 2 와 사유" || fail "tokens 6: 닫히지 않은 블록 = ${rc} $(cat "$T/tk-open.out.err")"
# 7 — setProperty defines; a fallback does not.
printf '%s\n' '<!doctype html>' '<style>.a { background: var(--x); }' '.b { color: var(--y, #fff); }' '</style>' \
  "<script>document.documentElement.style.setProperty('--x', v);</script>" > "$T/tk-js.html"
rc=$(run_scan "$T/tk-js.out" "$T/tk-js.html")
[ "$(line_set token-undefined "$T/tk-js.out")" = 3 ] && pass "tokens 7: setProperty 로 정한 이름은 지적하지 않고, 대체값 있는 정의 없는 이름은 지적한다" || fail "tokens 7: token-undefined = $(line_set token-undefined "$T/tk-js.out") (기대 3)"
grep -qE '^token-color [^ ]*:3 ' "$T/tk-js.out" && pass "tokens 7: 같은 줄의 대체값 리터럴은 token-color 로도 나온다" || fail "tokens 7: 3행 token-color 가 없다"
# 8 — the third header line.
grep -qxF "# 토큰 블록: $TOK 와 대조" "$T/tk-one.out" && pass "tokens 8: --tokens 가 있으면 대조한 토큰 파일을 머리에 적는다" || fail "tokens 8: 머리 셋째 줄 = $(sed -n 3p "$T/tk-one.out")"
grep -qxF '# 토큰 블록: 대조 안 함 (--tokens 없음)' "$T/tk-none.out" && pass "tokens 8: --tokens 가 없으면 대조 안 함을 머리에 적는다" || fail "tokens 8: 머리 셋째 줄 = $(sed -n 3p "$T/tk-none.out")"
[ "$(sed -n 3p "$T/tk-none.out")" = '# 토큰 블록: 대조 안 함 (--tokens 없음)' ] && pass "tokens 8: 토큰 블록 줄은 머리 셋째 줄이다" || fail "tokens 8: 셋째 줄이 토큰 블록 줄이 아니다"

# --- scan leak ----------------------------------------------------------------
materialize "$fixtures/leak.txt" "$T/leak.html" "$T/leak.labels"
rc=$(run_scan "$T/leak.out" "$T/leak.html")
[ "$rc" = 1 ] && pass "문자열 안의 /* 뒤에도 발견이 있어 종료 1" || fail "leak scan 종료 ${rc} (기대 1)"
lines_of token-color "$T/leak.out" > "$T/leak.color"
lines_of external-ref "$T/leak.out" > "$T/leak.ref"
got=$(tally "$T/leak.labels" "$T/leak.color" V)
[ "$got" = "18 18" ] && pass "문자열·중첩 템플릿·정규식·붙여 쓴 줄 주석 안의 /* 와 </script>, 따옴표 없는 속성값의 아포스트로피, 다음 줄로 넘어간 여는 태그 속성, 이름이 다른 태그와 닫는 태그 뒤의 색이 모두 잡힌다 (18)" \
  || fail "leak V 줄 (전체 적중) = ${got}, 기대 18 18"
[ ! -s "$T/leak.out.err" ] && pass "leak scan 의 stderr 는 비어 있다" \
  || fail "leak scan stderr: $(head -n 1 "$T/leak.out.err")"
got=$(tally "$T/leak.labels" "$T/leak.ref" R)
[ "$got" = "5 5" ] && pass "닫는 태그·정규식·중첩 템플릿 뒤와 다음 줄로 넘어간 여는 태그 속성 뒤의 외부 참조가 모두 잡힌다 (5)" \
  || fail "leak R 줄 (전체 적중) = ${got}, 기대 5 5"
# eof_case <name> <expected stderr reason> <screen lines...> — scan and size
# both refuse a screen whose parse ends open, with exit 2 and the reason.
eof_case() {
  local name=$1 why=$2 rc
  shift 2
  printf '%s\n' "$@" > "$T/eof.html"
  rc=$(run_scan "$T/eof.out" "$T/eof.html")
  if [ "$rc" = 2 ] && grep -qF "파싱을 잃었다 — ${why}" "$T/eof.out.err"; then
    pass "scan: ${name} 은 종료 2 와 이유"
  else
    fail "scan: ${name} 종료 ${rc} (기대 2, 이유 '${why}')"
  fi
  rc=0; bash "$CHECK" size "$T/eof.html" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && pass "size: ${name} 은 종료 2" || fail "size: ${name} 종료 ${rc} (기대 2)"
}
eof_case "열린 CSS 주석" "CSS 주석이 닫히지 않았다" '<style>.a { color: red; } /* open' '<p style="color: #fff">x</p>'
eof_case "열린 스크립트 주석" "스크립트 주석이 닫히지 않았다" '<script>var a = 1; /* open' 'var b = "#fff";'
eof_case "닫히지 않은 <script>" "<script> 가 닫히지 않았다" '<script>var a = 1;' 'var b = "#fff";'
eof_case "닫히지 않은 <style>" "<style> 이 닫히지 않았다" '<style>.a { color: #fff; }'
eof_case "열린 HTML 주석" "HTML 주석이 닫히지 않았다" '<p>a</p>' '<!-- open' '<p style="color: #fff">x</p>'
eof_case "열린 템플릿 문자열" "스크립트 템플릿 문자열이 닫히지 않았다" '<script>var t = `open' 'var b = "#fff";'
eof_case "열린 템플릿 치환" "스크립트 템플릿 문자열이 닫히지 않았다" '<script>var t = `a ${f({k: 1})' 'var b = "#fff";'
eof_case "</script> 앞에서 열린 템플릿 문자열" "스크립트 템플릿 문자열이 </script> 앞에서 닫히지 않았다" '<script>var t = `open' '</script>' '<p style="color: #fff">x</p>'
eof_case "닫히지 않은 태그" "태그가 닫히지 않았다" '<p>a</p>' '<img src="https://cdn.example.com/a.png'
eof_case "</script> 앞에서 열린 스크립트 주석" "스크립트 주석이 </script> 앞에서 닫히지 않았다" '<script>var a = 1; /* open' '</script>' '<p style="color: #fff">x</p>'
eof_case "</style> 앞에서 열린 CSS 주석" "CSS 주석이 </style> 앞에서 닫히지 않았다" '<style>.a { color: red; } /* open' '</style>' '<p style="color: #fff">x</p>'
eof_case "닫는 따옴표 앞에서 열린 style 속성 주석" "style 속성의 CSS 주석이 닫히지 않았다" '<p style="color: red; /* open">x</p>' '<p style="color: #fff">y</p>'
# A quote inside an unquoted attribute value is text: the screen is scanned,
# not refused, and the finding on the next line is kept.
printf '%s\n' "<p title=don't>hi</p>" '<p style="color: #fff">x</p>' > "$T/unq.html"
rc=$(run_scan "$T/unq.out" "$T/unq.html")
if [ "$rc" = 1 ] && [ ! -s "$T/unq.out.err" ] && [ "$(lines_of token-color "$T/unq.out")" = 2 ]; then
  pass "따옴표 없는 속성값의 아포스트로피는 텍스트다 (종료 1, 다음 줄 발견)"
else
  fail "따옴표 없는 속성값의 아포스트로피 scan 종료 ${rc} (기대 1, 빈 stderr, 2행 발견)"
fi

# --- scan hangul --------------------------------------------------------------
# Hangul in a script string or comment, a CSS string or comment, a style
# attribute and body text is parsed, not refused, under a UTF-8 locale — the
# locale where a byte-wise awk cuts a character in half.
utf8=$(locale -a 2>/dev/null | grep -ixE 'en_US\.utf-?8|c\.utf-?8' | sed -n '1p' || true)
if [ -z "$utf8" ]; then
  fail "UTF-8 로캘이 없어 한글 화면을 잴 수 없다"
else
  materialize "$fixtures/hangul.txt" "$T/hangul.html" "$T/hangul.labels"
  rc=0; LANG="$utf8" LC_ALL="$utf8" bash "$CHECK" scan "$T/hangul.html" > "$T/hangul.out" 2> "$T/hangul.out.err" || rc=$?
  if [ "$rc" = 1 ] && [ ! -s "$T/hangul.out.err" ]; then
    pass "한글 화면 scan 은 종료 1 이고 stderr 가 비어 있다 (${utf8})"
  else
    fail "한글 화면 scan 종료 ${rc} (기대 1, 빈 stderr): $(head -n 1 "$T/hangul.out.err")"
  fi
  lines_of token-color "$T/hangul.out" > "$T/hangul.color"
  lines_of external-ref "$T/hangul.out" > "$T/hangul.ref"
  got=$(tally "$T/hangul.labels" "$T/hangul.color" V)
  [ "$got" = "5 5" ] && pass "한글 문자열·주석 뒤의 색이 모두 잡힌다 (5)" || fail "hangul V 줄 (전체 적중) = ${got}, 기대 5 5"
  got=$(tally "$T/hangul.labels" "$T/hangul.ref" R)
  [ "$got" = "1 1" ] && pass "한글 주석 뒤의 스크립트 외부 참조가 잡힌다" || fail "hangul R 줄 (전체 적중) = ${got}, 기대 1 1"
  grep -qF '본문의 한글 문장' "$T/hangul.html" && ! grep -q '본문의' "$T/hangul.out" \
    && pass "한글 본문 문장은 발견이 아니다" || fail "한글 본문 문장이 발견으로 잡혔다"
  grep -qE "^token-color [^ ]*:15 <p style=\"content:'안내'; color: red\">한글</p>$" "$T/hangul.out" \
    && pass "발견 줄의 한글 문면이 바이트 그대로 보존된다" || fail "발견 줄의 한글 문면이 원문과 다르다"
  rc=0; got=$(LANG="$utf8" LC_ALL="$utf8" bash "$CHECK" size "$T/hangul.html" 2> "$T/hangul.size.err") || rc=$?
  [ "$rc:$got" = "0:5" ] && [ ! -s "$T/hangul.size.err" ] && pass "한글 화면 size 는 종료 0 (5)" \
    || fail "한글 화면 size = ${rc}:${got} (기대 0:5): $(head -n 1 "$T/hangul.size.err")"
fi

# --- size ---------------------------------------------------------------------
printf '%s\n' '<!doctype html>' '<html><body>' '<!-- <div><div><div> -->' '<div><p>a</p><p>b</p></div>' \
  '<script>if (a<b) { x = "<span>"; }</script>' '</body></html>' > "$T/size.html"
got=$(bash "$CHECK" size "$T/size.html")
[ "$got" = 6 ] && pass "size 는 주석·스크립트 밖의 시작 태그 수 (6)" || fail "size = ${got}, 기대 6"

# --- approval -----------------------------------------------------------------
R="$T/repo"
mkdir -p "$R/docs/visual" "$R/docs/visual-system"
(cd "$R" && git init -q && git config user.email t@example.com && git config user.name t)
printf '%s\n' '# 설계' > "$R/docs/feature.md"
printf '%s\n' '<!doctype html><p>home</p>' > "$R/docs/visual/docs-feature.home.html"
printf '%s\n' '<!doctype html><p>list</p>' > "$R/docs/visual/docs-feature.list.html"
printf '%s\n' '/* runtime */' > "$R/docs/visual/support.js"
printf '%s\n' ':root { --c: #000; }' > "$R/docs/visual-system/tokens.css"
DOC="$R/docs/feature.md"
SC="$R/docs/visual/docs-feature.md"
write_sidecar() { # <state> <approval line or ->
  {
    echo "# 시각 디자인 연결 — docs/feature.md"
    echo "<!-- cc-visual v1; writer=visual|visual-unattended; reader=implement,implement-unattended; owner-doc=docs/feature.md; origin-worktree=$R; NOT a design doc; mechanism-local, never staged by a skill -->"
    echo "**상태**: $1"
    [ "$2" = - ] || echo "$2"
    echo
    echo "### 화면 list"
    echo "**대상 경로**: src/list.html"
    echo
    echo "### 화면 home"
    echo "**대상 경로**: src/home.html"
  } > "$SC"
}
approval() { local rc=0; bash "$CHECK" approval "$DOC" > "$T/ap.out" 2>&1 || rc=$?; echo "$rc $(head -n 1 "$T/ap.out")"; }

got=$(approval)
case "$got" in "1 승인 없음 — 사이드카 없음"*) pass "approval: 사이드카 없음" ;; *) fail "approval 사이드카 없음 = ${got}" ;; esac
write_sidecar '검토 통과' -
got=$(approval)
case "$got" in "1 승인 없음 — 상태가 발행됨이 아니다"*) pass "approval: 상태가 발행됨 아님" ;; *) fail "approval 상태 = ${got}" ;; esac
write_sidecar 발행됨 -
got=$(approval)
[ "$got" = "1 승인 없음 — 구현 승인 줄 없음" ] && pass "approval: 승인 줄 없음" || fail "approval 승인 줄 없음 = ${got}"

bash "$CHECK" bundle "$DOC" --lines > "$T/bundle.txt"
{
  printf 'home %s\n' "$(shasum -a 256 "$R/docs/visual/docs-feature.home.html" | awk '{print $1}')"
  printf 'list %s\n' "$(shasum -a 256 "$R/docs/visual/docs-feature.list.html" | awk '{print $1}')"
  printf 'runtime %s\n' "$(shasum -a 256 "$R/docs/visual/support.js" | awk '{print $1}')"
  printf 'tokens %s\n' "$(shasum -a 256 "$R/docs/visual-system/tokens.css" | awk '{print $1}')"
} > "$T/bundle.want"
cmp -s "$T/bundle.txt" "$T/bundle.want" && pass "bundle --lines 는 화면 id 순 줄과 runtime·tokens 줄" || fail "bundle --lines 문면이 기대와 다르다"
B=$(bash "$CHECK" bundle "$DOC")
[ "$B" = "$(shasum -a 256 < "$T/bundle.want" | awk '{print $1}')" ] && pass "bundle 은 묶음 문면의 sha256" || fail "bundle 다이제스트가 문면의 sha256 이 아니다"
BANSHA=$(shasum -a 256 "$SEED" | awk '{print $1}')
write_sidecar 발행됨 "**구현 승인**: 2026-10-12T09:00:00Z — 입력 묶음 ${B} — 금지 목록 ${BANSHA} — 기계 검사 수용 token-space, pill-button"
got=$(approval)
[ "$got" = "0 승인 유효 ${B:0:12}" ] && pass "approval: 유효" || fail "approval 유효 = ${got}"
[ "$(wc -l < "$T/ap.out" | tr -d ' ')" = "1" ] && pass "approval: 출처 꼬리 없는 줄은 한 줄만 찍는다" || fail "approval 꼬리 없음 출력 = $(cat "$T/ap.out")"
# The provenance tail ` — 사람 답 <file name>`: a valid line keeps its first
# line and prints the record's name on a second.
APL="**구현 승인**: 2026-10-12T09:00:00Z — 입력 묶음 ${B} — 금지 목록 ${BANSHA} — 기계 검사 수용 없음"
write_sidecar 발행됨 "${APL} — 사람 답 S2P#3.md"
got=$(approval)
[ "$got" = "0 승인 유효 ${B:0:12}" ] && pass "approval: 출처 꼬리 달린 줄도 유효" || fail "approval 꼬리 유효 = ${got}"
[ "$(sed -n 2p "$T/ap.out")" = "출처 사람 답 S2P#3.md" ] && pass "approval: 꼬리가 있으면 둘째 줄에 출처 사람 답" || fail "approval 둘째 줄 = $(sed -n 2p "$T/ap.out")"
for badtail in ' — 사람 답 S2P #3.md' ' — 사람 답 halt/S2P#3.md' ' — 사람 답 S2P#3' ' — 사람 답 '; do
  write_sidecar 발행됨 "${APL}${badtail}"
  got=$(approval)
  case "$got" in "1 승인 무효 — 구현 승인 줄의 형식이 틀렸다"*) pass "approval: 잘못된 꼬리 「${badtail}」 는 형식 무효" ;; *) fail "approval 잘못된 꼬리 「${badtail}」 = ${got}" ;; esac
done
write_sidecar 발행됨 "**구현 승인**: 2026-10-12T09:00:00Z — 입력 묶음 ${B} — 금지 목록 ${BANSHA} — 기계 검사 수용 token-space, pill-button"
printf '%s\n' '<!doctype html><p>home!</p>' > "$R/docs/visual/docs-feature.home.html"
got=$(approval)
case "$got" in "1 승인 무효 — 입력 묶음이 달라졌다"*) pass "approval: 화면 한 바이트가 바뀌면 다이제스트 불일치" ;; *) fail "approval 다이제스트 불일치 = ${got}" ;; esac
write_sidecar 발행됨 "**구현 승인**: 2026-10-12T09:00:00Z — 입력 묶음 ${B} — 금지 목록 ${BANSHA}"
got=$(approval)
case "$got" in "1 승인 무효 — 구현 승인 줄의 형식이 틀렸다"*) pass "approval: 형식이 틀린 줄은 무효" ;; *) fail "approval 형식 = ${got}" ;; esac

# --- approval: the `**문서 반영**` line ----------------------------------------
# Read only after the six checks pass: no line, `불요` and `완료` keep the
# approval valid, `대기` and `실패` hold it, and a repeated, misplaced or
# malformed line voids it — each value with and without the provenance tail.
printf '%s\n' '<!doctype html><p>home</p>' > "$R/docs/visual/docs-feature.home.html"
SHA64=$(printf 'x' | shasum -a 256 | awk '{print $1}')
refl_case() { # <label> <want: "rc first line"> <lines under the approval line>
  write_sidecar 발행됨 "$(printf '%s\n%s' "$APL" "$3")"
  got=$(approval)
  [ "$got" = "$2" ] && pass "approval 문서 반영: $1" || fail "approval 문서 반영 $1 = ${got} (기대 $2)"
}
VALID="0 승인 유효 ${B:0:12}"
write_sidecar 발행됨 "$APL"
got=$(approval)
[ "$got" = "$VALID" ] && pass "approval 문서 반영: 줄이 없으면 기존대로 유효" || fail "approval 문서 반영 줄 없음 = ${got}"
refl_case "불요" "$VALID" "**문서 반영**: 불요"
refl_case "불요 + 꼬리" "$VALID" "**문서 반영**: 불요 — 사람 답 S2P#3.md"
refl_case "완료" "$VALID" "**문서 반영**: 완료 — 문서 sha256 ${SHA64}"
refl_case "완료 + 꼬리" "$VALID" "**문서 반영**: 완료 — 문서 sha256 ${SHA64} — 사람 답 S2P#3.md"
refl_case "대기" "1 승인 보류 — 설계 문서 반영 대기" "**문서 반영**: 대기 — 어긋남 2건"
refl_case "대기 + 꼬리" "1 승인 보류 — 설계 문서 반영 대기" "**문서 반영**: 대기 — 어긋남 2건 — 사람 답 S2P#3.md"
refl_case "실패" "1 승인 보류 — 설계 문서 반영 실패 — 다른 구속 결정과 충돌" "**문서 반영**: 실패 — 다른 구속 결정과 충돌"
refl_case "실패 + 꼬리" "1 승인 보류 — 설계 문서 반영 실패 — 다른 구속 결정과 충돌" "**문서 반영**: 실패 — 다른 구속 결정과 충돌 — 사람 답 S2P#3.md"
BADFORM="1 승인 무효 — 문서 반영 줄 형식 오류"
refl_case "두 줄은 형식 오류" "$BADFORM" "$(printf '%s\n%s' '**문서 반영**: 불요' '**문서 반영**: 불요')"
refl_case "승인 줄 바로 아래가 아니면 형식 오류" "$BADFORM" "$(printf '%s\n%s' '' '**문서 반영**: 불요')"
refl_case "모르는 값은 형식 오류" "$BADFORM" "**문서 반영**: 보류 — 사람 답 S2P#3.md"
refl_case "완료의 해시가 64 hex 가 아니면 형식 오류" "$BADFORM" "**문서 반영**: 완료 — 문서 sha256 abc"
refl_case "대기의 건수가 없으면 형식 오류" "$BADFORM" "**문서 반영**: 대기 — 어긋남 건"
refl_case "꼬리의 파일 이름에 경로가 있으면 형식 오류" "$BADFORM" "**문서 반영**: 불요 — 사람 답 halt/S2P#3.md"
refl_case "실패 사유가 꼬리를 담으면 형식 오류" "$BADFORM" "**문서 반영**: 실패 — 충돌 — 사람 답 S2P#2.md — 사람 답 S2P#3.md"
refl_case "실패 사유가 비면 형식 오류" "$BADFORM" "**문서 반영**: 실패 — "
printf '%s\n' '<!doctype html><p>home!</p>' > "$R/docs/visual/docs-feature.home.html"
refl_case "기존 검사가 먼저 — 묶음이 다르면 반영 줄보다 묶음 불일치" "1 승인 무효 — 입력 묶음이 달라졌다 (줄 ${B:0:12}, 지금 $(bash "$CHECK" bundle "$DOC" | cut -c1-12))" "**문서 반영**: 대기 — 어긋남 1건"
printf '%s\n' '<!doctype html><p>home</p>' > "$R/docs/visual/docs-feature.home.html"

# --- drift --------------------------------------------------------------------
# The block's count and digest (the body up to the next `### ` heading or the
# end of the file, normalized as the binding digest is), its absence (exit 1),
# and the check that each line's document side is in the document (exit 2).
DFEAT=$(cat "$DOC")
{
  printf '# 설계\n\n## 합의된 아키텍처\n\n### 흐름\n\n첫 화면은 목록을 보인다.\n\n#### 세부\n\n세부 문장 하나.\n\n'
  printf '```text\n울타리 안 문장\n# 울타리 안 제목\n```\n\n### 다른 절\n\n다른 문장.\n\n### 중복\n\n하나\n\n## 주요 결정사항과 근거\n\n### 중복\n\n둘\n'
} > "$DOC"
drift_sidecar() { # <block body> <end|mid>
  write_sidecar 발행됨 "$APL"
  if [ "$2" = mid ]; then
    { echo; echo "### 설계 문서 어긋남"; printf '%s\n' "$1"; echo "### 금지 후보"; echo "- \`x\` | 판단 | y | - — 1회 home"; } >> "$SC"
  else
    { echo; echo "### 설계 문서 어긋남"; printf '%s' "$1"; } >> "$SC"
  fi
}
drift() { local rc=0; bash "$CHECK" drift "$DOC" > "$T/dr.out" 2>&1 || rc=$?; echo "$rc"; }
GOODL1='- home · 흐름 · 「첫 화면은 목록을 보인다.」 → 「첫 화면은 카드를 보인다.」'
GOODL2='- home · 흐름 · 「세부 문장 하나.」 → (삭제)'
GOODL3='- list · 흐름 · 「울타리 안 문장」 → 「울타리 밖 문장」'
GOODL4='- list · 다른 절 · 「(없음)」 → 「새 문장」'
GOOD=$(printf '%s\n%s\n%s\n%s' "$GOODL1" "$GOODL2" "$GOODL3" "$GOODL4")
GOODSHA=$(printf '%s\n' "$GOOD" | shasum -a 256 | awk '{print $1}')
drift_sidecar "$(printf '\n\n%s   \n%s\n%s\n%s\n\n' "$GOODL1" "$GOODL2" "$GOODL3" "$GOODL4")" mid
rc=$(drift)
[ "$rc:$(cat "$T/dr.out")" = "0:어긋남 4건 · sha256 ${GOODSHA}" ] && pass "drift: 하위 제목 본문·코드 울타리 안 문면·「(없음)」 을 지나 건수와 정규화한 본문의 해시" || fail "drift 통과 = ${rc} $(cat "$T/dr.out")"
drift_sidecar "$(printf '%s\r\n\n' "$GOOD")" end
rc=$(drift)
[ "$rc:$(cat "$T/dr.out")" = "0:어긋남 4건 · sha256 ${GOODSHA}" ] && pass "drift: 파일 끝에서 끝나는 블록도 같은 해시 (CR·끝 빈 줄 정규화)" || fail "drift 파일 끝 = ${rc} $(cat "$T/dr.out")"
drift_sidecar "없음" mid
rc=$(drift)
[ "$rc:$(cat "$T/dr.out")" = "0:어긋남 0건 · sha256 $(printf '없음\n' | shasum -a 256 | awk '{print $1}')" ] && pass "drift: 본문이 없음 한 줄이면 0건" || fail "drift 없음 = ${rc} $(cat "$T/dr.out")"
write_sidecar 발행됨 "$APL"
rc=$(drift)
[ "$rc" = 1 ] && pass "drift: 블록이 없으면 종료 1" || fail "drift 블록 없음 = ${rc} $(cat "$T/dr.out")"
for badl in '- list · 없는 절 · 「다른 문장.」 → 「b」' '- list · 중복 · 「하나」 → 「b」' \
  '- list · 다른 절 · 「첫 화면은 목록을 보인다.」 → 「b」' '- home · 흐름 · 「다른 문장.」 → 「b」' \
  '- list · 울타리 안 제목 · 「(없음)」 → 「b」' '- list · 흐름 「세부 문장 하나.」 → 「b」'; do
  drift_sidecar "$(printf '%s\n%s' "$GOODL1" "$badl")" mid
  rc=$(drift)
  [ "$rc:$(cat "$T/dr.out")" = "2:${badl}" ] && pass "drift: 「${badl}」 는 찾지 못해 그 줄을 찍고 종료 2" || fail "drift 「${badl}」 = ${rc} $(cat "$T/dr.out")"
done

# --- reflection transitions ---------------------------------------------------
# The sidecar placed by hand through `대기` → `완료` and `대기` → `실패`: the
# predicate holds while waiting and after a failure, and is valid again once
# the edited document's hash is on the `완료` line.
drift_sidecar "$GOOD" mid
cp "$SC" "$T/sc.wait"
DSHA0=$(shasum -a 256 "$DOC" | awk '{print $1}')
awk -v l="**문서 반영**: 대기 — 어긋남 4건 — 사람 답 S2P#3.md" '{ print } index($0, "**구현 승인**:") == 1 { print l }' "$T/sc.wait" > "$SC"
got=$(approval)
[ "$got" = "1 승인 보류 — 설계 문서 반영 대기" ] && pass "전이: 대기 동안 승인 보류" || fail "전이 대기 = ${got}"
cp "$SC" "$T/sc.wait2"
awk '{ sub(/첫 화면은 목록을 보인다\./, "첫 화면은 카드를 보인다.") } { print }' "$DOC" > "$T/doc.new" && mv "$T/doc.new" "$DOC"
DSHA1=$(shasum -a 256 "$DOC" | awk '{print $1}')
[ "$DSHA0" != "$DSHA1" ] && pass "전이: 반영 뒤 문서 해시가 바뀐다" || fail "전이: 반영 뒤에도 문서 해시가 같다"
awk -v l="**문서 반영**: 완료 — 문서 sha256 ${DSHA1} — 사람 답 S2P#3.md" 'index($0, "**문서 반영**:") == 1 { print l; next } { print }' "$T/sc.wait2" > "$SC"
got=$(approval)
[ "$got" = "$VALID" ] && pass "전이: 대기 → 완료 뒤 승인 유효" || fail "전이 완료 = ${got}"
awk -v l="**문서 반영**: 실패 — 다른 구속 결정과 충돌 — 사람 답 S2P#3.md" 'index($0, "**문서 반영**:") == 1 { print l; next } { print }' "$T/sc.wait2" > "$SC"
got=$(approval)
[ "$got" = "1 승인 보류 — 설계 문서 반영 실패 — 다른 구속 결정과 충돌" ] && pass "전이: 대기 → 실패 뒤 승인 보류" || fail "전이 실패 = ${got}"
printf '%s\n' "$DFEAT" > "$DOC"

# --- binding ------------------------------------------------------------------
# The digest the sidecar carries is the driver's `binding_digest` with the
# `## 시각 정합 기준` section dropped: equal to the driver's value on a document
# without that section, and blind to that section where it is present.
DRIVER="$repo_root/plugins/cc-cmds/orchestrator/run.sh"
RR="$T/rrepo"
mkdir -p "$RR/docs/visual" "$RR/docs/visual-system" "$RR/docs/pipeline-run"
(cd "$RR" && git init -q)
RDOC="$RR/docs/reuse.md"
{
  printf '# 재사용 설계\n\n**상태**: 동결됨\n\n## 합의된 아키텍처\n\n본문   \n\n\n'
  printf '## 구현 시 검증 항목\n\n### R1. 항목\n**검증 등급**: 구현 시 검증\n- 검증 등급: 구현 시 검증\n'
} > "$RDOC"
drv_binding() {
  (cd "$RR" && CC_ORCH_SOURCE_ONLY=1 bash -c 'd=$1; m=$2; set --; . "$d" >/dev/null 2>&1; set +e; DOC=$m; binding_digest' _ "$DRIVER" "$1" 2>/dev/null)
}
rc=0; VB=$(bash "$CHECK" binding "$RDOC" 2>/dev/null) || rc=$?
DB=$(drv_binding "$RDOC")
if [ "$rc" = 0 ] && [[ "$VB" =~ ^[0-9a-f]{64}$ ]] && [ "$VB" = "$DB" ]; then
  pass "binding: 시각 정합 기준 절이 없는 문서에서 드라이버 binding_digest 와 같다"
else
  fail "binding = ${rc} ${VB}, 드라이버 ${DB}"
fi
cp "$RDOC" "$T/rdoc.save"
printf '\n## 시각 정합 기준\n\n- 화면 home 은 시안과 같다\n\n## 맺음\n\n끝\n' >> "$RDOC"
VB2=$(bash "$CHECK" binding "$RDOC")
{ cat "$T/rdoc.save"; printf '\n## 맺음\n\n끝\n'; } > "$T/rdoc.novis.md"
cp "$T/rdoc.novis.md" "$RR/docs/novis.md"
VB3=$(bash "$CHECK" binding "$RR/docs/novis.md")
[ "$VB2" = "$VB3" ] && pass "binding: 시각 정합 기준 절은 값에 들지 않는다" || fail "binding: 시각 정합 기준 절이 값을 바꿨다 (${VB2} ≠ ${VB3})"
[ "$VB2" != "$(drv_binding "$RDOC")" ] && pass "binding: 그 절이 있으면 드라이버 값과는 다르다 (위 단언이 공허하지 않다)" || fail "binding: 시각 정합 기준 절이 있는데도 드라이버 값과 같다"
rm -f "$RR/docs/novis.md"
rc=0; bash "$CHECK" binding > /dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && pass "binding: 인자가 없으면 2" || fail "binding 인자 없음 = ${rc}"

# --- reuse --------------------------------------------------------------------
# Each condition broken once against a sidecar where all hold, and no byte of
# the sidecar, the record, a screen file, system.md or tokens.css moves in any
# case.
RSC="$RR/docs/visual/docs-reuse.md"
REC="$RR/docs/pipeline-run/RUN2.interview.md"
RSYS="$RR/docs/visual-system/system.md"
RTOK="$RR/docs/visual-system/tokens.css"
printf '# 파이프라인 런 인터뷰 기록 — RUN1\n\n원천 기록\n' > "$REC"
printf '%s\n' '<!doctype html><p>home</p>' > "$RR/docs/visual/docs-reuse.home.html"
printf '%s\n' '<!doctype html><p>list</p>' > "$RR/docs/visual/docs-reuse.list.html"
printf '%s\n' ':root { --c: #111; }' > "$RTOK"
sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }
# write_system [<line>=<value>] — system.md as the generation stage writes it,
# unpublished, with one line replaced when given (`art`, `src`, `tok`), or a
# `**금지 해제**` line added (`lift`).
write_system() {
  local kv="${1:-}" k v art src tok
  k=${kv%%=*}; v=${kv#*=}
  art='(미발행)'; src='신규'; tok=$(sha_of "$RTOK")
  case "$k" in art) art=$v ;; src) src=$v ;; tok) tok=$v ;; esac
  {
    printf '# 디자인 시스템 연결 — %s\n' "$RR"
    echo "<!-- cc-visual-system v1; writer=visual-unattended; reader=visual; owner-doc=(없음); owner-repo=$RR; NOT a design doc; mechanism-local, never staged by a skill -->"
    echo "**아티팩트**: $art"
    echo "**출처**: $src"
    [ "$k" != conf ] || printf '%s\n' "$v"
    echo "**tokens.css sha256**: $tok"
    [ "$k" != lift ] || echo "**금지 해제**: $v"
  } > "$RSYS"
}
write_system
RB=$(bash "$CHECK" binding "$RDOC")
# write_reuse <state> [<field>=<value>] — the sidecar with every field matching,
# one field replaced when given (`head`, `owner`, `rec`, `bind`, `sys`, `home`).
write_reuse() {
  local st="$1" kv="${2:-}" k v head owner rec bind sys home
  k=${kv%%=*}; v=${kv#*=}
  head='cc-visual v1'; owner='docs/reuse.md'
  rec="docs/pipeline-run/RUN1.interview.md (sha256 $(sha_of "$REC"))"
  bind=$RB; sys=$(bash "$CHECK" system "$RDOC"); home=$(sha_of "$RR/docs/visual/docs-reuse.home.html")
  case "$k" in
    head) head=$v ;; owner) owner=$v ;; rec) rec=$v ;; bind) bind=$v ;; sys) sys=$v ;; home) home=$v ;;
  esac
  {
    echo "# 시각 디자인 연결 — docs/reuse.md"
    echo "<!-- ${head}; writer=visual-unattended; reader=visual; owner-doc=${owner}; origin-worktree=$RR; NOT a design doc; mechanism-local, never staged by a skill -->"
    echo "**상태**: $st"
    echo "**기록**: $rec"
    echo "**설계 문서 구속 다이제스트**: $bind"
    echo "**디자인 시스템 sha256**: $sys"
    echo
    echo "### 화면 home"
    echo "**대상 경로**: docs/visual/docs-reuse.home.html"
    echo "**sha256**: $home"
    echo
    echo "### 화면 list"
    echo "**대상 경로**: docs/visual/docs-reuse.list.html"
    echo "**sha256**: $(sha_of "$RR/docs/visual/docs-reuse.list.html")"
    echo
    echo "### 금지 후보"
  } > "$RSC"
}
reuse_sums() { for f in "$RSC" "$REC" "$RR/docs/visual/docs-reuse.home.html" "$RR/docs/visual/docs-reuse.list.html" "$RSYS" "$RTOK"; do [ -f "$f" ] && sha_of "$f" || echo 없음; done; }
# reuse_case <label> <want rc> <want first line prefix> — runs reuse and checks
# the answer and that no file it reads moved.
reuse_case() {
  local before after rc=0 out
  before=$(reuse_sums)
  out=$(bash "$CHECK" reuse "$RDOC" --record "$REC" 2>&1) || rc=$?
  after=$(reuse_sums)
  case "$rc $out" in "$2 $3"*) pass "reuse: $1" ;; *) fail "reuse $1 = ${rc} ${out}" ;; esac
  [ "$before" = "$after" ] && pass "reuse: $1 — 사이드카·기록·화면 파일이 그대로다" || fail "reuse: $1 — 파일이 바뀌었다"
}
reuse_case "사이드카가 없으면 재사용 불가" 1 "재사용 불가 — 사이드카 없음"
write_reuse '검토 통과'
reuse_case "모두 맞는 검토 통과 사이드카는 재사용" 0 "재사용 검토 통과"
write_reuse 발행됨
reuse_case "모두 맞는 발행됨 사이드카는 재사용" 0 "재사용 발행됨"
write_reuse 발행됨 'head=cc-visual v2'
reuse_case "머리가 cc-visual v1 이 아니면 재사용 불가" 1 "재사용 불가 — 사이드카 머리가 cc-visual v1 이 아니다"
write_reuse 발행됨 'owner=docs/other.md'
reuse_case "owner-doc 이 다른 문서면 재사용 불가" 1 "재사용 불가 — 사이드카의 owner-doc 이 이 문서가 아니다"
write_reuse '로컬 초안'
reuse_case "상태가 로컬 초안이면 재사용 불가" 1 "재사용 불가 — 상태가 검토 통과·발행됨이 아니다 (로컬 초안)"
write_reuse 발행됨 "rec=docs/pipeline-run/RUN2.interview.md (sha256 $(printf 'x' | shasum -a 256 | awk '{print $1}'))"
reuse_case "기록 sha256 이 다르면 재사용 불가 (경로가 새 런과 같아도)" 1 "재사용 불가 — 기록의 sha256 이 다르다"
write_reuse 발행됨 'rec=(없음)'
reuse_case "기록이 (없음)이면 재사용 불가" 1 "재사용 불가 — 사이드카의 기록 필드에 sha256 이 없다"
write_reuse 발행됨 "bind=$DB"
[ "$DB" != "$RB" ] || fail "reuse: 드라이버 값과 binding 값이 같아 다음 단언이 공허하다"
reuse_case "구속 다이제스트가 binding 값과 다르면 재사용 불가" 1 "재사용 불가 — 설계 문서 구속 다이제스트가 다르다"
write_reuse 발행됨 'sys=(없음)'
reuse_case "system.md 가 있는데 (없음)이면 재사용 불가" 1 "재사용 불가 — 디자인 시스템 sha256 이 다르다"
write_reuse 발행됨 "home=$(printf 'y' | shasum -a 256 | awk '{print $1}')"
reuse_case "화면 블록의 sha256 이 파일과 다르면 재사용 불가" 1 "재사용 불가 — 화면 home 의 sha256 이 다르다"
write_reuse 발행됨
mv "$RR/docs/visual/docs-reuse.list.html" "$T/list.save"
reuse_case "화면 파일이 없으면 재사용 불가" 1 "재사용 불가 — 화면 파일 없음 (list)"
mv "$T/list.save" "$RR/docs/visual/docs-reuse.list.html"
mv "$RR/docs/visual-system/system.md" "$T/system.save"
write_reuse 발행됨 'sys=(없음)'
reuse_case "system.md 가 없고 (없음)이면 재사용" 0 "재사용 발행됨"
mv "$T/system.save" "$RR/docs/visual-system/system.md"
# Publishing moves only the artifact line, so the pinned value still holds.
write_system; write_reuse 발행됨; write_system 'art=https://claude.ai/design/p/0000-ds'
reuse_case "아티팩트 줄만 발행으로 바뀌면 재사용" 0 "재사용 발행됨"
write_system; write_reuse 발행됨; write_system "tok=$(printf 'z' | shasum -a 256 | awk '{print $1}')"
reuse_case "tokens.css sha256 줄이 바뀌면 재사용 불가" 1 "재사용 불가 — 디자인 시스템 sha256 이 다르다"
write_system; write_reuse 발행됨; write_system 'lift=glassmorphism — 이 제품의 유리 카드는 정체성이다'
reuse_case "금지 해제 줄이 더해지면 재사용 불가" 1 "재사용 불가 — 디자인 시스템 sha256 이 다르다"
write_system; write_reuse 발행됨; write_system 'src=레포 기존'
reuse_case "출처 줄이 바뀌면 재사용 불가" 1 "재사용 불가 — 디자인 시스템 sha256 이 다르다"
write_system; write_reuse 발행됨
cp "$RTOK" "$T/tokens.save"; printf '%s\n' ':root { --c: #222; }' > "$RTOK"
reuse_case "tokens.css 바이트가 system.md 의 토큰 줄과 다르면 재사용 불가" 1 "재사용 불가 — tokens.css 가 system.md 의 tokens.css sha256 줄과 다르다"
mv "$T/tokens.save" "$RTOK"
write_system 'tok='; write_reuse 발행됨
reuse_case "system.md 의 토큰 줄이 비면 재사용 불가" 1 "재사용 불가 — tokens.css 가 system.md 의 tokens.css sha256 줄과 다르다"
# A sidecar pinned before the normalized digest carries the whole-file hash.
write_system 'art=https://claude.ai/design/p/0000-ds'
[ "$(sha_of "$RSYS")" != "$(bash "$CHECK" system "$RDOC")" ] \
  || fail "reuse: 발행된 system.md 의 전체 해시와 정규화 다이제스트가 같아 다음 단언이 공허하다"
write_reuse 발행됨 "sys=$(sha_of "$RSYS")"
reuse_case "옛 사이드카의 값이 발행된 system.md 의 전체 해시면 재사용" 0 "재사용 발행됨"

# --- system -------------------------------------------------------------------
# The normalized digest reproduces the final newline or its absence, so the
# value of a file without one is a fixed constant on BSD and GNU hosts alike.
printf '# DS\n**아티팩트**: https://claude.ai/design/p/0000-ds' > "$RSYS"
rc=0; out=$(bash "$CHECK" system "$RDOC" 2>&1) || rc=$?
[ "$rc $out" = "0 17267f540e667a9bf5ca9248080dfddf5f0f8c39041ea8bfb59e63a7864476f2" ] \
  && pass "system: 끝 개행 없는 system.md 의 정규화 다이제스트가 기대 상수와 같다" \
  || fail "system 끝 개행 없음 = ${rc} ${out}"
printf '# DS\n**아티팩트**: https://claude.ai/design/p/0000-ds\n' > "$RSYS"
want=$(printf '# DS\n**아티팩트**: (미발행)\n' | shasum -a 256 | awk '{print $1}')
rc=0; out=$(bash "$CHECK" system "$RDOC" 2>&1) || rc=$?
[ "$rc $out" = "0 $want" ] && pass "system: 아티팩트 줄을 미발행으로 되돌린 문면의 sha256 을 찍는다" || fail "system = ${rc} ${out}, 기대 ${want}"
printf '# DS\n' > "$RSYS"
rc=0; out=$(bash "$CHECK" system "$RDOC" 2>&1) || rc=$?
[ "$rc $out" = "0 $(sha_of "$RSYS")" ] && pass "system: 아티팩트 줄이 없으면 전체 해시와 같다" || fail "system 아티팩트 줄 없음 = ${rc} ${out}"
mv "$RSYS" "$T/system.save"
rc=0; out=$(bash "$CHECK" system "$RDOC" 2>&1) || rc=$?
[ "$rc $out" = "0 (없음)" ] && pass "system: system.md 가 없으면 (없음)" || fail "system 없음 = ${rc} ${out}"
mv "$T/system.save" "$RSYS"
for args in "" "--owner" "$RDOC --frob" "$T/nope.md"; do
  rc=0
  # shellcheck disable=SC2086
  bash "$CHECK" system $args > /dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && pass "system: 인자 「${args}」 는 2" || fail "system 인자 「${args}」 = ${rc}"
done
# owner_case <label> <want rc> <want line> — runs system --owner, checks the
# answer and that no file it reads moved.
owner_case() {
  local before after rc=0 out
  before=$(reuse_sums)
  out=$(bash "$CHECK" system "$RDOC" --owner 2>&1) || rc=$?
  after=$(reuse_sums)
  [ "$rc $out" = "$2 $3" ] && pass "system --owner: $1" || fail "system --owner $1 = ${rc} ${out}"
  [ "$before" = "$after" ] && pass "system --owner: $1 — 읽는 파일이 그대로다" || fail "system --owner: $1 — 파일이 바뀌었다"
}
write_system; write_reuse 발행됨
owner_case "이 문서 사이드카가 지금 값을 고정했으면 0" 0 "이 문서의 디자인 시스템"
write_system 'art=https://claude.ai/design/p/0000-ds'
owner_case "발행으로 아티팩트 줄만 바뀌어도 0" 0 "이 문서의 디자인 시스템"
write_reuse 발행됨 "sys=$(sha_of "$RSYS")"
owner_case "사이드카 값이 전체 해시여도 0" 0 "이 문서의 디자인 시스템"
write_system
write_reuse '로컬 초안' "rec=docs/pipeline-run/RUN9.interview.md (sha256 $(printf 'w' | shasum -a 256 | awk '{print $1}'))"
owner_case "기록 sha256 이 다른 같은 문서의 사이드카여도 0" 0 "이 문서의 디자인 시스템"
write_reuse 발행됨 'owner=docs/other.md'
owner_case "다른 문서의 사이드카면 1" 1 "이 문서의 디자인 시스템 아님 — 사이드카의 owner-doc 이 이 문서가 아니다"
write_reuse 발행됨 'head=cc-visual v2'
owner_case "사이드카 머리가 cc-visual v1 이 아니면 1" 1 "이 문서의 디자인 시스템 아님 — 사이드카 머리가 cc-visual v1 이 아니다"
write_reuse 발행됨 'sys=(없음)'
owner_case "사이드카 값이 지금 다이제스트와 다르면 1" 1 "이 문서의 디자인 시스템 아님 — 디자인 시스템 다이제스트가 다르다"
write_reuse 발행됨
cp "$RTOK" "$T/tokens.save"; printf '%s\n' ':root { --c: #333; }' > "$RTOK"
owner_case "토큰 줄이 tokens.css 와 다르면 1" 1 "이 문서의 디자인 시스템 아님 — tokens.css sha256 줄이 실제 tokens.css 와 다르다"
mv "$T/tokens.save" "$RTOK"
rm -f "$RSC"
owner_case "사이드카가 없으면 1" 1 "이 문서의 디자인 시스템 아님 — 사이드카 없음"
mv "$RSYS" "$T/system.save"
owner_case "system.md 가 없으면 1" 1 "이 문서의 디자인 시스템 아님 — system.md 없음"
mv "$T/system.save" "$RSYS"
for args in "" "$RDOC" "--record $REC" "$RDOC --record" "$RDOC --record $T/nope.md"; do
  rc=0
  # shellcheck disable=SC2086
  bash "$CHECK" reuse $args > /dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && pass "reuse: 인자 「${args}」 는 2" || fail "reuse 인자 「${args}」 = ${rc}"
done

# --- confirm ------------------------------------------------------------------
# The confirmation line sits right after `**출처**`; removing it in the
# normalized digest leaves the bytes of the same file without it, so writing
# or changing it moves no sidecar's pinned value.
TOKSHA=$(sha_of "$RTOK")
WAITL='**확인**: 대기 — 문서 docs/reuse.md — 런 20261104-aaaaaaaa'
OKL="**확인**: 사람 승인 — 문서 docs/reuse.md — tokens.css sha256 ${TOKSHA} — 사람 답 S2P#2.md — 런 20261104-aaaaaaaa — 2026-11-04T09:00:00Z"
OTHERL="**확인**: 사람 승인 — 문서 docs/other.md — tokens.css sha256 ${TOKSHA} — 사람 답 S2P#2.md — 런 20261104-aaaaaaaa — 2026-11-04T09:00:00Z"
write_system; plain=$(bash "$CHECK" system "$RDOC")
write_system "conf=${WAITL}"; withw=$(bash "$CHECK" system "$RDOC")
write_system "conf=${OKL}"; witho=$(bash "$CHECK" system "$RDOC")
[ "$plain" = "$withw" ] && [ "$plain" = "$witho" ] \
  && pass "system: 출처 다음 확인 줄은 정규화 다이제스트를 바꾸지 않는다" \
  || fail "system: 확인 줄이 정규화 다이제스트를 바꿨다 (${plain:0:12} / ${withw:0:12} / ${witho:0:12})"
write_system; cp "$RSYS" "$T/sys.plain"
write_system "conf=${WAITL}"
nl_plain=$(LC_ALL=C awk '{ if (w > 0) printf "\n"; printf "%s", $0; w++ } END { if (w > 0) printf "\n" }' "$T/sys.plain" | shasum -a 256 | awk '{print $1}')
nl_conf=$(LC_ALL=C awk 'index($0, "**확인**: ") == 1 { next } { if (w > 0) printf "\n"; printf "%s", $0; w++ } END { if (w > 0) printf "\n" }' "$RSYS" | shasum -a 256 | awk '{print $1}')
[ "$nl_plain" = "$nl_conf" ] && [ "$nl_plain" = "$(sha_of "$T/sys.plain")" ] \
  && pass "system: 출처 다음 확인 줄을 지운 바이트는 줄 없는 같은 파일의 바이트와 같다" \
  || fail "system: 확인 줄을 지운 바이트가 줄 없는 파일과 다르다"
printf '**확인**: 대기 — 문서 docs/reuse.md — 런 R1\n# DS\n' > "$RSYS"
first=$(bash "$CHECK" system "$RDOC"); printf '# DS\n' > "$RSYS"
[ "$first" = "$(sha_of "$RSYS")" ] && pass "system: 1행 확인 줄을 지워도 앞에 개행이 남지 않는다" || fail "system: 1행 확인 줄 제거가 바이트를 바꿨다"
confirm_case() { # <label> <want>
  local rc=0 out
  out=$(bash "$CHECK" confirm "$RDOC" 2>&1) || rc=$?
  [ "$rc $out" = "0 $2" ] && pass "confirm: $1" || fail "confirm $1 = ${rc} ${out}"
}
write_system
confirm_case "확인 줄이 없으면 확인 없음" "확인 없음"
write_system "conf=${WAITL}"
confirm_case "대기 줄" "확인 대기 — 문서 docs/reuse.md"
write_system "conf=${OKL}"
confirm_case "사람 승인 줄" "사람 승인 — 문서 docs/reuse.md"
write_system "conf=**확인**: 사람 승인 — 문서 docs/reuse.md"
confirm_case "꼬리 없는 사람 승인 줄은 형식 오류" "확인 형식 오류"
write_system "conf=**확인**: 됨"
confirm_case "두 꼴 밖의 줄은 형식 오류" "확인 형식 오류"
write_system "conf=${WAITL}
${OKL}"
confirm_case "확인 줄이 둘이면 형식 오류" "확인 형식 오류"
write_system "conf=- ${WAITL}"
confirm_case "글머리표를 단 확인 줄은 형식 오류" "확인 형식 오류"
write_system "conf=  ${WAITL}"
confirm_case "앞에 공백을 둔 확인 줄은 형식 오류" "확인 형식 오류"
write_system "conf=**확인**:대기 — 문서 docs/reuse.md — 런 20261104-aaaaaaaa"
confirm_case "콜론 뒤 공백이 없는 확인 줄은 형식 오류" "확인 형식 오류"
write_system "conf=${OKL}"
cp "$RTOK" "$T/tokens.save"; printf '%s\n' ':root { --c: #555; }' > "$RTOK"
confirm_case "승인 줄의 tokens.css 값이 실제 파일과 다르면 확인 대기" "확인 대기 — 문서 docs/reuse.md"
rm -f "$RTOK"
confirm_case "승인 줄이 있어도 tokens.css 가 없으면 확인 대기" "확인 대기 — 문서 docs/reuse.md"
mv "$T/tokens.save" "$RTOK"
mv "$RSYS" "$T/system.save"
confirm_case "system.md 가 없으면 확인 없음" "확인 없음"
mv "$T/system.save" "$RSYS"
rc=0; bash "$CHECK" confirm > /dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && pass "confirm: 인자가 없으면 2" || fail "confirm 인자 없음 = ${rc}"
# A reusable design system still waits when its line says so.
write_system; write_reuse 발행됨; write_system "conf=${WAITL}"
reuse_case "대기 줄이 있어도 재사용 판정은 그대로" 0 "재사용 발행됨"
confirm_case "재사용이 성립하는 디자인 시스템에서도 대기 줄이면 확인 대기" "확인 대기 — 문서 docs/reuse.md"

# --- system --owner widened by the confirmation line ---------------------------
write_system; write_reuse 발행됨 'sys=(없음)'; write_system "conf=${OKL}"
owner_case "사람 승인 줄이 이 문서면 옛 디자인 시스템을 고정한 사이드카여도 0" 0 "이 문서의 디자인 시스템 — 사람 확인"
write_system "conf=${OTHERL}"
owner_case "사람 승인 줄이 다른 문서면 같은 사이드카에서 1" 1 "이 문서의 디자인 시스템 아님 — 디자인 시스템 다이제스트가 다르다"
rm -f "$RSC"
write_system "conf=${WAITL}"
owner_case "대기 줄이 이 문서여도 사이드카 판정을 따른다" 1 "이 문서의 디자인 시스템 아님 — 사이드카 없음"
write_system "conf=${OKL}"
owner_case "사람 승인 줄이 이 문서면 사이드카가 없어도 0" 0 "이 문서의 디자인 시스템 — 사람 확인"
write_system "conf=${OTHERL}"
owner_case "다른 문서 키면 사이드카 없음으로 1" 1 "이 문서의 디자인 시스템 아님 — 사이드카 없음"
write_system "conf=${OKL}"
cp "$RTOK" "$T/tokens.save"; printf '%s\n' ':root { --c: #444; }' > "$RTOK"
owner_case "승인 줄의 tokens.css 값과 실제 파일이 다르면 넓히지 않고 사이드카 판정으로 1" 1 "이 문서의 디자인 시스템 아님 — 사이드카 없음"
mv "$T/tokens.save" "$RTOK"

# --- system-users -------------------------------------------------------------
# Other documents' sidecars pinning the current design system, or the --also
# digest; this document's own sidecar is never listed.
write_system
CUR=$(bash "$CHECK" system "$RDOC")
OLD=$(printf 'old' | shasum -a 256 | awk '{print $1}')
write_user() { # <slug> <owner> <state> <sys> [approval]
  {
    echo "# 시각 디자인 연결 — $2"
    echo "<!-- cc-visual v1; writer=visual-unattended; reader=visual; owner-doc=$2; origin-worktree=$RR; NOT a design doc; mechanism-local, never staged by a skill -->"
    echo "**상태**: $3"
    echo "**디자인 시스템 sha256**: $4"
    [ -z "${5:-}" ] || echo "**구현 승인**: $5"
  } > "$RR/docs/visual/$1.md"
}
users() { local rc=0 out; out=$(bash "$CHECK" system-users "$RDOC" "$@" 2>&1) || rc=$?; printf '%s %s' "$rc" "$out"; }
got=$(users)
[ "$got" = "0 없음" ] && pass "system-users: 다른 문서 사이드카가 없으면 없음" || fail "system-users 없음 = ${got}"
write_reuse 발행됨
write_user docs-a docs/a.md 발행됨 "$CUR" "2026-11-04T00:00:00Z — 입력 묶음 x"
write_user docs-b docs/b.md '검토 통과' "$OLD"
got=$(users)
[ "$got" = "0 docs/a.md — 상태 발행됨 — 구현 승인 있음" ] && pass "system-users: 지금 값을 고정한 다른 문서만 찍고 이 문서는 뺀다" || fail "system-users = ${got}"
got=$(users --also "$OLD")
[ "$got" = "0 docs/a.md — 상태 발행됨 — 구현 승인 있음
docs/b.md — 상태 검토 통과 — 구현 승인 없음" ] && pass "system-users: --also 값을 고정한 문서도 찍는다" || fail "system-users --also = ${got}"
rc=0; bash "$CHECK" system-users "$RDOC" --also nothex > /dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && pass "system-users: --also 가 16진수가 아니면 2" || fail "system-users --also 형식 = ${rc}"
rm -f "$RR/docs/visual/docs-a.md" "$RR/docs/visual/docs-b.md"

# --- approval never reads the confirmation line --------------------------------
# The interactive skill keeps working over a waiting design system; only the
# unattended consumers apply the waiting verdict.
printf '**확인**: 대기 — 문서 docs/other.md — 런 R1\n' > "$R/docs/visual-system/system.md"
printf '%s\n' '<!doctype html><p>home</p>' > "$R/docs/visual/docs-feature.home.html"
write_sidecar 발행됨 "${APL}"
got=$(approval)
[ "$got" = "0 승인 유효 ${B:0:12}" ] && pass "approval: 대기 줄이 있어도 묶음이 같으면 유효" || fail "approval 대기 = ${got}"
printf '**확인**: 엉망\n' > "$R/docs/visual-system/system.md"
got=$(approval)
[ "$got" = "0 승인 유효 ${B:0:12}" ] && pass "approval: 확인 형식 오류도 판정에 쓰지 않는다" || fail "approval 형식 오류 = ${got}"
rm -f "$R/docs/visual-system/system.md"
got=$(approval)
[ "$got" = "0 승인 유효 ${B:0:12}" ] && pass "approval: 확인 줄이 없으면 그대로 유효" || fail "approval 확인 없음 = ${got}"

# --- run-state -----------------------------------------------------------------
RS_RID=20261104-bbbbbbbb
RS_DIR="$T/run/$RS_RID"; mkdir -p "$RS_DIR/halt"
RS_LED="$T/ledger/$RS_RID.md"; mkdir -p "$T/ledger"
RS_MAN="$T/manifest.md"
rs_manifest() { # <skill of the second step>
  {
    echo '## 실행 계획'
    echo '```json'
    printf '{"steps":[{"id":"S2V","skill":"visual"},{"id":"S2P","skill":"%s"}]}\n' "$1"
    echo '```'
  } > "$RS_MAN"
}
rs_halt() { # <attempt> <step> [extra line]
  {
    echo "**스텝**: $2"
    [ -z "${3:-}" ] || echo "$3"
  } > "$RS_DIR/halt/S2P#$1.md"
}
rs_answer() { # <attempt> <by> <option>
  echo "- \`중단 답\` | 중단 기록=$RS_DIR/halt/S2P#$1.md | 답한 주체=$2 | 선택지=$3" >> "$RS_LED"
}
run_state() { local rc=0 out; out=$(bash "$CHECK" run-state "$RDOC" --run-dir "$RS_DIR" --ledger "$RS_LED" --manifest "$RS_MAN" 2>&1) || rc=$?; printf '%s %s' "$rc" "$out"; }
write_system
rs_manifest visual; : > "$RS_LED"
got=$(run_state)
[ "$got" = "0 S2P 없음
디자인-시스템-판정 기록 없음
디자인-시스템-판정 사람 답 없음
시각-판정 기록 없음
시각-판정 사람 답 없음
수정 횟수 0
확인 확인 없음" ] && pass "run-state: 기록이 없으면 일곱 줄 모두 없음" || fail "run-state 빈 런 = ${got}"
rs_manifest visual-publish
rs_halt 1 '디자인-시스템-판정 — 제시'
rs_answer 1 사람 '수정 요청'
rs_halt 2 '디자인-시스템-판정 — 제시' '- 입력 없음=S2P#1.md'
rs_answer 2 사람 '수정 요청'
rs_halt 3 '디자인-시스템-판정 — 제시'
rs_answer 3 좌석 '승인'
rs_halt 4 '시각-판정'
rs_answer 4 사람 '디자인 시스템 다시 열기'
write_system "conf=${WAITL}"
got=$(run_state)
[ "$got" = "0 S2P 있음
디자인-시스템-판정 기록 S2P#3.md
디자인-시스템-판정 사람 답 없음
시각-판정 기록 S2P#4.md
시각-판정 사람 답 디자인 시스템 다시 열기
수정 횟수 2
확인 확인 대기 — 문서 docs/reuse.md" ] && pass "run-state: 최신 기록·사람 답·입력 없음을 뺀 수정 횟수·확인 상태" || fail "run-state = ${got}"
mkdir -p "$T/ledger2"; RS_OTHER="$T/ledger2/other.md"; cp "$RS_LED" "$RS_OTHER"
got=$(bash "$CHECK" run-state "$RDOC" --run-dir "$RS_DIR" --ledger "$RS_OTHER" --manifest "$RS_MAN" 2>&1 | sed -n 6p)
[ "$got" = "수정 횟수 0" ] && pass "run-state: 이 런의 원장이 아니면 답 행을 읽지 않는다" || fail "run-state 다른 원장 = ${got}"
rc=0; bash "$CHECK" run-state "$RDOC" --run-dir "$RS_DIR" > /dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && pass "run-state: 인자가 모자라면 2" || fail "run-state 인자 = ${rc}"
write_system

# --- grammar examples of the shared contract ----------------------------------
# Print the first fenced block under `### <heading>` of the references file.
example_block() {
  awk -v want="### $2" '
    /^```/ { if (infence) { if (grab) { done = 1; exit } ; infence = 0; next }
             infence = 1; if (armed) { grab = 1; armed = 0 } ; next }
    infence { if (grab) print; next }
    /^### / { armed = ($0 == want); next }
    END { if (!done) exit 3 }
  ' "$1"
}
if [[ ! -f "$REFS" ]]; then
  fail "공유 계약 파일이 없다: $REFS"
else
  if example_block "$REFS" '사이드카 예시' > "$T/ex.sidecar"; then
    pass "공유 계약에 사이드카 예시가 있다"
    G="$T/grepo"
    mkdir -p "$G/docs/visual"
    (cd "$G" && git init -q)
    key=$(sed -n '2p' "$T/ex.sidecar" | sed -nE 's/^<!-- cc-visual v1;.*owner-doc=([^;]*);.*$/\1/p')
    h1=$(sed -n '1p' "$T/ex.sidecar")
    case "$h1" in
      '# 시각 디자인 연결 — '*) pass "사이드카 예시의 1행은 사람이 읽는 H1" ;;
      *) fail "사이드카 예시의 1행이 H1 이 아니다" ;;
    esac
    if [ -z "$key" ]; then
      fail "사이드카 예시의 2행 기계 머리에서 owner-doc 을 읽지 못했다"
    else
      mkdir -p "$G/$(dirname "$key")"
      printf '%s\n' '# 예시 설계' > "$G/$key"
      gslug=$(printf '%s' "${key%.md}" | tr '/' '-')
      for id in $(sed -nE 's/^### 화면 ([^[:space:]]+)[[:space:]]*$/\1/p' "$T/ex.sidecar"); do
        printf '<!doctype html><p>%s</p>\n' "$id" > "$G/docs/visual/${gslug}.${id}.html"
      done
      cp "$T/ex.sidecar" "$G/docs/visual/${gslug}.md"
      rc=0; bash "$CHECK" approval "$G/$key" > "$T/ex.ap" 2>&1 || rc=$?
      case "$(head -n 1 "$T/ex.ap")" in
        "승인 무효 — 입력 묶음이 달라졌다"*) pass "사이드카 예시의 구현 승인 줄은 형식 검사를 지나 묶음 대조까지 간다" ;;
        *) fail "사이드카 예시의 approval = $(head -n 1 "$T/ex.ap")" ;;
      esac
      GB=$(bash "$CHECK" bundle "$G/$key")
      sed -E "s/ — 입력 묶음 [0-9a-f]{64} — / — 입력 묶음 ${GB} — /" "$T/ex.sidecar" > "$G/docs/visual/${gslug}.md"
      rc=0; got=$(bash "$CHECK" approval "$G/$key" 2>&1) || rc=$?
      [ "$rc:$got" = "0:승인 유효 ${GB:0:12}" ] && pass "사이드카 예시는 묶음을 맞추면 승인 유효로 읽힌다" || fail "맞춘 사이드카 예시의 approval = ${rc} ${got}"
      cand=$(grep -E '^- `' "$T/ex.sidecar" | sed -n '1p' || true)
      if [ -z "$cand" ]; then
        fail "사이드카 예시에 금지 후보 줄이 없다"
      else
        mkdir -p "$T/xdg/cc-cmds"
        cp "$SEED" "$T/xdg/cc-cmds/visual-bans"
        rc=0; env -u CC_PIPELINE_RUN_ID XDG_CONFIG_HOME="$T/xdg" bash "$CONFIG" append "$cand" > "$T/ex.append" 2>&1 || rc=$?
        [ "$rc" = 0 ] && pass "사이드카 예시의 금지 후보 줄을 visual-config.sh append 가 받는다" || fail "금지 후보 예시 append 종료 ${rc}: $(cat "$T/ex.append")"
      fi
    fi
  else
    fail "공유 계약에 '### 사이드카 예시' 아래 코드 블록이 없다"
  fi
  if example_block "$REFS" '금지 해제 예시' > "$T/ex.lift"; then
    lid=$(sed -nE 's/^\*\*금지 해제\*\*:[[:space:]]*([a-z0-9-]+)[[:space:]]+—.*$/\1/p' "$T/ex.lift" | sed -n '1p')
    rc=$(run_scan "$T/ex.lift.out" "$T/bans.html" --bans "$T/bans.list" --lifts "$T/ex.lift")
    if [ -n "$lid" ] && grep -qxF "# 금지 해제: ${lid}" "$T/ex.lift.out"; then
      pass "금지 해제 예시를 scan --lifts 가 읽는다 (${lid})"
    else
      fail "금지 해제 예시를 scan --lifts 가 읽지 못했다"
    fi
  else
    fail "공유 계약에 '### 금지 해제 예시' 아래 코드 블록이 없다"
  fi
fi

echo
echo "passed=${passed} failures=${failures}"
[ "$failures" = 0 ] || exit 1
