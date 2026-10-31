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
#              a malformed ban line is a usage error
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
#              changed, valid — and bundle --lines prints the bundle text
#   binding    equal to the driver's binding_digest on a document without a
#              `## 시각 정합 기준` section, blind to that section where it is
#   reuse      a 검토 통과 and a 발행됨 sidecar where all six conditions hold
#              are reusable, each condition broken once is not, argument
#              errors are 2, and no sidecar, record or screen byte moves
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

for need in "$CHECK" "$CONFIG" "$SEED" "$fixtures/v11.txt" "$fixtures/v32.txt" "$fixtures/refs.txt" "$fixtures/bans.txt" "$fixtures/leak.txt" "$fixtures/hangul.txt"; do
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
n=0
while IFS= read -r label; do
  n=$((n + 1))
  case "$label" in
    -) ;;
    N)
      if grep -qE "^[^ ]+ [^ ]*:${n} " "$T/bans.out"; then fail "금지 목록 비적중 줄 ${n} 이 잡혔다"; else pass "금지 목록 비적중 줄 ${n}"; fi
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
if [ "$rc" = 0 ] && printf '%s' "$VB" | grep -qxE '[0-9a-f]{64}' && [ "$VB" = "$DB" ]; then
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
# Six conditions, each broken once against a sidecar where all hold, and no
# byte of the sidecar, the record or a screen file moves in any case.
RSC="$RR/docs/visual/docs-reuse.md"
REC="$RR/docs/pipeline-run/RUN2.interview.md"
printf '# 파이프라인 런 인터뷰 기록 — RUN1\n\n원천 기록\n' > "$REC"
printf '%s\n' '<!doctype html><p>home</p>' > "$RR/docs/visual/docs-reuse.home.html"
printf '%s\n' '<!doctype html><p>list</p>' > "$RR/docs/visual/docs-reuse.list.html"
printf '# 디자인 시스템 연결 — %s\n' "$RR" > "$RR/docs/visual-system/system.md"
sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }
RB=$(bash "$CHECK" binding "$RDOC")
# write_reuse <state> [<field>=<value>] — the sidecar with every field matching,
# one field replaced when given (`head`, `owner`, `rec`, `bind`, `sys`, `home`).
write_reuse() {
  local st="$1" kv="${2:-}" k v head owner rec bind sys home
  k=${kv%%=*}; v=${kv#*=}
  head='cc-visual v1'; owner='docs/reuse.md'
  rec="docs/pipeline-run/RUN1.interview.md (sha256 $(sha_of "$REC"))"
  bind=$RB; sys='(없음)'; [ ! -f "$RR/docs/visual-system/system.md" ] || sys=$(sha_of "$RR/docs/visual-system/system.md"); home=$(sha_of "$RR/docs/visual/docs-reuse.home.html")
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
reuse_sums() { for f in "$RSC" "$REC" "$RR/docs/visual/docs-reuse.home.html" "$RR/docs/visual/docs-reuse.list.html"; do [ -f "$f" ] && sha_of "$f" || echo 없음; done; }
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
for args in "" "$RDOC" "--record $REC" "$RDOC --record" "$RDOC --record $T/nope.md"; do
  rc=0
  # shellcheck disable=SC2086
  bash "$CHECK" reuse $args > /dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && pass "reuse: 인자 「${args}」 는 2" || fail "reuse 인자 「${args}」 = ${rc}"
done

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
