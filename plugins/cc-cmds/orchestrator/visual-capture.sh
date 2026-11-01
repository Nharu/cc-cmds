#!/usr/bin/env bash
# Headless Chrome screenshots for the visual design skills.
#
# Subcommands:
#   ref <screen.html> --out <dir> [--size WxH] [--timeout <seconds>]
#       Capture the screen file over `file://` into <dir>/ref.png. The path in
#       the URL is percent-encoded byte by byte: ASCII letters, digits and
#       `/ . _ - ~` stay, every other byte (a Hangul byte included) becomes
#       `%XX` with upper-case hex, so a `#`, `?`, `%` or space in a directory
#       name is part of the path and not a fragment, query or broken URL.
#   app --root <dir> --out <dir> [--size WxH] [--timeout <seconds>]
#       Serve <dir> on a loopback-only static server on a free port, capture
#       http://127.0.0.1:<port>/index.html into <dir>/app.png, then stop the
#       server.
#
# Chrome always runs with the same fixed argv: headless, device scale 1, a
# throwaway profile, and every outside fetch sent to a closed local proxy
# (`--proxy-server=127.0.0.1:9`), so a screen that reaches outside fails fast
# instead of loading — or never settling. The loopback capture of `app` is not
# proxied (Chrome bypasses the proxy for 127.0.0.1). Chrome does not always
# exit by itself, so the helper keeps its own time limit and kills the browser
# and everything still holding the throwaway profile.
#
# --out must be an existing directory outside every git tree: the screenshots
# are evidence for one comparison, never a file of the repository.
#
# Chrome is looked up as google-chrome, chromium, chromium-browser, chrome on
# PATH, in that order, then at the macOS application path.
#
# Output: `찍음 <png path>` on success (and `서버 127.0.0.1:<port>` for app);
# otherwise `비교 안 함 — <reason>`.
#
# Exit codes:
#   0 — captured
#   1 — not compared (no Chrome, no python3, no index.html, Chrome failed or
#       timed out, no screenshot written)
#   2 — usage error
#
# Compatibility: bash 3.2 (macOS); BSD and GNU userland alike.

set -euo pipefail

readonly MAC_CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

usage() {
  echo "사용법: visual-capture.sh ref <화면.html> --out <디렉터리> [--size WxH] [--timeout 초] | app --root <디렉터리> --out <디렉터리> [--size WxH] [--timeout 초]" >&2
  exit 2
}

not_compared() {
  echo "비교 안 함 — $1"
  exit 1
}

find_chrome() {
  local n
  for n in google-chrome chromium chromium-browser chrome; do
    if command -v "$n" >/dev/null 2>&1; then
      command -v "$n"
      return 0
    fi
  done
  if [ -x "$MAC_CHROME" ]; then
    printf '%s\n' "$MAC_CHROME"
    return 0
  fi
  return 1
}

PROFILE=''
CHROME_PID=''
SERVER_PID=''
SERVER_LOG=''

cleanup() {
  if [ -n "$CHROME_PID" ]; then
    kill -TERM "$CHROME_PID" 2>/dev/null || true
    kill -KILL "$CHROME_PID" 2>/dev/null || true
  fi
  if [ -n "$PROFILE" ]; then
    pkill -KILL -f -- "$PROFILE" 2>/dev/null || true
    rm -rf "$PROFILE"
  fi
  if [ -n "$SERVER_PID" ]; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  [ -z "$SERVER_LOG" ] || rm -f "$SERVER_LOG"
}
trap cleanup EXIT

# run_chrome <chrome> <url> <png> <W,H> <timeout seconds>
run_chrome() {
  local chrome=$1 url=$2 png=$3 size=$4 limit=$5 ticks max rc
  PROFILE=$(mktemp -d "${TMPDIR:-/tmp}/visual-capture-profile.XXXXXX")
  rm -f "$png"
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    "--window-size=${size}" --proxy-server=127.0.0.1:9 --no-first-run \
    --disable-background-networking --disable-component-update --disable-sync \
    "--user-data-dir=${PROFILE}" "--screenshot=${png}" "$url" >/dev/null 2>&1 &
  CHROME_PID=$!
  ticks=0
  max=$((limit * 5))
  while kill -0 "$CHROME_PID" 2>/dev/null; do
    if [ "$ticks" -ge "$max" ]; then
      kill -TERM "$CHROME_PID" 2>/dev/null || true
      sleep 0.5
      kill -KILL "$CHROME_PID" 2>/dev/null || true
      pkill -KILL -f -- "$PROFILE" 2>/dev/null || true
      wait "$CHROME_PID" 2>/dev/null || true
      CHROME_PID=''
      if [ -s "$png" ]; then
        return 0
      fi
      not_compared "Chrome 이 ${limit}초 안에 끝나지 않아 멈췄다"
    fi
    sleep 0.2
    ticks=$((ticks + 1))
  done
  rc=0
  wait "$CHROME_PID" 2>/dev/null || rc=$?
  CHROME_PID=''
  pkill -KILL -f -- "$PROFILE" 2>/dev/null || true
  [ -s "$png" ] || not_compared "Chrome 이 스크린숏을 쓰지 않았다 (종료 ${rc})"
}

