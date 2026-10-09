#!/usr/bin/env bash
# Test plugins/cc-cmds/orchestrator/notify-focus-ax.swift — the accessibility
# helper the banner click handler compiles on first use.
#
# THE HELPER IS BUILT THE WAY A USER'S MACHINE BUILDS IT: through the handler's
# own `build` verb, into a cache root under the work directory. A pass therefore
# says the compile recipe the handler ships works with the compiler this host
# has, not only that the source compiles under some other spelling.
#
# WHAT IS ASSERTED IS THE EXIT-CODE CONTRACT, AND NOTHING THAT MOVES A WINDOW.
# The handler branches on the helper's status alone, so the statuses are what
# a regression would break. No verb here is pointed at iTerm2: `raise`, `map`
# and `focused` are given this suite's own pid, which answers 3 without
# accessibility trust and 5 with it (not iTerm2) — either way before any window
# is touched. `makekey` asks no trust and answers 5 for that pid.
#
# WHERE THIS RUNS. darwin only. Elsewhere it prints one `SKIP:` line. On darwin
# without a Swift compiler it fails under CI and otherwise skips, because the
# macOS runner always has one and a skip there would hide a broken recipe.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"

passed=0
failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

if [ "$(uname -s)" != Darwin ]; then
  printf 'SKIP: darwin 이 아니다 — 도우미는 macOS 에서만 빌드된다\n'
  printf 'test-notify-focus-ax: 0 passed, 0 failed\n'
  exit 0
fi

# The same existence test the handler makes; the shims are never called.
if [ ! -x /Library/Developer/CommandLineTools/usr/bin/swiftc ] \
   && [ ! -x /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc ]; then
  if [ -n "${CI:-}" ]; then
    bad "컴파일러" "Command Line Tools 와 Xcode 어느 쪽의 swiftc 도 없다"
  else
    printf 'SKIP: Swift 컴파일러가 없다\n'
  fi
  printf 'test-notify-focus-ax: %s passed, %s failed\n' "$passed" "$failed"
  [ "$failed" -eq 0 ]
  exit
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-notify-focus-ax.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

t0=$(date +%s)
env -u CC_CMDS_NOTIFY_FOCUS_AX -u CC_CMDS_NOTIFY_FOCUS_SWIFTC \
  CC_CMDS_NOTIFY_FOCUS_CACHE="$WORK/cache" CC_CMDS_NOTIFY_FOCUS_TRACE="$WORK/trace" \
  bash "$ORCH/notify-focus.sh" build
check "build 동사: 종료 코드 0" "$?" "0"
printf 'build: %s초\n' "$(( $(date +%s) - t0 ))"
HX=$(find "$WORK/cache/helper" -mindepth 2 -maxdepth 2 -name notify-focus-ax -type f -perm -u+x 2>/dev/null | awk 'NR==1')
if [ -z "$HX" ]; then
  bad "도우미가 빌드됐다" "$(find "$WORK/cache/helper" -maxdepth 2 2>/dev/null | tr '\n' ' ')"
  [ -f "$WORK/trace" ] && sed -n '1,20p' "$WORK/trace" >&2
  printf 'test-notify-focus-ax: %s passed, %s failed\n' "$passed" "$failed"
  exit 1
fi
ok "도우미가 빌드됐다"
check "실패 스탬프 없음" "$(find "$WORK/cache/helper" -maxdepth 1 -name '*.failed' | wc -l | tr -d ' ')" "0"
check "빌드 잠금이 풀렸다" "$(find "$WORK/cache/helper" -maxdepth 1 -name '*.lock' | wc -l | tr -d ' ')" "0"

# rc <label> <want…> -- <argv…> — the status must be one of the wanted values.
rc() {
  local label=$1 want=() got w
  shift
  while [ "$1" != "--" ]; do want+=("$1"); shift; done
  shift
  "$@" >"$WORK/out" 2>"$WORK/err"
  got=$?
  for w in "${want[@]}"; do
    if [ "$got" = "$w" ]; then
      ok "$label ($got)"
      return
    fi
  done
  bad "$label" "got $got, want ${want[*]}; $(tr '\n' ' ' < "$WORK/err")"
}

