#!/usr/bin/env bash
# lint-notify-fire-sites: self-skip
# Pin the shape the seat guard depends on: the notifier is launched from exactly
# two lines, and both of them are inside the shared emitter's fire function.
#
# WHY THIS EXISTS AT ALL. Reclaiming a stacking slot needs no caller guard —
# it erases a line in a file and delivers nothing to anybody — while CLEARING a
# banner does, because it changes what is on a person's screen right now. The
# proposal to put a defensive guard on the reclaim site too was rejected on the
# ground that it would kill the guard's value as a marker: every guarded site
# today shares the property of handing an event to a person, and adding one to a
# site that hands over nothing means the next reader can no longer tell the two
# kinds apart. This lint is the compensating control accepted in its place. If
# it is absent, the guard-copying proposal was rejected for nothing and a banner
# clear can be added outside the emitter, with no guard, and nothing objects.
#
# THE SCOPE IS THE ORCHESTRATOR, deliberately, and not the whole tree. The
# notification helper skill is a separate dispatcher that stays as it is, so a
# tree-wide count would be measuring two unrelated systems as one.
#
# Rules:
#   1  exactly two lines in the orchestrator EXECUTE the notifier         [fail]
#   2  both of them are in the emitter file                               [fail]
#   3  both of them come after the fire function opens                    [fail]
#
# The existence probe (`command -v terminal-notifier`) is excluded: it launches
# nothing. Everything else that names the binary counts, and the check is NOT
# narrowed to lines carrying `-title` — narrowing that way would make a banner
# CLEAR (`-remove`) structurally invisible, and a clear arriving without a seat
# guard is precisely the thing this lint was put here to catch.
#
# Rule 3 is spelled as "after the fire function opens" rather than "inside its
# braces" because the fire function is the last in the file, which makes the two
# the same statement and the former needs no brace matching.
#
# Usage:
#   bash scripts/lint-notify-fire-sites.sh
#
# Env overrides (fixture runner):
#   ORCH_ROOT=<dir>   # directory holding the orchestrator's shell files
#
# Posture: if the emitter is absent the whole check is a silent skip, so the
# script stays green during an incremental rollout.
#
# Exit codes:
#   0 — pass (or skipped)
#   1 — at least one violation
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
orch_root="${ORCH_ROOT:-$repo_root/plugins/cc-cmds/orchestrator}"
EMITTER_NAME="notify-run.sh"
FIRE_FN="cc_notify_fire() {"

if [ ! -f "$orch_root/$EMITTER_NAME" ]; then
  echo "SKIP: $EMITTER_NAME not found under $orch_root — banner emitter not present"
  exit 0
fi

fail=0

# Comment-stripped, so the prose above and the design notes beside the call
# sites are not counted as call sites themselves.
sites=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  hits=$(sed 's/#.*//' "$f" 2>/dev/null \
         | grep -n 'terminal-notifier' \
         | grep -v 'command -v' || true)
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    sites="${sites}$(basename "$f"):${h%%:*}
"
  done <<EOF
$hits
EOF
done <<EOF
$(find "$orch_root" -type f -name '*.sh' 2>/dev/null | sort || true)
EOF

n=$(printf '%s' "$sites" | grep -c . || true)
if [ "${n:-0}" != "2" ]; then
  echo "FAIL: 오케스트레이터에서 발사기를 실행하는 줄이 ${n:-0}개 (기대 2개)" >&2
  echo "       찾은 것: $(printf '%s' "$sites" | tr '\n' ' ')" >&2
  fail=1
fi

fire_line=$(grep -nF "$FIRE_FN" "$orch_root/$EMITTER_NAME" | sed -n '1p' | cut -d: -f1)
if [ -z "$fire_line" ]; then
  echo "FAIL: ${EMITTER_NAME} 에서 발사 함수 「${FIRE_FN}」 를 찾지 못했다" >&2
  fail=1
fi

while IFS= read -r s; do
  [ -n "$s" ] || continue
  case "${s%%:*}" in
    "$EMITTER_NAME") : ;;
    *)
      echo "FAIL: 발사기를 부르는 줄이 emitter 밖에 있다: $s" >&2
      echo "       배너를 올리거나 지우는 일은 좌석 가드가 붙은 자리에서만 한다" >&2
      fail=1
      continue ;;
  esac
  if [ -n "$fire_line" ] && [ "${s##*:}" -lt "$fire_line" ]; then
    echo "FAIL: 발사기를 부르는 줄이 발사 함수 밖에 있다: $s (함수 시작 $fire_line)" >&2
    fail=1
  fi
done <<EOF
$sites
EOF

if [ "$fail" != "0" ]; then
  echo "lint-notify-fire-sites: violations found" >&2
  exit 1
fi

echo "OK:   notify fire sites — 발사기를 부르는 줄은 정확히 둘이고 둘 다 emitter 의 발사 함수 안이다"
exit 0
