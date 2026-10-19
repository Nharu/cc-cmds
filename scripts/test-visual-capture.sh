#!/usr/bin/env bash
# Executable specification of plugins/cc-cmds/orchestrator/visual-capture.sh.
#
# A stub directory first on PATH holds a fake for every name the helper looks
# up (google-chrome, chromium, chromium-browser, chrome). With a fake under one
# name only, a real browser under an earlier name anywhere on PATH (a CI runner
# with Chrome preinstalled, a development host with Homebrew chromium) would
# be found first, because the lookup scans the whole PATH for each name in
# turn. Each fake records its own name and argv and writes a PNG.
#
# Cases:
#   argv       --headless, --proxy-server=127.0.0.1:9 and a --screenshot= path
#              outside every git tree; the first name in lookup order is the
#              one called
#   timeout    a browser that never exits is killed at the time limit and the
#              result is `비교 안 함`
#   out guard  an --out inside a git tree is a usage error
#   app        a loopback server is started, the browser fetches index.html
#              from it, and the port is closed afterwards (lsof)
#   no index   --root without index.html is `비교 안 함`
#   no Chrome  nothing on PATH and no macOS application path is
#              `비교 안 함 — Chrome 없음`
#
# python3 and lsof are required; there is no skipping branch.
#
# Usage:
#   bash scripts/test-visual-capture.sh
#
# Exit codes:
#   0 — every case passed
#   1 — at least one case failed
#   2 — the suite could not run (missing helper, python3 or lsof)
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`; BSD
# and GNU userland alike.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
CAPTURE="$repo_root/plugins/cc-cmds/orchestrator/visual-capture.sh"

[[ -f "$CAPTURE" ]] || { echo "test-visual-capture: missing $CAPTURE" >&2; exit 2; }
for tool in python3 lsof; do
  command -v "$tool" >/dev/null 2>&1 || { echo "test-visual-capture: $tool 이 없다 — 이 시험은 건너뛰지 않는다" >&2; exit 2; }
done

passed=0
failures=0
pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }

T=$(mktemp -d "${TMPDIR:-/tmp}/test-visual-capture.XXXXXX")
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub" "$T/out" "$T/site"
cat > "$T/stub/google-chrome" <<'STUB'
#!/usr/bin/env bash
log="${FAKE_CHROME_LOG:?}"
{ echo "name=$(basename "$0")"; echo "pid=$$"; for a in "$@"; do echo "arg=$a"; done; } >> "$log"
png=''
url=''
for a in "$@"; do
  case "$a" in --screenshot=*) png=${a#--screenshot=} ;; esac
  url=$a
done
case "${FAKE_CHROME_MODE:-ok}" in
  hang) exec sleep 30 ;;
  fetch)
    python3 -I -c 'import sys, urllib.request as u
o = u.build_opener(u.ProxyHandler({}))
print("status=%d" % o.open(sys.argv[1], timeout=5).status)' "$url" >> "$log"
    ;;
esac
printf '\211PNG\r\n\032\n' > "$png"
STUB
chmod +x "$T/stub/google-chrome"
for n in chromium chromium-browser chrome; do
  cp "$T/stub/google-chrome" "$T/stub/$n"
done

printf '%s\n' '<!doctype html><p>ref</p>' > "$T/site/screen.html"
LOG="$T/chrome.log"

cap() { # <mode> <args...> — output in $T/cap.out, status in $RC
  local mode=$1
  shift
  RC=0
  : > "$LOG"
  env PATH="$T/stub:$PATH" FAKE_CHROME_LOG="$LOG" FAKE_CHROME_MODE="$mode" \
    bash "$CAPTURE" "$@" > "$T/cap.out" 2>&1 || RC=$?
}

# --- argv ---------------------------------------------------------------------
cap ok ref "$T/site/screen.html" --out "$T/out" --size 800x600
[ "$RC" = 0 ] && grep -qxF "찍음 $T/out/ref.png" "$T/cap.out" && pass "ref: 찍고 경로를 알린다" || fail "ref = ${RC} $(cat "$T/cap.out")"
[ -s "$T/out/ref.png" ] && pass "ref: --out 아래에 PNG 가 생긴다" || fail "ref PNG 가 없다"
grep -qxF 'name=google-chrome' "$LOG" && pass "탐색 순서의 첫 이름(google-chrome)이 불린다" || fail "불린 이름 = $(grep '^name=' "$LOG")"
grep -qxF 'arg=--headless=new' "$LOG" && pass "argv 에 --headless=new" || fail "argv 에 --headless 가 없다"
grep -qxF 'arg=--proxy-server=127.0.0.1:9' "$LOG" && pass "argv 에 --proxy-server=127.0.0.1:9" || fail "argv 에 닫힌 프록시가 없다"
grep -qxF "arg=--screenshot=$T/out/ref.png" "$LOG" && pass "argv 의 --screenshot= 은 트리 밖 --out 아래" || fail "argv 의 --screenshot= = $(grep -- '--screenshot=' "$LOG")"
grep -qxF 'arg=--window-size=800,600' "$LOG" && pass "argv 의 --window-size 는 --size 를 따른다" || fail "argv 의 --window-size = $(grep -- '--window-size' "$LOG")"
grep -qxF "arg=file://$T/site/screen.html" "$LOG" && pass "ref 는 file:// 로 연다" || fail "ref URL = $(tail -n 1 "$LOG")"
prof=$(sed -nE 's/^arg=--user-data-dir=(.*)$/\1/p' "$LOG")
[ -n "$prof" ] && [ ! -e "$prof" ] && pass "버린 프로필 디렉터리는 끝나면 지운다" || fail "프로필 디렉터리가 남았다: ${prof}"

# --- timeout ------------------------------------------------------------------
cap hang ref "$T/site/screen.html" --out "$T/out" --timeout 1
[ "$RC" = 1 ] && grep -q '^비교 안 함 — Chrome 이 1초 안에 끝나지 않아 멈췄다' "$T/cap.out" \
  && pass "제한 시간을 넘으면 비교 안 함" || fail "timeout = ${RC} $(cat "$T/cap.out")"
hp=$(sed -nE 's/^pid=([0-9]+)$/\1/p' "$LOG" | sed -n '1p')
if [ -n "$hp" ] && kill -0 "$hp" 2>/dev/null; then
  fail "제한 시간을 넘은 브라우저가 살아 있다 (pid ${hp})"
  kill -KILL "$hp" 2>/dev/null || true
else
  pass "제한 시간을 넘은 브라우저는 죽인다"
fi

# --- out guard ----------------------------------------------------------------
mkdir -p "$T/repo"
(cd "$T/repo" && git init -q)
cap ok ref "$T/site/screen.html" --out "$T/repo"
[ "$RC" = 2 ] && grep -q 'git 트리 밖이어야 한다' "$T/cap.out" && pass "git 트리 안 --out 은 사용 오류" || fail "트리 안 --out = ${RC}"

# --- app ----------------------------------------------------------------------
printf '%s\n' '<!doctype html><p>app</p>' > "$T/site/index.html"
cap fetch app --root "$T/site" --out "$T/out" --timeout 20
[ "$RC" = 0 ] && grep -qxF "찍음 $T/out/app.png" "$T/cap.out" && pass "app: 찍고 경로를 알린다" || fail "app = ${RC} $(cat "$T/cap.out")"
port=$(sed -nE 's/^서버 127\.0\.0\.1:([0-9]+)$/\1/p' "$T/cap.out")
grep -qxF "arg=http://127.0.0.1:${port}/index.html" "$LOG" && pass "app: 루프백 서버의 index.html 을 연다" || fail "app URL = $(tail -n 2 "$LOG")"
grep -qxF 'status=200' "$LOG" && pass "app: 브라우저가 루프백 서버에서 200 을 받았다" || fail "app 서버 응답 = $(grep status "$LOG" || echo 없음)"
if [ -n "$port" ] && lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
  fail "app: 끝난 뒤에도 포트 ${port} 가 열려 있다"
else
  [ -n "$port" ] && pass "app: 끝나면 서버를 내린다 (포트 ${port} 닫힘)" || fail "app 출력에 포트가 없다"
fi

# --- no index -----------------------------------------------------------------
mkdir -p "$T/empty"
cap ok app --root "$T/empty" --out "$T/out"
[ "$RC" = 1 ] && grep -qxF '비교 안 함 — --root 에 index.html 이 없다' "$T/cap.out" && pass "app: index.html 이 없으면 비교 안 함" || fail "app index 없음 = ${RC} $(cat "$T/cap.out")"

# --- no Chrome ----------------------------------------------------------------
mkdir -p "$T/bare" "$T/nochrome"
for tool in bash env dirname basename git grep tr sed head mktemp rm pkill sleep cat; do
  p=$(command -v "$tool" || true)
  [ -n "$p" ] && ln -s "$p" "$T/bare/$tool"
done
sed "s|^readonly MAC_CHROME=.*|readonly MAC_CHROME='$T/nochrome/Google Chrome'|" "$CAPTURE" > "$T/capture-nomac.sh"
RC=0
env PATH="$T/bare" "$T/bare/bash" "$T/capture-nomac.sh" ref "$T/site/screen.html" --out "$T/out" > "$T/cap.out" 2>&1 || RC=$?
[ "$RC" = 1 ] && grep -qxF '비교 안 함 — Chrome 없음' "$T/cap.out" && pass "PATH 에도 macOS 경로에도 없으면 비교 안 함 — Chrome 없음" || fail "Chrome 없음 = ${RC} $(cat "$T/cap.out")"

echo
echo "passed=${passed} failures=${failures}"
[ "$failures" = 0 ] || exit 1