check_out() {
  [ -d "$1" ] || { echo "visual-capture.sh: --out 디렉터리가 없다: $1" >&2; exit 2; }
  if (cd "$1" && git rev-parse --git-dir >/dev/null 2>&1); then
    echo "visual-capture.sh: --out 은 git 트리 밖이어야 한다: $1" >&2
    exit 2
  fi
  (cd "$1" && pwd -P)
}

parse_size() {
  printf '%s' "$1" | grep -qE '^[1-9][0-9]*x[1-9][0-9]*$' \
    || { echo "visual-capture.sh: --size 는 WxH 꼴이어야 한다: $1" >&2; exit 2; }
  printf '%s' "$1" | tr x ,
}

parse_timeout() {
  printf '%s' "$1" | grep -qE '^[1-9][0-9]*$' \
    || { echo "visual-capture.sh: --timeout 은 양의 정수(초)여야 한다: $1" >&2; exit 2; }
  printf '%s' "$1"
}

# url_path <path> — the path percent-encoded for a file:// URL. The bytes are
# read with od under the C locale, so a multi-byte character is encoded byte by
# byte whatever the caller's locale.
url_path() {
  printf '%s' "$1" | LC_ALL=C od -An -v -tx1 | LC_ALL=C awk '
    BEGIN { hx = "0123456789abcdef" }
    {
      for (i = 1; i <= NF; i++) {
        h = tolower($i)
        n = (index(hx, substr(h, 1, 1)) - 1) * 16 + index(hx, substr(h, 2, 1)) - 1
        if ((n >= 48 && n <= 57) || (n >= 65 && n <= 90) || (n >= 97 && n <= 122) \
            || n == 47 || n == 46 || n == 95 || n == 45 || n == 126)
          printf "%c", n
        else
          printf "%%%s", toupper(h)
      }
    }
  '
}

cmd_ref() {
  local screen='' out='' size=1440x900 limit=60 chrome dir png
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) [ $# -ge 2 ] || usage; out=$2; shift 2 ;;
      --size) [ $# -ge 2 ] || usage; size=$2; shift 2 ;;
      --timeout) [ $# -ge 2 ] || usage; limit=$2; shift 2 ;;
      --*) usage ;;
      *) [ -z "$screen" ] || usage; screen=$1; shift ;;
    esac
  done
  [ -n "$screen" ] && [ -n "$out" ] || usage
  [ -f "$screen" ] || { echo "visual-capture.sh ref: 화면 파일이 없다: $screen" >&2; exit 2; }
  size=$(parse_size "$size")
  limit=$(parse_timeout "$limit")
  out=$(check_out "$out")
  chrome=$(find_chrome) || not_compared "Chrome 없음"
  dir=$(cd "$(dirname "$screen")" && pwd -P)
  png="$out/ref.png"
  run_chrome "$chrome" "file://$(url_path "${dir}/$(basename "$screen")")" "$png" "$size" "$limit"
  echo "찍음 ${png}"
}

cmd_app() {
  local root='' out='' size=1440x900 limit=60 chrome png port ticks
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || usage; root=$2; shift 2 ;;
      --out) [ $# -ge 2 ] || usage; out=$2; shift 2 ;;
      --size) [ $# -ge 2 ] || usage; size=$2; shift 2 ;;
      --timeout) [ $# -ge 2 ] || usage; limit=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$root" ] && [ -n "$out" ] || usage
  [ -d "$root" ] || { echo "visual-capture.sh app: --root 디렉터리가 없다: $root" >&2; exit 2; }
  size=$(parse_size "$size")
  limit=$(parse_timeout "$limit")
  out=$(check_out "$out")
  [ -f "$root/index.html" ] || not_compared "--root 에 index.html 이 없다"
  command -v python3 >/dev/null 2>&1 || not_compared "python3 이 없어 루프백 서버를 띄울 수 없다"
  chrome=$(find_chrome) || not_compared "Chrome 없음"
  root=$(cd "$root" && pwd -P)

  SERVER_LOG=$(mktemp "${TMPDIR:-/tmp}/visual-capture-server.XXXXXX")
  python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$root" > "$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  port=''
  ticks=0
  while [ -z "$port" ]; do
    port=$(sed -nE 's/^Serving HTTP on [^ ]+ port ([0-9]+).*$/\1/p' "$SERVER_LOG" | head -n 1)
    [ -n "$port" ] && break
    kill -0 "$SERVER_PID" 2>/dev/null || not_compared "루프백 서버가 뜨지 않았다"
    [ "$ticks" -lt 50 ] || not_compared "루프백 서버가 10초 안에 포트를 알리지 않았다"
    sleep 0.2
    ticks=$((ticks + 1))
  done

  png="$out/app.png"
  run_chrome "$chrome" "http://127.0.0.1:${port}/index.html" "$png" "$size" "$limit"
  kill -TERM "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=''
  echo "서버 127.0.0.1:${port}"
  echo "찍음 ${png}"
}

[ $# -ge 1 ] || usage
sub=$1
shift
case "$sub" in
  ref) cmd_ref "$@" ;;
  app) cmd_app "$@" ;;
  *) usage ;;
esac
