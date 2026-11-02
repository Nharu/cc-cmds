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
#              one called; the file:// URL is the path percent-encoded
#   url encoding  a screen under a directory whose name holds `#`, a space
#              and Hangul is opened at a URL with `%23`, `%20` and the
#              Hangul bytes as upper-case `%XX`, equal to Python's
#              urllib.parse.quote of the path
#   timeout    a browser that never exits is killed at the time limit and the
#              result is `비교 안 함`
#   out guard  an --out inside a git tree is a usage error
#   app        a loopback server is started, the browser fetches index.html
#              from it under the same closed proxy and no bypass list, and the
#              port is closed afterwards (lsof)
#   no index   --root without index.html is `비교 안 함`
#   no Chrome  nothing on PATH and no macOS application path is
#              `비교 안 함 — Chrome 없음`
#   real render  with the real Chrome (no stub on PATH): a screen whose head
#              holds the token block filled from the visual-check fixture
#              tokens.css (first checked clean by `visual-check.sh scan
#              --tokens`) and the same screen without the block are captured;
#              the decoded PNG pixel is the background token's colour for the
#              first and white for the second
#
# python3, lsof and a real Chrome are required; there is no skipping branch.
# When the helper finds no Chrome for the real render case, the suite ends
# with exit 2; any other `비교 안 함` there is a failure.
#
# Usage:
#   bash scripts/test-visual-capture.sh
#
# Exit codes:
#   0 — every case passed
#   1 — at least one case failed
#   2 — the suite could not run (missing helper, python3, lsof or Chrome)
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`; BSD
# and GNU userland alike.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
CAPTURE="$repo_root/plugins/cc-cmds/orchestrator/visual-capture.sh"
CHECK="$repo_root/plugins/cc-cmds/orchestrator/visual-check.sh"
TOKENS="$repo_root/tests/fixtures/visual-check/tokens.css"

for need in "$CAPTURE" "$CHECK" "$TOKENS"; do
  [[ -f "$need" ]] || { echo "test-visual-capture: missing $need" >&2; exit 2; }
done
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

# file_url <path> — the URL the helper must open, by an independent encoder:
# letters, digits and `_ . - ~` (Python's always-safe set) and `/` stay.
file_url() {
  python3 -I -c 'import os, sys, urllib.parse as p; print("file://" + p.quote(os.fsencode(sys.argv[1]), safe="/"))' "$1"
}

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
grep -qxF "arg=$(file_url "$T/site/screen.html")" "$LOG" && pass "ref 는 file:// 로 연다" || fail "ref URL = $(tail -n 1 "$LOG")"
prof=$(sed -nE 's/^arg=--user-data-dir=(.*)$/\1/p' "$LOG")
[ -n "$prof" ] && [ ! -e "$prof" ] && pass "버린 프로필 디렉터리는 끝나면 지운다" || fail "프로필 디렉터리가 남았다: ${prof}"

# --- url encoding -------------------------------------------------------------
odd="$T/x#1 한"
mkdir -p "$odd"
cp "$T/site/screen.html" "$odd/screen.html"
cap ok ref "$odd/screen.html" --out "$T/out"
url=$(sed -nE 's/^arg=(file:.*)$/\1/p' "$LOG" | tail -n 1)
[ "$RC" = 0 ] && pass "url encoding: # 과 공백이 든 디렉터리의 화면도 찍는다" || fail "url encoding = ${RC} $(cat "$T/cap.out")"
case "$url" in
  *'/x%231%20%ED%95%9C/screen.html') pass "url encoding: # → %23, 공백 → %20, 한글은 바이트마다 대문자 %XX" ;;
  *) fail "url encoding: URL = ${url}" ;;
esac
[ "$url" = "$(file_url "$odd/screen.html")" ] && pass "url encoding: 독립 인코더(urllib.parse.quote)와 같은 주소" || fail "url encoding: ${url} ≠ $(file_url "$odd/screen.html")"

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
# app 도 ref 와 같은 닫힌 프록시로 뜨고 루프백 우회 목록을 따로 싣지 않는다 — 실제
# Chrome 에서 127.0.0.1 은 그 플래그 없이 프록시를 우회해 찍혔고, 루프백이 아닌
# 호스트로 가는 img·fetch 는 같은 argv 에서 막혔다.
grep -qxF 'arg=--proxy-server=127.0.0.1:9' "$LOG" && pass "app: argv 에 --proxy-server=127.0.0.1:9" || fail "app argv 에 닫힌 프록시가 없다"
if grep -q '^arg=--proxy-bypass-list' "$LOG"; then
  fail "app: argv 에 --proxy-bypass-list 가 있다 — $(grep '^arg=--proxy-bypass-list' "$LOG")"
else
  pass "app: argv 에 루프백 우회 목록을 따로 싣지 않는다"
fi
for flag in --disable-background-networking --disable-component-update --disable-sync --no-first-run; do
  grep -qxF "arg=$flag" "$LOG" && pass "app: argv 에 $flag" || fail "app argv 에 $flag 가 없다"
done
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

# --- real render --------------------------------------------------------------
# The real browser, found the way the helper finds it: no stub on PATH. The
# screen with the token block must paint its background with the tokens file's
# --color-bg (#123456 in the light theme); without the block the variable is
# empty and the page stays white.
cat > "$T/pixel.py" <<'PY'
import struct, sys, zlib
path, x, y = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
data = open(path, 'rb').read()
if data[:8] != b'\x89PNG\r\n\x1a\n':
    sys.exit('PNG 가 아니다')
pos, idat = 8, b''
w = h = depth = ctype = inter = None
while pos < len(data):
    n, kind = struct.unpack('>I4s', data[pos:pos + 8])
    body = data[pos + 8:pos + 8 + n]
    pos += 12 + n
    if kind == b'IHDR':
        w, h, depth, ctype, _, _, inter = struct.unpack('>IIBBBBB', body)
    elif kind == b'IDAT':
        idat += body
    elif kind == b'IEND':
        break
if depth != 8 or ctype not in (2, 6) or inter != 0:
    sys.exit('읽지 못하는 PNG 형식 (깊이 %s, 색 형식 %s, 비월 %s)' % (depth, ctype, inter))
if not (0 <= x < w and 0 <= y < h):
    sys.exit('좌표가 그림 밖이다 (%dx%d)' % (w, h))
bpp = 3 if ctype == 2 else 4
raw = zlib.decompress(idat)
stride = w * bpp
prev = bytearray(stride)
i = 0
for _ in range(y + 1):
    f = raw[i]
    line = bytearray(raw[i + 1:i + 1 + stride])
    i += 1 + stride
    for k in range(stride):
        a = line[k - bpp] if k >= bpp else 0
        b = prev[k]
        c = prev[k - bpp] if k >= bpp else 0
        if f == 1:
            line[k] = (line[k] + a) & 255
        elif f == 2:
            line[k] = (line[k] + b) & 255
        elif f == 3:
            line[k] = (line[k] + (a + b) // 2) & 255
        elif f == 4:
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            line[k] = (line[k] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 255
    prev = line
print('#%02x%02x%02x' % tuple(prev[x * bpp:x * bpp + 3]))
PY
mkdir -p "$T/real" "$T/real-out"
real_screen() { # <out> <with|without>
  {
    echo '<!doctype html>'
    echo '<html><head>'
    if [ "$2" = with ]; then echo '<style data-cc-tokens>'; cat "$TOKENS"; echo '</style>'; fi
    echo '<style>'
    echo 'html, body { margin: 0; height: 100%; background: var(--color-bg); }'
    echo '</style>'
    echo '</head><body></body></html>'
  } > "$1"
}
real_screen "$T/real/with.html" with
real_screen "$T/real/without.html" without
rc=0; bash "$CHECK" scan "$T/real/with.html" --tokens "$TOKENS" > "$T/real/scan.out" 2>&1 || rc=$?
[ "$rc" = 0 ] && pass "실제 렌더 화면은 visual-check.sh scan --tokens 에서 발견 0" || fail "실제 렌더 화면 scan --tokens = ${rc}: $(grep -vE '^# ' "$T/real/scan.out" | head -n 3)"
# real_pixel <screen> <png name> — capture with the real browser and set PX to
# the pixel at (200,150) of a 400x300 viewport, or to the failure; the suite
# ends with exit 2 when the helper finds no Chrome.
real_pixel() {
  local rc=0
  bash "$CAPTURE" ref "$1" --out "$T/real-out" --size 400x300 --timeout 60 > "$T/real/cap.out" 2>&1 || rc=$?
  if grep -qxF '비교 안 함 — Chrome 없음' "$T/real/cap.out"; then
    echo "test-visual-capture: 실제 Chrome 이 없다 — real render 사례는 건너뛰지 않는다" >&2
    exit 2
  fi
  if [ "$rc" != 0 ]; then
    PX="캡처 실패 ${rc}: $(cat "$T/real/cap.out")"
    return 0
  fi
  mv "$T/real-out/ref.png" "$T/real-out/$2"
  PX=$(python3 -I "$T/pixel.py" "$T/real-out/$2" 200 150 2>&1 || true)
}
real_pixel "$T/real/with.html" with.png
[ "$PX" = '#123456' ] && pass "real render: 토큰 블록을 담은 화면은 배경 토큰 색 (#123456)" || fail "real render: 블록 있는 화면 화소 = ${PX} (기대 #123456)"
real_pixel "$T/real/without.html" without.png
[ "$PX" = '#ffffff' ] && pass "real render: 토큰 블록을 뺀 화면은 흰색 (#ffffff)" || fail "real render: 블록 없는 화면 화소 = ${PX} (기대 #ffffff)"

echo
echo "passed=${passed} failures=${failures}"
[ "$failures" = 0 ] || exit 1
