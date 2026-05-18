#!/usr/bin/env bash
# Marker scrape happy path: generic ARM (milestone empty), non-AskUserQuestion
# terminal, marker emitted in assistant text block → fires with marker copy
# instead of binary fallback. Verifies §1.2 marker scrape + §4.2 summary/
# workflow priority overrides.
set -euo pipefail

flag_file="$FLAG_DIR/pending-test-marker-present-happy-path.flag"
printf '{"schema":2,"armed_at":1700000000,"session_id":"test-marker-present-happy-path","request_text":"빌드 끝나면 알려줘","context_hint":"build","mode":"single","milestone":"","fire_count":0,"last_fire_at":null}\n' > "$flag_file"

"$STOP_HOOK_SH" < "$HOOK_INPUT" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

if [[ ! -s "$NOTIFIER_LOG" ]]; then
  echo "FAIL: terminal-notifier was NOT invoked (Rule 2 should pass + marker should override)" >&2
  cat "$HOOK_STDERR" >&2 || true
  exit 1
fi

# Marker workflow ("빌드") MUST override Bash fallback ("npm")
grep -q -- '-title \[cc-cmds\] 빌드' "$NOTIFIER_LOG" || {
  echo "FAIL: banner workflow should be marker value '빌드', got:" >&2
  cat "$NOTIFIER_LOG" >&2
  exit 1
}

# Marker summary MUST override binary fallback
grep -q -- '-message 빌드 성공: 0 errors 12 warnings' "$NOTIFIER_LOG" || {
  echo "FAIL: banner summary should be marker value, got:" >&2
  cat "$NOTIFIER_LOG" >&2
  exit 1
}

exit 0
