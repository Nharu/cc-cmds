#!/usr/bin/env bash
# single mode + fire-now invocation in turn slice → Stop hook MUST silent-
# exit (turn_slice dedup). Avoids double banner from fire-now + Stop-hook
# turn-end fire. Flag presence here is illustrative — in real life single
# mode is consumed by fire-now; the hook's silent exit must not depend on
# flag presence (Rule 2 still passes, marker_bypass uninvolved).
set -euo pipefail

flag_file="$FLAG_DIR/pending-test-dedup-after-fire-now-single.flag"
printf '{"schema":2,"armed_at":1700000000,"session_id":"test-dedup-after-fire-now-single","request_text":"빌드 끝나면 알림","context_hint":"build","mode":"single","milestone":"빌드","fire_count":0,"last_fire_at":null}\n' > "$flag_file"

"$STOP_HOOK_SH" < "$HOOK_INPUT" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

if [[ -s "$NOTIFIER_LOG" ]]; then
  echo "FAIL: Stop hook fired despite fire-now dedup (double banner)"
  cat "$NOTIFIER_LOG" >&2
  exit 1
fi

exit 0
