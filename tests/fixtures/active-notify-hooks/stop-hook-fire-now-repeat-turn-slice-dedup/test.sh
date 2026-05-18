#!/usr/bin/env bash
# repeat mode + fire-now invocation → Stop hook silent-exit (turn_slice
# dedup). In real life, repeat-mode fire-now would silent no-op because
# repeat ARM never carries a milestone — this is the §3.3 invocation-
# presence seam (acknowledged trade-off). The dedup logic is checked here
# independent of fire-now's actual execution path.
set -euo pipefail

flag_file="$FLAG_DIR/pending-test-fire-now-repeat-dedup.flag"
printf '{"schema":2,"armed_at":1700000000,"session_id":"test-fire-now-repeat-dedup","request_text":"매번 알려줘","context_hint":"loop","mode":"repeat","milestone":"","fire_count":0,"last_fire_at":null}\n' > "$flag_file"

"$STOP_HOOK_SH" < "$HOOK_INPUT" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

if [[ -s "$NOTIFIER_LOG" ]]; then
  echo "FAIL: Stop hook fired despite fire-now dedup"
  cat "$NOTIFIER_LOG" >&2
  exit 1
fi

exit 0