unset CC_CMDS_NOTIFY_FOCUS_AX_MISSING CC_CMDS_NOTIFY_FOCUS_TRACE
rc "동사 없음은 사용법 오류" 2 -- "$HX"
rc "모르는 동사는 사용법 오류" 2 -- "$HX" bogus
rc "raise 에 --ceiling 없음" 2 -- "$HX" raise 1 2
rc "raise 의 pid 가 숫자 아님" 2 -- "$HX" raise x 2 --ceiling 10
rc "map 에 --ceiling 없음" 2 -- "$HX" map 1
rc "onspace 에 인자 없음" 2 -- "$HX" onspace
rc "없는 창의 onspace" 4 -- "$HX" onspace 4294967295
rc "trusted 는 0 또는 3" 0 3 -- "$HX" trusted
rc "iTerm2 가 아닌 pid 의 raise" 3 5 -- "$HX" raise $$ 1 --ceiling 10
rc "iTerm2 가 아닌 pid 의 map" 3 5 -- "$HX" map $$ --ceiling 10
rc "aecheck 는 0 또는 1" 0 1 -- "$HX" aecheck
rc "focused 에 인자 없음" 2 -- "$HX" focused
rc "focused 의 pid 가 숫자 아님" 2 -- "$HX" focused x
rc "makekey 에 인자 하나" 2 -- "$HX" makekey 1
rc "makekey 의 wid 가 숫자 아님" 2 -- "$HX" makekey 1 x
rc "iTerm2 가 아닌 pid 의 focused" 3 5 -- "$HX" focused $$
# makekey asks no trust, so a pid that is not iTerm2 is 5 on every host — and
# not 8, which says the three symbols resolve on this runner.
rc "iTerm2 가 아닌 pid 의 makekey" 5 -- "$HX" makekey $$ 1
# --focus takes no value: it is not a usage error on raise, and stays an
# unknown option on map.
rc "값 없는 --focus 를 붙인 raise" 3 5 -- "$HX" raise $$ 1 --focus --ceiling 10
rc "map 의 --focus 는 사용법 오류" 2 -- "$HX" map $$ --focus --ceiling 10

# The missing-symbol seam: the check runs before trust, so the status is 8
# whatever this host has granted.
rc "raise 의 심볼이 없으면 8" 8 -- env CC_CMDS_NOTIFY_FOCUS_AX_MISSING=_AXUIElementGetWindow "$HX" raise $$ 1 --ceiling 10
rc "map 의 심볼이 없으면 8" 8 -- env CC_CMDS_NOTIFY_FOCUS_AX_MISSING=_AXUIElementCreateWithRemoteToken "$HX" map $$ --ceiling 10
rc "onspace 의 심볼이 없으면 8" 8 -- env CC_CMDS_NOTIFY_FOCUS_AX_MISSING=CGSCopySpacesForWindows "$HX" onspace 1
rc "연결 심볼이 없으면 8" 8 -- env CC_CMDS_NOTIFY_FOCUS_AX_MISSING=CGSMainConnectionID "$HX" onspace 1
rc "focused 의 심볼이 없으면 8" 8 -- env CC_CMDS_NOTIFY_FOCUS_AX_MISSING=_AXUIElementGetWindow "$HX" focused $$
for sym in _SLPSSetFrontProcessWithOptions SLPSPostEventRecordTo GetProcessForPID; do
  rc "makekey 의 $sym 이 없으면 8" 8 -- env CC_CMDS_NOTIFY_FOCUS_AX_MISSING=$sym "$HX" makekey $$ 1
done

# The trace goes to stderr only when asked for, and never to stdout.
CC_CMDS_NOTIFY_FOCUS_TRACE=1 "$HX" onspace 4294967295 >"$WORK/out" 2>"$WORK/err"
check "추적 켬: 표준 출력 0 바이트" "$(wc -c < "$WORK/out" | tr -d ' ')" "0"
check "추적 켬: 표준 오류에 줄이 있다" "$([ -s "$WORK/err" ] && echo 있음 || echo 없음)" "있음"
"$HX" onspace 4294967295 >"$WORK/out" 2>"$WORK/err"
check "추적 끔: 표준 오류 0 바이트" "$(wc -c < "$WORK/err" | tr -d ' ')" "0"

printf 'test-notify-focus-ax: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
