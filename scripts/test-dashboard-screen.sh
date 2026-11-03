#!/usr/bin/env bash
# lint-bash-portability: self-skip
# The run dashboard's screen: the three static files the server hands out, read
# as text, and the two page routes served by a `preview` server over a fixture
# root.
#
# The server sends `Content-Security-Policy: default-src 'self'`, so the screen
# builds every node with DOM calls and loads nothing from outside. The static
# cases below hold that from the file side: a pattern the policy would refuse,
# or an address outside the page, fails here before a browser ever sees it.
#
# THE PREVIEW SERVER THIS SUITE STARTS IS STOPPED. `preview` writes no server
# record, so the exit trap stops it by the pid this suite holds.
#
# Usage: bash scripts/test-dashboard-screen.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"
DASH="$ORCH/dashboard.py"
SCREEN="$ORCH/dashboard"
. "$repo_root/scripts/run-fixture.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-dashboard-screen.XXXXXX")
XDG_STATE_HOME="$WORK/state"
export XDG_STATE_HOME
mkdir -p "$XDG_STATE_HOME/cc-cmds/run"

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

if ! command -v python3 >/dev/null 2>&1; then
  bad "python3" "python3 를 찾지 못했다 — 이 스위트는 한 줄도 돌 수 없다"
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  bad "curl" "curl 을 찾지 못했다 — 페이지 경로를 잴 수 없다"
  exit 1
fi

pyq() { PYTHONDONTWRITEBYTECODE=1 python3 "$@"; }

wait_gone() {
  local i=0
  while [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
}
free_port() {
  pyq -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}
cleanup() {
  [ -n "${PREVIEW_PID:-}" ] && kill "$PREVIEW_PID" 2>/dev/null
  fx_reap
  rm -rf "$WORK"
}
trap cleanup EXIT

get() {
  # get <port> <path> — status code on stdout, body in $WORK/body.
  curl -s --path-as-is -o "$WORK/body" -w '%{http_code}' --max-time 10 \
    -H 'X-CC-Poll: 1' "http://127.0.0.1:$1$2"
}

# hits <fixed-string> <file…> — how many lines of those files carry the string.
hits() {
  local needle="$1"; shift
  { grep -F -h -- "$needle" "$@" 2>/dev/null || true; } | wc -l | tr -d ' '
}

FILES=("$SCREEN/index.html" "$SCREEN/app.js" "$SCREEN/app.css")
for f in "${FILES[@]}"; do
  [ -s "$f" ] || bad "정적 파일 ${f##*/}" "비었거나 없다"
done

# ---------------------------------------------------------------------------
# S1 — nothing the policy refuses, comments included.
# ---------------------------------------------------------------------------
for pat in 'style=' '<style' 'innerHTML' 'insertAdjacentHTML' 'eval('; do
  for f in "${FILES[@]}"; do
    check "S1 ${f##*/} 에 '$pat' 이 없다" "$(hits "$pat" "$f")" "0"
  done
done

# ---------------------------------------------------------------------------
# S2 — the light theme only.
# ---------------------------------------------------------------------------
check "S2 app.css 에 prefers-color-scheme 이 없다" "$(hits 'prefers-color-scheme' "$SCREEN/app.css")" "0"

# ---------------------------------------------------------------------------
# S3 — no address outside the page; app.js holds the SVG namespace alone.
# ---------------------------------------------------------------------------
for f in "$SCREEN/index.html" "$SCREEN/app.css"; do
  check "S3 ${f##*/} 에 http:// 가 없다" "$(hits 'http://' "$f")" "0"
  check "S3 ${f##*/} 에 https:// 가 없다" "$(hits 'https://' "$f")" "0"
done
check "S3 app.js 에 https:// 가 없다" "$(hits 'https://' "$SCREEN/app.js")" "0"
check "S3 app.js 의 http:// 는 SVG 이름공간 상수 하나뿐이다" \
  "$(pyq -c 'import re,sys
t=open(sys.argv[1],encoding="utf-8").read()
print(" ".join(m.group(0) for m in re.finditer(r"http://[^\"'"'"'\s)]*", t)))' "$SCREEN/app.js")" \
  "http://www.w3.org/2000/svg"

# ---------------------------------------------------------------------------
# S4 — a preview server over a fixture root serves index.html on both routes.
# ---------------------------------------------------------------------------
fx_mkrun screen-run; fx_ledger_path; fx_segment S1 실행중
PP=$(free_port)
env -u CI -u CC_PIPELINE_SEGMENT -u CC_PIPELINE_STAGE_ID XDG_STATE_HOME="$XDG_STATE_HOME" \
  PYTHONDONTWRITEBYTECODE=1 python3 "$DASH" preview --port "$PP" 2>"$WORK/preview.err" &
PREVIEW_PID=$!
i=0
while [ "$i" -lt 50 ] && [ "$(get "$PP" /healthz)" != "200" ]; do sleep 0.1; i=$((i + 1)); done
check "S4 preview 가 /healthz 에 답한다" "$(get "$PP" /healthz)" "200"
for path in / /run/screen-run; do
  check "S4 $path 가 200 이다" "$(get "$PP" "$path")" "200"
  check "S4 $path 의 본문이 index.html 이다" \
    "$(cmp -s "$WORK/body" "$SCREEN/index.html" && printf 같음 || printf 다름)" "같음"
done
kill "$PREVIEW_PID" 2>/dev/null
wait_gone "$PREVIEW_PID"
PREVIEW_PID=""

printf '\ntest-dashboard-screen: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
